// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmWager} from "src/SwarmWager.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";
import {SwarmWagerHandler} from "./helpers/SwarmWagerHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmWagerInvariantTest is Test {
    PaymentToken private token;
    RecordingIntake private intake;
    AskSwarmRegistry private registry;
    SwarmWager private wager;
    SwarmWagerHandler private handler;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        token = new PaymentToken();
        intake = new RecordingIntake(address(token), makeAddr("wager fee recipient"), makeAddr("wager writer"));
        registry = new AskSwarmRegistry(address(intake), address(token), vm.addr(0xA11CE));
        wager = new SwarmWager(address(registry), address(token));
        address[4] memory actors =
            [makeAddr("wager alice"), makeAddr("wager bob"), makeAddr("wager carol"), makeAddr("wager dave")];
        handler = new SwarmWagerHandler(wager, registry, token, intake, actors);
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], handler.INITIAL());
            vm.prank(actors[i]);
            token.approve(address(wager), type(uint256).max);
        }

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.join.selector;
        selectors[2] = handler.topUp.selector;
        selectors[3] = handler.resolve.selector;
        selectors[4] = handler.deliver.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.cancel.selector;
        selectors[7] = handler.abandon.selector;
        selectors[8] = handler.changePrice.selector;
        selectors[9] = handler.advanceTime.selector;
        selectors[10] = handler.donate.selector;
        selectors[11] = handler.wrongState.selector;
        selectors[12] = handler.failingResolve.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));

        // Start with both winning sides, a refund, a pending ask, an open wager and a
        // matched wager. Even an unlucky random sequence begins with meaningful exposure.
        handler.create(0, 1, true, 1, bytes32("dust yes"));
        handler.create(1, type(uint96).max, false, 1, bytes32("maximum no"));
        handler.create(2, 3 ether, true, 1, bytes32("refused"));
        handler.create(3, 2 ether, false, 1, bytes32("pending"));
        handler.create(0, 1 ether, false, 1 days, bytes32("open"));
        handler.create(1, 4 ether, true, 1, bytes32("matched"));
        handler.join(0, 1);
        handler.join(1, 0);
        handler.join(2, 3);
        handler.join(3, 0);
        handler.join(5, 2);
        handler.topUp(5, 3, 5);
        vm.warp(vm.getBlockTimestamp() + 2);
        handler.resolve(0, 2);
        handler.resolve(1, 3);
        handler.resolve(2, 0);
        handler.resolve(3, 1);
        handler.deliver(0, 0);
        handler.settle(0, 3);
        handler.deliver(1, 1);
        handler.settle(1, 2);
        handler.deliver(2, 2);
        handler.settle(2, 0);
        handler.donate(2, 1);
        handler.failingResolve(5);
        handler.assertAccounting();
        handler.assertRecords();
    }

    function invariant_escrowAndEveryActorBalanceReconcile() public view {
        handler.assertAccounting();
    }

    function invariant_termsRequestsAndTerminalStatesStayConsistent() public view {
        handler.assertRecords();
    }

    function afterInvariant() public {
        handler.closeAll();
    }

    function test_handlerReachesEveryOutcomeAndAllExitPaths() public {
        for (uint8 mode; mode < 12; ++mode) {
            uint256 seed = handler.created();
            handler.create(mode % 4, 1 + mode, mode % 2 == 0, 1, bytes32(uint256(mode)));
            handler.join(seed, (mode + 1) % 4);
            vm.warp(vm.getBlockTimestamp() + 2);
            handler.resolve(seed, (mode + 2) % 4);
            handler.deliver(seed, mode);
            handler.settle(seed, (mode + 3) % 4);
            assertGt(handler.deliveredModes(mode), 0, "outcome handler was vacuous");
            handler.assertAccounting();
            handler.assertRecords();
        }
        for (uint8 op; op < 6; ++op) {
            for (uint256 state; state < 6; ++state) {
                handler.wrongState(state, op, state);
            }
        }
        handler.closeAll();
        assertGt(handler.paid(), 0);
        assertGt(handler.refunded(), 0);
        assertGt(handler.cancelled(), 0);
        assertGt(handler.abandoned(), 0);
        assertGt(handler.failedCalls(), 0);
        assertEq(handler.created(), handler.paid() + handler.refunded() + handler.cancelled() + handler.abandoned());
    }
}
