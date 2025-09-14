// SPDX-License-Identifier: BUSL-1.1

/*
    This file is part of the Onyx Protocol.

    (c) Enzyme Foundation <foundation@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.8.28;

import {ComponentHelpersMixin} from "src/components/utils/ComponentHelpersMixin.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {Shares} from "src/shares/Shares.sol";
import {ValuationHandler} from "src/components/value/ValuationHandler.sol";

import {ValuationHandlerHarness} from "test/harnesses/ValuationHandlerHarness.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {TestHelpers} from "test/utils/TestHelpers.sol";

import {stdError} from "forge-std/Test.sol";

contract ValuationHandlerTest is TestHelpers {
    Shares shares;
    address owner;
    address admin = makeAddr("ValuationHandlerTest.admin");

    ValuationHandlerHarness valuationHandler;

    function setUp() public {
        shares = createShares();
        owner = shares.owner();

        vm.prank(owner);
        shares.addAdmin(admin);

        valuationHandler = new ValuationHandlerHarness({_shares: address(shares)});
    }

    // WYLIS 1
    function test_updateShareValue_revert_highFeeRate_longIdleGap() public {
        // --- Setup: healthy positions, negligible fees, first update succeeds ---
        address trackerA = makeAddr("highFee:trackerA");
        address trackerB = makeAddr("highFee:trackerB");

        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerB);

        // Positions total = 10_000 (arbitrary value units)
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 6_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 4_000});

        // Untracked = 0; we’re focusing on fee vs positions
        int256 untrackedValue = 0;

        // Start with minimal owed fees so first update passes
        uint256 initialFees = 0;
        address feeHandler = setMockFeeHandler(address(shares), initialFees);

        // Ensure non-zero total supply so value-per-share path runs
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // First update: succeeds (10_000 positions, 0 fees)
        vm.prank(owner);
        valuationHandler.updateShareValue(untrackedValue);

        // --- Time passes with high fee rate configured externally (e.g., 8%/yr) ---
        // Simulate ~18 months idle to justify ~12%+ fees accrual.
        vm.warp(block.timestamp + 78 weeks);

        // Reprice fees owed to exceed positions (e.g., 12_500 > 10_000)
        // This models "high rate + long gap" without needing the real fee math here.
        uint256 grownFees = 12_500;
        feeHandler_mockGetTotalValueOwed({_feeHandler: feeHandler, _totalValueOwed: grownFees});

        // Expect arithmetic underflow when computing:
        //   totalValue = totalPositionsValue (10_000) - totalFeesOwed (12_500)
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(untrackedValue);
    }

    // WYLIS 2
    function test_updateShareValue_revert_unpaidFees_alreadyLarge() public {
        // --- Setup: positions are fine, but already-owed fees ≈ positions (or greater) ---
        address trackerA = makeAddr("unpaidFees:trackerA");
        address trackerB = makeAddr("unpaidFees:trackerB");

        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerB);

        // Positions total = 10_000
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 6_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 4_000});

        // No untracked value; we're isolating fee vs positions
        int256 untrackedValue = 0;

        // Set fees to exceed positions by 1 to force immediate underflow on first update
        uint256 alreadyOwed = 10_001;
        setMockFeeHandler(address(shares), alreadyOwed);

        // Ensure nonzero supply so value-per-share path executes
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // First update should already revert because:
        // totalValue = positions (10_000) - fees (10_001) => underflow
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(untrackedValue);
    }

    // WYLIS 3
    function test_updateShareValue_revert_afterDrawdown_feesExceedPositions() public {
        // --- Initial setup: positions comfortably exceed fees, first update succeeds ---

        // Create two position trackers and mock initial healthy values (sum = 3_000)
        address trackerA = makeAddr("drawdown:trackerA");
        address trackerB = makeAddr("drawdown:trackerB");

        // Register trackers
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerB);

        // Mock initial tracked positions value
        // (choose arbitrary positive ints; units are generic "value" units)
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 1_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 2_000});

        // No untracked value for this scenario; we want positions-only to demonstrate the bug
        int256 untrackedValue = 0;

        // Set a FeeHandler with already-owed fees less than positions (e.g., 500 < 3000)
        // so the first update does NOT revert.
        uint256 feesOwed = 500;
        address feeHandler = setMockFeeHandler(address(shares), feesOwed);

        // Ensure there is a nonzero share supply so value-per-share calculation runs
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // First update: should succeed
        vm.prank(owner);
        valuationHandler.updateShareValue(untrackedValue);

        // --- Drawdown: positions are repriced DOWN between updates ---

        // Now simulate a market drop so totalPositionsValue < alreadyOwed fees.
        // Re-mock trackers to much lower values (sum = 400) while fees remain 500.
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 150});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 250});

        // Keep the same "already owed" amount (or even increase it if desired).
        // Re-mock the FeeHandler.getTotalValueOwed() to return the same 500.
        feeHandler_mockGetTotalValueOwed({_feeHandler: feeHandler, _totalValueOwed: feesOwed});

        // Expect an arithmetic underflow when computing:
        //   totalValue = totalPositionsValue (400) - totalFeesOwed (500)  => underflows
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(untrackedValue);
    }

    // WYLIS 4a
    function test_updateShareValue_rateHikeBeforeSettle_spikesAccrual() public {
        // --- Position setup: total tracked positions = 1_000_000 (big to minimize integer rounding) ---
        address trackerA = makeAddr("rateHike:trackerA");
        address trackerB = makeAddr("rateHike:trackerB");

        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerB);

        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 600_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 400_000});

        // Non-zero supply so value-per-share is computed
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // --- Install our accrual mock as FeeHandler with LOW rate initially (e.g., 1% APR = 100 bps) ---
        FeeHandlerAccrualMock fh = new FeeHandlerAccrualMock();
        fh.setRateBps(100); // 1%/yr

        vm.prank(shares.owner());
        Shares(address(shares)).setFeeHandler(address(fh));

        // t0
        uint256 t0 = 1000;
        vm.warp(t0);

        // First settle via updateShareValue → initializes lastSettle with no fees accrued
        vm.prank(owner);
        valuationHandler.updateShareValue(0);

        // --- Short idle window (e.g., 12 weeks), then admin bumps rate sharply (e.g., 20% APR) ---
        uint256 idle = 12 weeks; // << shorter than the long gap in the high-rate test
        vm.warp(t0 + idle);

        // Admin raises rate BEFORE settle
        fh.setRateBps(2000); // 20%/yr

        // For clarity, recompute the same tracked values before settle (no price change in this scenario)
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 600_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 400_000});

        // Expected "all-at-new-rate" accrual the mock will apply:
        // accrualWrong = positions(1_000_000) * 2000 bps * idle / (365d * 10_000)
        uint256 positions = 1_000_000;
        uint256 accrualWrong = (positions * 2000 * idle) / (365 days * 10_000);

        // Expected "piecewise-correct" accrual if it had used the old rate for the elapsed window:
        // accrualCorrect = positions * 100 bps * idle / (365d * 10_000)
        uint256 accrualCorrect = (positions * 100 * idle) / (365 days * 10_000);

        // Sanity: new-rate accrual must be strictly larger than old-rate accrual
        assertGt(accrualWrong, accrualCorrect, "sanity: higher rate should accrue more");

        // Now settle; the mock should spike owed to 'accrualWrong'
        vm.prank(owner);
        valuationHandler.updateShareValue(0);

        // Read the fee handler's view of total owed
        uint256 owed = fh.getTotalValueOwed();

        // Assert the spike matches the "all-at-new-rate" calculation
        assertEq(owed, accrualWrong, "owed should equal accrual at new rate across entire idle window");

        // (Optional) Also assert it's strictly greater than the piecewise-correct value
        assertGt(owed, accrualCorrect, "owed should exceed piecewise-correct accrual");
    }

    // WYLIS 4b
    function test_updateShareValue_revert_rateHikeBeforeSettle_whenUnpaidNearPositions() public {
        // Positions kept small so a short window + reasonable bps can tip it over.
        address tracker = makeAddr("rateHikeRevert:tracker");
        vm.prank(admin);
        valuationHandler.addPositionTracker(tracker);
        // positions = 1,000
        positionTracker_mockGetPositionValue({_positionTracker: tracker, _value: 1_000});

        // Non-zero supply
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // Install accrual mock; start at low rate
        FeeHandlerAccrualMock fh = new FeeHandlerAccrualMock();
        fh.setRateBps(100); // 1% APR baseline

        vm.prank(shares.owner());
        Shares(address(shares)).setFeeHandler(address(fh));

        // t0 — initialize mock
        uint256 t0 = 1000;
        vm.warp(t0);
        vm.prank(owner);
        valuationHandler.updateShareValue(0); // arms lastSettle, owed = 0

        // Seed unpaid fees close to positions (simulate prior history)
        // e.g., alreadyOwed = 950 (just under 1,000)
        fh.__setTotalOwed(950);

        // Short delay, then admin hikes rate before settle
        vm.warp(t0 + 26 weeks); // ~half a year
        fh.setRateBps(2000); // 20% APR (within "high but plausible" bounds)

        // Keep same positions reading
        positionTracker_mockGetPositionValue({_positionTracker: tracker, _value: 1_000});

        // Now the settle will:
        //   accrual ~= positions * 20% * 0.5yr = 1000 * 0.2 * 0.5 = 100
        //   new owed = 950 + 100 = 1050 > positions (1000)  => underflow in net calculation
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(0);
    }

    // WYLIS 5
    /// @dev Multiple fee types / ordering: management accrues first against net (positions - alreadyOwed),
    /// then a performance fee is taken on gains over a watermark. With significant carryover,
    /// the interplay can push total owed over assets, triggering the arithmetic underflow revert in updateShareValue().
    function test_updateShareValue_revert_multiFeeOrdering_carryoverPushesOverAssets() public {
        // --- Setup trackers and positions ---
        address trackerA = makeAddr("multiFee:trackerA");
        address trackerB = makeAddr("multiFee:trackerB");
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerB);

        // Positions total = 1_050_000
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 600_000});
        positionTracker_mockGetPositionValue({_positionTracker: trackerB, _value: 450_000});

        // Provide non-zero supply so per-share math executes
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000});

        // --- Install a mock FeeHandler with management + performance fee ordering ---
        FeeHandlerMgmtPerfMock fh = new FeeHandlerMgmtPerfMock();
        // Carryover owed from prior periods (e.g., previously accrued performance fee)
        fh.__setTotalOwed(1_045_500); // already owed is very high
        // Prior gains set a high watermark at 1_000_000
        fh.__setWatermark(1_000_000);
        // 8% APR management; 20% performance over watermark
        fh.setRates({mgmtBps: 800, perfBps: 2_000});

        vm.prank(shares.owner());
        Shares(address(shares)).setFeeHandler(address(fh));

        // Let some time pass so management accrues
        vm.warp(block.timestamp + 26 weeks); // ~0.5 year

        // With ordering: mgmt accrues first on net (1_050_000 - 1_045_500 = 4_500) -> ~180
        // Then performance on (1_050_000 - 1_000_000) = 50_000 -> 10_000
        // Total owed becomes ~1_055_680 (> positions 1_050_000). Expect arithmetic underflow revert.
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(int256(0));
    }

    // WYLIS 6 (ceil-style rounding)
    /// @dev Rounding/precision + large numbers:
    /// With huge position values and near-equality between assets and already-owed,
    /// fee calculations that use ceil-style rounding at intermediate steps can flip the sign
    /// with only a tiny elapsed window. This demonstrates the revert with a *very small* gap
    /// because rounding biases fees upward by at least 1 wei.
    function test_updateShareValue_revert_roundingBiasWithLargeValues_smallGap() public {
        // Trackers
        address trackerA = makeAddr("rounding:trackerA");
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);

        // Massive positions total (1e18)
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: 1_000_000_000_000_000_000});

        // Non-zero supply
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000_000_000_000_000});

        // Install rounding-up fee handler
        FeeHandlerRoundingUpMock fh = new FeeHandlerRoundingUpMock();
        // Seed: already owed is assets - 1 (knife-edge)
        fh.__setTotalOwed(1_000_000_000_000_000_000 - 1);
        // Watermark set to just 1 wei below current positions to trigger a minimal "gain"
        fh.__setWatermark(1_000_000_000_000_000_000 - 1);
        // 10% APR mgmt, 0.01% performance (1 bps) — both ceil to at least 1 wei
        fh.setRates({_mgmtBps: 1000, _perfBps: 1});

        vm.prank(shares.owner());
        Shares(address(shares)).setFeeHandler(address(fh));

        // Tiny elapsed time (1 day) — exact math would often floor to 0,
        // but ceilDiv in the mock produces >= 1 wei for mgmt fee.
        vm.warp(block.timestamp + 1 days);

        // Expect underflow because:
        // - Mgmt fee rounds up to 1 wei => owed == positions
        // - Perf fee on 1 wei "gain" rounds up to 1 wei => owed == positions + 1 wei
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(0);
    }

    // WYLIS 6b (floor-based)
    // Rounding/precision + large numbers (floor arithmetic):
    // With huge position values and owed ≈ assets, even a small (but >= 1 wei) performance fee
    // computed on an intentional gain over the high-water mark can flip the sign with only a tiny elapsed window.
    // This uses floor division throughout to mirror production-style math.
    function test_updateShareValue_revert_roundingBiasWithLargeValues_smallGap_floor() public {
        // --- Trackers ---
        address trackerA = makeAddr("roundingFloor:trackerA");
        vm.prank(admin);
        valuationHandler.addPositionTracker(trackerA);

        // Massive positions total (1e18)
        uint256 positions = 1_000_000_000_000_000_000; // 1e18
        positionTracker_mockGetPositionValue({_positionTracker: trackerA, _value: int256(positions)});

        // Non-zero supply
        increaseSharesSupply({_shares: address(shares), _increaseAmount: 1_000_000_000_000_000_000}); // 1e18

        // Install floor-math fee handler
        FeeHandlerMgmtPerfMock fh = new FeeHandlerMgmtPerfMock();

        // Seed: owed is assets - 10 (knife-edge but leaves mgmtFee=0 after floor)
        fh.__setTotalOwed(positions - 10);

        // Watermark set so there is a meaningful gain to generate >= 1 wei perf fee at 1 bps
        // gain = positions - watermark = 200,000  => perfFee = floor(200,000 * 0.0001) = 20
        fh.__setWatermark(positions - 200_000);

        // Rates: 10% APR mgmt, 0.01% performance (1 bps)
        fh.setRates({mgmtBps: 1000, perfBps: 1});

        vm.prank(shares.owner());
        Shares(address(shares)).setFeeHandler(address(fh));

        // Tiny elapsed time (1 day). With floor math:
        // - mgmtFee on base=10 wei: floor(10 * 0.10 * (1/365)) = 0
        // - perfFee on gain=200,000 at 1 bps: floor(200,000 * 0.0001) = 20
        vm.warp(block.timestamp + 1 days);

        // Expect underflow because:
        // newOwed = (positions - 10) + 0 + 20 = positions + 10  => owed > positions
        vm.expectRevert(stdError.arithmeticError);

        vm.prank(owner);
        valuationHandler.updateShareValue(0);
    }
}

// WYLIS 4
/// @dev Simple accrual mock that applies the *current* rate to the entire elapsed window on each settle.
///      This models the "admin rate change before settle" spike behavior.
contract FeeHandlerAccrualMock is IFeeHandler {
    uint256 public rateBps; // e.g., 800 = 8% APR
    uint256 public lastSettle; // timestamp of last settle
    uint256 public totalOwed; // accumulated fees
    bool private initialized;

    // Admin: set the APR in basis points
    function setRateBps(uint256 _bps) external {
        rateBps = _bps;
    }

    // Called by ValuationHandler.updateShareValue(totalPositionsValue)
    function settleDynamicFeesGivenPositionsValue(uint256 positionsValue) external {
        // First call just initializes the clock
        if (!initialized) {
            initialized = true;
            lastSettle = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - lastSettle;
        lastSettle = block.timestamp;

        // Accrue using the *current* rate across the whole elapsed window.
        // YEAR = 365 days; divide by 10_000 for basis points.
        unchecked {
            uint256 accrual = (positionsValue * rateBps * dt) / (365 days * 10_000);
            totalOwed += accrual;
        }
    }

    function getTotalValueOwed() external view returns (uint256) {
        return totalOwed;
    }

    // --- Unused IFeeHandler methods (no-op stubs to satisfy interface) ---
    function settleEntranceFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }

    function settleExitFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }

    function __setTotalOwed(uint256 x) external {
        totalOwed = x;
        // ensure subsequent settle uses an elapsed window from "now"
        initialized = true;
        lastSettle = block.timestamp;
    }
}

// WYLIS 5
contract FeeHandlerMgmtPerfMock is IFeeHandler {
    // Rates
    uint256 public mgmtRateBps; // e.g., 800 = 8% APR
    uint256 public perfRateBps; // e.g., 2000 = 20% over watermark
    // State
    uint256 public lastSettle; // timestamp
    uint256 public totalOwed; // cumulative fees owed
    uint256 public watermark; // high watermark in "positions value" units
    bool private initialized;

    function setRates(uint256 mgmtBps, uint256 perfBps) external {
        mgmtRateBps = mgmtBps;
        perfRateBps = perfBps;
    }

    function __setTotalOwed(uint256 x) external {
        totalOwed = x;
        initialized = true;
        lastSettle = block.timestamp;
    }

    function __setWatermark(uint256 x) external {
        watermark = x;
    }

    // Ordering: (1) accrue management fee against net (positions - totalOwed), then
    //           (2) charge performance fee on gains vs watermark.
    function settleDynamicFeesGivenPositionsValue(uint256 positionsValue) external {
        uint256 nowTs = block.timestamp;
        if (!initialized) {
            initialized = true;
            lastSettle = nowTs;
            // seed watermark on first call to current positions to avoid immediate perf fee
            if (watermark == 0) {
                watermark = positionsValue;
            }
            return;
        }

        uint256 elapsed = nowTs - lastSettle;
        lastSettle = nowTs;

        // (1) Management on net base over elapsed fraction of a year
        uint256 base = positionsValue > totalOwed ? positionsValue - totalOwed : 0;
        // elapsed / 365d in 1e18 fixed point to avoid precision issues
        uint256 mgmtFee = (base * mgmtRateBps * elapsed) / (365 days) / 10_000;
        totalOwed += mgmtFee;

        // (2) Performance on gains over watermark (no time proration)
        if (positionsValue > watermark && perfRateBps > 0) {
            uint256 gain = positionsValue - watermark;
            uint256 perfFee = (gain * perfRateBps) / 10_000;
            totalOwed += perfFee;
            // conventional: advance watermark to positions after taking perf
            watermark = positionsValue;
        }
    }

    // View-style helpers expected by Shares/ValuationHandler
    function getTotalValueOwed() external view returns (uint256) {
        return totalOwed;
    }

    // Unused in these tests but required by IFeeHandler
    function settleEntranceFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }

    function settleExitFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }
}

// WYLIS 6a (ceil-style rounding)
contract FeeHandlerRoundingUpMock is IFeeHandler {
    uint256 public mgmtRateBps; // e.g., 1000 = 10% APR
    uint256 public perfRateBps; // e.g., 1 = 0.01%
    uint256 public lastSettle;
    uint256 public totalOwed;
    uint256 public watermark;
    bool private initialized;

    function setRates(uint256 _mgmtBps, uint256 _perfBps) external {
        mgmtRateBps = _mgmtBps;
        perfRateBps = _perfBps;
    }

    function __setTotalOwed(uint256 x) external {
        totalOwed = x;
        initialized = true;
        lastSettle = block.timestamp;
    }

    function __setWatermark(uint256 x) external {
        watermark = x;
    }

    function settleDynamicFeesGivenPositionsValue(uint256 positionsValue) external {
        uint256 nowTs = block.timestamp;
        if (!initialized) {
            initialized = true;
            lastSettle = nowTs;
            if (watermark == 0) {
                watermark = positionsValue;
            }
            return;
        }

        uint256 elapsed = nowTs - lastSettle;
        lastSettle = nowTs;

        // Management fee: ceil( base * rateBps * elapsed / (365d * 10_000) )
        uint256 base = positionsValue > totalOwed ? positionsValue - totalOwed : 0;
        if (base > 0 && mgmtRateBps > 0 && elapsed > 0) {
            uint256 num = base * mgmtRateBps * elapsed;
            uint256 den = (365 days) * 10_000;
            uint256 mgmtFee = (num + den - 1) / den; // ceilDiv
            totalOwed += mgmtFee;
        }

        // Performance fee on gains: ceil( (positions - watermark) * perfRateBps / 10_000 )
        if (positionsValue > watermark && perfRateBps > 0) {
            uint256 gain = positionsValue - watermark;
            uint256 num2 = gain * perfRateBps;
            uint256 den2 = 10_000;
            uint256 perfFee = (num2 + den2 - 1) / den2; // ceilDiv
            totalOwed += perfFee;
            // advance watermark after taking perf
            watermark = positionsValue;
        }
    }

    function getTotalValueOwed() external view returns (uint256) {
        return totalOwed;
    }

    function settleEntranceFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }

    function settleExitFeeGivenGrossShares(uint256) external pure returns (uint256) {
        return 0;
    }
}
