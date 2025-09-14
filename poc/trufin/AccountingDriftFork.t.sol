// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

// Your interfaces & vault
import {IStakeManager} from "../../contracts/interfaces/IStakeManager.sol";
import {IValidatorShare} from "../../contracts/interfaces/IValidatorShare.sol";
import {TruStakeMATICv2} from "../../contracts/main/TruStakeMATICv2.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Test-only reader for StakeManager (TruFin IStakeManager doesn't expose)
interface IStakeManagerLike {
    function getValidatorContract(uint256 validatorId) external view returns (address);

    function validators(uint256)
        external
        view
        returns (
            uint256 amount,
            uint256 reward,
            uint256 activationEpoch,
            uint256 deactivationEpoch,
            uint256 jailTime,
            address signer,
            address contractAddress,
            uint256 status,
            uint256 commissionRate,
            uint256 lastCommissionUpdate,
            uint256 delegatorsReward, // <-- index 10
            uint256 delegatedAmount,
            uint256 initialRewardPerStake
        );

    function getValidatorShareAddress() external view returns (address);
}

interface IValidatorShareLike {
    function withdrawRewards() external;
    function exchangeRate() external view returns (uint256);
}

interface IValShare {
    function getTotalStake(address user) external view returns (uint256);
    function unbondNonces(address user) external view returns (uint256);
}

// Minimal whitelist mock used by the vault
interface IWhitelist {
    function isUserWhitelisted(address) external view returns (bool);
}

contract MockWhitelist is IWhitelist {
    function isUserWhitelisted(address) external pure returns (bool) {
        return true;
    }
}

