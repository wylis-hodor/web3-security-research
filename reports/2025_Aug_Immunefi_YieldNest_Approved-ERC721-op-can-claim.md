# Title

Approved ERC-721 operator can claim and redirect withdrawal proceeds — direct theft of user funds (WithdrawalQueueManager)
Submitted 21 days ago by @wylis (Whitehat) for YieldNest

# Target

Primacy of Impact

# Impact(s)

Direct theft of any user funds, whether at-rest or in-motion, other than unclaimed yield

# PoC Link

https://gist.github.com/wylis-hodor/009bda1bd34fdc71c1249871217d4a8c

# Description

## Intro

An approved ERC-721 operator of a YieldNest withdrawal-claim NFT can call `claimWithdrawal` and set a `receiver`, causing the vault to transfer the ETH proceeds to that address while burning the NFT. Because the contract authorizes owner **or approved**, a marketplace listing lets the exchange’s operator redirect the user’s withdrawal to themselves or a third party. This flaw enables **direct theft of user funds in motion** whenever a claim NFT is approved to a non-owner.

## Vulnerability Details

**Root cause — over-permissive authorization for a funds-moving action.**

In `WithdrawalQueueManager._claimWithdrawal()`, the caller check allows owner **or** approved to execute a *payout*:

```solidity
if (_ownerOf(claim.tokenId) != msg.sender && _getApproved(claim.tokenId) != msg.sender) {
    revert CallerNotOwnerNorApproved(claim.tokenId, msg.sender);
}
```

This only reverts if the caller is **neither** the owner **nor** the per-token approved address. As a result, any address approved via standard ERC-721 `approve(tokenOperator, tokenId)` can pass this gate even when it is not the owner.

**Second flaw — ungoverned receiver.**

The claim request provides an arbitrary `receiver` and the contract does not validate that it equals the NFT owner:

```solidity
address receiver = claim.receiver;
```

Combining these two issues yields a condition where a marketplace/operator that holds per-token ERC-721 approval (granted during listing) can call `claimWithdrawal` and set `receiver` to itself or any third party, redirecting the full ETH payout away from the rightful owner while burning the NFT.

ERC-721 approval is intended to authorize token transfer/listing, not to delegate custody over external cash flows tied to that token. Treating “approved” as equivalent to “owner” for a funds-moving action expands authorization beyond user intent and typical marketplace expectations.

This is not an “NFT-only” issue: the loss is the ETH redemption proceeds (“funds in motion”), not just control over an NFT.

Protocols like Lido demonstrate the correct guard.  Claims should be restricted to the owner only (no operator substitution), e.g. in `WithdrawalQueueBase._claim()`:

```solidity
if (request.owner != msg.sender) revert NotOwner(msg.sender, request.owner);
```

This prevents marketplace operators from executing the payout; only the owner can trigger the transfer, eliminating the vector.

## Impact Details

* **Primary impact:** Direct theft user funds.
* **Scope:** Any finalized, unclaimed withdrawal-claim NFT whose owner has granted an ERC-721 approval is vulnerable, and an attacker can steal up to 100% of the net redemption for each such claim.
* **Loss magnitude:** System-wide impact scales to the sum of all finalized & unclaimed claims at exploit time, bounded by vault liquidity.


## Proof of Concept

Attached two Foundry tests demonstrate that an approved ERC-721 operator (not the owner) can execute `claimWithdrawal` and choose the payout `receiver`, redirecting ETH to themselves or to any third party.

1. User requests a withdrawal (mints claim NFT).
Call `requestWithdrawal(amount)` from the user.
Result: an ERC-721 claim NFT (`tokenId`) is minted to the user; ynETH is pulled in.

2. Finalizer finalizes the request (sets redemption rate).
Call `manager.finalizeRequestsUpToIndex(tokenId + 1)`.

3. User grants marketplace-style approval to operator.
Call `approve(attacker, tokenId)`.

4. Operator performs the claim using the NFT approval (not the owner).

* Self-redirect case (`testApprovedOperatorCanRedirectProceeds`):
Operator calls `claimWithdrawal({ tokenId, finalizationId, receiver: attacker });`

* Third-party redirect case (`testApprovedOperatorCanRedirectProceeds_ToThirdParty`):
Operator calls `claimWithdrawal({ tokenId, finalizationId, receiver: thirdParty });`

5. Contract accepts the operator and pays the chosen receiver.
Because `_claimWithdrawal` checks owner **or** approved, the operator passes authorization and the contract uses the supplied `receiver`.

6. Observe on-chain effects.

* NFT is burned: Transfer(owner → 0x0, tokenId).

* Vault pays ETH: Net proceeds (e.g., 9.9 ETH for a 10 ETH claim with 1% fee) sent to `receiver` (attacker or thirdParty).

* Owner cannot claim again: a follow-up owner claim reverts (e.g., `CallerNotOwnerNorApproved`), confirming the payout is gone.

## Gist

https://gist.github.com/wylis-hodor/009bda1bd34fdc71c1249871217d4a8c
