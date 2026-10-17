// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport} from "./helpers/RegistryTestSupport.sol";

/// The second launch's independent review: the index must respect an answer's validity window
/// (a97feadf), a caller must be able to cap the price an ask pulls (7b194c37), and an ask Intake
/// completed without reaching either hook must have a terminal state (8f2c2abc).
contract AskSwarmRegistryReviewTest is RegistryTestSupport {
    event Indexed(bytes32 indexed questionHash, bytes32 indexed requestId);
    event Lost(bytes32 indexed requestId);

    // ---- a97feadf: the displacement rule covers issuedAt and expiresAt ----

    /// The reviewer's scenario: an equal-strength answer valid for 60 s must not evict one valid
    /// for 30 days, so the question cannot be left open to a 2-of-2 panel a minute later.
    function test_shortLivedEqualAnswerCannotCutHeldValidityShort() public {
        bytes32 strong = _store("no", 15, 11, 11, START, START + 30 days);
        assertTrue(registry.isCurrent(QUESTION));

        bytes32 shortLived = _store("no", 15, 11, 11, START, START + 60);
        assertEq(registry.latestFor(QUESTION), strong, "60 s answer evicted a 30-day one");
        (, AskSwarmRegistry.Answer memory recorded) = registry.get(shortLived);
        assertTrue(recorded.verified, "still a verified delivery, for the record");

        vm.warp(START + 61);
        assertTrue(registry.isCurrent(QUESTION));
        (bytes32 filtered,) = registry.answerOf(QUESTION, 15, 11);
        assertEq(filtered, strong);

        bytes32 weak = _store("yes", 2, 2, 2, START + 61, START + 61 + 30 days);
        assertEq(registry.latestFor(QUESTION), strong, "2-of-2 captured the index");
        (bytes32 heldId, AskSwarmRegistry.Answer memory held) = registry.answerOf(QUESTION);
        assertEq(heldId, strong);
        assertEq(held.answer, bytes("no"));
        assertTrue(weak != heldId);

        // After the strong answer's own window, the next eligible delivery takes the index.
        vm.warp(START + 30 days + 1);
        assertFalse(registry.isCurrent(QUESTION));
        bytes32 later = _store("yes", 2, 2, 2, START + 30 days + 1, START + 31 days);
        assertEq(registry.latestFor(QUESTION), later);
    }

    /// Out-of-order delivery: an equal-strength answer issued earlier than the held one does not
    /// displace it, nor does one that is fresher but expires sooner. Matching on every count and
    /// beating on none still displaces on delivery (the later delivery wins, as before).
    function test_staleOrShorterLivedEqualAnswerDoesNotDisplaceOnDelivery() public {
        vm.warp(START + 100);
        bytes32 newer = _store("newer", 15, 11, 11, START + 100, START + 1 days);
        _store("issued earlier", 15, 11, 11, START, START + 1 days);
        assertEq(registry.latestFor(QUESTION), newer, "older issuedAt displaced a newer answer");
        _store("issued earlier, lives longer", 15, 11, 11, START, START + 2 days);
        assertEq(registry.latestFor(QUESTION), newer, "longer validity does not excuse staleness");
        _store("as fresh, expires sooner", 15, 11, 11, START + 100, START + 1 days - 1);
        assertEq(registry.latestFor(QUESTION), newer);
        _store("stronger but expires sooner", 20, 14, 16, START + 100, START + 1 days - 1);
        assertEq(registry.latestFor(QUESTION), newer, "strength does not excuse a shorter window");

        bytes32 tie = _store("tie", 15, 11, 11, START + 100, START + 1 days);
        assertEq(registry.latestFor(QUESTION), tie, "a delivery matching on every count takes the index");
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, newer));
        registry.reindex(newer);

        bytes32 fresher = _store("fresher", 15, 11, 11, START + 101, START + 1 days);
        assertEq(registry.latestFor(QUESTION), fresher);
        bytes32 longer = _store("lives longer", 15, 11, 11, START + 101, START + 1 days + 1);
        assertEq(registry.latestFor(QUESTION), longer);
        bytes32 stronger = _store("stronger", 16, 11, 12, START + 101, START + 1 days + 1);
        assertEq(registry.latestFor(QUESTION), stronger);
    }

    function test_deliveryEmitsIndexedOnlyWhenTheIndexMoves() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, "first");
        bytes memory signature = _sign(a);
        vm.expectEmit(true, true, false, false, address(registry));
        emit Indexed(QUESTION, id);
        _deliver(id, a, signature);

        bytes32 weaker = _ask();
        OracleAttestation memory w = _attestation(weaker, "weaker");
        w.panelSize = 2;
        w.quorum = 2;
        w.agreed = 2;
        bytes memory ws = _sign(w);
        vm.recordLogs();
        _deliver(weaker, w, ws);
        bytes32 topic = keccak256("Indexed(bytes32,bytes32)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != topic, "Indexed emitted although the index did not move");
        }
    }

    // ---- a97feadf, consequence (a): reindex ----

    /// A weaker, longer-lived majority answer delivered while a stronger short-lived one is current
    /// is not indexed; once the strong one expires, anyone can point the index at it.
    function test_reindexFallsBackToAValidAnswerAfterTheHeldOneExpires() public {
        bytes32 strong = _store("strong, 60 s", 20, 14, 16, START, START + 60);
        bytes32 weak = _store("weaker, 30 days", 15, 11, 11, START, START + 30 days);
        assertEq(registry.latestFor(QUESTION), strong);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, weak));
        registry.reindex(weak);

        vm.warp(START + 61);
        assertFalse(registry.isCurrent(QUESTION), "index is dark");
        (bytes32 none,) = registry.answerOf(QUESTION, 0, 0);
        assertEq(none, bytes32(0));

        vm.expectEmit(true, true, false, false, address(registry));
        emit Indexed(QUESTION, weak);
        vm.prank(bob); // anyone, not only the asker
        registry.reindex(weak);
        assertEq(registry.latestFor(QUESTION), weak);
        assertTrue(registry.isCurrent(QUESTION));
        (bytes32 current, AskSwarmRegistry.Answer memory a) = registry.answerOf(QUESTION, 15, 11);
        assertEq(current, weak);
        assertEq(a.answer, bytes("weaker, 30 days"));

        // The held answer itself is a tie with itself: not re-indexable, so nothing can churn.
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, weak));
        registry.reindex(weak);
        // The expired strong answer cannot come back.
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, strong));
        registry.reindex(strong);
        (, AskSwarmRegistry.Answer memory old) = registry.get(strong);
        assertTrue(old.verified, "history is untouched");
    }

    /// Among several valid fallbacks, a later reindex only replaces an earlier one it strictly
    /// beats, so a weak fallback cannot block a stronger one and ties cannot ping-pong.
    function test_reindexReplacesAFallbackOnlyByStrictDominance() public {
        bytes32 strong = _store("strong, 60 s", 20, 14, 16, START, START + 60);
        bytes32 weak = _store("2 of 2", 2, 2, 2, START, START + 30 days);
        bytes32 mid = _store("11 of 15", 15, 11, 11, START, START + 30 days);
        bytes32 midTwin = _store("11 of 15 twin", 15, 11, 11, START, START + 30 days);
        assertEq(registry.latestFor(QUESTION), strong);

        vm.warp(START + 61);
        registry.reindex(weak);
        assertEq(registry.latestFor(QUESTION), weak);
        registry.reindex(mid);
        assertEq(registry.latestFor(QUESTION), mid, "stronger fallback must take over a weaker one");
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, weak));
        registry.reindex(weak);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, midTwin));
        registry.reindex(midTwin);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, mid));
        registry.reindex(mid);
        assertEq(registry.latestFor(QUESTION), mid);
    }

    function test_reindexRefusesEveryIneligibleRecord() public {
        bytes32 held = _store("held", 15, 11, 11, START, START + 1 days);

        bytes32 unknown = keccak256("never asked");
        bytes32 pending = _ask();
        bytes32 unverified = _ask();
        OracleAttestation memory u = _attestation(unverified, "tampered");
        u.panelSize = 100;
        u.agreed = 100;
        bytes memory su = _sign(u);
        u.figure ^= 1;
        _deliver(unverified, u, su);
        bytes32 minority = _store("minority", 20, 2, 10, START, START + 2 days);
        bytes32 weaker = _store("weaker", 14, 11, 11, START, START + 2 days);
        bytes32 expiring = _store("expired", 100, 51, 100, START, START + 10);
        vm.warp(START + 11);

        bytes32[6] memory ids = [unknown, pending, unverified, minority, weaker, expiring];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, ids[i]));
            registry.reindex(ids[i]);
        }
        assertEq(registry.latestFor(QUESTION), held);
        assertTrue(registry.isCurrent(QUESTION));
    }

    // ---- 7b194c37: a price ceiling ----

    function test_askAtMostRefusesAPriceAboveTheCeiling() public {
        uint256 before = token.balanceOf(alice);
        assertEq(registry.price(), 0.5 ether, "the quote alice saw");
        intake.setPrice(10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.PriceAboveMax.selector, 10 ether, 0.5 ether));
        registry.askAtMost("{}", 0.5 ether);
        assertEq(token.balanceOf(alice), before, "a refused ask charged its caller");
        assertEq(registry.asked(), 0);
        assertEq(intake.nonce(), 0);

        // exactly the ceiling is accepted and pulls exactly the live price
        vm.prank(alice);
        bytes32 id = registry.askAtMost("{}", 10 ether);
        assertEq(token.balanceOf(alice), before - 10 ether);
        assertEq(token.balanceOf(recipient), 10 ether);
        (AskSwarmRegistry.Ask memory k,) = registry.get(id);
        assertEq(k.asker, alice);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(token.balanceOf(address(registry)), 0);

        // a ceiling above the price pulls the price, not the ceiling
        intake.setPrice(0.5 ether);
        vm.prank(alice);
        registry.askAtMost("{}", type(uint256).max);
        assertEq(token.balanceOf(alice), before - 10.5 ether);

        // the price-zero case still reads NotSold, not PriceAboveMax
        intake.setPrice(0);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.NotSold.selector);
        registry.askAtMost("{}", 0);
    }

    /// `ask(bytes)` keeps its documented behaviour: it pays whatever Intake quotes when mined.
    function test_askWithoutCeilingStillPaysTheLivePrice() public {
        intake.setPrice(10 ether);
        uint256 before = token.balanceOf(alice);
        _ask();
        assertEq(token.balanceOf(alice), before - 10 ether);
    }

    // ---- 8f2c2abc: Lost ----

    /// The reviewer's scenario: ask B is completed on Intake with A's arguments, the registry refuses
    /// the replay, and B would stay Pending forever. Anyone can now mark it Lost; before Intake has
    /// completed it, nobody can.
    function test_markLostSettlesAnAskIntakeCompletedWithoutDelivering() public {
        bytes32 a = _store("answer", 15, 11, 11, START, START + 1 days);
        bytes32 b = _ask();
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.StillOpen.selector, b));
        registry.markLost(b);

        OracleAttestation memory again = _attestation(a, "replacement");
        bytes memory signature = _sign(again);
        vm.prank(writer);
        assertFalse(intake.complete(b, 0, abi.encode(a, again, signature)));
        assertTrue(intake.requestInfo(b).completed);
        (AskSwarmRegistry.Ask memory kb,) = registry.get(b);
        assertEq(uint8(kb.status), uint8(AskSwarmRegistry.Status.Pending));

        vm.warp(START + 365 days);
        vm.expectEmit(true, false, false, false, address(registry));
        emit Lost(b);
        vm.prank(bob);
        registry.markLost(b);
        AskSwarmRegistry.Answer memory ab;
        (kb, ab) = registry.get(b);
        assertEq(uint8(kb.status), uint8(AskSwarmRegistry.Status.Lost));
        assertEq(kb.asker, alice);
        assertEq(kb.askedAt, START);
        assertFalse(ab.verified);
        assertEq(ab.answerHash, bytes32(0));
        assertEq(ab.answer.length, 0);
        assertEq(registry.latestFor(QUESTION), a, "Lost touches no answer");
        assertEq(registry.asked(), 2);
        assertEq(token.balanceOf(address(registry)), 0);

        // terminal: neither hook nor a second markLost can reopen it
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, b));
        registry.markLost(b);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, b));
        registry.onOracleResult(b, again, signature);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, b));
        registry.onFailure(b, 1, bytes32("body_invalid"), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, a));
        registry.markLost(a);
        bytes32 unknown = keccak256("never asked");
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, unknown));
        registry.markLost(unknown);
    }

    /// A failure completion with empty arguments: Intake skips the hook and marks the request
    /// completed, so the ask is Lost, not Refused.
    function test_markLostAfterAFailureCompletionWithEmptyArguments() public {
        bytes32 id = _ask();
        vm.prank(writer);
        assertFalse(intake.complete(id, 1, ""));
        assertTrue(intake.requestInfo(id).completed);
        registry.markLost(id);
        (AskSwarmRegistry.Ask memory k,) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Lost));
    }

    function test_statusCodesAreAppendedNotRenumbered() public pure {
        assertEq(uint8(AskSwarmRegistry.Status.None), 0);
        assertEq(uint8(AskSwarmRegistry.Status.Pending), 1);
        assertEq(uint8(AskSwarmRegistry.Status.Answered), 2);
        assertEq(uint8(AskSwarmRegistry.Status.Refused), 3);
        assertEq(uint8(AskSwarmRegistry.Status.NoResult), 4);
        assertEq(uint8(AskSwarmRegistry.Status.Unverified), 5);
        assertEq(uint8(AskSwarmRegistry.Status.Lost), 6);
    }

    // ---- helpers ----

    function _store(bytes memory answer, uint16 panel, uint16 quorum, uint16 agreed, uint64 issuedAt, uint64 expiry)
        internal
        returns (bytes32 id)
    {
        id = _ask();
        OracleAttestation memory a = _attestation(id, answer);
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        a.issuedAt = issuedAt;
        a.expiresAt = expiry;
        _deliver(id, a, _sign(a));
    }
}