contract AccountingDriftForkTest is Test {
    using stdStorage for StdStorage;

    address constant STAKE_MANAGER_PROXY = 0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908;
    address constant MATIC_ERC20 = 0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0;

    address alice;
    address bob;
    uint256 constant INITIAL_DEPOST = 100 ether;
    uint256 constant DELEGATOR_REWARD = 1 ether;
    uint256 constant SECOND_DEPOSIT = 1 ether;
    uint256 constant BUY_AMOUNT = 1 ether;
    TruStakeMATICv2 vault;

    uint256 validatorId = 8; // an ID that is not "locked"
    address validatorShare;

    function setUp() public {
        // use env RPC and a fixed block number
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 23341747);

        alice = makeAddr("ALICE");
        deal(MATIC_ERC20, alice, 1_000e18);

        bob = makeAddr("BOB");
        deal(MATIC_ERC20, bob, 1_000e18);

        // Deploy whitelist + treasury + implementation
        address treasury = makeAddr("TREASURY");
        MockWhitelist whitelist = new MockWhitelist();
        TruStakeMATICv2 impl = new TruStakeMATICv2();

        // Resolve a working validator share
        IStakeManagerLike sm = IStakeManagerLike(STAKE_MANAGER_PROXY);
        validatorShare = sm.getValidatorContract(validatorId);
        //console2.log("validatorShare", validatorShare);

        // Initialize via proxy
        bytes memory initData = abi.encodeWithSelector(
            TruStakeMATICv2.initialize.selector,
            MATIC_ERC20,
            STAKE_MANAGER_PROXY,
            validatorShare,
            address(whitelist),
            treasury,
            uint256(0), // _phi
            uint256(0) // _distPhi
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = TruStakeMATICv2(address(proxy));
    }

    function test_DepositViaVault_Happy() public {
        // visible amount
        uint256 amount = 100e18;

        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amount);
        vault.deposit(amount); // your real deposit path
        vm.stopPrank();

        // Sanity
        assertEq(IERC20(MATIC_ERC20).balanceOf(alice), 900e18, "Alice should spend 100 MATIC");
    }

    // function test_Drift_AfterDelegatorsReward() public {
    //     // 1) Baseline: deposit via the vault
    //     vm.startPrank(alice);
    //     IERC20(MATIC_ERC20).approve(address(vault), INITIAL_DEPOST);
    //     vault.depositToSpecificValidator(INITIAL_DEPOST, validatorShare);
    //     vm.stopPrank();

    //     (uint256 st0,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     (, uint256 s0,,) = vault.validators(validatorShare);
    //     uint256 liq0 = IValidatorShare(validatorShare).getLiquidRewards(address(vault));

    //     console2.log("=== Baseline after vault deposit ===");
    //     console2.log("stake (validator truth)", st0);
    //     console2.log("liquid (validator)", liq0);
    //     console2.log("acct  (vault)", s0);
    //     console2.log("truth (= stake + liquid)", st0 + liq0);
    //     console2.log("drift (truth - acct)", st0 + liq0 - s0);

    //     assertEq(st0, s0, "pre: acct==truth"); // no rewards yet

    //     // 2) Find the exact slot for validators[vid].delegatorsReward (field index 10)
    //     uint256 snap = vm.snapshot();
    //     uint256 slotU = stdstore.target(STAKE_MANAGER_PROXY).sig(IStakeManagerLike.validators.selector).with_key(
    //         validatorId
    //     ).depth(10) // delegatorsReward in the tuple
    //         .find(); // <-- may temporarily write to slots
    //     vm.revertTo(snap); // undo probe writes

    //     // 3) Seed delegatorsReward safely
    //     vm.store(
    //         STAKE_MANAGER_PROXY,
    //         bytes32(slotU), // cast the found slot
    //         bytes32(DELEGATOR_REWARD)
    //     );

    //     // // (optional) sanity read via the struct getter
    //     // (,,,,,,,,,, uint256 dr,,) = IStakeManagerLike(STAKE_MANAGER_PROXY).validators(validatorId);
    //     // require(dr == DELEGATOR_REWARD, "seed failed");

    //     // 4) Truth = stake + liquid; vault only tracks stake
    //     (uint256 st1,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     uint256 liq1 = IValidatorShare(validatorShare).getLiquidRewards(address(vault));
    //     uint256 truth = st1 + liq1;

    //     (, uint256 acct,,) = vault.validators(validatorShare);
    //     console2.log("=== After delegatorsReward ===");
    //     console2.log("seededReward", DELEGATOR_REWARD);
    //     console2.log("stake (validator truth)", st1);
    //     console2.log("liquid (credited to vault)", liq1);
    //     console2.log("acct  (vault, stake-only)", acct);
    //     console2.log("truth (= stake + liquid)", truth);
    //     console2.log("drift (truth - acct)", truth - acct);

    //     assertGt(liq1, 0, "expected non-zero liquid rewards");
    //     assertTrue(truth != acct, "expected drift (truth = stake+liquid) != vault stake");
    //     assertEq(truth - acct, liq1, "drift should equal liquid rewards");

    //     // 5) ENTRY FAIRNESS: if vault ignores liquid in price, Charlie over-mints shares

    //     uint256 supply0 = IERC20(address(vault)).totalSupply();
    //     uint256 truthNAV0 = st1 + liq1; // validator truth NAV for the vault
    //     uint256 acctNAV0 = acct; // vault's internal stake-only accounting

    //     vm.startPrank(bob);
    //     IERC20(MATIC_ERC20).approve(address(vault), SECOND_DEPOSIT);
    //     uint256 supplyBefore = IERC20(address(vault)).totalSupply();
    //     vault.depositToSpecificValidator(SECOND_DEPOSIT, validatorShare);
    //     vm.stopPrank();

    //     uint256 supplyAfter = IERC20(address(vault)).totalSupply();
    //     uint256 minted = supplyAfter - supplyBefore;

    //     // “Fair” shares (using truth NAV) vs “acct-based” shares (if vault ignored liquid)
    //     uint256 expectedTruthShares = (1e18 * supply0) / truthNAV0;
    //     uint256 expectedAcctShares = (1e18 * supply0) / acctNAV0;

    //     console2.log("---- entry fairness ----");
    //     console2.log("supply0                   ", supply0);
    //     console2.log("truthNAV0 (=stake+liquid) ", truthNAV0);
    //     console2.log("acctNAV0  (=stake only)   ", acctNAV0);
    //     console2.log("expected shares (truth)   ", expectedTruthShares);
    //     console2.log("expected shares (acct)    ", expectedAcctShares);
    //     console2.log("actual minted             ", minted);

    //     // If the vault priced off acctNAV (ignoring liquid), minted ~= expectedAcctShares (> expectedTruthShares)
    //     // That means Charlie was over-minted at Alice's expense.
    // }

    // function test_Drift_AfterDelegatorsReward2() public {
    //     // 1) Baseline: deposit via the vault
    //     vm.startPrank(alice);
    //     IERC20(MATIC_ERC20).approve(address(vault), INITIAL_DEPOST);
    //     vault.depositToSpecificValidator(INITIAL_DEPOST, validatorShare);
    //     vm.stopPrank();

    //     (uint256 st0,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     (, uint256 s0,,) = vault.validators(validatorShare);
    //     uint256 liq0 = IValidatorShare(validatorShare).getLiquidRewards(address(vault));

    //     console2.log("=== Baseline after vault deposit ===");
    //     console2.log("stake (validator truth)", st0);
    //     console2.log("liquid (validator)", liq0);
    //     console2.log("acct  (vault)", s0);
    //     console2.log("truth (= stake + liquid)", st0 + liq0);
    //     console2.log("drift (truth - acct)", st0 + liq0 - s0);

    //     assertEq(st0, s0, "pre: acct==truth"); // no rewards yet

    //     // 2) Find the exact slot for validators[vid].delegatorsReward (field index 10)
    //     uint256 snap = vm.snapshot();
    //     uint256 slotU = stdstore.target(STAKE_MANAGER_PROXY).sig(IStakeManagerLike.validators.selector).with_key(
    //         validatorId
    //     ).depth(10) // delegatorsReward in the tuple
    //         .find(); // <-- may temporarily write to slots
    //     vm.revertTo(snap); // undo probe writes

    //     // 3) Seed delegatorsReward safely
    //     vm.store(
    //         STAKE_MANAGER_PROXY,
    //         bytes32(slotU), // cast the found slot
    //         bytes32(DELEGATOR_REWARD)
    //     );

    //     // 1) Snapshot vault’s view vs validator truth BEFORE unbond
    //     (uint256 stBefore,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     (, uint256 acctBefore,,) = vault.validators(validatorShare);
    //     console2.log("pre-unbond validator truth stake:", stBefore);
    //     console2.log("pre-unbond vault stakedAmount   :", acctBefore);

    //     // 2) Unbond a small amount (assets)
    //     // (uses the vault's withdrawFromSpecificValidator path)
    //     vm.startPrank(alice);
    //     vault.withdrawFromSpecificValidator(0.5 ether, validatorShare);
    //     vm.stopPrank();

    //     // 3) Compare AFTER unbond
    //     (uint256 stAfter,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     (, uint256 acctAfter,,) = vault.validators(validatorShare);
    //     console2.log("post-unbond validator truth stake:", stAfter);
    //     console2.log("post-unbond vault stakedAmount   :", acctAfter);

    //     // 4) Show the unit-mix drift: vault subtracts assets; earlier it added shares on stake
    //     console2.log("truth (assets)     :", stBefore - stAfter);
    //     console2.log("vault stakedAmount :", acctBefore - acctAfter);
    //     // If buyVoucher minted != assets on stake (common when exchangeRate != 1),
    //     // these two deltas will not match -> DRIFT
    // }

    // function test_DepositMintsFewerShares_WhenLiquid_onFork() public {
    //     // --- 1) Alice seeds the pool so price is defined (supply > 0) ---
    //     vm.startPrank(alice);
    //     IERC20(MATIC_ERC20).approve(address(vault), INITIAL_DEPOST);
    //     vault.depositToSpecificValidator(INITIAL_DEPOST, validatorShare);
    //     vm.stopPrank();

    //     (uint256 st0,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     uint256 liq0 = IValidatorShare(validatorShare).getLiquidRewards(address(vault));
    //     (, uint256 acct0,,) = vault.validators(validatorShare);

    //     console2.log("=== Baseline ===");
    //     console2.log("stake (validator truth)", st0);
    //     console2.log("liquid (validator)     ", liq0);
    //     console2.log("acct  (vault)          ", acct0);
    //     assertEq(st0, acct0, "pre: acct==truth (no liquid yet)");

    //     // --- 2) Seed delegatorsReward on StakeManager so the vault has liquid > 0 ---
    //     //     (we use stdstore find() safely with snapshot/revert)
    //     uint256 snap = vm.snapshot();
    //     uint256 slotU = stdstore.target(STAKE_MANAGER_PROXY).sig(IStakeManagerLike.validators.selector).with_key(
    //         validatorId
    //     ).depth(10) // field 10 = delegatorsReward
    //         .find();
    //     vm.revertTo(snap);

    //     vm.store(
    //         STAKE_MANAGER_PROXY,
    //         bytes32(slotU),
    //         bytes32(DELEGATOR_REWARD) // e.g. 1 ether is fine on this fork
    //     );

    //     // --- 3) Observe price inputs now: stake unchanged, liquid > 0 ---
    //     (uint256 st1,) = IValidatorShare(validatorShare).getTotalStake(address(vault));
    //     uint256 liq1 = IValidatorShare(validatorShare).getLiquidRewards(address(vault));
    //     (, uint256 acct1,,) = vault.validators(validatorShare);

    //     uint256 supply0 = IERC20(address(vault)).totalSupply();
    //     uint256 navTruth = st1 + liq1; // what the vault should price off
    //     uint256 navAcct = st1; // stake-only (incorrect if used)

    //     console2.log("=== After delegatorsReward ===");
    //     console2.log("seededReward            ", DELEGATOR_REWARD);
    //     console2.log("stake (validator truth) ", st1);
    //     console2.log("liquid (credited)       ", liq1);
    //     console2.log("acct  (stake-only)      ", acct1);
    //     console2.log("truth NAV (=s+l)        ", navTruth);
    //     assertGt(liq1, 0, "expected non-zero liquid rewards");

    //     // --- 4) Bob deposits; minted shares should match truth NAV pricing ---
    //     vm.startPrank(bob);
    //     IERC20(MATIC_ERC20).approve(address(vault), BUY_AMOUNT);
    //     uint256 supplyBefore = IERC20(address(vault)).totalSupply();
    //     uint256 bobBalBefore = IERC20(address(vault)).balanceOf(bob);
    //     uint256 mintedActual = vault.depositToSpecificValidator(BUY_AMOUNT, validatorShare);
    //     vm.stopPrank();

    //     uint256 supplyAfter = IERC20(address(vault)).totalSupply();
    //     uint256 bobBalAfter = IERC20(address(vault)).balanceOf(bob);

    //     // Return value should equal supply delta and Bob's share delta
    //     assertEq(mintedActual, supplyAfter - supplyBefore, "return != supply delta");
    //     assertEq(mintedActual, bobBalAfter - bobBalBefore, "return != user share delta");

    //     // What pricing SHOULD produce (truth NAV) vs stake-only (incorrect)
    //     uint256 expectedTruthShares = (BUY_AMOUNT * supply0) / navTruth;
    //     uint256 expectedAcctShares = (BUY_AMOUNT * supply0) / navAcct;

    //     console2.log("---- entry pricing ----");
    //     console2.log("supply0                   ", supply0);
    //     console2.log("truthNAV0 (=stake+liquid) ", navTruth);
    //     console2.log("acctNAV0  (=stake only)   ", navAcct);
    //     console2.log("expected shares (truth)   ", expectedTruthShares);
    //     console2.log("expected shares (acct)    ", expectedAcctShares);
    //     console2.log("actual minted             ", mintedActual);

    //     // Assertions that capture what we saw on the real fork:
    //     // - Pricing uses truth NAV (stake+liquid), so minted == expectedTruthShares (±1 wei rounding).
    //     // - Since price > 1, minted < BUY_AMOUNT and < expectedAcctShares.
    //     assertApproxEqAbs(mintedActual, expectedTruthShares, 1, "minted should match truth NAV pricing");
    //     assertLt(mintedActual, BUY_AMOUNT, "price > 1 ; minted < assets");
    //     assertLt(mintedActual, expectedAcctShares, "minted must be < stake-only pricing");
    // }

    // fork version of bug i already filed
    function test_SetDelegatedAmount_RevertDeposit() public {
        uint256 amt = 1 ether;

        // fund Alice
        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amt);

        // deposit into specific validator
        vault.depositToSpecificValidator(amt, validatorShare);
        vm.stopPrank();

        // now totalSupply() should be > 0
        uint256 tsupply = IERC20(validatorShare).totalSupply();
        console2.log("ValidatorShare totalSupply:", tsupply);

        uint256 rate = IValidatorShareLike(validatorShare).exchangeRate();
        console2.log("ValidatorShare exchangeRate:", rate);

        // set delegated amount
        vm.prank(validatorShare);
        IStakeManager(STAKE_MANAGER_PROXY).updateValidatorState(validatorId, 1 ether);

        rate = IValidatorShareLike(validatorShare).exchangeRate();
        console2.log("ValidatorShare exchangeRate2:", rate);

        // second deposit reverts
        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amt);
        vm.expectRevert(bytes("Too much slippage"));
        vault.depositToSpecificValidator(amt, validatorShare);
        vm.stopPrank();
    }

    // function test_PublicCompoundRewards_MintsTreasuryAndDilutes() public {
    //     uint256 amt = 10 ether;

    //     // Seed Alice and do an initial mint so there are outside holders
    //     deal(MATIC_ERC20, alice, amt);
    //     vm.startPrank(alice);
    //     IERC20(MATIC_ERC20).approve(address(vault), amt);
    //     vault.depositToSpecificValidator(amt, validatorShare);
    //     vm.stopPrank();

    //     address treasury = vault.treasuryAddress();

    //     uint256 supplyBefore = vault.totalSupply();
    //     uint256 aliceBefore = vault.balanceOf(alice);
    //     uint256 treasBefore = vault.balanceOf(treasury);

    //     // Any caller can trigger it
    //     vm.prank(bob);
    //     vault.compoundRewards(validatorShare);

    //     uint256 supplyAfter = vault.totalSupply();
    //     uint256 aliceAfter = vault.balanceOf(alice);
    //     uint256 treasAfter = vault.balanceOf(treasury);

    //     // Treasury got newly minted shares; total supply increased
    //     assertGt(treasAfter, treasBefore, "treasury did not get minted shares");
    //     assertGt(supplyAfter, supplyBefore, "supply did not grow");

    //     // Alice’s % ownership dropped (dilution)
    //     // Compare ratios without floating-point: alice/supply
    //     assertLt(aliceAfter * 1e18 / supplyAfter, aliceBefore * 1e18 / supplyBefore, "no dilution observed");
    // }

    function test_StakedAmount_Drift_AfterExternalUpdate() public {
        uint256 amt = 1 ether;

        // 1) Seed and deposit so validator has >0 shares for the vault
        deal(MATIC_ERC20, alice, amt);
        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amt);
        vault.depositToSpecificValidator(amt, validatorShare);
        vm.stopPrank();

        // 2) Snapshot vault’s view vs validator’s ground truth
        uint256 vaultBefore = vault.totalAssets(); // or validators[share].stakedAmount if exposed
        uint256 extBefore = IValShare(validatorShare).getTotalStake(address(vault));

        console2.log("before: vault.totalAssets   =", vaultBefore);
        console2.log("before: validator totalStake=", extBefore);

        // 3) Legit caller bumps delegatedAmount on StakeManager (changes exchange rate / stake)
        int256 delta = 1 ether;
        vm.prank(validatorShare);
        IStakeManager(STAKE_MANAGER_PROXY).updateValidatorState(validatorId, delta);

        // 4) Re-measure
        uint256 vaultAfter = vault.totalAssets();
        uint256 extAfter = IValShare(validatorShare).getTotalStake(address(vault));

        console2.log("after:  vault.totalAssets   =", vaultAfter);
        console2.log("after:  validator totalStake=", extAfter);

        // 5) Show drift (assert a meaningful gap). Adjust epsilon as needed.
        uint256 diff = (extAfter > vaultAfter) ? (extAfter - vaultAfter) : (vaultAfter - extAfter);
        assertGt(diff, 0, "expected drift between vault and validator stake");

        // After the external bump:
        uint256 preview = vault.previewRedeem(1e18); // or vault.convertToAssets(1e18)
        console2.log("previewRedeem(1e18) =", preview);

        // Ground truth from validator:
        uint256 trueAssets = IValShare(validatorShare).getTotalStake(address(vault));
        console2.log("validator stake    =", trueAssets);

        // Expect preview to understate vs trueAssets if it uses totalAssets() under the hood
        assertLt(preview, trueAssets, "preview should be less than actual validator stake");
    }

    function _initiateWithdrawViaVault(uint256 shares, address _validator) internal returns (uint256 unbondNonce) {
        // Try a few common signatures the vaults use; pick the one your build exposes.
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("withdrawFromSpecificValidator(uint256,address)", shares, _validator)
        );
        if (!ok) {
            (ok, ret) =
                address(vault).call(abi.encodeWithSignature("initiateWithdrawal(uint256,address)", shares, _validator));
        }
        if (!ok) {
            (ok, ret) =
                address(vault).call(abi.encodeWithSignature("requestWithdraw(uint256,address)", shares, _validator));
        }
        require(ok, "no withdraw-init function matched");

        // Many implementations return the unbond nonce; if not, read it from ValidatorShare
        if (ret.length >= 32) {
            unbondNonce = abi.decode(ret, (uint256));
        } else {
            // Falls back to reading ValidatorShare.unbondNonces(vault)
            unbondNonce = IValShare(validatorShare).unbondNonces(address(vault));
        }
    }

    function test_UnbondInitiate_ThenPreviewMismatch_AndClaimBlocked() public {
        uint256 amt = 1 ether;

        // 1) Deposit 1 MATIC
        deal(MATIC_ERC20, alice, amt);
        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amt);
        vault.depositToSpecificValidator(amt, validatorShare);
        vm.stopPrank();

        // 2) Snapshot truths
        uint256 assetsBefore = vault.totalAssets(); // likely 0 for reasons in your earlier logs
        uint256 stakeBefore = IValShare(validatorShare).getTotalStake(address(vault));
        console2.log("before: vault.totalAssets   =", assetsBefore);
        console2.log("before: validator totalStake=", stakeBefore);

        // 3) Authorized bump of delegatedAmount (rate ↑)
        vm.prank(validatorShare);
        IStakeManager(STAKE_MANAGER_PROXY).updateValidatorState(validatorId, 1 ether);

        uint256 assetsAfter = vault.totalAssets();
        uint256 stakeAfter = IValShare(validatorShare).getTotalStake(address(vault));
        console2.log("after:  vault.totalAssets   =", assetsAfter);
        console2.log("after:  validator totalStake=", stakeAfter);

        // 4) Previews still ignore drift (you already saw this)
        uint256 previewOut = vault.previewRedeem(1e18); // or convertToAssets(1e18)
        console2.log("previewRedeem(1e18) =", previewOut);
        console2.log("validator stake    =", stakeAfter);
        // Assert mismatch (preview < true backing)
        assertLt(previewOut, stakeAfter, "preview ignores validator-side increase");

        // 5) Initiate withdraw (get a real unbond nonce)
        uint256 nonce = _initiateWithdrawViaVault(1e18, validatorShare);
        console2.log("unbond nonce =", nonce);

        // 6) Try to claim now → should revert: unbonding not finished (expected on fork)
        vm.startPrank(alice);
        vm.expectRevert(); // "unbonding not finished" (exact string may differ)
        vault.withdrawClaim(nonce, validatorShare);
        vm.stopPrank();

        // This demonstrates:
        // - Users are quoted less than true backing (preview underreports),
        // - They cannot realize the extra until epoch progression (claim blocked on fork),
        //   i.e., temporary freezing of unclaimed yield.
    }

    function test_SetDelegatedAmount_RevertDeposit_WithdrawInit_OK_ClaimBlocked() public {
        uint256 amt = 1 ether;

        // 1) First deposit succeeds
        vm.startPrank(alice);
        IERC20(MATIC_ERC20).approve(address(vault), amt);
        vault.depositToSpecificValidator(amt, validatorShare);
        vm.stopPrank();

        // 2) Bump rate via authorized caller
        vm.prank(validatorShare);
        IStakeManager(STAKE_MANAGER_PROXY).updateValidatorState(validatorId, 1 ether);

        // 3) Second deposit reverts due to minShares misuse
        // vm.startPrank(alice);
        // IERC20(MATIC_ERC20).approve(address(vault), amt);
        // vm.expectRevert(bytes("Too much slippage"));
        // vault.depositToSpecificValidator(amt, validatorShare);
        // vm.stopPrank();

        // 4) Withdraw INIT of Alice’s original position
        vm.startPrank(alice);
        vm.expectRevert(stdError.arithmeticError);
        (uint256 shareDecreaseUser, uint256 unbondNonce) = vault.withdrawFromSpecificValidator(1 ether, validatorShare);
        vm.stopPrank();

        console2.log("withdraw init shareDecreaseUser:", shareDecreaseUser);
        console2.log("withdraw init unbondNonce     :", unbondNonce);

        // // 5) Immediate claim should REVERT (unbonding not finished on fork)
        // vm.startPrank(alice);
        // vm.expectRevert(); // exact reason depends on validator/epoch checks
        // vault.withdrawClaim(unbondNonce, validatorShare);
        // vm.stopPrank();
    }
}
