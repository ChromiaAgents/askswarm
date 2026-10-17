// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {PaymentToken, RecordingIntake, RegistryTestSupport} from "./helpers/RegistryTestSupport.sol";

/// Drives the registry with hostile deliveries (wrong key, wrong domain, high-s twin, short
/// signature, oversized answer, a field changed after signing, pre-dated issuance, odd failure
/// statuses, direct hook calls and replays of settled ids) beside honest ones, and checks after
/// every call, whichever handler made it, that the question index only moved the way the contract
/// promises: to a verified strict majority of the same question, and, while the held answer was
/// current, only to one at least as strong, as fresh and as long-lived (strictly better on one
/// count when `reindex` moved it). Asks Intake completed without delivering are settled `Lost`
/// through `markLost` and nothing else. Settled records are snapshotted and must never change.
contract IndexTransitionHandler is Test {
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant QUESTIONS = 3;

    AskSwarmRegistry internal immutable registry;
    AskSwarmRegistry internal immutable otherDomain;
    PaymentToken internal immutable token;
    RecordingIntake internal immutable intake;
    uint256 internal immutable key;
    address[3] internal actors;

    bytes32[] public ids;
    mapping(bytes32 => bool) public settled;
    mapping(bytes32 => bool) public stranded;
    mapping(bytes32 => bytes32) public recordHash;
    uint256 public totalPaid;
    uint256 public indexMoves;
    uint256 public verifiedDeliveries;
    uint256 public hostileDeliveries;
    uint256 public reindexMoves;
    uint256 public lostMarked;
    bool internal strictMove;

    struct Held {
        bytes32 id;
        bool current;
        uint16 panelSize;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    constructor(
        AskSwarmRegistry registry_,
        AskSwarmRegistry otherDomain_,
        PaymentToken token_,
        RecordingIntake intake_,
        uint256 key_,
        address[3] memory actors_
    ) {
        registry = registry_;
        otherDomain = otherDomain_;
        token = token_;
        intake = intake_;
        key = key_;
        actors = actors_;
    }

    modifier observed() {
        Held[QUESTIONS] memory before;
        for (uint256 q; q < QUESTIONS; ++q) {
            bytes32 id = registry.latestFor(question(q));
            (, AskSwarmRegistry.Answer memory a) = registry.get(id);
            before[q] = Held(
                id,
                id != bytes32(0) && a.verified && block.timestamp <= a.expiresAt,
                a.panelSize,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            );
        }
        strictMove = false;
        _;
        for (uint256 q; q < QUESTIONS; ++q) {
            bytes32 id = registry.latestFor(question(q));
            if (id == before[q].id) continue;
            ++indexMoves;
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered), "index moved to an unanswered ask");
            assertTrue(a.verified, "index moved to an unverified answer");
            assertEq(a.questionHash, question(q), "index moved to another question's answer");
            assertGt(uint256(a.agreed) * 2, a.panelSize, "index moved to a minority answer");
            if (before[q].current) {
                assertGe(a.panelSize, before[q].panelSize, "smaller panel displaced a current answer");
                assertGe(a.agreed, before[q].agreed, "weaker agreement displaced a current answer");
                assertGe(a.issuedAt, before[q].issuedAt, "older answer displaced a current answer");
                assertGe(a.expiresAt, before[q].expiresAt, "shorter-lived answer displaced a current answer");
                if (strictMove) {
                    assertTrue(
                        a.panelSize > before[q].panelSize || a.agreed > before[q].agreed
                            || a.issuedAt > before[q].issuedAt || a.expiresAt > before[q].expiresAt,
                        "reindex flipped an exact tie"
                    );
                }
            }
        }
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            if (settled[id]) assertEq(_hash(id), recordHash[id], "a settled record changed");
        }
    }

    function ask(uint256 actorSeed, uint256 priceSeed) external observed {
        uint256 price = bound(priceSeed, 1, 2 ether);
        intake.setPrice(price);
        address actor = actors[actorSeed % actors.length];
        if (token.balanceOf(actor) < price) return;
        vm.prank(actor);
        bytes32 id = registry.ask(abi.encodePacked("{\"n\":", vm.toString(ids.length), "}"));
        ids.push(id);
        totalPaid += price;
    }

    function deliver(
        uint256 idSeed,
        uint8 questionSeed,
        uint16 panelSeed,
        uint16 agreedSeed,
        uint16 quorumSeed,
        uint32 lifeSeed,
        uint32 issuedSeed,
        uint8 modeSeed
    ) external observed {
        (bytes32 id, bool found) = _pending(idSeed);
        if (!found) return;
        uint256 mode = modeSeed % 8; // 0..1 honest, 2..7 hostile
        OracleAttestation memory a;
        a.requestId = keccak256(abi.encode("oracle", id));
        a.chainId = 1;
        a.questionHash = question(questionSeed % QUESTIONS);
        a.answerType = 2;
        a.answer = mode == 7 ? new bytes(bound(lifeSeed, 4097, 12_000)) : abi.encode(keccak256(abi.encode(id)));
        a.panelSize = uint16(bound(panelSeed, 2, 100));
        a.agreed = uint16(bound(agreedSeed, 1, a.panelSize));
        a.quorum = uint16(bound(quorumSeed, 1, a.agreed));
        // Mostly fresh, sometimes up to 10 minutes ahead (beyond the 5-minute tolerance), sometimes
        // issued up to a day before delivery (older than the held answer).
        a.issuedAt = uint64(block.timestamp + (issuedSeed % 4 == 0 ? bound(issuedSeed, 0, 10 minutes) : 0));
        if (issuedSeed % 4 == 1) a.issuedAt -= uint64(bound(issuedSeed >> 2, 0, 1 days));
        a.expiresAt = uint64(block.timestamp + bound(lifeSeed, 0, 2 days));
        a.panelJobId = keccak256(abi.encode("job", id));

        bytes32 d = mode == 3 ? otherDomain.digest(a) : registry.digest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mode == 2 ? key + 1 : key, d);
        bytes memory signature = abi.encodePacked(r, s, v);
        if (mode == 4) signature = abi.encodePacked(r, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        if (mode == 5) signature = abi.encodePacked(r, s);
        if (mode == 6) a.figure ^= 1; // changed after signing

        vm.prank(intake.writer());
        assertTrue(intake.complete(id, 0, abi.encode(id, a, signature)), "pending ask not delivered within 200k");
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory stored) = registry.get(id);
        if (mode >= 2) {
            ++hostileDeliveries;
            assertFalse(stored.verified, "hostile delivery verified");
            assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        } else if (stored.verified) {
            ++verifiedDeliveries;
        }
        _settle(id);
    }

    function fail(uint256 idSeed, uint8 statusSeed, bytes32 reason) external observed {
        (bytes32 id, bool found) = _pending(idSeed);
        if (!found) return;
        uint8 status = uint8(bound(statusSeed, 1, 255));
        vm.prank(intake.writer());
        assertTrue(intake.complete(id, status, abi.encode(id, status, reason, uint16(3), uint16(5), bytes(""))));
        (AskSwarmRegistry.Ask memory k,) = registry.get(id);
        assertEq(
            uint8(k.status), uint8(status == 1 ? AskSwarmRegistry.Status.Refused : AskSwarmRegistry.Status.NoResult)
        );
        _settle(id);
    }

    /// The writer completes an open request with a settled id's strongest possible answer.
    function replay(uint256 settledSeed, uint256 openSeed, uint8 questionSeed) external observed {
        (bytes32 open, bool foundOpen) = _pending(openSeed);
        if (!foundOpen || ids.length == 0) return;
        bytes32 target = ids[settledSeed % ids.length];
        if (!settled[target]) return;
        OracleAttestation memory a;
        a.questionHash = question(questionSeed % QUESTIONS);
        a.answer = abi.encode(uint256(1));
        a.panelSize = 100;
        a.quorum = 100;
        a.agreed = 100;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 30 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.digest(a));
        vm.prank(intake.writer());
        assertFalse(intake.complete(open, 0, abi.encode(target, a, abi.encodePacked(r, s, v))), "replay delivered");
        stranded[open] = true;
    }

    /// Intake completes a pending ask with a failure status and no arguments: no hook runs and the
    /// ask is stranded `Pending` until someone calls `markLost`.
    function strand(uint256 idSeed, uint8 statusSeed) external observed {
        (bytes32 id, bool found) = _pending(idSeed);
        if (!found) return;
        vm.prank(intake.writer());
        assertFalse(intake.complete(id, uint8(bound(statusSeed, 1, 2)), ""), "empty failure reached a hook");
        stranded[id] = true;
    }

    /// Anyone may call `markLost`: it settles exactly the asks Intake completed without delivering,
    /// refuses open ones with `StillOpen`, and settled ones (and unknown ids) unchanged.
    function markLost(uint256 idSeed, uint256 callerSeed) external observed {
        bytes32 id = ids.length == 0 ? bytes32(idSeed) : ids[idSeed % ids.length];
        vm.prank(actors[callerSeed % actors.length]);
        (bool ok, bytes memory reason) = address(registry).call(abi.encodeCall(registry.markLost, (id)));
        if (ids.length == 0) {
            assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, id));
        } else if (settled[id]) {
            assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, id));
        } else if (stranded[id]) {
            assertTrue(ok, "a stranded ask could not be marked lost");
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Lost));
            assertEq(a.answerHash, bytes32(0), "markLost wrote an answer");
            ++lostMarked;
            _settle(id);
        } else {
            assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.StillOpen.selector, id));
        }
    }

    /// Anyone points the index at any record; the observed modifier checks every move it makes.
    function reindex(uint256 idSeed, uint256 callerSeed) external observed {
        bytes32 id = ids.length == 0 ? bytes32(idSeed) : ids[idSeed % ids.length];
        strictMove = true;
        vm.prank(actors[callerSeed % actors.length]);
        (bool ok, bytes memory reason) = address(registry).call(abi.encodeCall(registry.reindex, (id)));
        if (ok) {
            ++reindexMoves;
            (, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(registry.latestFor(a.questionHash), id);
        } else {
            assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, id));
        }
    }

    /// Anyone but Intake, including the writer and the registry itself, is refused by both hooks.
    function directHook(uint256 idSeed, uint256 callerSeed, bool failureHook) external observed {
        bytes32 id = ids.length == 0 ? bytes32(idSeed) : ids[idSeed % ids.length];
        address[5] memory callers = [actors[0], actors[1], actors[2], intake.writer(), address(registry)];
        address caller = callers[callerSeed % callers.length];
        OracleAttestation memory a;
        bytes memory data = failureHook
            ? abi.encodeCall(registry.onFailure, (id, uint8(1), bytes32("x"), uint16(0), uint16(0), bytes("")))
            : abi.encodeCall(registry.onOracleResult, (id, a, bytes("")));
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(registry).call(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.NotIntake.selector));
    }

    function warp(uint32 secondsSeed) external observed {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3 days));
    }

    function question(uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode("index question", index));
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function _settle(bytes32 id) internal {
        settled[id] = true;
        recordHash[id] = _hash(id);
    }

    function _hash(bytes32 id) internal view returns (bytes32) {
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        return keccak256(abi.encode(k, a));
    }

    function _pending(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 length = ids.length;
        for (uint256 i; i < length; ++i) {
            id = ids[(seed % length + i) % length];
            if (!settled[id] && !stranded[id]) return (id, true);
        }
    }
}

