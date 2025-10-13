# Title
Keeper-initiated borrower order cancellation/matching misattributes event fields to keeper instead of the order owner

## Summary
Keeper-initiated borrower order cancellation/matching misattributes event fields (`maker/borrower`) to `msg.sender` (keeper) instead of the order owner.

## Finding Description
When a keeper calls `matchLimitBorrowOrder(borrower, ...)`, the contract emits:

* `OrderCanceled(isLender=false, maker=<keeper>, ...)` instead of `maker=<borrower>`

* `OrderMatched(..., borrower=<keeper>, ...)` instead of the real borrower

This breaks off-chain consumers that rely on events to drive state (subgraphs/ETL/UX). Typical symptoms:

* Borrower’s canceled orders remain “open” in UIs that filter OrderCanceled.maker == borrower

* Misattributed history (keeper appears to have been the borrower)

*Off-chain automations that reconcile by maker fail to settle correctly

No fund loss or protocol DoS; on-chain state remains correct.

### Root cause
Event parameters use msg.sender in keeper paths rather than the order owner (borrower for borrow orders; pool/lender address for lend orders).

## Impact Explanation
Low (no funds at risk; incorrect event attribution).

* Indexers/UX that key off maker/borrower show canceled orders as open or attribute matches to the keeper.

* Off-chain automations that reconcile by maker mis-settle.

## Likelihood Explanation
High (any keeper-triggered match will hit it).

## Proof of Concept
Reference my test:

```solidity
function testEvent_MakerOnBorrowCancel_IsBorrower_NotKeeper() public {
        // Arrange: same setup as IOC test but do not flood with extra details
        vm.prank(lender);
        loanToken.approve(address(pool), 30e18);
        vm.prank(lender);
        pool.deposit(30e18, lender);

        uint64 rate = 2e18;
        uint64 ltv = 0.5e18;
        uint256 amount = 100e18;
        uint256 collateralBuffer = 0.05e18;

        (,, uint256 collateralRequired,) = orderbook.previewBorrow(
            PreviewBorrowParams({
                borrower: borrower,
                amount: amount,
                collateralBuffer: collateralBuffer,
                rate: rate,
                ltv: ltv,
                isMarketOrder: false,
                isCollateral: false
            })
        );

        vm.startPrank(borrower);
        collateralToken.approve(address(orderbook), collateralRequired);
        orderbook.insertLimitBorrowOrder(rate, ltv, amount, 0, collateralBuffer, collateralRequired);
        vm.stopPrank();

        vm.recordLogs();

        vm.prank(keeper);
        orderbook.matchLimitBorrowOrder(borrower, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("OrderCanceled(bool,address,uint256,uint256,uint256)");

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(orderbook)) continue;
            if (logs[i].topics[0] != sig) continue;

            // If `maker` is indexed in the event, it will be in topics.
            if (logs[i].topics.length > 2) {
                address maker = address(uint160(uint256(logs[i].topics[2])));
                assertEq(maker, borrower, "maker (indexed) != borrower");
                found = true;
                break;
            } else {
                (bool isLender, address maker,,,) = abi.decode(logs[i].data, (bool, address, uint256, uint256, uint256));
                assertFalse(isLender);
                assertEq(maker, borrower, "maker (data) != borrower");
                found = true;
                break;
            }
        }
        assertTrue(found, "OrderCanceled not found");
    }
 ```
 
 Place test in `test/OrderbookTest.t.sol`.   Expect revert `[Revert] maker (indexed) != borrower: 0xC3f2c61C4836Afeb9Ae601c91F6FE661df3D634E != 0x7d8A6b343f153D9d026466636ED35cA13C367fD2` which is due to `emit OrderCanceled(isLender: false, maker: keeper: [0xC3f2c61C4836Afeb9Ae601c91F6FE661df3D634E], rate: 2000000000000000000 [2e18], ltv: 500000000000000000 [5e17], amount: 100000000000000000000 [1e20])`.  
 
  When fixed, the event is `emit OrderCanceled(isLender: false, maker: borrower: [0x7d8A6b343f153D9d026466636ED35cA13C367fD2], rate: 2000000000000000000 [2e18], ltv: 500000000000000000 [5e17], amount: 100000000000000000000 [1e20])`, which passes the test. 
 
## Recommendation
In the keeper match/cancel paths emit borrower or maker instead of keeper (msg.sender).  E.g. in In OrderbookLib._cancelOrder this fixes the PoC:

```solidity
// Read storage BEFORE removal
address maker = entry.account;

tree.removeEntry(compositeKey, entryIndex);

emit EventsLib.OrderCanceled(isLender, maker, rate, ltv, amount);
```

Mirror on the lender side for keeper-driven cancellation emits `maker = msg.sender`.