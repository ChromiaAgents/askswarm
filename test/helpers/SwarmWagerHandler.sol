// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmWager} from "src/SwarmWager.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {PaymentToken, RecordingIntake} from "./RegistryTestSupport.sol";

/// An independent ledger for several concurrent wagers. The token and transport are fixtures;
/// both SwarmWager and the registry execute their real code, including signature verification.
contract SwarmWagerHandler is Test {
    uint256 public constant INITIAL = uint256(type(uint96).max) * 1024;
    uint256 private constant KEY = 0xA11CE; // Only the locally deployed registry trusts this fixture key.
    uint256 private constant MAX_WAGERS = 32;
    uint256 private constant WINDOW = 3 days;

    enum Outcome {
        Pending,
        Yes,
        No,
        Refund
    }

    struct Model {
        address creator;
        address yes;
        address no;
        uint96 stake;
        uint256 fee;
        uint64 joinBy;
        uint64 resolveAfter;
        uint64 askedAt;
        SwarmWager.State state;
        bytes32 requestId;
        bytes body;
        Outcome outcome;
        address winner;
        bytes32 closedHash;
    }

    SwarmWager public immutable wager;
    AskSwarmRegistry public immutable registry;
    PaymentToken public immutable token;
    RecordingIntake public immutable intake;
    address[4] public actors;
    mapping(uint256 => Model) private models;
    mapping(address => uint256) public debits;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public donations;
    mapping(bytes32 => uint256) private requestOwner;
    uint256 public created;
    uint256 public joined;
    uint256 public resolved;
    uint256 public paid;
    uint256 public refunded;
    uint256 public cancelled;
    uint256 public abandoned;
    uint256 public failedCalls;
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public totalFees;
    uint256 public totalDonations;
    uint256[12] public deliveredModes;

    constructor(SwarmWager w, AskSwarmRegistry r, PaymentToken t, RecordingIntake i, address[4] memory users) {
        wager = w;
        registry = r;
        token = t;
        intake = i;
        actors = users;
    }

    function create(uint256 actorSeed, uint96 stakeSeed, bool side, uint32 termSeed, bytes32 bodySeed) public {
        if (created == MAX_WAGERS) return;
        address actor = actors[actorSeed % 4];
        // Keep dust and the storage type's maximum reachable, not just token-sized amounts.
        uint96 stake = stakeSeed == 0 ? 1 : stakeSeed;
        uint64 joinBy = uint64(vm.getBlockTimestamp() + bound(termSeed, 1, 2 days));
        uint64 resolveAfter = joinBy + uint64(termSeed % 1 days);
        // Opaque transport fixture: this suite does not model the offchain JSON screen.
        bytes memory body = abi.encode(bodySeed, created);
        uint256 fee = intake.currentPrice();
        bytes memory data = abi.encodeCall(wager.create, (body, side, stake, joinBy, resolveAfter));
        if (fee == 0 || fee > type(uint96).max) {
            _fails(created + 1, actor, data, abi.encodeWithSelector(SwarmWager.BadTerms.selector));
            return;
        }
        vm.prank(actor);
        uint256 id = wager.create(body, side, stake, joinBy, resolveAfter);
        assertEq(id, ++created, "ids must be contiguous and unique");
        Model storage m = models[id];
        m.creator = actor;
        m.yes = side ? actor : address(0);
        m.no = side ? address(0) : actor;
        m.stake = stake;
        m.fee = fee;
        m.joinBy = joinBy;
        m.resolveAfter = resolveAfter;
        m.body = body;
        m.state = SwarmWager.State.Open;
        _debit(actor, uint256(stake) + fee);
    }

    function join(uint256 seed, uint256 actorSeed) public {
        uint256 id = _find(seed, SwarmWager.State.Open);
        if (id == 0) return;
        Model storage m = models[id];
        address actor = actors[actorSeed % 4];
        if (vm.getBlockTimestamp() > m.joinBy || actor == m.creator) {
            _fails(
                id,
                actor,
                abi.encodeCall(wager.join, (id)),
                abi.encodeWithSelector(
                    vm.getBlockTimestamp() > m.joinBy ? SwarmWager.TooLate.selector : SwarmWager.SameParty.selector
                )
            );
            return;
        }
        vm.prank(actor);
        wager.join(id);
        if (m.yes == address(0)) m.yes = actor;
        else m.no = actor;
        m.state = SwarmWager.State.Matched;
        _debit(actor, m.stake);
        ++joined;
    }

    function topUp(uint256 seed, uint256 actorSeed, uint96 amount) public {
        uint256 id = _find(seed, SwarmWager.State.Matched);
        if (id == 0) return;
        Model storage m = models[id];
        address actor = actors[actorSeed % 4];
        if (amount == 0 || m.fee + amount > type(uint96).max) {
            _fails(
                id,
                actor,
                abi.encodeCall(wager.topUpFee, (id, amount)),
                abi.encodeWithSelector(SwarmWager.BadTerms.selector)
            );
            return;
        }
        vm.prank(actor);
        wager.topUpFee(id, amount);
        m.fee += amount;
        _debit(actor, amount);
    }

    function resolve(uint256 seed, uint256 actorSeed) public {
        uint256 id = _find(seed, SwarmWager.State.Matched);
        if (id == 0) return;
        Model storage m = models[id];
        address actor = actors[actorSeed % 4];
        uint256 price = intake.currentPrice();
        bytes4 errorSelector;
        if (vm.getBlockTimestamp() < m.resolveAfter) errorSelector = SwarmWager.TooEarly.selector;
        else if (price > m.fee) errorSelector = SwarmWager.BadTerms.selector;
        else if (price == 0) errorSelector = AskSwarmRegistry.NotSold.selector;
        if (errorSelector != bytes4(0)) {
            _fails(id, actor, abi.encodeCall(wager.resolve, (id)), abi.encodeWithSelector(errorSelector));
            return;
        }
        vm.expectCall(address(token), abi.encodeCall(token.approve, (address(registry), price)));
        vm.expectCall(address(registry), abi.encodeCall(registry.askAtMost, (m.body, price)));
        vm.prank(actor);
        wager.resolve(id);
        (SwarmWager.Wager memory actual,) = wager.get(id);
        assertNotEq(actual.requestId, bytes32(0));
        assertEq(requestOwner[actual.requestId], 0, "request reused by two wagers");
        requestOwner[actual.requestId] = id;
        m.requestId = actual.requestId;
        m.askedAt = uint64(vm.getBlockTimestamp());
        m.state = SwarmWager.State.Asked;
        _credit(m.creator, m.fee - price);
        m.fee = 0;
        totalFees += price;
        ++resolved;
        assertEq(intake.lastBody(), m.body, "wrong wager body sent");
    }

    /// Named outcome classes avoid rebuilding SwarmWager's answer predicate as the test oracle.
    /// 0 yes, 1 no, 2 refused, 3 split, 4 bad signature, 5 lost, 6 minority,
    /// 7 uint256, 8 noncanonical bool, 9 short bool, 10 long bool, 11 tied panel.
    function deliver(uint256 seed, uint8 modeSeed) public {
        uint256 id = _pending(seed);
        if (id == 0) return;
        Model storage m = models[id];
        bytes32 rid = m.requestId;
        uint256 mode = modeSeed % 12;
        if (mode == 2 || mode == 3) {
            uint8 status = mode == 2 ? 1 : 2;
            vm.prank(intake.writer());
            assertTrue(
                intake.complete(
                    rid, status, abi.encode(rid, status, bytes32("no_consensus"), uint16(2), uint16(6), bytes(""))
                )
            );
        } else if (mode == 5) {
            vm.prank(intake.writer());
            assertFalse(intake.complete(rid, 0, hex"00"));
            registry.markLost(rid);
        } else {
            OracleAttestation memory a;
            a.requestId = keccak256(abi.encode("oracle UUID", rid));
            a.chainId = 1;
            // Several wagers deliberately share a question hash. Settlement must use each
            // wager's request, never whichever answer currently occupies latestFor.
            a.questionHash = keccak256("shared sequence question");
            a.answerType = mode == 7 ? 3 : 0;
            a.answer = abi.encode(mode == 1 ? uint256(0) : mode == 8 ? type(uint256).max : uint256(1));
            if (mode == 9) a.answer = hex"01";
            if (mode == 10) a.answer = abi.encode(uint256(1), uint256(0));
            a.panelSize = 6;
            a.quorum = 2;
            a.agreed = mode == 6 ? 2 : mode == 11 ? 3 : 4;
            a.issuedAt = uint64(vm.getBlockTimestamp());
            a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.digest(a));
            bytes memory signature = mode == 4 ? bytes(hex"00") : abi.encodePacked(r, s, v);
            vm.prank(intake.writer());
            assertTrue(intake.complete(rid, 0, abi.encode(rid, a, signature)), "callback failed its 200k stipend");
        }
        m.outcome = mode == 0 ? Outcome.Yes : mode == 1 ? Outcome.No : Outcome.Refund;
        ++deliveredModes[mode];
        // Deliveries themselves must never move wager funds.
        assertAccounting();
    }

    function settle(uint256 seed, uint256 actorSeed) public {
        uint256 id = _find(seed, SwarmWager.State.Asked);
        if (id == 0) return;
        _settle(id, actors[actorSeed % 4]);
    }

    function cancel(uint256 seed, uint256 actorSeed) public {
        uint256 id = _find(seed, SwarmWager.State.Open);
        if (id == 0) return;
        Model storage m = models[id];
        address actor = actors[actorSeed % 4];
        if (actor != m.creator && vm.getBlockTimestamp() <= m.joinBy) {
            _fails(
                id, actor, abi.encodeCall(wager.cancel, (id)), abi.encodeWithSelector(SwarmWager.NotCreator.selector)
            );
            return;
        }
        _cancel(id, actor);
    }

    function abandon(uint256 seed, uint256 actorSeed) public {
        uint256 id = _find(seed, SwarmWager.State.Matched);
        if (id == 0) return;
        if (vm.getBlockTimestamp() <= uint256(models[id].resolveAfter) + WINDOW) {
            _fails(
                id,
                actors[actorSeed % 4],
                abi.encodeCall(wager.abandon, (id)),
                abi.encodeWithSelector(SwarmWager.TooEarly.selector)
            );
            return;
        }
        _abandon(id, actors[actorSeed % 4]);
    }

    function changePrice(uint256 seed) public {
        uint256 mode = seed % 7;
        uint256 price = mode == 0
            ? 0
            : mode == 1
                ? 1
                : mode == 2
                    ? 0.25 ether
                    : mode == 3
                        ? 1 ether
                        : mode == 4 ? type(uint96).max : mode == 5 ? uint256(type(uint96).max) + 1 : 0.5 ether;
        intake.setPrice(price);
    }

    function advanceTime(uint256 seed, uint32 delta) public {
        uint256 next = vm.getBlockTimestamp() + bound(delta, 0, 4 days);
        if (created != 0 && seed % 5 != 4) {
            Model storage m = models[1 + seed % created];
            uint256 mode = seed % 4;
            next = mode == 0
                ? m.joinBy
                : mode == 1
                    ? m.resolveAfter
                    : mode == 2 ? uint256(m.resolveAfter) + WINDOW : uint256(m.askedAt) + WINDOW;
            next += delta % 2;
        }
        if (next > vm.getBlockTimestamp()) vm.warp(next);
    }

    function donate(uint256 actorSeed, uint96 rawAmount) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(rawAmount, 1, 1 ether);
        vm.prank(actor);
        token.transfer(address(wager), amount);
        donations[actor] += amount;
        totalDonations += amount;
    }

    /// Explicitly try every entry point in incompatible states, including unknown ids. The expected
    /// WrongState error also proves these calls did not reach token or oracle dependencies.
    function wrongState(uint256 seed, uint8 operation, uint256 actorSeed) public {
        uint256 op = operation % 6;
        SwarmWager.State required =
            op < 2 ? SwarmWager.State.Open : op < 5 ? SwarmWager.State.Matched : SwarmWager.State.Asked;
        SwarmWager.State wanted = SwarmWager.State(seed % 6);
        uint256 id = wanted == required || wanted == SwarmWager.State.None ? 0 : _find(seed, wanted);
        if (id == 0) id = created + 1;
        _fails(
            id,
            actors[actorSeed % 4],
            _action(id, operation),
            abi.encodeWithSelector(SwarmWager.WrongState.selector, models[id].state)
        );
    }

    /// Fail after the registry has pulled the fee and Intake has moved it to its recipient.
    /// The entire nested transaction, including counters and allowances, must roll back.
    function failingResolve(uint256 seed) public {
        uint256 id = _find(seed, SwarmWager.State.Matched);
        if (id == 0 || vm.getBlockTimestamp() < models[id].resolveAfter) return;
        uint256 savedPrice = intake.currentPrice();
        intake.setPrice(models[id].fee);
        intake.setRejection(2, false);
        _fails(
            id,
            actors[seed % 4],
            abi.encodeCall(wager.resolve, (id)),
            abi.encodeWithSelector(RecordingIntake.RequestRejected.selector)
        );
        intake.setRejection(0, false);
        intake.setPrice(savedPrice);
    }

    function assertAccounting() public view {
        uint256 owed;
        for (uint256 id = 1; id <= created; ++id) {
            Model storage m = models[id];
            if (m.state == SwarmWager.State.Open) owed += uint256(m.stake) + m.fee;
            else if (m.state == SwarmWager.State.Matched) owed += uint256(m.stake) * 2 + m.fee;
            else if (m.state == SwarmWager.State.Asked) owed += uint256(m.stake) * 2;
        }
        assertEq(token.balanceOf(address(wager)), owed + totalDonations, "escrow is not fully backed");
        assertEq(totalIn, totalOut + totalFees + owed, "cash flow does not reconcile");
        assertEq(token.balanceOf(intake.recipient()), totalFees, "fee paid twice or paid without resolving");
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(wager), address(registry)), 0, "standing registry allowance");
        assertEq(token.allowance(address(registry), address(intake)), 0, "standing intake allowance");
        uint256 balances = token.balanceOf(address(wager)) + totalFees;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            uint256 balance = token.balanceOf(actor);
            assertEq(
                balance + debits[actor] + donations[actor], INITIAL + credits[actor], "wrong actor charged or paid"
            );
            balances += balance;
        }
        assertEq(token.totalSupply(), INITIAL * 4, "supply changed after setup");
        assertEq(balances, INITIAL * 4, "tokens missing from known holders");
        assertEq(wager.count(), created);
        assertEq(registry.asked(), resolved, "oracle asked more than once per resolve");
        assertEq(intake.nonce(), resolved);
    }

    function assertRecords() public view {
        for (uint256 id = 1; id <= created; ++id) {
            Model storage m = models[id];
            (SwarmWager.Wager memory w, bytes memory body) = wager.get(id);
            assertEq(w.creator, m.creator);
            assertEq(w.yes, m.yes);
            assertEq(w.no, m.no);
            assertEq(w.stake, m.stake);
            assertEq(w.fee, m.fee);
            assertEq(w.joinBy, m.joinBy);
            assertEq(w.resolveAfter, m.resolveAfter);
            assertEq(w.askedAt, m.askedAt);
            assertEq(uint8(w.state), uint8(m.state), "illegal lifecycle transition");
            assertEq(w.winner, m.winner, "wrong side won");
            assertEq(w.requestId, m.requestId);
            assertEq(body, m.body, "terms changed after funding");
            if (m.closedHash != bytes32(0)) {
                assertEq(keccak256(abi.encode(w, body)), m.closedHash, "closed wager changed");
            }
            if (m.requestId != bytes32(0)) {
                (AskSwarmRegistry.Ask memory k,) = registry.get(m.requestId);
                assertEq(k.asker, address(wager));
                assertEq(k.askedAt, m.askedAt);
                assertEq(requestOwner[m.requestId], id);
            }
        }
    }

    /// Called by afterInvariant, not a random target: even total oracle outage must leave
    /// each position with a finite exit. No fresh token mint or funding is allowed here.
    function closeAll() external {
        uint256 deadline = vm.getBlockTimestamp();
        for (uint256 id = 1; id <= created; ++id) {
            Model storage m = models[id];
            uint256 end = (m.askedAt == 0 ? uint256(m.resolveAfter) : uint256(m.askedAt)) + WINDOW + 1;
            if (end > deadline) deadline = end;
        }
        vm.warp(deadline);
        intake.setRejection(0, true); // exits must work without quoting or buying a new request
        for (uint256 id = 1; id <= created; ++id) {
            SwarmWager.State state = models[id].state;
            if (state == SwarmWager.State.Open) _cancel(id, actors[3]);
            else if (state == SwarmWager.State.Matched) _abandon(id, actors[3]);
            else if (state == SwarmWager.State.Asked) _settle(id, actors[3]);
        }
        assertAccounting();
        assertRecords();
        assertEq(token.balanceOf(address(wager)), totalDonations, "user funds trapped after all deadlines");
        assertEq(paid + refunded + cancelled + abandoned, created);
    }

    function _settle(uint256 id, address actor) private {
        Model storage m = models[id];
        if (m.outcome == Outcome.Pending && vm.getBlockTimestamp() <= uint256(m.askedAt) + WINDOW) {
            _fails(
                id, actor, abi.encodeCall(wager.settle, (id)), abi.encodeWithSelector(SwarmWager.StillPending.selector)
            );
            return;
        }
        vm.prank(actor);
        wager.settle(id);
        if (m.outcome == Outcome.Yes || m.outcome == Outcome.No) {
            m.winner = m.outcome == Outcome.Yes ? m.yes : m.no;
            _credit(m.winner, uint256(m.stake) * 2);
            m.state = SwarmWager.State.Paid;
            ++paid;
        } else {
            _credit(m.yes, m.stake);
            _credit(m.no, m.stake);
            m.state = SwarmWager.State.Refunded;
            ++refunded;
        }
        _close(id);
    }

    function _cancel(uint256 id, address actor) private {
        Model storage m = models[id];
        vm.prank(actor);
        wager.cancel(id);
        _credit(m.creator, uint256(m.stake) + m.fee);
        m.fee = 0; // the contract zeroes the returned escrow (review finding 9bcb33ce3798)
        m.state = SwarmWager.State.Refunded;
        ++cancelled;
        _close(id);
    }

    function _abandon(uint256 id, address actor) private {
        Model storage m = models[id];
        vm.prank(actor);
        wager.abandon(id);
        _credit(m.yes, m.stake);
        _credit(m.no, m.stake);
        _credit(m.creator, m.fee);
        m.fee = 0; // the contract zeroes the returned escrow (review finding 9bcb33ce3798)
        m.state = SwarmWager.State.Refunded;
        ++abandoned;
        _close(id);
    }

    function _close(uint256 id) private {
        (SwarmWager.Wager memory w, bytes memory body) = wager.get(id);
        models[id].closedHash = keccak256(abi.encode(w, body));
    }

    function _debit(address actor, uint256 amount) private {
        debits[actor] += amount;
        totalIn += amount;
    }

    function _credit(address actor, uint256 amount) private {
        credits[actor] += amount;
        totalOut += amount;
    }

    function _find(uint256 seed, SwarmWager.State state) private view returns (uint256) {
        for (uint256 i; i < created; ++i) {
            uint256 id = 1 + ((seed % created + i) % created);
            if (models[id].state == state) return id;
        }
        return 0;
    }

    function _pending(uint256 seed) private view returns (uint256) {
        for (uint256 i; i < created; ++i) {
            uint256 id = 1 + ((seed % created + i) % created);
            // Late delivery after the wager's timeout refund is deliberately still reachable.
            if (models[id].requestId != bytes32(0) && models[id].outcome == Outcome.Pending) return id;
        }
        return 0;
    }

    function _action(uint256 id, uint8 operation) private view returns (bytes memory) {
        uint256 op = operation % 6;
        if (op == 0) return abi.encodeCall(wager.join, (id));
        if (op == 1) return abi.encodeCall(wager.cancel, (id));
        if (op == 2) return abi.encodeCall(wager.topUpFee, (id, uint96(1)));
        if (op == 3) return abi.encodeCall(wager.resolve, (id));
        if (op == 4) return abi.encodeCall(wager.abandon, (id));
        return abi.encodeCall(wager.settle, (id));
    }

    function _fails(uint256 id, address actor, bytes memory data, bytes memory expectedError) private {
        (SwarmWager.Wager memory beforeW, bytes memory beforeBody) = wager.get(id);
        uint256 allowanceBefore = token.allowance(actor, address(wager));
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(wager).call(data);
        assertFalse(ok, "invalid call succeeded");
        assertEq(reason, expectedError, "failure came from an unexpected guard");
        (SwarmWager.Wager memory afterW, bytes memory afterBody) = wager.get(id);
        assertEq(
            keccak256(abi.encode(afterW, afterBody)), keccak256(abi.encode(beforeW, beforeBody)), "revert changed wager"
        );
        assertEq(token.allowance(actor, address(wager)), allowanceBefore, "revert spent user allowance");
        ++failedCalls;
        assertAccounting();
    }
}
