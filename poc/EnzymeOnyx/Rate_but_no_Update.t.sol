// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {Shares} from "src/shares/Shares.sol";
import {ValuationHandler} from "src/components/value/ValuationHandler.sol";
import {FeeHandler} from "src/components/fees/FeeHandler.sol";
import {ERC7540LikeDepositQueue} from "src/components/issuance/deposit-handlers/ERC7540LikeDepositQueue.sol";
import {ERC7540LikeRedeemQueue} from "src/components/issuance/redeem-handlers/ERC7540LikeRedeemQueue.sol";
import {IComponentProxy} from "src/interfaces/IComponentProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// ───────────────────────────────── helpers ─────────────────────────────────

/// Minimal ERC20 used as the deposit asset.
contract TestERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Minimal proxy that satisfies ComponentHelpersMixin: SHARES() must return the Shares address.
/// All component/queue calls delegate to `implementation`.
contract ComponentProxy is IComponentProxy {
    address public immutable SHARES;
    address public implementation;

    constructor(address shares_, address implementation_) {
        SHARES = shares_;
        implementation = implementation_;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch result
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
    }

    receive() external payable {}
}

// Minimal tracker that marks the vault by valuing its asset balance at the CURRENT rate.
contract BalanceTracker {
    address public immutable shares;
    address public immutable asset;
    ValuationHandler public immutable val;

    constructor(address _shares, address _asset, ValuationHandler _val) {
        shares = _shares;
        asset = _asset;
        val = _val;
    }

    function getPositionValue() external view returns (int256) {
        uint256 bal = IERC20(asset).balanceOf(shares);
        // Value the vault's asset holdings at the CURRENT rate.
        uint256 v = val.convertAssetAmountToValue(asset, bal);
        return int256(v);
    }
}

