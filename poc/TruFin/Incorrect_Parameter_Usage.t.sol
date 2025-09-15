// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {TruStakeMATICv2} from "../../contracts/main/TruStakeMATICv2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// ------------------------------------------------------------------------
/// Whitelist stub that approves everyone
/// ------------------------------------------------------------------------
contract WhitelistAlwaysTrue {
    function isUserWhitelisted(address) external pure returns (bool) {
        return true;
    }
}

/// @notice Faithful subset of Polygon PoS ValidatorShare logic (just what we need):
/// - ERC20-like "shares" (internal only)
/// - buyVoucher() mints shares based on current exchange rate and REVERTS if shares < minSharesToMint
/// - sellVoucher_new() burns shares for stake
/// - getTotalStake(user) = userShares * exchangeRate / RATE_PRECISION (like Polygon)
/// - compoundRewards() simulates validator rewards
contract ValidatorShareLite {
    // Change to 1e18 so rate/units align with vault expectations
    uint256 private constant RATE_PRECISION = 1e18;

    ERC20Mock public stakeToken;

    mapping(address => uint256) private _shares;
    uint256 private _totalShares;
    uint256 private _totalStake;

    constructor(address _stakeToken) {
        stakeToken = ERC20Mock(_stakeToken);
    }

    // --- Views ---
    function exchangeRate() public view returns (uint256) {
        if (_totalShares == 0) return RATE_PRECISION; // 1e18 at genesis
        // rate = totalStake / totalShares, scaled by 1e18
        return (_totalStake * RATE_PRECISION) / _totalShares;
    }

    function getExchangeRate() external view returns (uint256) {
        return exchangeRate(); // returns 1e18 at genesis
    }

    function balanceOf(address user) external view returns (uint256) {
        return _shares[user];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function totalStake() external view returns (uint256) {
        return _totalStake;
    }

    function getTotalStake(address user) external view returns (uint256) {
        return (_shares[user] * exchangeRate()) / RATE_PRECISION;
    }

    // --- Core ---
    function buyVoucher(uint256 amount, uint256 minSharesToMint) external payable returns (uint256) {
        uint256 rate = exchangeRate();
        uint256 sharesToMint = (amount * 1e18) / rate;
        // Fail fast on slippage BEFORE any token transfer, matching how many production routers/validators
        // do slippage checks prior to moving funds.
        require(sharesToMint >= minSharesToMint, "INSUFFICIENT_SHARES");
        if (amount > 0) {
            require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull fail");
        }

        _totalStake += amount;
        _totalShares += sharesToMint;
        _shares[msg.sender] += sharesToMint;

        // return value the vault expects (Polygon returns amountToDeposit)
        return amount;
    }

    function sellVoucher_new(uint256 claimAmount, uint256 maxSharesToBurn) external {
        uint256 rate = exchangeRate();
        uint256 requiredShares = (claimAmount * RATE_PRECISION) / rate;

        require(requiredShares <= _shares[msg.sender], "INSUFFICIENT_BAL");
        require(requiredShares <= maxSharesToBurn, "SLIPPAGE");

        _shares[msg.sender] -= requiredShares;
        _totalShares -= requiredShares;
        require(_totalStake >= claimAmount, "STAKE_UNDERFLOW");
        _totalStake -= claimAmount;
    }

    // --- Rewards simulation ---
    function compoundRewards(uint256 rewardAmount) external payable {
        if (msg.value > 0) {
            require(rewardAmount == msg.value, "reward != msg.value");
        }
        _totalStake += rewardAmount; // shares unchanged → rate increases
    }

    // --- Shims ---
    function getLiquidRewards(address) external pure returns (uint256) {
        return 0;
    }

    function withdrawRewards() external pure returns (uint256) {
        return 0;
    }

    function restake() external {}
}

/// ------------------------------------------------------------------------
/// Foundry test
/// ------------------------------------------------------------------------
contract Matic_SimpleDepositTest is Test {
    TruStakeMATICv2 public vault; // proxy address cast to the logic type
    TruStakeMATICv2 public impl; // implementation (not used after deploy)
    ERC20Mock public tMATIC;
    ValidatorShareLite public validator;
    WhitelistAlwaysTrue public whitelist;

    address public VALIDATOR;
    address public TREASURY = address(0x7777);
    address public ALICE = address(0xA11CE);
    address public BOB = address(0xB0B);

    function setUp() public {
        // --- Deploy mocks ---
        tMATIC = new ERC20Mock();
        whitelist = new WhitelistAlwaysTrue();

        // Our faithful-lite Polygon validator
        validator = new ValidatorShareLite(address(tMATIC));
        VALIDATOR = address(validator);

        // --- Deploy vault implementation + initialize via proxy ---
        impl = new TruStakeMATICv2();

        bytes memory initCalldata = abi.encodeCall(
            TruStakeMATICv2.initialize,
            (
                address(tMATIC),
                address(this), // stakeManager, which we do not use
                VALIDATOR,
                address(whitelist),
                TREASURY,
                uint256(0), // phi
                uint256(0) // distPhi
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initCalldata);
        vault = TruStakeMATICv2(address(proxy));

        // --- Allow the validator to pull tMATIC from the vault ---
        // (On real Polygon the StakeManager is the spender; in our slim harness the validator pulls directly.)
        vm.prank(address(vault));
        tMATIC.approve(VALIDATOR, type(uint256).max);
    }

    function test_DepositHappy() public {
        uint256 amount = 100 ether;

        // fund + approve
        tMATIC.mint(ALICE, amount);
        vm.startPrank(ALICE);
        tMATIC.approve(address(vault), amount);

        // deposit
        vault.depositToSpecificValidator(amount, VALIDATOR);
        vm.stopPrank();

        // checks (realistic flow: tokens moved from vault to validator in buyVoucher)
        assertGt(vault.balanceOf(ALICE), 0, "ALICE should have vault shares");
        assertEq(tMATIC.balanceOf(address(vault)), 0, "vault should NOT hold underlying after deposit");
        assertEq(tMATIC.balanceOf(VALIDATOR), amount, "validator should hold the staked underlying");
        assertEq(vault.totalStaked(), amount, "totalStaked should equal deposit (rate==1)");
    }

    function test_DepositReverts_AfterRateUp() public {
        uint256 amt = 100 ether;

        // FIRST deposit at rate == 1 → PASS
        tMATIC.mint(ALICE, amt);
        vm.startPrank(ALICE);
        tMATIC.approve(address(vault), amt);
        vault.depositToSpecificValidator(amt, address(validator));
        vm.stopPrank();

        // Push exchange rate above 1
        uint256 reward = validator.totalStake() / 100; // for ~1%
        validator.compoundRewards(reward);

        // SECOND deposit REVERTs in validator’s minShares check
        tMATIC.mint(BOB, amt);
        vm.startPrank(BOB);
        tMATIC.approve(address(vault), amt);
        vm.expectRevert(bytes("INSUFFICIENT_SHARES"));
        vault.depositToSpecificValidator(amt, address(validator));
        vm.stopPrank();
    }
}
