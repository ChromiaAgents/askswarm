// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmWager} from "src/SwarmWager.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RecordingIntake} from "./helpers/RegistryTestSupport.sol";
import {WagerFaultToken} from "./mocks/WagerFaultToken.sol";

contract SwarmWagerAtomicityTest is Test {
    uint256 private constant KEY = 0xA11CE;
    uint256 private constant INITIAL = uint256(type(uint96).max) * 10;
    uint256 private constant FEE = 0.5 ether;
    WagerFaultToken private token;
    RecordingIntake private intake;
    AskSwarmRegistry private registry;
    SwarmWager private wager;
    address private alice;
    address private bob;
    address private keeper;
    address private recipient;
    address private writer;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        alice = makeAddr("atomic alice");
        bob = makeAddr("atomic bob");
        keeper = makeAddr("atomic keeper");
        recipient = makeAddr("atomic recipient");
        writer = makeAddr("atomic writer");
        token = new WagerFaultToken();
        intake = new RecordingIntake(address(token), recipient, writer);
        registry = new AskSwarmRegistry(address(intake), address(token), vm.addr(KEY));
        wager = new SwarmWager(address(registry), address(token));
        token.mint(alice, INITIAL);
        token.mint(bob, INITIAL);
        vm.prank(alice);
        token.approve(address(wager), INITIAL);
        vm.prank(bob);
        token.approve(address(wager), INITIAL);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedPaymentPreservesConcurrentEscrow(uint8 op, uint8 leg, uint8 mode, uint96 stake) public {
        _failureCase(op % 8, leg, WagerFaultToken.Reply(2 + mode % 4), stake == 0 ? 1 : stake);
    }

    function test_everyPaymentLegRejectsFalseRevertAndMalformedReturns() public {
        for (uint8 op; op < 8; ++op) {
            uint256 legs = op == 3 ? 5 : op == 5 ? 3 : op == 7 ? 2 : 1;
            for (uint8 leg; leg < legs; ++leg) {
                for (uint8 mode = 2; mode < 6; ++mode) {
                    uint256 snapshot = vm.snapshotState();
                    _failureCase(op, leg, WagerFaultToken.Reply(mode), 3 ether);
                    assertTrue(vm.revertToStateAndDelete(snapshot));
                }
            }
        }
    }

    function _failureCase(uint8 op, uint8 leg, WagerFaultToken.Reply mode, uint96 stake) private {
        uint256 id = 1;
        if (op != 0) id = _create(stake);
        if (op == 2 || op == 3 || op == 5 || op >= 6) {
            vm.prank(bob);
            wager.join(id);
        }
        if (op == 3 || op == 5 || op >= 6) vm.warp(vm.getBlockTimestamp() + 2);
        if (op >= 6) {
            wager.resolve(id);
            _deliver(id, op == 7);
        }
        if (op == 5) vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        if (op == 3) intake.setPrice(FEE / 2); // ensure resolve also has a nonzero remainder transfer

        // Leave an unrelated open wager funded: failures and retries cannot borrow its escrow.
        uint256 sentinel;
        if (op != 0) sentinel = _create(17);
        bytes32 sentinelBefore = sentinel == 0 ? bytes32(0) : _record(sentinel);
        bytes memory data;
        address actor = keeper;
        address faultCaller = address(wager);
        bytes4 selector = token.transfer.selector;
        uint256 ordinal = 1;
        if (op == 0) {
            data = abi.encodeCall(
                wager.create,
                (bytes("{}"), false, stake, uint64(vm.getBlockTimestamp() + 1), uint64(vm.getBlockTimestamp() + 2))
            );
            actor = alice;
            selector = token.transferFrom.selector;
        } else if (op == 1) {
            data = abi.encodeCall(wager.join, (id));
            actor = bob;
            selector = token.transferFrom.selector;
        } else if (op == 2) {
            data = abi.encodeCall(wager.topUpFee, (id, uint96(1)));
            actor = bob;
            selector = token.transferFrom.selector;
        } else if (op == 3) {
            data = abi.encodeCall(wager.resolve, (id));
            uint256 selected = leg % 5;
            faultCaller =
                selected == 1 || selected == 2 ? address(registry) : selected == 3 ? address(intake) : address(wager);
            selector = selected == 0 || selected == 2
                ? token.approve.selector
                : selected == 4 ? token.transfer.selector : token.transferFrom.selector;
        } else if (op == 4) {
            data = abi.encodeCall(wager.cancel, (id));
            actor = alice;
        } else if (op == 5) {
            data = abi.encodeCall(wager.abandon, (id));
            ordinal = 1 + leg % 3; // yes stake, no stake, creator's fee
        } else {
            data = abi.encodeCall(wager.settle, (id));
            ordinal = op == 7 ? 1 + leg % 2 : 1;
        }
        token.configure(faultCaller, selector, ordinal, mode);
        bytes32 beforeState = _snapshot(id);
        vm.prank(actor);
        (bool success,) = address(wager).call(data);
        // A reverted refund or remainder leg is credited to its recipient rather than undoing the
        // call (finding d4e9fc2df017): the call succeeds and the recipient withdraws later.
        bool credited = mode == WagerFaultToken.Reply.Revert && ((op == 3 && leg % 5 == 4) || op == 5 || op == 7);
        if (credited) {
            assertTrue(success, "a reverted refund leg blocked the call");
            if (sentinel != 0) assertEq(_record(sentinel), sentinelBefore);
            token.configure(address(0), bytes4(0), 0, WagerFaultToken.Reply.True);
            // The fault token's call counter rolls back with the reverted leg, so later legs of the
            // same call may fault too; each is credited and the reconciliation below checks the sum.
            assertGt(wager.owed(alice) + wager.owed(bob), 0, "no leg was credited");
            if (wager.owed(alice) != 0) {
                vm.prank(alice);
                wager.withdraw();
            }
            if (wager.owed(bob) != 0) {
                vm.prank(bob);
                wager.withdraw();
            }
            assertEq(wager.owed(alice) + wager.owed(bob), 0);
            _exitAndReconcile(op, id, stake, sentinel);
            return;
        }
        assertFalse(success, "an unsuccessful token operation was accepted");
        assertEq(_snapshot(id), beforeState, "failure partially changed state, balances, or allowances");
        assertEq(token.calls(), 0, "failed token side effects survived");
        if (sentinel != 0) assertEq(_record(sentinel), sentinelBefore);

        token.configure(address(0), bytes4(0), 0, WagerFaultToken.Reply.True);
        vm.prank(actor);
        (success,) = address(wager).call(data);
        assertTrue(success, "same operation was not retryable after token recovery");
        if (sentinel != 0) assertEq(_record(sentinel), sentinelBefore);

        _exitAndReconcile(op, id, stake, sentinel);
    }

    function _exitAndReconcile(uint8 op, uint256 id, uint96 stake, uint256 sentinel) private {
        // Bring the target to an exit and account for each participant independently.
        SwarmWager.Wager memory w = _w(id);
        uint256 spent = op == 3 ? FEE / 2 : op >= 6 ? FEE : 0;
        if (w.state == SwarmWager.State.Open) {
            vm.prank(alice);
            wager.cancel(id);
        } else if (w.state == SwarmWager.State.Matched) {
            vm.warp(uint256(w.resolveAfter) + 3 days + 1);
            wager.abandon(id);
        } else if (w.state == SwarmWager.State.Asked) {
            vm.warp(uint256(w.askedAt) + 3 days + 1);
            wager.settle(id);
        }
        uint256 sentinelEscrow = sentinel == 0 ? 0 : 17 + (op == 3 ? FEE / 2 : FEE);
        uint256 gift = op == 2 ? 1 : 0;
        // The creator chose no; the only winning path above delivers yes to Bob.
        assertEq(token.balanceOf(alice), INITIAL - sentinelEscrow - spent + gift - (op == 6 ? stake : 0));
        assertEq(token.balanceOf(bob), INITIAL - gift + (op == 6 ? stake : 0));
        assertEq(token.balanceOf(keeper), 0, "permissionless keeper took funds");
        assertEq(token.balanceOf(address(wager)), sentinelEscrow);
        assertEq(token.balanceOf(recipient), spent);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(wager), address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(registry.asked(), spent == 0 ? 0 : 1);
        assertEq(intake.nonce(), registry.asked());
    }

    function test_noReturnTokenCompletesWinsRefundsCancellationAndAbandonment() public {
        token.configure(address(0), bytes4(0), 0, WagerFaultToken.Reply.Empty);
        uint256 winnerId = _create(1);
        vm.prank(bob);
        wager.join(winnerId);
        vm.warp(vm.getBlockTimestamp() + 2);
        intake.setPrice(FEE / 2);
        wager.resolve(winnerId);
        _deliver(winnerId, false);
        wager.settle(winnerId);
        assertEq(_w(winnerId).winner, bob);

        uint256 refundId = _create(type(uint96).max);
        vm.prank(bob);
        wager.join(refundId);
        vm.warp(vm.getBlockTimestamp() + 2);
        wager.resolve(refundId);
        _deliver(refundId, true);
        wager.settle(refundId);

        uint256 cancelId = _create(1);
        vm.prank(alice);
        wager.cancel(cancelId);
        uint256 abandonId = _create(type(uint96).max);
        vm.prank(bob);
        wager.join(abandonId);
        vm.prank(bob);
        wager.topUpFee(abandonId, 1);
        vm.warp(vm.getBlockTimestamp() + 3 days + 3);
        wager.abandon(abandonId);
        assertEq(token.balanceOf(address(wager)), 0);
        assertEq(token.balanceOf(alice), INITIAL - FEE);
        assertEq(token.balanceOf(bob), INITIAL);
        assertEq(token.balanceOf(recipient), FEE);
        assertEq(token.allowance(address(wager), address(registry)), 0);
    }

    function _create(uint96 stake) private returns (uint256) {
        vm.prank(alice);
        return
            wager.create(
                bytes("{}"), false, stake, uint64(vm.getBlockTimestamp() + 1), uint64(vm.getBlockTimestamp() + 2)
            );
    }

    function _w(uint256 id) private view returns (SwarmWager.Wager memory w) {
        (w,) = wager.get(id);
    }

    function _record(uint256 id) private view returns (bytes32) {
        (SwarmWager.Wager memory w, bytes memory body) = wager.get(id);
        return keccak256(abi.encode(w, body));
    }

    function _snapshot(uint256 id) private view returns (bytes32) {
        uint256[9] memory money = [
            token.balanceOf(alice),
            token.balanceOf(bob),
            token.balanceOf(address(wager)),
            token.balanceOf(address(registry)),
            token.balanceOf(address(intake)),
            token.balanceOf(recipient),
            token.allowance(alice, address(wager)),
            token.allowance(bob, address(wager)),
            token.totalSupply()
        ];
        return keccak256(
            abi.encode(
                _record(id),
                wager.count(),
                registry.asked(),
                intake.nonce(),
                money,
                token.allowance(address(wager), address(registry)),
                token.allowance(address(registry), address(intake))
            )
        );
    }

    function _deliver(uint256 id, bool refused) private {
        bytes32 rid = _w(id).requestId;
        if (refused) {
            vm.prank(writer);
            assertTrue(
                intake.complete(
                    rid, 1, abi.encode(rid, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
                )
            );
            return;
        }
        OracleAttestation memory a;
        a.requestId = keccak256(abi.encode("atomic UUID", rid));
        a.chainId = 1;
        a.questionHash = keccak256("atomicity fixture");
        a.answer = abi.encode(true);
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 3;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.digest(a));
        vm.prank(writer);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v))));
    }
}
