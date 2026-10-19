// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {SwarmWager} from "src/SwarmWager.sol";
import {PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

/// @dev Deploys the launch's three applications in one call with CREATE2, as the project factory
/// does in one transaction: registry first, then the market and the wager pointing at it.
contract SystemLaunchProbe {
    function deployAll(address intake, address imd, address signer, address treasury)
        external
        returns (AskSwarmRegistry registry, SwarmMarket market, SwarmWager wager)
    {
        registry = new AskSwarmRegistry{salt: keccak256("AskSwarmRegistry")}(intake, imd, signer);
        market = new SwarmMarket{salt: keccak256("SwarmMarket")}(address(registry), imd, treasury);
        wager = new SwarmWager{salt: keccak256("SwarmWager")}(address(registry), imd);
    }
}

/// @notice Drives the whole Robinhood Chain system (one registry shared by a SwarmMarket and a
/// SwarmWager) through random call sequences: markets and wagers opened, staked, joined, topped up,
/// resolved, abandoned, cancelled, settled and claimed by four actors, while the Intake writer
/// answers, refuses, fails or strands their asks with every kind of attestation and the price and
/// the clock move. Each settlement is checked against the outcome the brief prescribes for the
/// answer that was delivered, computed here from what the handler sent rather than read back.
contract SystemHandler is Test {
    uint256 internal constant SIGNING_KEY = 0x4663A11CE;
    uint256 internal constant WRONG_KEY = 0x4663B0B;
    uint256 internal constant FUNDS = 1e30;

    PaymentToken public immutable token;
    RecordingIntake public immutable intake;
    AskSwarmRegistry public immutable registry;
    SwarmMarket public immutable market;
    SwarmWager public immutable wager;
    address public immutable writer;
    address public immutable treasury;
    address public immutable intakeRecipient;
    address[4] internal actors;

    // ---- ghost state, written only from what this handler did ----
    // markets
    mapping(uint256 => uint256) public gMarketEscrow; // fee escrow the market should still hold
    mapping(uint256 => uint256) public gYes;
    mapping(uint256 => uint256) public gNo;
    mapping(uint256 => mapping(address => uint256)) public gYesOf;
    mapping(uint256 => mapping(address => uint256)) public gNoOf;
    mapping(uint256 => uint256) public gFeeTaken;
    mapping(uint256 => uint256) public gClaimedOut;
    mapping(uint256 => uint8) public gMarketTerminal; // 0 none, else the Phase it ended in
    // wagers
    mapping(uint256 => uint256) public gWagerFee;
    mapping(uint256 => uint256) public gWagerStake;
    mapping(uint256 => bool) public gWagerMatched;
    mapping(uint256 => uint8) public gWagerTerminal;

    // deliveries, keyed by registry request id
    struct Delivery {
        bool done;
        uint8 mode;
        uint64 issuedAt;
    }

    mapping(bytes32 => Delivery) public gDelivery;
    bytes32[] public asked; // every request id the market or the wager bought
    uint256 public gIntakePaid; // what the registry forwarded to Intake on their behalf

    // reachability counters
    uint256 public marketsYes;
    uint256 public marketsNo;
    uint256 public marketsVoid;
    uint256 public marketsVoidAfterAsk;
    uint256 public wagersPaid;
    uint256 public wagersRefundedAfterAsk;
    uint256 public claims;
    uint256 public lateVoids;
    uint256 public smallPanelVoids;

    constructor(
        PaymentToken token_,
        RecordingIntake intake_,
        AskSwarmRegistry registry_,
        SwarmMarket market_,
        SwarmWager wager_,
        address writer_,
        address treasury_,
        address recipient_
    ) {
        token = token_;
        intake = intake_;
        registry = registry_;
        market = market_;
        wager = wager_;
        writer = writer_;
        treasury = treasury_;
        intakeRecipient = recipient_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("system actor ", vm.toString(i)));
            actors[i] = a;
            token.mint(a, FUNDS);
            vm.startPrank(a);
            token.approve(address(market_), type(uint256).max);
            token.approve(address(wager_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function askedCount() external view returns (uint256) {
        return asked.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    // ================= market =================

    function openMarket(uint256 actorSeed, uint256 closeDelay, uint256 resolveDelay, uint256 bodySeed) external {
        address a = _actor(actorSeed);
        uint64 closeAt = _now() + uint64(bound(closeDelay, 1, 12 hours));
        uint64 resolveAfter = closeAt + uint64(bound(resolveDelay, 0, 6 hours));
        uint256 p = intake.currentPrice();
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        uint256 id =
            market.open(bodySeed % 2 == 0 ? bytes("same body for both") : bytes("market body"), closeAt, resolveAfter);
        assertEq(before - token.balanceOf(a), p, "open pulls exactly the price");
        gMarketEscrow[id] = p;
    }

    function _marketId(uint256 seed) internal view returns (uint256) {
        // Mostly the three newest, so a sequence carries one market through its whole life.
        uint256 c = market.count();
        if (c == 0) return 0;
        return seed % 8 == 0 ? 1 + (seed >> 8) % c : c - (seed >> 8) % (c < 3 ? c : 3);
    }

    function stake(uint256 actorSeed, uint256 idSeed, bool yes, uint256 amount) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        uint128 amt = uint128(bound(amount, 1, 1_000 ether));
        (SwarmMarket.Market memory m,) = market.get(id);
        vm.prank(a);
        if (m.phase != SwarmMarket.Phase.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, m.phase));
            market.stake(id, yes, amt);
            return;
        }
        if (_now() >= m.closeAt) {
            vm.expectRevert(SwarmMarket.Closed.selector);
            market.stake(id, yes, amt);
            return;
        }
        market.stake(id, yes, amt);
        if (yes) {
            gYes[id] += amt;
            gYesOf[id][a] += amt;
        } else {
            gNo[id] += amt;
            gNoOf[id][a] += amt;
        }
    }

    function topUpMarket(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        uint96 amt = uint96(bound(amount, 1, 1 ether));
        uint256 window = market.RESOLVE_WINDOW();
        vm.prank(_actor(actorSeed));
        if (m.phase != SwarmMarket.Phase.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, m.phase));
            market.topUpFee(id, amt);
            return;
        }
        if (_now() > uint256(m.resolveAfter) + window) {
            vm.expectRevert(SwarmMarket.TooLate.selector);
            market.topUpFee(id, amt);
            return;
        }
        market.topUpFee(id, amt);
        gMarketEscrow[id] += amt;
    }

    function resolveMarket(uint256 idSeed, bool warpIntoWindow, uint256 offset) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        if (
            warpIntoWindow && m.phase == SwarmMarket.Phase.Open && _now() < m.resolveAfter && gYes[id] != 0
                && gNo[id] != 0
        ) {
            vm.warp(uint256(m.resolveAfter) + bound(offset, 0, market.RESOLVE_WINDOW()));
        }
        if (m.phase != SwarmMarket.Phase.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, m.phase));
            market.resolve(id);
            return;
        }
        if (_now() < m.resolveAfter) {
            vm.expectRevert(SwarmMarket.TooEarly.selector);
            market.resolve(id);
            return;
        }
        if (_now() > uint256(m.resolveAfter) + market.RESOLVE_WINDOW()) {
            vm.expectRevert(SwarmMarket.TooLate.selector);
            market.resolve(id);
            return;
        }
        address creator = m.creator;
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 p = intake.currentPrice();
        if (gYes[id] == 0 || gNo[id] == 0) {
            market.resolve(id);
            _marketVoided(id);
            assertEq(token.balanceOf(creator) - creatorBefore, gMarketEscrow[id], "one-sided void returns escrow");
            gMarketEscrow[id] = 0;
            return;
        }
        if (p > gMarketEscrow[id]) {
            vm.expectRevert(SwarmMarket.BadTerms.selector);
            market.resolve(id);
            return;
        }
        uint256 recipientBefore = token.balanceOf(intakeRecipient);
        market.resolve(id);
        assertEq(token.balanceOf(intakeRecipient) - recipientBefore, p, "the market pays the swarm exactly once");
        assertEq(token.balanceOf(creator) - creatorBefore, gMarketEscrow[id] - p, "remainder to creator");
        gIntakePaid += p;
        gMarketEscrow[id] = 0;
        (m,) = market.get(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Asked));
        asked.push(m.requestId);
    }

    function abandonMarket(uint256 idSeed) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        if (m.phase != SwarmMarket.Phase.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, m.phase));
            market.abandon(id);
            return;
        }
        if (_now() <= uint256(m.resolveAfter) + market.RESOLVE_WINDOW()) {
            vm.expectRevert(SwarmMarket.TooEarly.selector);
            market.abandon(id);
            return;
        }
        uint256 creatorBefore = token.balanceOf(m.creator);
        market.abandon(id);
        _marketVoided(id);
        assertEq(token.balanceOf(m.creator) - creatorBefore, gMarketEscrow[id], "abandon returns escrow");
        gMarketEscrow[id] = 0;
    }

    function settleMarket(uint256 idSeed) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        if (m.phase != SwarmMarket.Phase.Asked) {
            vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, m.phase));
            market.settle(id);
            return;
        }
        uint256 deadline = uint256(m.askedAt) + market.ANSWER_WINDOW();
        (,, AskSwarmRegistry.Status st) = registry.asks(m.requestId);
        if (st == AskSwarmRegistry.Status.Pending && _now() <= deadline) {
            vm.expectRevert(SwarmMarket.StillPending.selector);
            market.settle(id);
            return;
        }
        Delivery memory d = gDelivery[m.requestId];
        // Expected from what the writer delivered: only a verified, canonical bool from a strict
        // majority of at least MIN_PANEL, issued no later than the answer deadline, decides.
        bool decides = d.done && d.mode <= 3 && d.issuedAt <= deadline && d.mode != 2;
        uint256 creatorBefore = token.balanceOf(m.creator);
        uint256 treasuryBefore = token.balanceOf(treasury);
        market.settle(id);
        (m,) = market.get(id);
        if (!decides) {
            _marketVoided(id);
            marketsVoidAfterAsk++;
            if (d.done && d.mode == 2) smallPanelVoids++;
            if (d.done && d.mode == 3 && d.issuedAt > deadline) lateVoids++;
            assertEq(token.balanceOf(treasury), treasuryBefore, "a void takes no fee");
            return;
        }
        bool yes = d.mode != 1;
        assertEq(uint8(m.phase), uint8(yes ? SwarmMarket.Phase.Yes : SwarmMarket.Phase.No), "answer decides");
        uint256 losers = yes ? gNo[id] : gYes[id];
        uint256 fee = losers * 2 / 100;
        assertEq(token.balanceOf(treasury) - treasuryBefore, fee - fee / 2, "treasury half of 2% of losers");
        assertEq(token.balanceOf(m.creator) - creatorBefore, fee / 2, "creator half of 2% of losers");
        assertEq(m.winnersShare, losers - fee);
        gFeeTaken[id] = fee;
        gMarketTerminal[id] = uint8(m.phase);
        if (yes) marketsYes++;
        else marketsNo++;
    }

    function _marketVoided(uint256 id) internal {
        (SwarmMarket.Market memory m,) = market.get(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void), "voided");
        assertEq(m.feeEscrow, 0);
        gMarketTerminal[id] = uint8(SwarmMarket.Phase.Void);
        marketsVoid++;
    }

    function claim(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _marketId(idSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        uint256 owed = _expectedClaim(id, a);
        assertEq(market.claimable(id, a), owed, "claimable matches the parimutuel rule");
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        if (owed == 0) {
            vm.expectRevert(SwarmMarket.NothingToClaim.selector);
            market.claim(id);
            return;
        }
        market.claim(id);
        assertEq(token.balanceOf(a) - before, owed);
        gClaimedOut[id] += owed;
        claims++;
        vm.prank(a);
        vm.expectRevert(SwarmMarket.NothingToClaim.selector);
        market.claim(id);
    }

    /// The payout rule written out from the ghost stakes: void returns every stake; a decided market
    /// pays a winner its stake plus its pro-rata share of the losing pool after the fee.
    function _expectedClaim(uint256 id, address a) public view returns (uint256) {
        if (market.claimed(id, a)) return 0;
        uint8 t = gMarketTerminal[id];
        if (t == uint8(SwarmMarket.Phase.Void)) return gYesOf[id][a] + gNoOf[id][a];
        if (t == uint8(SwarmMarket.Phase.Yes)) {
            uint256 y = gYesOf[id][a];
            return y == 0 ? 0 : y + y * (gNo[id] - gFeeTaken[id]) / gYes[id];
        }
        if (t == uint8(SwarmMarket.Phase.No)) {
            uint256 n = gNoOf[id][a];
            return n == 0 ? 0 : n + n * (gYes[id] - gFeeTaken[id]) / gNo[id];
        }
        return 0;
    }

    // ================= wager =================

    function _wagerId(uint256 seed) internal view returns (uint256) {
        uint256 c = wager.count();
        if (c == 0) return 0;
        return seed % 8 == 0 ? 1 + (seed >> 8) % c : c - (seed >> 8) % (c < 3 ? c : 3);
    }

    function createWager(
        uint256 actorSeed,
        bool saysYes,
        uint256 amount,
        uint256 joinDelay,
        uint256 resolveDelay,
        uint256 bodySeed
    ) external {
        address a = _actor(actorSeed);
        uint96 s = uint96(bound(amount, 1, 1_000 ether));
        uint64 joinBy = _now() + uint64(bound(joinDelay, 1, 2 days));
        uint64 resolveAfter = joinBy + uint64(bound(resolveDelay, 0, 1 days));
        uint256 p = intake.currentPrice();
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        uint256 id = wager.create(
            bodySeed % 2 == 0 ? bytes("same body for both") : bytes("wager body"), saysYes, s, joinBy, resolveAfter
        );
        assertEq(before - token.balanceOf(a), uint256(s) + p);
        gWagerFee[id] = p;
        gWagerStake[id] = s;
    }

    function joinWager(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        address a = _actor(actorSeed);
        if (a == w.creator) a = actors[(actorSeed % 4 + 1) % 4];
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        if (w.state != SwarmWager.State.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.join(id);
            return;
        }
        if (_now() > w.joinBy) {
            vm.expectRevert(SwarmWager.TooLate.selector);
            wager.join(id);
            return;
        }
        wager.join(id);
        assertEq(before - token.balanceOf(a), gWagerStake[id], "equal stake");
        gWagerMatched[id] = true;
        (w,) = wager.get(id);
        assertTrue(w.yes == a || w.no == a);
        assertTrue(w.yes != w.no);
    }

    function cancelWager(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        address a = _actor(actorSeed);
        uint256 before = token.balanceOf(w.creator);
        vm.prank(a);
        if (w.state != SwarmWager.State.Open) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.cancel(id);
            return;
        }
        if (a != w.creator && _now() <= w.joinBy) {
            vm.expectRevert(SwarmWager.NotCreator.selector);
            wager.cancel(id);
            return;
        }
        wager.cancel(id);
        assertEq(token.balanceOf(w.creator) - before, gWagerStake[id] + gWagerFee[id]);
        gWagerFee[id] = 0;
        gWagerTerminal[id] = uint8(SwarmWager.State.Refunded);
    }

    function topUpWager(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        uint96 amt = uint96(bound(amount, 1, 1 ether));
        vm.prank(_actor(actorSeed));
        if (w.state != SwarmWager.State.Matched) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.topUpFee(id, amt);
            return;
        }
        wager.topUpFee(id, amt);
        gWagerFee[id] += amt;
    }

    function resolveWager(uint256 idSeed, bool warpPast) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (warpPast && w.state == SwarmWager.State.Matched && _now() < w.resolveAfter) vm.warp(w.resolveAfter);
        if (w.state != SwarmWager.State.Matched) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.resolve(id);
            return;
        }
        if (_now() < w.resolveAfter) {
            vm.expectRevert(SwarmWager.TooEarly.selector);
            wager.resolve(id);
            return;
        }
        uint256 p = intake.currentPrice();
        if (p > gWagerFee[id]) {
            vm.expectRevert(SwarmWager.BadTerms.selector);
            wager.resolve(id);
            return;
        }
        uint256 creatorBefore = token.balanceOf(w.creator);
        uint256 recipientBefore = token.balanceOf(intakeRecipient);
        wager.resolve(id);
        assertEq(token.balanceOf(intakeRecipient) - recipientBefore, p);
        assertEq(token.balanceOf(w.creator) - creatorBefore, gWagerFee[id] - p);
        gIntakePaid += p;
        gWagerFee[id] = 0;
        (w,) = wager.get(id);
        asked.push(w.requestId);
    }

    function abandonWager(uint256 idSeed) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Matched) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.abandon(id);
            return;
        }
        if (_now() <= uint256(w.resolveAfter) + wager.ANSWER_WINDOW()) {
            vm.expectRevert(SwarmWager.TooEarly.selector);
            wager.abandon(id);
            return;
        }
        uint256 yesBefore = token.balanceOf(w.yes);
        uint256 noBefore = token.balanceOf(w.no);
        uint256 creatorBefore = token.balanceOf(w.creator);
        wager.abandon(id);
        // yes and no are distinct; the creator is one of them.
        uint256 got = token.balanceOf(w.yes) - yesBefore + token.balanceOf(w.no) - noBefore;
        assertEq(got, 2 * gWagerStake[id] + gWagerFee[id], "both stakes and the fee back");
        assertEq(token.balanceOf(w.creator) - creatorBefore, gWagerStake[id] + gWagerFee[id]);
        gWagerFee[id] = 0;
        gWagerTerminal[id] = uint8(SwarmWager.State.Refunded);
    }

    function settleWager(uint256 idSeed) external {
        uint256 id = _wagerId(idSeed);
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Asked) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, w.state));
            wager.settle(id);
            return;
        }
        (,, AskSwarmRegistry.Status st) = registry.asks(w.requestId);
        if (st == AskSwarmRegistry.Status.Pending && _now() <= uint256(w.askedAt) + wager.ANSWER_WINDOW()) {
            vm.expectRevert(SwarmWager.StillPending.selector);
            wager.settle(id);
            return;
        }
        Delivery memory d = gDelivery[w.requestId];
        // The wager pays on any verified canonical bool from a strict majority (modes 0-3).
        bool pays = d.done && d.mode <= 3;
        uint256 yesBefore = token.balanceOf(w.yes);
        uint256 noBefore = token.balanceOf(w.no);
        wager.settle(id);
        uint256 pot = 2 * gWagerStake[id];
        if (!pays) {
            assertEq(token.balanceOf(w.yes) - yesBefore, gWagerStake[id]);
            assertEq(token.balanceOf(w.no) - noBefore, gWagerStake[id]);
            gWagerTerminal[id] = uint8(SwarmWager.State.Refunded);
            wagersRefundedAfterAsk++;
            return;
        }
        address winner = d.mode == 1 ? w.no : w.yes;
        address loser = d.mode == 1 ? w.yes : w.no;
        assertEq(token.balanceOf(winner) - (winner == w.yes ? yesBefore : noBefore), pot, "pot to the right side");
        assertEq(token.balanceOf(loser), loser == w.yes ? yesBefore : noBefore, "loser gets nothing");
        (w,) = wager.get(id);
        assertEq(w.winner, winner);
        gWagerTerminal[id] = uint8(SwarmWager.State.Paid);
        wagersPaid++;
    }

    // ================= the oracle side =================

    /// Modes: 0 yes, 1 no (panel 9, 7 agreed, quorum 5); 2 yes from a panel of 5 (below the
    /// market's MIN_PANEL); 3 yes issued 299 s ahead (late if that passes the deadline);
    /// 4 non-canonical bool word 2; 5 a bytes32 answer type; 6 signed by the wrong key;
    /// 7 verified but no strict majority (5 of 10); 8 refused; 9 no result; 10 stranded then markLost.
    function deliver(uint256 askSeed, uint256 modeSeed, bool nearDeadline) external {
        if (asked.length == 0) return;
        uint256 len = asked.length;
        bytes32 rid = asked[askSeed % 4 == 0 ? (askSeed >> 8) % len : len - 1 - (askSeed >> 8) % (len < 2 ? len : 2)];
        (,, AskSwarmRegistry.Status st) = registry.asks(rid);
        if (st != AskSwarmRegistry.Status.Pending) return;
        uint8 mode = uint8(modeSeed % 11);
        if (nearDeadline) {
            (uint64 askedAt) = _askedAt(rid);
            uint256 target = uint256(askedAt) + 3 days - 120;
            if (_now() < target) vm.warp(target);
        }
        if (mode >= 8) {
            vm.prank(writer);
            if (mode == 10) {
                assertFalse(intake.complete(rid, 1, ""));
                registry.markLost(rid);
            } else {
                uint8 status = mode == 8 ? 1 : 2;
                assertTrue(
                    intake.complete(rid, status, abi.encode(rid, status, bytes32("x"), uint16(0), uint16(0), bytes("")))
                );
            }
            gDelivery[rid] = Delivery(true, mode, 0);
            return;
        }
        OracleAttestation memory a = _attestation(rid, mode);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mode == 6 ? WRONG_KEY : SIGNING_KEY, registry.digest(a));
        vm.prank(writer);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v))), "callback fits 200k");
        (,, st) = registry.asks(rid);
        assertEq(
            uint8(st),
            uint8(mode == 6 ? AskSwarmRegistry.Status.Unverified : AskSwarmRegistry.Status.Answered),
            "registry status"
        );
        gDelivery[rid] = Delivery(true, mode, a.issuedAt);
    }

    function _askedAt(bytes32 rid) internal view returns (uint64 askedAt) {
        (, askedAt,) = registry.asks(rid);
    }

    function _attestation(bytes32 rid, uint8 mode) internal view returns (OracleAttestation memory a) {
        uint64 t = _now();
        a = OracleAttestation({
            requestId: keccak256(abi.encode("oracle uuid", rid)),
            chainId: 4663,
            questionHash: keccak256(abi.encode("question", rid)),
            answerType: mode == 5 ? 2 : 0,
            answer: abi.encode(mode == 4 ? uint256(2) : (mode == 1 ? 0 : 1)),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(0),
            panelJobId: keccak256(abi.encode("job", rid)),
            panelSize: mode == 2 ? 5 : (mode == 7 ? 10 : 9),
            quorum: mode == 2 ? 3 : 5,
            agreed: mode == 2 ? 4 : (mode == 7 ? 5 : 7),
            issuedAt: mode == 3 ? t + 299 : t,
            expiresAt: t + 10 days
        });
    }

    /// One market carried from opening to claims in a single step, so every sequence also holds
    /// decided markets beside the ones the granular actions leave half-way. The answer mode,
    /// stakes and whether to settle and claim are random; every step runs the checks above.
    function marketLifecycle(uint256 seed, uint256 mode, bool late, bool finish) external {
        this.openMarket(seed, 1 + seed % 7 hours, seed % 3 hours, seed >> 3);
        for (uint256 i; i < 2 + seed % 3; ++i) {
            this.stake(seed >> (8 + i), 1, i % 2 == 0, uint256(keccak256(abi.encode(seed, i))));
        }
        this.resolveMarket(1, true, seed >> 16);
        this.deliver(1, mode, late);
        if (!finish) return;
        this.settleMarket(1);
        uint256 id = market.count();
        for (uint256 i; i < 4; ++i) {
            this.claim(i, (id - 1) << 8);
        }
    }

    function wagerLifecycle(uint256 seed, uint256 mode, bool late, bool finish) external {
        this.createWager(seed, seed % 2 == 0, seed >> 4, 1 + seed % 5 hours, seed % 2 hours, seed >> 2);
        this.joinWager(seed >> 8, 1);
        this.resolveWager(1, true);
        this.deliver(1, mode, late);
        if (finish) this.settleWager(1);
    }

    function changePrice(uint256 seed) external {
        intake.setPrice(bound(seed, 0.1 ether, 1 ether));
    }

    function warp(uint256 seed, uint8 kind) external {
        vm.warp(_now() + (kind < 32 ? bound(seed, 1 hours, 4 days) : bound(seed, 1, 1 hours)));
    }

    // ================= what each contract must hold =================

    function marketOwed() public view returns (uint256 total) {
        uint256 c = market.count();
        for (uint256 id = 1; id <= c; ++id) {
            total += gMarketEscrow[id] + gYes[id] + gNo[id] - gFeeTaken[id] - gClaimedOut[id];
        }
    }

    function wagerOwed() public view returns (uint256 total) {
        uint256 c = wager.count();
        for (uint256 id = 1; id <= c; ++id) {
            if (gWagerTerminal[id] != 0) continue;
            total += gWagerFee[id] + gWagerStake[id] * (gWagerMatched[id] ? 2 : 1);
        }
    }
}