contract AssetRate_Before_Value is Test {
    Shares shares;
    ValuationHandler valuationHandler;
    FeeHandler feeHandler;
    ERC7540LikeDepositQueue depQ;
    ERC7540LikeRedeemQueue redQ;
    TestERC20 asset;

    address owner = address(0x0123);
    address user1 = address(0xBEEF);
    address user2 = address(0xB10C);

    uint256 constant USER_STARTING_SH = 100e18; // 100 shares (18 decimals)
    uint128 constant INITIAL_RATE = 1e18; // 1.0

    // convenience
    function _deployProxied(address impl) internal returns (address proxyAddr) {
        ComponentProxy p = new ComponentProxy(address(shares), impl);
        proxyAddr = address(p);
    }

    function setUp() public {
        // Shares + validator
        vm.startPrank(owner);
        shares = new Shares();
        shares.init({_owner: owner, _name: "Onyx Shares", _symbol: "ONX", _valueAsset: bytes32("USD")});

        // Mint asset
        asset = new TestERC20();
        asset.initialize("Test Token", "TTK", 18);
        asset.mint(user1, USER_STARTING_SH);
        asset.mint(user2, USER_STARTING_SH);

        // Wire ValuationHandler (proxy), set 1:1 price, zero untracked value
        ValuationHandler vhImpl = new ValuationHandler();
        address vhProxy = _deployProxied(address(vhImpl));
        valuationHandler = ValuationHandler(vhProxy);
        shares.setValuationHandler(vhProxy);

        // 1:1 asset→value rate with long expiry
        ValuationHandler.AssetRateInput[] memory rates = new ValuationHandler.AssetRateInput[](1);
        rates[0] = ValuationHandler.AssetRateInput({
            asset: address(asset),
            rate: 1e18,
            expiry: uint40(block.timestamp + 365 days)
        });
        valuationHandler.setAssetRatesThenUpdateShareValue(rates, 0);

        // Wire FeeHandler (proxy) and neutralize entrance/exit fees
        address feeProxy = _deployProxied(address(new FeeHandler()));
        feeHandler = FeeHandler(feeProxy);
        shares.setFeeHandler(feeProxy);
        feeHandler.setEntranceFee(0, owner);
        feeHandler.setExitFee(0, owner);
        feeHandler.setFeeAsset(address(asset));

        // Deploy queues behind proxies and point them to asset;
        // shares is learned via ComponentHelpersMixin + proxy.Shares immutable.
        address dqProxy = _deployProxied(address(new ERC7540LikeDepositQueue()));
        address rqProxy = _deployProxied(address(new ERC7540LikeRedeemQueue()));
        depQ = ERC7540LikeDepositQueue(dqProxy);
        redQ = ERC7540LikeRedeemQueue(rqProxy);

        depQ.setAsset(address(asset));
        redQ.setAsset(address(asset));
        depQ.setDepositMinRequestDuration(0);
        redQ.setRedeemMinRequestDuration(0);
        depQ.setDepositRestriction(ERC7540LikeDepositQueue.DepositRestriction.None);

        // Grant handler roles to the queues
        shares.addDepositHandler(dqProxy);
        shares.addRedeemHandler(rqProxy);
        vm.stopPrank();

        // Deploy and register the tracker
        BalanceTracker tracker = new BalanceTracker(address(shares), address(asset), valuationHandler);
        vm.prank(owner);
        valuationHandler.addPositionTracker(address(tracker));
    }

    function _setup_rateFlip() internal returns (uint256 P_old, uint128 R_new) {
        // --- Arrange baseline ---
        // Read the current stored share price (this is the stale price the queue will snapshot)
        (P_old,) = valuationHandler.getSharePrice();
        assertGt(P_old, 0, "precondition: non-zero stored share price");

        // Install an initial asset rate and a long expiry
        uint40 expiry = uint40(block.timestamp + 30 days);
        {
            ValuationHandler.AssetRateInput[] memory inputs = new ValuationHandler.AssetRateInput[](1);
            inputs[0] = ValuationHandler.AssetRateInput({asset: address(asset), rate: INITIAL_RATE, expiry: expiry});
            vm.prank(owner);
            valuationHandler.setAssetRate(inputs[0]);
        }

        // Deposit shares for the users so they can redeem
        uint256[] memory depBatch = new uint256[](2);

        vm.startPrank(user1);
        asset.approve(address(depQ), USER_STARTING_SH);
        depBatch[0] = depQ.requestDeposit(USER_STARTING_SH, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(depQ), USER_STARTING_SH);
        depBatch[1] = depQ.requestDeposit(USER_STARTING_SH, user2, user2);
        vm.stopPrank();

        vm.prank(owner);
        depQ.executeDepositRequests(depBatch);
        assertEq(shares.balanceOf(user1), USER_STARTING_SH);

        // --- Flip the asset rate to a WORSE rate (R_new < R_old) WITHOUT updating share value ---
        R_new = (INITIAL_RATE * 9) / 10; // -10% in value units per asset
        {
            ValuationHandler.AssetRateInput[] memory inputs = new ValuationHandler.AssetRateInput[](1);
            inputs[0] = ValuationHandler.AssetRateInput({asset: address(asset), rate: R_new, expiry: expiry});
            vm.prank(owner);
            valuationHandler.setAssetRate(inputs[0]);
        }
    }

    function test_redeem_overWithdraw_whenRateUpdatedButSharePriceStale_queuePath() public {
        (uint256 P_old, uint128 R_new) = _setup_rateFlip();

        // IMPORTANT: Do NOT call valuationHandler.updateShareValue() here.
        // Queues will still use P_old for value, but convert with the fresh R_new.

        // --- Capture user's asset balance before settlement ---
        uint256 balBefore = asset.balanceOf(user1);
        console2.log("user1 asset balance after deposit", balBefore);
        console2.log("user1 balance in vault", shares.balanceOf(user1));

        // Read how many underlying tokens the vault actually has right now
        uint256 vaultAssetBal = IERC20(address(asset)).balanceOf(address(shares));
        assertEq(vaultAssetBal, USER_STARTING_SH * 2, "precondition: vault has all assets");
        console2.log("vault asset balance", vaultAssetBal);

        // --- User1 enqueues redeem request ---
        uint256[] memory ids = new uint256[](1);
        vm.prank(user1);
        ids[0] = redQ.requestRedeem(USER_STARTING_SH, user1, user1);

        // --- Admin executes the redeem batch (queue path under test) ---
        vm.prank(owner);
        redQ.executeRedeemRequests(ids);

        // --- Observe payout ---
        uint256 balAfter = asset.balanceOf(user1);
        uint256 userAssets_bug = balAfter - balBefore;

        // --- Compute "fair" asset amount baseline for comparison ---
        // Queue math does: valueDue = S * P_old; assetsOut = valueDue / R_new (fresh)
        // If the maintainer had called updateShareValue() first, the fair baseline
        // under a single-asset, zero-fee assumption equates to using R_old for conversion:
        //   userAssets_fair = (S * P_old) / R_old
        uint256 userAssets_fair = (USER_STARTING_SH * P_old) / 1e18 /*wad*/ * 1e18 / INITIAL_RATE;

        // The bug: using stale P_old with fresh R_new (< R_old) pays MORE asset than fair.
        assertGt(
            userAssets_bug,
            userAssets_fair,
            "over-withdraw should exceed fair amount when price is stale and rate is fresh"
        );

        // Optional: check proportionality ~ R_old/R_new (within 1 wei slop)
        // userAssets_bug / userAssets_fair ≈ R_old / R_new
        assertApproxEqAbs(userAssets_bug * uint256(R_new), userAssets_fair * uint256(INITIAL_RATE), 1e18);
        console2.log("user1 should have got", userAssets_fair);
        console2.log("user1 did get", userAssets_bug);
        console2.log("Rate old", INITIAL_RATE);
        console2.log("Rate new", R_new);

        // Show user2 cannot redeem their balance because the vault is drained
        assertEq(shares.balanceOf(user2), USER_STARTING_SH, "precondition: user2 has shares");
        console2.log("user2 balance in vault before redeem", shares.balanceOf(user2));

        vm.prank(user2);
        ids[0] = redQ.requestRedeem(USER_STARTING_SH, user2, user2);

        // --- Admin executes the redeem batch ---
        vm.prank(owner);
        vm.expectRevert(bytes("ERC20: subtraction underflow"));
        redQ.executeRedeemRequests(ids);

        assertEq(asset.balanceOf(user2), 0, "user2 should not have received assets");
        assertEq(shares.balanceOf(user2), 0, "user2 shares should be in queue");
        console2.log("user2 asset balance after redeem fails", asset.balanceOf(user2));
        console2.log("user2 balance in vault after redeem fails", shares.balanceOf(user2));

        assertEq(shares.balanceOf(address(redQ)), USER_STARTING_SH, "queue should hold user2's shares");
        console2.log("redeem queue balance before cancel", shares.balanceOf(address(redQ)));

        // --- Cancel queue to get shares back, but only user2 can!!!! ---
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ERC7540LikeRedeemQueue.ERC7540LikeRedeemQueue__CancelRequest__Unauthorized.selector)
        );
        redQ.cancelRedeem(ids[0]);

        vm.prank(user2);
        uint256 refunded = redQ.cancelRedeem(ids[0]);
        assertEq(refunded, USER_STARTING_SH, "cancel redeem shares not refunded correctly");

        // update value as should have done before
        vm.prank(owner);
        valuationHandler.updateShareValue(0);

        // user2 can redeem now
        vm.prank(user2);
        ids[0] = redQ.requestRedeem(USER_STARTING_SH, user2, user2);

        vm.prank(owner);
        redQ.executeRedeemRequests(ids);
        assertLt(asset.balanceOf(user2), USER_STARTING_SH, "user2 shares fully redeemed when should be partial");
        console2.log("user2 asset balance after update and redeem", asset.balanceOf(user2));
    }

    function test_noOverWithdraw_withTracker_whenRateUpdated_andShareValueRefreshed_queuePath() public {
        (, uint128 R_new) = _setup_rateFlip();

        // --- REFRESH share value (control test to show how admin just do it) ---

        vm.prank(owner);
        valuationHandler.updateShareValue(0); // <- align P to R_new via tracker

        // recompute P_new after refresh
        (uint256 P_new,) = valuationHandler.getSharePrice();
        assertGt(P_new, 0);

        // --- execute redeem & compare against fair (now-aligned) expectation ---
        uint256 balBefore = asset.balanceOf(user1);

        uint256[] memory ids = new uint256[](2);

        vm.prank(user1);
        ids[0] = redQ.requestRedeem(USER_STARTING_SH, user1, user1);

        vm.prank(user2);
        ids[1] = redQ.requestRedeem(USER_STARTING_SH, user2, user2);

        vm.prank(owner);
        redQ.executeRedeemRequests(ids);
        uint256 userAssets_now = asset.balanceOf(user1) - balBefore;

        // expected when price and rate are aligned:
        uint256 expected = (USER_STARTING_SH * P_new) / 1e18 /*wad*/ * 1e18 / uint256(R_new);

        // No over-withdraw once refreshed (allow tiny rounding slop)
        assertApproxEqAbs(userAssets_now, expected, 2); // or a few wei if needed
        assertLe(userAssets_now, expected + 2);
        console2.log("after user1 bal", asset.balanceOf(user1));
        console2.log("after user2 bal", asset.balanceOf(user2));
    }
}
