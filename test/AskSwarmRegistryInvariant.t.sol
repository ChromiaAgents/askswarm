// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport, PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

/// Random calls are made through the public payment path and the one-shot Intake transport.
/// Donations are tracked separately: only fees received by ask must be forwarded, whereas
/// unsolicited transfers are explicitly unrecoverable in the registry's design.
contract RegistrySequenceHandler is Test {
    uint256 private constant KEY = 0xA11CE;
    uint256 public constant INITIAL_BALANCE = 100 ether;
    AskSwarmRegistry public immutable registry;
    PaymentToken public immutable token;
    RecordingIntake public immutable intake;
    address[3] public actors;
    bytes32[] public ids;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public donated;
    uint256 public totalPaid;
    uint256 public totalDonated;
    uint256 public failedAsks;
    uint256 public settlements;
    uint256 public stranded;

    struct ExpectedAsk {
        address asker;
        uint64 askedAt;
        AskSwarmRegistry.Status status;
        bytes32 settledRecordHash;
        // Completed in Intake by a writer that forwarded another (settled) id's arguments: the
        // registry refused the replay, so this ask stays Pending here and can never be completed.
        bool stranded;
    }
    mapping(bytes32 => ExpectedAsk) public expected;

    constructor(AskSwarmRegistry registry_, PaymentToken token_, RecordingIntake intake_, address[3] memory actors_) {
        registry = registry_;
        token = token_;
        intake = intake_;
        actors = actors_;
    }

    function ask(uint256 actorSeed, uint256 priceSeed, bytes32 body) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (available == 0) return;
        uint256 p = bound(priceSeed, 1, available < 10 ether ? available : 10 ether);
        intake.setPrice(p);
        vm.startPrank(actor);
        token.approve(address(registry), p);
        bytes32 id = registry.ask(abi.encode(body));
        vm.stopPrank();
        assertEq(expected[id].asker, address(0), "request ids must be unique");
        expected[id] = ExpectedAsk(actor, uint64(block.timestamp), AskSwarmRegistry.Status.Pending, bytes32(0), false);
        ids.push(id);
        paid[actor] += p;
        totalPaid += p;
    }

    function failingAsk(uint256 actorSeed, uint8 failureSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 mode = failureSeed % 5;
        uint256 available = token.balanceOf(actor);
        uint256 price = available == 0 ? 1 : (available < 0.5 ether ? available : 0.5 ether);
        intake.setPrice(mode == 0 ? 0 : mode == 1 ? available + 1 : price);
        vm.prank(actor);
        token.approve(address(registry), mode == 2 ? price - 1 : type(uint256).max);
        if (mode == 3) intake.setRejection(2, false);
        if (mode == 4) token.configure(PaymentToken.Reply.True, PaymentToken.Reply.False, address(0));
        uint256 countBefore = registry.asked();
        uint256 recipientBefore = token.balanceOf(intake.recipient());
        uint256 allowanceBefore = token.allowance(actor, address(registry));
        vm.prank(actor);
        (bool ok,) = address(registry).call(abi.encodeCall(registry.ask, (bytes("{}"))));
        assertFalse(ok, "a deliberately failing ask unexpectedly succeeded");
        assertEq(token.balanceOf(actor), available, "failed ask charged its caller");
        assertEq(token.balanceOf(intake.recipient()), recipientBefore, "failed ask paid the recipient");
        assertEq(token.allowance(actor, address(registry)), allowanceBefore, "failed ask used approval");
        assertEq(registry.asked(), countBefore, "failed ask registered a request");
        failedAsks++;
        intake.setRejection(0, false);
        token.configure(PaymentToken.Reply.True, PaymentToken.Reply.True, address(0));
    }

    function donate(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available < 1 ether ? available : 1 ether);
        vm.prank(actor);
        token.transfer(address(registry), amount);
        donated[actor] += amount;
        totalDonated += amount;
    }

    // mode 0 = valid; 1 = signature tampered; 2 = no quorum; 3 = expired; 4 = oversized.
    function answer(
        uint256 idSeed,
        uint8 modeSeed,
        uint16 panelSeed,
        uint16 votesSeed,
        uint16 lifetimeSeed,
        uint8 questionSeed,
        bytes32 value
    ) public {
        (bytes32 id, bool found) = _pending(idSeed);
        if (!found) return;
        uint256 mode = modeSeed % 5;
        uint16 panel = uint16(bound(panelSeed, 2, 100));
        uint16 agreed = uint16(bound(votesSeed, 1, panel));
        bytes32 question = questionHash(questionSeed % 4);
        bytes32 previouslyHeld = registry.latestFor(question);
        (, AskSwarmRegistry.Answer memory held) = registry.get(previouslyHeld);
        OracleAttestation memory a = OracleAttestation({
            requestId: keccak256(abi.encode("oracle id", id)),
            chainId: 1,
            questionHash: question,
            answerType: 2,
            answer: mode == 4 ? new bytes(4097) : abi.encode(value),
            figure: uint256(value),
            fromBlock: 100,
            toBlock: 200,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode(id)),
            panelSize: panel,
            quorum: agreed,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + bound(lifetimeSeed, 0, 1 days))
        });
        if (mode == 2) a.agreed = a.quorum - 1;
        if (mode == 3) a.expiresAt = uint64(block.timestamp - 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.digest(a));
        if (mode == 1) a.figure ^= 1;
        vm.prank(intake.writer());
        bool delivered = intake.complete(id, 0, abi.encode(id, a, abi.encodePacked(r, s, v)));
        assertTrue(delivered, "bounded callback must fit the stipend");
        bool valid = mode == 0;
        expected[id].status = valid ? AskSwarmRegistry.Status.Answered : AskSwarmRegistry.Status.Unverified;
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory actual) = registry.get(id);
        assertEq(uint8(k.status), uint8(expected[id].status));
        assertEq(actual.verified, valid);
        if (mode != 4) {
            assertEq(actual.answer, a.answer);
            assertEq(actual.answerHash, keccak256(a.answer));
            assertEq(actual.questionHash, question);
            assertEq(actual.panelSize, a.panelSize);
            assertEq(actual.quorum, a.quorum);
            assertEq(actual.agreed, a.agreed);
            assertEq(actual.issuedAt, a.issuedAt);
            assertEq(actual.expiresAt, a.expiresAt);
        }
        expected[id].settledRecordHash = keccak256(abi.encode(k, actual));
        settlements++;

        // Check transitions against the previously held answer, not a second implementation
        // of signature verification or storage packing.
        bytes32 nowHeld = registry.latestFor(question);
        if (!valid || agreed <= panel / 2) {
            assertEq(nowHeld, previouslyHeld, "invalid or minority answer changed the index");
        } else if (
            held.verified && block.timestamp <= held.expiresAt
                && (panel < held.panelSize
                    || agreed < held.agreed
                    || a.issuedAt < held.issuedAt
                    || a.expiresAt < held.expiresAt)
        ) {
            assertEq(nowHeld, previouslyHeld, "weaker, staler or shorter-lived answer displaced a current answer");
        } else {
            assertEq(nowHeld, id, "eligible answer was not indexed");
        }
    }

    function refuse(uint256 idSeed, bool split, bytes32 reason, uint16 voteSeed) public {
        (bytes32 id, bool found) = _pending(idSeed);
        if (!found) return;
        uint8 status = split ? 2 : 1;
        uint16 agreed = split ? uint16(bound(voteSeed, 0, 14)) : 0;
        vm.prank(intake.writer());
        assertTrue(
            intake.complete(
                id, status, abi.encode(id, status, reason, agreed, split ? uint16(15) : uint16(0), bytes(""))
            )
        );
        expected[id].status = split ? AskSwarmRegistry.Status.NoResult : AskSwarmRegistry.Status.Refused;
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        assertEq(uint8(k.status), uint8(expected[id].status));
        assertFalse(a.verified);
        expected[id].settledRecordHash = keccak256(abi.encode(k, a));
        settlements++;
    }

    function advanceTime(uint32 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 2 days));
    }

    function unauthorizedCallback(uint256 idSeed, uint256 actorSeed) public {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        bytes32 beforeHash = keccak256(abi.encode(k, a));
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(registry)
            .call(
                abi.encodeCall(
                    registry.onFailure, (id, uint8(1), bytes32("body_invalid"), uint16(0), uint16(0), bytes(""))
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.NotIntake.selector));
        (k, a) = registry.get(id);
        assertEq(keccak256(abi.encode(k, a)), beforeHash);
    }

    /// Audit finding 1b549341: the live Intake forwards status-0 arguments unchecked, so a writer
    /// could complete an open request with a settled id's arguments. The registry refuses the
    /// replay (the call is not delivered), the settled record is byte-identical afterwards, and the
    /// open request is left Pending here.
    function replaySettledThroughOpenRequest(uint256 settledSeed, uint256 openSeed, uint8 questionSeed, bytes32 value)
        public
    {
        (bytes32 settled, bool foundSettled) = _settled(settledSeed);
        (bytes32 open, bool foundOpen) = _pending(openSeed);
        if (!foundSettled || !foundOpen) return;
        bytes32 question = questionHash(questionSeed % 4);
        bytes32 heldBefore = registry.latestFor(question);
        OracleAttestation memory a = OracleAttestation({
            requestId: keccak256(abi.encode("oracle id", settled)),
            chainId: 1,
            questionHash: question,
            answerType: 2,
            answer: abi.encode(value),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode(settled, open)),
            panelSize: 100,
            quorum: 2,
            agreed: 100,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.digest(a));
        vm.prank(intake.writer());
        bool delivered = intake.complete(open, 0, abi.encode(settled, a, abi.encodePacked(r, s, v)));
        assertFalse(delivered, "registry accepted a re-delivery of a settled ask");
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory actual) = registry.get(settled);
        assertEq(keccak256(abi.encode(k, actual)), expected[settled].settledRecordHash, "settled record changed");
        assertEq(registry.latestFor(question), heldBefore, "replay moved the index");
        (AskSwarmRegistry.Ask memory ko,) = registry.get(open);
        assertEq(uint8(ko.status), uint8(AskSwarmRegistry.Status.Pending), "replay settled the open ask");
        expected[open].stranded = true;
        stranded++;
    }

    /// Review finding a97feadf, consequence (a): anyone may point the index at a recorded answer
    /// under the delivery rule, strict on ties. The expectation is computed from the read API
    /// against the currently held answer, not from the contract's own helper.
    function reindex(uint256 idSeed) public {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        (, AskSwarmRegistry.Answer memory c) = registry.get(id);
        bytes32 question = c.questionHash;
        bytes32 heldId = registry.latestFor(question);
        (, AskSwarmRegistry.Answer memory h) = registry.get(heldId);
        bool heldCurrent = h.verified && block.timestamp <= h.expiresAt;
        bool eligible = c.verified && block.timestamp <= c.expiresAt && c.agreed > c.panelSize / 2;
        bool atLeast = c.panelSize >= h.panelSize && c.agreed >= h.agreed && c.issuedAt >= h.issuedAt
            && c.expiresAt >= h.expiresAt;
        bool beats =
            c.panelSize > h.panelSize || c.agreed > h.agreed || c.issuedAt > h.issuedAt || c.expiresAt > h.expiresAt;
        bool shouldMove = eligible && (!heldCurrent || (atLeast && beats));
        (bool ok, bytes memory reason) = address(registry).call(abi.encodeCall(registry.reindex, (id)));
        assertEq(ok, shouldMove, "reindex accepted or refused against the rule");
        if (!ok) assertEq(reason, abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, id));
        assertEq(registry.latestFor(question), ok ? id : heldId, "reindex moved the index wrongly");
        if (ok) assertTrue(registry.isCurrent(question));
    }

    /// Review finding 8f2c2abc: a Pending ask that Intake has completed (here: stranded by a replay)
    /// can be settled as Lost by anyone; an open or settled ask cannot.
    function markLost(uint256 idSeed) public {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        ExpectedAsk memory e = expected[id];
        (bool ok, bytes memory reason) = address(registry).call(abi.encodeCall(registry.markLost, (id)));
        if (e.status == AskSwarmRegistry.Status.Pending && e.stranded) {
            assertTrue(ok, "completed-but-undelivered ask could not be marked lost");
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Lost));
            assertFalse(a.verified);
            assertEq(a.answerHash, bytes32(0));
            expected[id].status = AskSwarmRegistry.Status.Lost;
            expected[id].settledRecordHash = keccak256(abi.encode(k, a));
            settlements++;
        } else {
            assertFalse(ok, "open or settled ask was marked lost");
            assertEq(
                reason,
                e.status == AskSwarmRegistry.Status.Pending
                    ? abi.encodeWithSelector(AskSwarmRegistry.StillOpen.selector, id)
                    : abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, id)
            );
        }
    }

    function retryCompletedRequest(uint256 idSeed) public {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        if (expected[id].status == AskSwarmRegistry.Status.Pending && !expected[id].stranded) return;
        vm.prank(intake.writer());
        (bool ok, bytes memory reason) = address(intake)
            .call(
                abi.encodeCall(
                    intake.complete,
                    (id, uint8(1), abi.encode(id, uint8(1), bytes32("retry"), uint16(0), uint16(0), bytes("")))
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(RecordingIntake.AlreadyCompleted.selector));
    }

    function questionHash(uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode("question", index));
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function assertAccounting() external view {
        assertEq(token.balanceOf(address(registry)), totalDonated, "ask retained or spent donated IMD");
        assertEq(token.balanceOf(intake.recipient()), totalPaid, "fees not forwarded exactly");
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0, "standing Intake approval");
        uint256 accounted = totalPaid + totalDonated;
        uint256 sumPaid;
        uint256 sumDonated;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(
                token.balanceOf(actor) + paid[actor] + donated[actor],
                INITIAL_BALANCE,
                "actor paid anything other than successful asks and donations"
            );
            accounted += token.balanceOf(actor);
            sumPaid += paid[actor];
            sumDonated += donated[actor];
        }
        assertEq(sumPaid, totalPaid);
        assertEq(sumDonated, totalDonated);
        assertEq(accounted, token.totalSupply(), "IMD conservation");
        assertEq(token.totalSupply(), INITIAL_BALANCE * actors.length);
        assertEq(registry.asked(), ids.length, "phantom or missing requests");
        assertEq(intake.nonce(), ids.length);
    }

    function assertRecordsAndIndexes() external view {
        uint256 settled;
        uint256 strandedSeen;
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            ExpectedAsk memory e = expected[id];
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(k.asker, e.asker);
            assertEq(k.askedAt, e.askedAt);
            assertEq(uint8(k.status), uint8(e.status));
            RecordingIntake.Request memory r = intake.requestInfo(id);
            assertEq(r.completed, e.status != AskSwarmRegistry.Status.Pending || e.stranded);
            if (e.stranded) ++strandedSeen;
            if (e.status != AskSwarmRegistry.Status.Pending) {
                ++settled;
                assertEq(r.delivered, e.status != AskSwarmRegistry.Status.Lost, "Lost is only for undelivered");
                assertEq(keccak256(abi.encode(k, a)), e.settledRecordHash, "settled record changed");
                if (e.status == AskSwarmRegistry.Status.Lost) assertEq(a.answerHash, bytes32(0));
            } else {
                assertFalse(r.delivered);
                assertFalse(a.verified);
                assertEq(a.answerHash, bytes32(0), "pending ask reads as answered");
            }
        }
        assertEq(settled, settlements);
        assertEq(strandedSeen, stranded);
        for (uint256 i; i < 4; ++i) {
            bytes32 question = questionHash(i);
            (bytes32 id, AskSwarmRegistry.Answer memory a) = registry.answerOf(question);
            assertEq(registry.latestFor(question), id);
            if (id == bytes32(0)) {
                assertFalse(registry.isCurrent(question));
                continue;
            }
            assertEq(uint8(expected[id].status), uint8(AskSwarmRegistry.Status.Answered));
            assertTrue(a.verified);
            assertEq(a.questionHash, question, "index points at another question");
            assertGt(a.agreed, uint256(a.panelSize) / 2, "indexed answer lacks majority");
            assertGe(a.agreed, a.quorum);
            assertEq(registry.isCurrent(question), block.timestamp <= a.expiresAt);
            (bytes32 filtered,) = registry.answerOf(question, a.panelSize, a.agreed);
            assertEq(filtered, block.timestamp <= a.expiresAt ? id : bytes32(0));
            (filtered,) = registry.answerOf(question, a.panelSize + 1, a.agreed);
            assertEq(filtered, bytes32(0));
            (filtered,) = registry.answerOf(question, a.panelSize, a.agreed + 1);
            assertEq(filtered, bytes32(0));
        }
    }

    function _pending(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 length = ids.length;
        if (length == 0) return (id, false);
        uint256 start = seed % length;
        for (uint256 i; i < length; ++i) {
            id = ids[(start + i) % length];
            if (expected[id].status == AskSwarmRegistry.Status.Pending && !expected[id].stranded) return (id, true);
        }
        return (id, false);
    }

    function _settled(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 length = ids.length;
        if (length == 0) return (id, false);
        uint256 start = seed % length;
        for (uint256 i; i < length; ++i) {
            id = ids[(start + i) % length];
            if (expected[id].status != AskSwarmRegistry.Status.Pending) return (id, true);
        }
        return (id, false);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract AskSwarmRegistryInvariantTest is RegistryTestSupport {
    RegistrySequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        address charlie = makeAddr("payment charlie");
        token.mint(charlie, 100 ether);
        handler = new RegistrySequenceHandler(registry, token, intake, [alice, bob, charlie]);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.ask.selector;
        selectors[1] = handler.failingAsk.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.answer.selector;
        selectors[4] = handler.refuse.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.unauthorizedCallback.selector;
        selectors[7] = handler.retryCompletedRequest.selector;
        selectors[8] = handler.replaySettledThroughOpenRequest.selector;
        selectors[9] = handler.reindex.selector;
        selectors[10] = handler.markLost.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));

        // Guarantee a live pending request, an indexed answer, a failure, a donation, a reverted
        // ask, a refused replay, a stranded ask and a lost one even in sequences whose random calls
        // otherwise miss those states.
        handler.ask(0, 0.5 ether, bytes32("first"));
        handler.ask(1, 0.5 ether, bytes32("second"));
        handler.ask(2, 1, bytes32("pending"));
        handler.ask(2, 1, bytes32("stranded"));
        handler.ask(0, 1, bytes32("lost"));
        handler.answer(0, 0, 15, 11, 3600, 0, bytes32("answer"));
        handler.refuse(1, true, bytes32("disagreed"), 10);
        handler.donate(2, 1);
        handler.failingAsk(1, 3);
        handler.replaySettledThroughOpenRequest(0, 3, 0, bytes32("replay"));
        handler.replaySettledThroughOpenRequest(0, 4, 1, bytes32("replay"));
        handler.markLost(4);
        assertEq(handler.stranded(), 2);
        (AskSwarmRegistry.Ask memory lost,) = registry.get(handler.ids(4));
        assertEq(uint8(lost.status), uint8(AskSwarmRegistry.Status.Lost));
    }

    function invariant_paymentsAreConservedAndNoFeeIsRetained() public view {
        handler.assertAccounting();
    }

    function invariant_requestsAndCanonicalAnswersStayConsistent() public view {
        handler.assertRecordsAndIndexes();
    }
}