contract RobinhoodSystemInvariantTest is Test {
    uint256 internal constant SIGNING_KEY = 0x4663A11CE;
    SystemHandler public h;
    PaymentToken internal token;
    RecordingIntake internal intake;
    AskSwarmRegistry internal registry;
    SwarmMarket internal market;
    SwarmWager internal wager;
    address internal treasury;
    address internal recipient;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_792_300_000);
        vm.roll(26_300_000);
        treasury = makeAddr("askswarm treasury");
        recipient = makeAddr("intake recipient");
        address writer = makeAddr("intake writer");
        token = new PaymentToken();
        intake = new RecordingIntake(address(token), recipient, writer);
        SystemLaunchProbe probe = new SystemLaunchProbe();
        (registry, market, wager) = probe.deployAll(address(intake), address(token), vm.addr(SIGNING_KEY), treasury);
        assertEq(address(market.REGISTRY()), address(registry));
        assertEq(address(wager.REGISTRY()), address(registry));
        h = new SystemHandler(token, intake, registry, market, wager, writer, treasury, recipient);
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](21);
        s[0] = SystemHandler.openMarket.selector;
        s[1] = SystemHandler.stake.selector;
        s[2] = SystemHandler.topUpMarket.selector;
        s[3] = SystemHandler.resolveMarket.selector;
        s[4] = SystemHandler.abandonMarket.selector;
        s[5] = SystemHandler.settleMarket.selector;
        s[6] = SystemHandler.claim.selector;
        s[7] = SystemHandler.createWager.selector;
        s[8] = SystemHandler.joinWager.selector;
        s[9] = SystemHandler.cancelWager.selector;
        s[10] = SystemHandler.topUpWager.selector;
        s[11] = SystemHandler.resolveWager.selector;
        s[12] = SystemHandler.abandonWager.selector;
        s[13] = SystemHandler.settleWager.selector;
        s[14] = SystemHandler.deliver.selector;
        s[15] = SystemHandler.changePrice.selector;
        s[16] = SystemHandler.warp.selector;
        s[17] = SystemHandler.stake.selector; // staking twice as often fills both sides
        s[18] = SystemHandler.marketLifecycle.selector;
        s[19] = SystemHandler.wagerLifecycle.selector;
        s[20] = SystemHandler.settleMarket.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    /// The market holds exactly every open stake and unspent escrow, less fees and claims paid
    /// out: nothing leaks and nothing is created. Rounding dust stays inside, so equality holds.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_marketHoldsExactlyWhatIsOwed() public view {
        assertEq(token.balanceOf(address(market)), h.marketOwed());
    }

    /// No decided or voided market owes its stakers more than it still holds for them.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_marketClaimsAreSolventPerMarket() public view {
        uint256 c = market.count();
        for (uint256 id = 1; id <= c; ++id) {
            uint8 t = h.gMarketTerminal(id);
            if (t == 0) continue;
            uint256 owed;
            for (uint256 i; i < 4; ++i) {
                address a = h.actor(i);
                assertEq(market.claimable(id, a), h._expectedClaim(id, a), "claimable follows the rule");
                owed += market.claimable(id, a);
            }
            uint256 held = h.gYes(id) + h.gNo(id) - h.gFeeTaken(id) - h.gClaimedOut(id);
            assertLe(owed, held, "claims exceed what the market holds for this market");
            assertLe(held - owed, 4, "dust is at most one wei per staker");
            (SwarmMarket.Market memory m,) = market.get(id);
            assertEq(uint8(m.phase), t, "a finished market never reopens");
        }
    }

    /// The wager holds exactly the open stakes and fee escrow of unfinished wagers.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_wagerHoldsExactlyWhatIsOwed() public view {
        assertEq(token.balanceOf(address(wager)), h.wagerOwed());
        uint256 c = wager.count();
        for (uint256 id = 1; id <= c; ++id) {
            uint8 t = h.gWagerTerminal(id);
            if (t == 0) continue;
            (SwarmWager.Wager memory w,) = wager.get(id);
            assertEq(uint8(w.state), t, "a finished wager never reopens");
            // `cancel`, `abandon` and `resolve` all zero the fee escrow once it is paid out.
            assertEq(w.fee, 0, "a finished wager keeps no fee escrow");
        }
    }

    /// The registry never keeps IMD or an allowance; every ask the two consumers made was paid to
    /// Intake once, and the token supply is conserved across everyone.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_registryPassesThroughAndSupplyIsConserved() public view {
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(token.allowance(address(market), address(registry)), 0, "market leaves no allowance");
        assertEq(token.allowance(address(wager), address(registry)), 0, "wager leaves no allowance");
        assertEq(token.balanceOf(recipient), h.gIntakePaid());
        assertEq(intake.nonce(), h.askedCount(), "one ask per resolve");
        assertEq(registry.asked(), h.askedCount());
        uint256 sum = token.balanceOf(address(market)) + token.balanceOf(address(wager)) + token.balanceOf(recipient)
            + token.balanceOf(treasury);
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(h.actor(i));
        }
        assertEq(sum, token.totalSupply());
    }

    // ---- the handler reaches every outcome (the invariants above are not vacuous) ----

    function test_handlerReachesEveryOutcome() public {
        // Market decided Yes, with fees.
        h.openMarket(0, 1 hours, 0, 0);
        h.stake(1, 1, true, 30 ether);
        h.stake(2, 1, false, 70 ether);
        h.stake(3, 1, true, 11 ether);
        h.resolveMarket(1, true, 0);
        h.deliver(1, 0, false);
        h.settleMarket(1);
        // Market decided No.
        h.openMarket(1, 1 hours, 0, 1);
        h.stake(1, 1, true, 5 ether);
        h.stake(2, 1, false, 7 ether);
        h.resolveMarket(1, true, 10);
        h.deliver(1, 1, false);
        h.settleMarket(1);
        // Market voided by a panel below MIN_PANEL, then by a late answer.
        h.openMarket(2, 1 hours, 0, 0);
        h.stake(1, 1, true, 5 ether);
        h.stake(2, 1, false, 7 ether);
        h.resolveMarket(1, true, 0);
        h.deliver(1, 2, false);
        h.settleMarket(1);
        h.openMarket(3, 1 hours, 0, 0);
        h.stake(1, 1, true, 5 ether);
        h.stake(2, 1, false, 7 ether);
        h.resolveMarket(1, true, 0);
        h.deliver(1, 3, true);
        h.settleMarket(1);
        // Wager paid (a panel of 5 is enough for a wager), and one refunded on a refusal.
        h.createWager(0, true, 10 ether, 1 hours, 0, 0);
        h.joinWager(1, 1);
        h.resolveWager(1, true);
        h.deliver(1, 2, false);
        h.settleWager(1);
        h.createWager(1, false, 3 ether, 1 hours, 0, 1);
        h.joinWager(2, 1);
        h.resolveWager(1, true);
        h.deliver(1, 8, false);
        h.settleWager(1);
        for (uint256 i; i < 4; ++i) {
            for (uint256 id; id < 4; ++id) {
                h.claim(i, id << 8); // seed % 8 == 0 picks id + 1 exactly
            }
        }
        assertEq(h.marketsYes(), 1);
        assertEq(h.marketsNo(), 1);
        assertEq(h.smallPanelVoids(), 1);
        assertEq(h.lateVoids(), 1);
        assertEq(h.wagersPaid(), 1);
        assertEq(h.wagersRefundedAfterAsk(), 1);
        assertGt(h.claims(), 6);
        invariant_marketHoldsExactlyWhatIsOwed();
        invariant_marketClaimsAreSolventPerMarket();
        invariant_wagerHoldsExactlyWhatIsOwed();
        invariant_registryPassesThroughAndSupplyIsConserved();
    }
}