/// forge-config: default.invariant.runs = 192
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AskSwarmRegistryIndexInvariantTest is RegistryTestSupport {
    IndexTransitionHandler internal handler;

    function setUp() public override {
        super.setUp();
        address carol = makeAddr("index carol");
        token.mint(carol, 100 ether);
        AskSwarmRegistry otherDomain = new AskSwarmRegistry(address(intake), address(token), vm.addr(SIGNING_KEY));
        handler = new IndexTransitionHandler(registry, otherDomain, token, intake, SIGNING_KEY, [alice, bob, carol]);
        vm.prank(carol);
        token.approve(address(registry), type(uint256).max);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.ask.selector;
        selectors[1] = handler.deliver.selector;
        selectors[2] = handler.fail.selector;
        selectors[3] = handler.replay.selector;
        selectors[4] = handler.directHook.selector;
        selectors[5] = handler.warp.selector;
        selectors[6] = handler.strand.selector;
        selectors[7] = handler.markLost.selector;
        selectors[8] = handler.reindex.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));

        // Seed a held answer per question so displacement is exercised from the first call.
        for (uint256 q; q < 3; ++q) {
            handler.ask(q, 0.5 ether);
            handler.deliver(q, uint8(q), 15, 11, 11, 1 days, 1, 0);
            assertTrue(registry.latestFor(handler.question(q)) != bytes32(0));
        }
        handler.ask(0, 0.5 ether);
    }

    /// The handlers the campaign relies on reach the states they check: a stranded ask marked
    /// `Lost`, and a `reindex` move onto a weaker but still-valid answer once the held one expires.
    function test_handlersReachLostAndReindexMoves() public {
        bytes32 stranded = handler.ids(3);
        handler.strand(3, 1);
        handler.markLost(3, 0);
        (AskSwarmRegistry.Ask memory k,) = registry.get(stranded);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Lost));
        assertEq(handler.lostMarked(), 1);

        handler.ask(0, 0.5 ether);
        bytes32 small = handler.ids(4);
        handler.deliver(4, 0, 3, 2, 2, 2 days, 2, 0); // 2 of 3, valid 2 days: not indexed over 11 of 15
        assertTrue(registry.latestFor(handler.question(0)) != small);
        handler.reindex(4, 0);
        assertEq(handler.reindexMoves(), 0, "reindex displaced a current, stronger answer");

        handler.warp(1 days + 1);
        handler.reindex(4, 1);
        assertEq(handler.reindexMoves(), 1);
        assertEq(registry.latestFor(handler.question(0)), small);
    }

    function invariant_registryHoldsNothingAndForwardsEveryFee() public view {
        assertEq(token.balanceOf(address(registry)), 0, "registry retained IMD");
        assertEq(address(registry).balance, 0, "registry holds ETH");
        assertEq(token.allowance(address(registry), address(intake)), 0, "standing Intake approval");
        assertEq(token.balanceOf(recipient), handler.totalPaid(), "fees not forwarded exactly");
        assertEq(registry.asked(), handler.count(), "phantom or missing asks");
    }

    function invariant_indexOnlyHoldsVerifiedMajoritiesOfTheirOwnQuestion() public view {
        for (uint256 q; q < 3; ++q) {
            bytes32 question = handler.question(q);
            (bytes32 id, AskSwarmRegistry.Answer memory a) = registry.answerOf(question);
            assertTrue(id != bytes32(0), "a seeded question lost its index entry");
            assertTrue(handler.settled(id));
            assertTrue(a.verified);
            assertEq(a.questionHash, question);
            assertGt(uint256(a.agreed) * 2, a.panelSize);
            assertGe(a.agreed, a.quorum);
            assertEq(registry.isCurrent(question), block.timestamp <= a.expiresAt);
        }
    }

    function invariant_everyAskIsPendingOrSettledOnce() public view {
        for (uint256 i; i < handler.count(); ++i) {
            bytes32 id = handler.ids(i);
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            (,,, bool completed) = intake.requests(id);
            if (k.status == AskSwarmRegistry.Status.Lost) {
                assertTrue(completed && handler.stranded(id), "Lost without an undelivered completion");
            }
            if (handler.settled(id)) {
                assertTrue(completed, "settled an ask Intake never completed");
                assertTrue(uint8(k.status) >= uint8(AskSwarmRegistry.Status.Answered));
                assertEq(keccak256(abi.encode(k, a)), handler.recordHash(id));
            } else {
                assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
                assertEq(a.answerHash, bytes32(0));
            }
        }
    }
}
