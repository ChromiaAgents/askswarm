// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

/// A finite actor universe with a cash journal independent of the market's balance/getters.
/// Only the handler is targeted: the fuzzer cannot mint tokens or fabricate registry storage.
contract SwarmMarketHandler is Test {
    uint256 public constant INITIAL = 1e36;
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant MAX_MARKETS = 24;
    address public immutable treasury = makeAddr("invariant treasury");
    address public immutable recipient = makeAddr("invariant oracle recipient");
    address public immutable writer = makeAddr("invariant writer");
    PaymentToken public immutable token;
    RecordingIntake public immutable intake;
    AskSwarmRegistry public immutable registry;
    SwarmMarket public immutable market;
    address[4] public actors;
    uint256[4] internal debits;
    uint256[4] internal credits;

    struct Ledger {
        uint256 creator;
        uint64 closeAt;
        uint64 resolveAfter;
        uint64 askedAt;
        uint64 issuedAt;
        SwarmMarket.Phase phase;
        SwarmMarket.Phase answer;
        uint256 escrow;
        uint256 yes;
        uint256 no;
        uint256 fee;
        uint256 paid;
        uint256 dust;
        bytes32 requestId;
        bytes32 terminalHash;
        uint256[4] yesBy;
        uint256[4] noBy;
        uint256[4] entitlement;
        bool[4] claimed;
    }

    mapping(uint256 => Ledger) internal ledger;
    mapping(bytes32 => bool) internal usedRequest;
    uint256 public opened;
    uint256 public deposits;
    uint256 public donations;
    uint256 public oraclePaid;
    uint256 public escrowReturned;
    uint256 public fees;
    uint256 public treasuryPaid;
    uint256 public claimsPaid;
    uint256 public asks;
    uint256 public successfulClaims;
    uint256 public rejectedCalls;
    uint256 public lateSettles;
    uint256 public lateIssued;
    uint256[6] public transitions;

    constructor() {
        token = new PaymentToken();
        intake = new RecordingIntake(address(token), recipient, writer);
        registry = new AskSwarmRegistry(address(intake), address(token), vm.addr(KEY));
        market = new SwarmMarket(address(registry), address(token), treasury);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0x1000 + i));
            token.mint(actors[i], INITIAL);
            vm.prank(actors[i]);
            token.approve(address(market), type(uint256).max);
        }
    }

    function openMarket(uint256 actorSeed, uint32 delay) public {
        if (opened == MAX_MARKETS) return;
        uint256 who = actorSeed % 4;
        uint64 closeAt = uint64(vm.getBlockTimestamp() + bound(delay, 1, 6 hours));
        uint256 price = intake.currentPrice();
        bytes memory data = abi.encodeCall(market.open, (bytes("opaque invariant body"), closeAt, closeAt));
        if (price == 0) {
            _reject(actors[who], 0, data, abi.encodeWithSelector(SwarmMarket.BadTerms.selector));
            return;
        }
        vm.prank(actors[who]);
        uint256 id = market.open("opaque invariant body", closeAt, closeAt);
        assertEq(id, ++opened);
        Ledger storage g = ledger[id];
        g.creator = who;
        g.closeAt = closeAt;
        g.resolveAfter = closeAt;
        g.phase = SwarmMarket.Phase.Open;
        g.escrow = price;
        deposits += price;
        debits[who] += price;
        transitions[uint8(SwarmMarket.Phase.Open)]++;
    }

    function stake(uint256 idSeed, uint256 actorSeed, bool yes, uint128 raw) public {
        uint256 id = _id(idSeed);
        uint256 who = actorSeed % 4;
        uint128 amount = uint128(bound(raw, 0, 1e24));
        Ledger storage g = ledger[id];
        bytes memory reason = _phaseError(g.phase, SwarmMarket.Phase.Open);
        if (reason.length == 0 && vm.getBlockTimestamp() >= g.closeAt) {
            reason = abi.encodeWithSelector(SwarmMarket.Closed.selector);
        }
        if (reason.length == 0 && amount == 0) reason = abi.encodeWithSelector(SwarmMarket.BadTerms.selector);
        if (reason.length != 0) {
            _reject(actors[who], id, abi.encodeCall(market.stake, (id, yes, amount)), reason);
            return;
        }
        vm.prank(actors[who]);
        market.stake(id, yes, amount);
        if (yes) {
            g.yes += amount;
            g.yesBy[who] += amount;
        } else {
            g.no += amount;
            g.noBy[who] += amount;
        }
        deposits += amount;
        debits[who] += amount;
    }

    function topUp(uint256 idSeed, uint256 actorSeed, uint96 raw) public {
        uint256 id = _id(idSeed);
        uint256 who = actorSeed % 4;
        uint96 amount = uint96(bound(raw, 0, 2 ether));
        Ledger storage g = ledger[id];
        bytes memory reason = _phaseError(g.phase, SwarmMarket.Phase.Open);
        if (reason.length == 0 && vm.getBlockTimestamp() > uint256(g.resolveAfter) + 1 hours) {
            reason = abi.encodeWithSelector(SwarmMarket.TooLate.selector);
        }
        if (reason.length == 0 && amount == 0) reason = abi.encodeWithSelector(SwarmMarket.BadTerms.selector);
        if (reason.length != 0) {
            _reject(actors[who], id, abi.encodeCall(market.topUpFee, (id, amount)), reason);
            return;
        }
        vm.prank(actors[who]);
        market.topUpFee(id, amount);
        g.escrow += amount;
        deposits += amount;
        debits[who] += amount;
    }

    function changePrice(uint96 raw) public {
        intake.setPrice(bound(raw, 0, 2 ether));
    }

    function resolve(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = _id(idSeed);
        Ledger storage g = ledger[id];
        uint256 now_ = vm.getBlockTimestamp();
        bytes memory reason = _phaseError(g.phase, SwarmMarket.Phase.Open);
        if (reason.length == 0 && now_ < g.resolveAfter) {
            reason = abi.encodeWithSelector(SwarmMarket.TooEarly.selector);
        }
        if (reason.length == 0 && now_ > uint256(g.resolveAfter) + 1 hours) {
            reason = abi.encodeWithSelector(SwarmMarket.TooLate.selector);
        }
        uint256 price = intake.currentPrice();
        bool oneSided = g.yes == 0 || g.no == 0;
        if (reason.length == 0 && !oneSided && (price == 0 || price > g.escrow)) {
            reason = abi.encodeWithSelector(SwarmMarket.BadTerms.selector);
        }
        if (reason.length != 0) {
            _reject(actors[actorSeed % 4], id, abi.encodeCall(market.resolve, (id)), reason);
            return;
        }
        vm.prank(actors[actorSeed % 4]);
        market.resolve(id);
        uint256 refund = g.escrow;
        if (!oneSided) {
            refund -= price;
            oraclePaid += price;
            asks++;
            g.askedAt = uint64(now_);
            g.phase = SwarmMarket.Phase.Asked;
            (SwarmMarket.Market memory m,) = market.get(id);
            g.requestId = m.requestId;
            assertFalse(usedRequest[m.requestId], "two markets share an oracle request");
            usedRequest[m.requestId] = true;
            (AskSwarmRegistry.Ask memory k,) = registry.get(m.requestId);
            assertEq(k.asker, address(market));
            assertEq(k.askedAt, now_);
            assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
            assertEq(intake.lastBody(), "opaque invariant body");
            assertEq(intake.lastAmount(), price);
            transitions[uint8(SwarmMarket.Phase.Asked)]++;
        }
        escrowReturned += refund;
        credits[g.creator] += refund;
        g.escrow = 0;
        if (oneSided) _finish(id, SwarmMarket.Phase.Void);
    }

    /// Callback results go through the actual registry's signature verification and 200k stipend.
    /// The signed issuedAt is the delivery time, backdated to no later than the answer deadline,
    /// or the second after the deadline when the registry's issuedAt tolerance allows it.
    function deliver(uint256 idSeed, uint8 kindSeed) public {
        uint256 id = _id(idSeed);
        Ledger storage g = ledger[id];
        if (g.phase != SwarmMarket.Phase.Asked || g.answer != SwarmMarket.Phase.None) return;
        uint8 kind = kindSeed % 11;
        bytes32 rid = g.requestId;
        g.answer = kind == 0 ? SwarmMarket.Phase.Yes : kind == 1 ? SwarmMarket.Phase.No : SwarmMarket.Phase.Void;
        if (kind == 2 || kind == 3) {
            uint8 status = kind - 1;
            vm.prank(writer);
            assertTrue(
                intake.complete(
                    rid, status, abi.encode(rid, status, bytes32("refused or split"), uint16(0), uint16(0), bytes(""))
                )
            );
        } else if (kind == 4) {
            vm.prank(writer);
            assertFalse(intake.complete(rid, 2, ""));
            registry.markLost(rid);
        } else {
            OracleAttestation memory a;
            a.requestId = keccak256(abi.encode("oracle uuid", rid));
            a.chainId = 1;
            a.questionHash = keccak256(abi.encode("question", id));
            a.answer = abi.encode(kind != 1);
            a.panelSize = 7;
            a.quorum = 4;
            a.agreed = 4;
            uint256 now_ = vm.getBlockTimestamp();
            uint256 deadline = uint256(g.askedAt) + 3 days;
            uint256 variant = (kindSeed / 11) % 3;
            uint256 issued = now_;
            if (variant == 1 && deadline < now_) issued = deadline;
            if (variant == 2 && deadline + 1 <= now_ + 5 minutes && deadline + 1 > now_) issued = deadline + 1;
            a.issuedAt = uint64(issued);
            a.expiresAt = uint64((issued > now_ ? issued : now_) + 1 days);
            g.issuedAt = a.issuedAt;
            if (issued > deadline) lateIssued++;
            if (kind == 6) a.panelSize = 8; // exactly half the panel
            if (kind == 7) a.answerType = 3;
            if (kind == 8) a.answer = abi.encode(uint256(2));
            if (kind == 9) a.answer = hex"01";
            if (kind == 10) a.panelSize = 6;
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(kind == 5 ? KEY + 1 : KEY, registry.digest(a));
            vm.prank(writer);
            assertTrue(
                intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v))), "registry delivery failed"
            );
        }
    }

    function settle(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = _id(idSeed);
        Ledger storage g = ledger[id];
        bytes memory reason = _phaseError(g.phase, SwarmMarket.Phase.Asked);
        bool expired = vm.getBlockTimestamp() > uint256(g.askedAt) + 3 days;
        if (reason.length == 0 && !expired && g.answer == SwarmMarket.Phase.None) {
            reason = abi.encodeWithSelector(SwarmMarket.StillPending.selector);
        }
        if (reason.length != 0) {
            _reject(actors[actorSeed % 4], id, abi.encodeCall(market.settle, (id)), reason);
            return;
        }
        vm.prank(actors[actorSeed % 4]);
        market.settle(id);
        // Pending past the window voids; a decisive answer decides however late settle is called,
        // unless its signed issuedAt is after the window.
        SwarmMarket.Phase outcome = g.answer;
        if (outcome == SwarmMarket.Phase.None) outcome = SwarmMarket.Phase.Void;
        if (outcome != SwarmMarket.Phase.Void && g.issuedAt > uint256(g.askedAt) + 3 days) {
            outcome = SwarmMarket.Phase.Void;
        }
        if (expired && outcome != SwarmMarket.Phase.Void) lateSettles++;
        _finish(id, outcome);
    }

    function abandon(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = _id(idSeed);
        Ledger storage g = ledger[id];
        bytes memory reason = _phaseError(g.phase, SwarmMarket.Phase.Open);
        if (reason.length == 0 && vm.getBlockTimestamp() <= uint256(g.resolveAfter) + 1 hours) {
            reason = abi.encodeWithSelector(SwarmMarket.TooEarly.selector);
        }
        if (reason.length != 0) {
            _reject(actors[actorSeed % 4], id, abi.encodeCall(market.abandon, (id)), reason);
            return;
        }
        vm.prank(actors[actorSeed % 4]);
        market.abandon(id);
        escrowReturned += g.escrow;
        credits[g.creator] += g.escrow;
        g.escrow = 0;
        _finish(id, SwarmMarket.Phase.Void);
    }

    function claim(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = _id(idSeed);
        uint256 who = actorSeed % 4;
        Ledger storage g = ledger[id];
        uint256 expected = g.claimed[who] ? 0 : g.entitlement[who];
        if (expected == 0) {
            _reject(
                actors[who],
                id,
                abi.encodeCall(market.claim, (id)),
                abi.encodeWithSelector(SwarmMarket.NothingToClaim.selector)
            );
            return;
        }
        vm.prank(actors[who]);
        assertEq(market.claim(id), expected, "claim paid the wrong amount");
        g.claimed[who] = true;
        g.paid += expected;
        claimsPaid += expected;
        credits[who] += expected;
        successfulClaims++;
    }

    function donate(uint256 actorSeed, uint96 raw) public {
        uint256 who = actorSeed % 4;
        uint256 amount = bound(raw, 0, 1 ether);
        vm.prank(actors[who]);
        token.transfer(address(market), amount);
        donations += amount;
        debits[who] += amount;
    }

    /// Move monotonically to exact boundaries, their neighbours, or an ordinary elapsed time.
    function advance(uint256 idSeed, uint8 edgeSeed, uint32 elapsed) public {
        Ledger storage g = ledger[_id(idSeed)];
        uint256 edge = edgeSeed % 8;
        uint256 at;
        if (edge == 0) at = g.closeAt == 0 ? 0 : g.closeAt - 1;
        else if (edge == 1) at = g.closeAt;
        else if (edge == 2) at = g.resolveAfter;
        else if (edge == 3) at = uint256(g.resolveAfter) + 1 hours;
        else if (edge == 4) at = uint256(g.resolveAfter) + 1 hours + 1;
        else if (edge == 5) at = uint256(g.askedAt) + 3 days;
        else if (edge == 6) at = uint256(g.askedAt) + 3 days + 1;
        else at = vm.getBlockTimestamp() + bound(elapsed, 0, 3 hours);
        if (at > vm.getBlockTimestamp()) vm.warp(at);
    }

    function _finish(uint256 id, SwarmMarket.Phase phase) internal {
        Ledger storage g = ledger[id];
        g.phase = phase;
        uint256 winning = phase == SwarmMarket.Phase.Yes ? g.yes : g.no;
        uint256 losing = phase == SwarmMarket.Phase.Yes ? g.no : g.yes;
        if (phase != SwarmMarket.Phase.Void) {
            // 2% of the losing pool; odd fee wei belongs to the treasury.
            g.fee = losing / 50;
            credits[g.creator] += g.fee / 2;
            treasuryPaid += g.fee - g.fee / 2;
            fees += g.fee;
        }
        uint256 totalOwed;
        for (uint256 i; i < 4; ++i) {
            uint256 owed = market.claimable(id, actors[i]);
            if (phase == SwarmMarket.Phase.Void) {
                assertEq(owed, g.yesBy[i] + g.noBy[i], "void must refund both stakes");
            } else {
                uint256 principal = phase == SwarmMarket.Phase.Yes ? g.yesBy[i] : g.noBy[i];
                assertGe(owed, principal, "winner lost principal");
                uint256 reward = owed - principal;
                // Characterize floor division without duplicating claimable's computation.
                uint256 numerator = principal * (losing - g.fee);
                assertLe(reward * winning, numerator, "winner overpaid");
                assertGt((reward + 1) * winning, numerator, "winner underpaid");
            }
            g.entitlement[i] = owed;
            totalOwed += owed;
        }
        assertLe(totalOwed + g.fee, g.yes + g.no, "market promises more than it received");
        g.dust = g.yes + g.no - g.fee - totalOwed;
        assertLt(g.dust, 4, "more than one rounding wei per winning actor");
        if (phase == SwarmMarket.Phase.Void) assertEq(g.dust, 0);
        g.terminalHash = _hash(id);
        transitions[uint8(phase)]++;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return seed % (opened + 1); // includes the nonexistent market zero
    }

    function _phaseError(SwarmMarket.Phase have, SwarmMarket.Phase want) internal pure returns (bytes memory) {
        if (have != want) return abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, have);
        return "";
    }

    function _hash(uint256 id) internal view returns (bytes32) {
        (SwarmMarket.Market memory m, bytes memory body) = market.get(id);
        return keccak256(abi.encode(m, body));
    }

    function _reject(address actor, uint256 id, bytes memory data, bytes memory reason) internal {
        bytes32 before_ = _hash(id);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(market).call(data);
        assertFalse(ok, "invalid lifecycle call succeeded");
        assertEq(ret, reason, "unexpected revert (not an allowed failure)");
        assertEq(_hash(id), before_, "revert changed market");
        rejectedCalls++;
    }

    function assertAccounting() public view {
        uint256 liabilities;
        uint256 dust;
        assertEq(market.count(), opened);
        for (uint256 id = 1; id <= opened; ++id) {
            Ledger storage g = ledger[id];
            (SwarmMarket.Market memory m, bytes memory body) = market.get(id);
            assertEq(uint8(m.phase), uint8(g.phase), "illegal phase transition");
            assertEq(m.creator, actors[g.creator]);
            assertEq(m.closeAt, g.closeAt);
            assertEq(m.resolveAfter, g.resolveAfter);
            assertEq(m.askedAt, g.askedAt);
            assertEq(m.requestId, g.requestId);
            assertEq(m.feeEscrow, g.escrow);
            assertEq(m.yesPool, g.yes);
            assertEq(m.noPool, g.no);
            assertEq(body, "opaque invariant body");
            bool terminal = uint8(g.phase) >= uint8(SwarmMarket.Phase.Yes);
            if (terminal) {
                assertEq(_hash(id), g.terminalHash, "finished market changed");
                assertLe(g.paid + g.fee, g.yes + g.no);
                dust += g.dust;
            } else {
                liabilities += g.yes + g.no + g.escrow;
                assertEq(m.winnersShare, 0);
            }
            for (uint256 i; i < 4; ++i) {
                assertEq(market.yesStake(id, actors[i]), g.yesBy[i]);
                assertEq(market.noStake(id, actors[i]), g.noBy[i]);
                assertEq(market.claimed(id, actors[i]), g.claimed[i]);
                uint256 owed = g.claimed[i] ? 0 : g.entitlement[i];
                assertEq(market.claimable(id, actors[i]), owed);
                if (terminal) liabilities += owed;
            }
        }
        uint256 held = token.balanceOf(address(market));
        assertEq(held, liabilities + dust + donations, "liabilities not backed, or money disappeared");
        assertEq(held + claimsPaid + fees + escrowReturned + oraclePaid, deposits + donations, "cash journal mismatch");
        for (uint256 i; i < 4; ++i) {
            assertEq(
                token.balanceOf(actors[i]) + debits[i],
                INITIAL + credits[i],
                "actor received or lost unaccounted tokens"
            );
        }
        assertEq(token.balanceOf(treasury), treasuryPaid);
        assertEq(token.balanceOf(recipient), oraclePaid);
        assertEq(token.totalSupply(), 4 * INITIAL);
        assertEq(registry.asked(), asks);
        assertEq(intake.nonce(), asks);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(market), address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
    }

    /// Called only after each campaign: demonstrate liveness, including every remaining claim.
    function unwind() external {
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 dust;
        for (uint256 id = 1; id <= opened; ++id) {
            Ledger storage g = ledger[id];
            if (g.phase == SwarmMarket.Phase.Open) abandon(id, 3);
            if (g.phase == SwarmMarket.Phase.Asked) settle(id, 3);
            for (uint256 i; i < 4; ++i) {
                claim(id, i);
            }
            dust += g.dust;
        }
        assertAccounting();
        assertEq(token.balanceOf(address(market)), donations + dust, "unclaimed funds remain after unwind");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmMarketInvariantTest is Test {
    SwarmMarketHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        handler = new SwarmMarketHandler();
        // Start with live positions and each outcome, so no campaign can pass on empty state.
        for (uint256 id = 1; id <= 6; ++id) {
            handler.openMarket(id % 4, 60);
            handler.stake(id, 0, true, 31);
            handler.stake(id, 1, true, 17);
            handler.stake(id, 1, false, 19);
            handler.stake(id, 2, false, 134);
        }
        handler.topUp(1, 3, 1 ether);
        handler.advance(1, 2, 0);
        for (uint256 id = 1; id <= 5; ++id) {
            handler.resolve(id, 3);
        }
        handler.deliver(1, 0);
        handler.settle(1, 2);
        handler.deliver(2, 1);
        handler.settle(2, 0);
        handler.deliver(3, 3);
        handler.settle(3, 1);
        handler.deliver(4, 0); // answered, still unsettled
        handler.claim(1, 0);
        handler.claim(3, 1);
        handler.donate(3, 7);
        handler.openMarket(0, 1 hours); // still taking stakes
        handler.assertAccounting();

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.openMarket.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.topUp.selector;
        selectors[3] = handler.changePrice.selector;
        selectors[4] = handler.resolve.selector;
        selectors[5] = handler.deliver.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.abandon.selector;
        selectors[8] = handler.claim.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_cashLiabilitiesFeesAndTerminalStates() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.unwind();
    }

    function test_handlerReachesAllPhasesAndUnwinds() public {
        for (uint8 phase = 1; phase <= 5; ++phase) {
            assertGt(handler.transitions(phase), 0);
        }
        assertGt(handler.successfulClaims(), 0);
        handler.claim(1, 0); // duplicate, checked rejection
        handler.stake(2, 0, true, 1); // closed terminal market
        handler.settle(5, 0); // pending registry result
        assertGe(handler.rejectedCalls(), 3);
        // A Yes delivered at the deadline but signed for the second after it voids, not Yes.
        handler.advance(5, 5, 0);
        handler.deliver(5, 22);
        assertEq(handler.lateIssued(), 1);
        handler.settle(5, 1);
        (SwarmMarket.Market memory m,) = handler.market().get(5);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));
        // Market 4's Yes was issued in the window; settling 10 days later still decides it.
        handler.unwind();
        assertEq(handler.lateSettles(), 1);
        (m,) = handler.market().get(4);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Yes));
    }
}
