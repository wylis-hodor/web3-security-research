# Title
Preview/execute divergence in market borrow allows under-delivery and pool-level revert

## Summary
Preview vs execute parity is broken for market borrows. The contract borrows from pools before enforcing the user’s minOut/slippage bound, so if liquidity drops between preview and execution the tx does not fail early with `InsufficientAmountReceived` but instead bubbles a late pool-level `ERC20InsufficientBalance` revert after moving collateral/approvals. This breaks the advertised slippage guarantee and causes avoidable temporary DoS and gas waste.

## Finding Description
Affected path: `Orderbook.matchMarketBorrowOrder(...)` (market borrow). During execution the contract deposits collateral and calls `pool.borrow(...)` per matched slice **before** it verifies that the aggregate amount now achievable still meets `minAmountExpected`. If liquidity changes after preview (normal churn or adversarial frontrun), a pool can no longer satisfy the requested slice. The code still attempts `borrow(requestedSlice)` and the tx reverts deep in the pool with `ERC20InsufficientBalance` instead of cleanly reverting up front with `InsufficientAmountReceived`.

Security guarantees broken:
1. Slippage/minOut guarantee: Users set `minAmountExpected` based on a preview. Execution should either deliver at least that or revert with `InsufficientAmountReceived` before any state change. Today it can under-deliver and fail late.

2. Canonical error semantics: Off-chain automation cannot rely on a consistent `InsufficientAmountReceived` signal; instead it sees pool-specific reverts.

3. Side-effect-free failure: The tx performs approvals/collateral transfers before discovering `minOut` cannot be met, wasting gas and creating partial side effects on failure.

Why this is not a duplicate of prior preview fixes:

Previous work ensured `previewBorrow` accounts for available liquidity at preview time. This finding is about execution-time ordering: enforcing `minOut` too late and borrowing more than is currently achievable when state has changed between preview and execute.

## Impact Explanation
Impact (Medium):
Breaks the minOut/slippage guarantee and error semantics; causes temporary DoS of the borrow flow under liquidity churn; wastes gas on late failure.

## Likelihood Explanation

Likelihood (High):
Easy to trigger with normal LP activity or trivial adversarial action; MEV can frontrun in the same block; applies across all pairs using the market-borrow aggregator.

## Proof of Concept
Preconditions: `collateralBuffer >= 0.01e18`

1. Seed pool with 1_000e18. Call `previewBorrow(...)` for `amount = 250e18`, get `pv.totalMatched = 250e18` and a `collateralRequired`.

2. Between preview and execute, reduce pool liquidity to 100e18 (e.g., an LP withdraw or competing borrow). An attacker or MEV can do this in the same block; it also occurs organically under churn.

3. Call `matchMarketBorrowOrder(amount=250e18, minOut=pv.totalMatched, collateralBuffer=...)`.

Observed: execution deposits collateral, then calls `pool.borrow(250e18, ...)`, reverting with `ERC20InsufficientBalance`.

Expected: early revert with `InsufficientAmountReceived` before any state change.

```solidity
function testPreviewExecuteParity_MarketBorrow_RevertsEarlyOnMinOut() public {
        // 1) Seed lender liquidity
        vm.prank(lender);
        loanToken.approve(address(pool), 1_000e18);
        vm.prank(lender);
        pool.deposit(1_000e18, lender);

        uint256 amount = 250e18;
        uint256 buf = 0.05e18;

        // 2) Take a quote (preview) in good conditions
        (
            PreviewMatchedOrder memory pv,
            /*unused*/
            ,
            uint256 collateralRequired,
            /*unused2*/
        ) = orderbook.previewBorrow(
            PreviewBorrowParams({
                borrower: borrower,
                amount: amount,
                collateralBuffer: buf,
                rate: 0,
                ltv: 0,
                isMarketOrder: true,
                isCollateral: false
            })
        );

        // Sanity: we previewed full fill
        assertEq(pv.totalMatched, amount, "setup: expected full match in preview");

        // 3) Adversarial change: yank liquidity so only 100e18 remains
        vm.prank(lender);
        pool.withdraw(900e18, lender, lender);

        // 4) Execute with minOut = old preview (amount), must revert with InsufficientAmountReceived
        vm.startPrank(borrower);
        collateralToken.approve(address(orderbook), collateralRequired);
        vm.expectRevert(ErrorsLib.InsufficientAmountReceived.selector); // SHOULD revert here
        orderbook.matchMarketBorrowOrder(amount, pv.totalMatched, buf, 0, 0);
        vm.stopPrank();
    }
```

## Recommendation

  - Ensure the tx reverts early with `InsufficientAmountReceived` before any state change if `minOut` cannot be met. No  pool-level `ERC20InsufficientBalance` bubbling up.

  - Waste less gas. Do a view-only preflight to compute the achievable aggregate, compare to `minOut`, and only then move tokens. Deposit collateral once, after the check.

  - Clamp each per-pool borrow to its fresh preview amount in the same tx so execution never calls `borrow` for more than is currently available.

One possible remediation (Plan-then-execute): Inside `matchMarketBorrowOrder`, perform a view-only plan (reusing the same routing logic as preview) to compute per-pool amounts and `collateralRequired` from _current_ state. If the planned `aggregate < minAmountExpected`, revert `InsufficientAmountReceived` before any state changes. Otherwise, borrow exactly the planned per-pool amounts.