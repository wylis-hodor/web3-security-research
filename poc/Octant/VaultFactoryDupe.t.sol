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

    function test_HappyPath_NewVaultAndIndexEvent() public {
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

        // Decode emitted logs like an indexer
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawNewVault = false;
        for (uint256 i = 0; i < logs.length; i++) {
            // topic0 = keccak256("NewVault(address,address)")
            if (logs[i].topics.length == 3 && logs[i].topics[0] == keccak256("NewVault(address,address)")) {
                address evVault = address(uint160(uint256(logs[i].topics[1])));
                address evAsset = address(uint160(uint256(logs[i].topics[2])));

                console2.log("=== NewVault event decoded ===");
                console2.log("Vault address:", evVault);
                console2.log("Asset address:", evAsset);
                console2.log("Vault name:", IMultistrategyVault(vaultAddr).name());
                console2.log("Vault symbol:", IMultistrategyVault(vaultAddr).symbol());
                console2.log("Asset name:", IERC20Metadata(evAsset).name());
                console2.log("Asset symbol:", IERC20Metadata(evAsset).symbol());

                assertEq(evVault, vaultAddr);
                assertEq(evAsset, address(token));
                sawNewVault = true;
            }
        }
        assertTrue(sawNewVault, "NewVault event not found");
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
    }
}
