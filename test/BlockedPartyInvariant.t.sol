// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {SwarmWager} from "src/SwarmWager.sol";
import {RecordingIntake} from "./helpers/RegistryTestSupport.sol";
import {BlockableIMD} from "./mocks/BlockableIMD.sol";

/// @notice Drives the Robinhood Chain system on a token that, like Robinhood Chain's IMD, can block
/// any address, while the four actors and the treasury are blocked and unblocked at random. Every
/// push the contracts make is predicted here from the brief: a push to a third party (creator
/// remainder, fees, refunds) lands if the receiver is free and is credited to `owed` if blocked;
/// a push to the caller's own claim reverts while that caller is blocked. `owed` is then compared
/// with the prediction, and each contract's balance with everything it still owes.
contract BlockedPartyHandler is Test {
    uint256 internal constant SIGNING_KEY = 0x4663B10C;
    uint256 internal constant FUNDS = 1e27;
    bytes internal constant BODY = '{"v":1,"question":"blocked party","answerType":"bool","panelSize":9,"quorum":5}';

    BlockableIMD public immutable imd;
    RecordingIntake public immutable intake;
    AskSwarmRegistry public immutable registry;
    SwarmMarket public immutable market;
    SwarmWager public immutable wager;
    address public immutable writer;
    address public immutable treasury;
    address[5] internal parties; // four actors, then the treasury

    uint256 public minted;
    uint256 public price;

    // markets
    mapping(uint256 => uint256) public mEscrow;
    mapping(uint256 => uint256) public mPools;
    mapping(uint256 => uint256) public mYes;
    mapping(uint256 => uint256) public mNo;
    mapping(uint256 => mapping(address => uint256)) public mYesOf;
    mapping(uint256 => mapping(address => uint256)) public mNoOf;
    mapping(uint256 => uint256) public mFee;
    mapping(uint256 => uint256) public mOut;
    mapping(uint256 => uint8) public mTerminal;
    // wagers
    mapping(uint256 => uint256) public wHeld;
    mapping(uint256 => uint8) public wTerminal;
    // what each party should be owed by each contract
    mapping(address => uint256) public gMarketOwed;
    mapping(address => uint256) public gWagerOwed;
    // deliveries: 0 none, 1 yes, 2 no, 3 refused
    mapping(bytes32 => uint8) public gAnswer;
    mapping(bytes32 => uint64) public gIssuedAt;
    bytes32[] public asked;

    // reachability
    uint256 public credits;
    uint256 public withdrawals;
    uint256 public blockedWithdrawals;
    uint256 public blockedClaims;
    uint256 public blockedWinnerSettles;
    uint256 public settlesPastBlockedParty;

    constructor(
        BlockableIMD imd_,
        RecordingIntake intake_,
        AskSwarmRegistry registry_,
        SwarmMarket market_,
        SwarmWager wager_,
        address writer_,
        address treasury_
    ) {
        imd = imd_;
        intake = intake_;
        registry = registry_;
        market = market_;
        wager = wager_;
        writer = writer_;
        treasury = treasury_;
        price = intake_.currentPrice();
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("blockable actor ", vm.toString(i)));
            parties[i] = a;
            imd.mint(a, FUNDS);
            minted += FUNDS;
            vm.startPrank(a);
            imd.approve(address(market_), type(uint256).max);
            imd.approve(address(wager_), type(uint256).max);
            vm.stopPrank();
        }
        parties[4] = treasury_;
    }

    function party(uint256 i) external view returns (address) {
        return parties[i];
    }

    function askedCount() external view returns (uint256) {
        return asked.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return parties[seed % 4];
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _pick(uint256 seed, uint256 c) internal pure returns (uint256) {
        if (c == 0) return 0;
        return seed % 4 == 0 ? 1 + (seed >> 8) % c : c - (seed >> 8) % (c < 3 ? c : 3);
    }

    /// The prediction for a third-party push: delivered when free, credited to `owed` when blocked.
    function _expectPush(bool isMarket, address to, uint256 amount, uint256 balBefore) internal {
        if (amount == 0) return;
        if (imd.blocked(to)) {
            if (isMarket) gMarketOwed[to] += amount;
            else gWagerOwed[to] += amount;
            assertEq(imd.balanceOf(to), balBefore, "a blocked party receives nothing");
            credits++;
        }
    }

    // ================= blocking =================

    function toggleBlock(uint256 seed) external {
        address a = parties[seed % 5];
        imd.setBlocked(a, !imd.blocked(a));
    }

    function warp(uint256 seed) external {
        vm.warp(_now() + bound(seed, 1, 2 days));
    }

    // ================= market =================

    function openMarket(uint256 actorSeed, uint256 closeDelay, uint256 topUp) external {
        address a = _actor(actorSeed);
        uint64 closeAt = _now() + uint64(bound(closeDelay, 1, 6 hours));
        vm.startPrank(a);
        if (imd.blocked(a)) {
            vm.expectRevert(SwarmMarket.TransferFailed.selector);
            market.open(BODY, closeAt, closeAt);
            vm.stopPrank();
            return;
        }
        uint256 id = market.open(BODY, closeAt, closeAt);
        uint96 extra = uint96(bound(topUp, 0, 0.3 ether));
        if (extra != 0) market.topUpFee(id, extra);
        vm.stopPrank();
        mEscrow[id] = price + extra;
    }

    function stake(uint256 actorSeed, uint256 idSeed, bool yes, uint256 amount) external {
        uint256 id = _pick(idSeed, market.count());
        if (id == 0) return;
        address a = _actor(actorSeed);
        uint128 amt = uint128(bound(amount, 1, 100 ether));
        (SwarmMarket.Market memory m,) = market.get(id);
        bool isBlocked = imd.blocked(a);
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
        if (isBlocked) {
            vm.expectRevert(SwarmMarket.TransferFailed.selector);
            market.stake(id, yes, amt);
            return;
        }
        market.stake(id, yes, amt);
        mPools[id] += amt;
        if (yes) {
            mYes[id] += amt;
            mYesOf[id][a] += amt;
        } else {
            mNo[id] += amt;
            mNoOf[id][a] += amt;
        }
    }

    function resolveMarket(uint256 idSeed, uint256 offset) external {
        uint256 id = _pick(idSeed, market.count());
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        if (m.phase != SwarmMarket.Phase.Open) return;
        if (_now() > uint256(m.resolveAfter) + market.RESOLVE_WINDOW()) {
            uint256 bal = imd.balanceOf(m.creator);
            market.abandon(id); // never waits on the creator, blocked or not
            _expectPush(true, m.creator, mEscrow[id], bal);
            mEscrow[id] = 0;
            mTerminal[id] = uint8(SwarmMarket.Phase.Void);
            return;
        }
        if (_now() < m.resolveAfter) vm.warp(uint256(m.resolveAfter) + bound(offset, 0, market.RESOLVE_WINDOW()));
        uint256 before = imd.balanceOf(m.creator);
        market.resolve(id);
        (m,) = market.get(id);
        if (mYes[id] == 0 || mNo[id] == 0) {
            assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));
            _expectPush(true, m.creator, mEscrow[id], before);
            mTerminal[id] = uint8(SwarmMarket.Phase.Void);
        } else {
            assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Asked));
            _expectPush(true, m.creator, mEscrow[id] - price, before);
            asked.push(m.requestId);
        }
        mEscrow[id] = 0;
    }

    function settleMarket(uint256 idSeed) external {
        uint256 id = _pick(idSeed, market.count());
        if (id == 0) return;
        (SwarmMarket.Market memory m,) = market.get(id);
        if (m.phase != SwarmMarket.Phase.Asked) return;
        uint256 deadline = uint256(m.askedAt) + market.ANSWER_WINDOW();
        uint8 ans = gAnswer[m.requestId];
        if (ans == 0 && _now() <= deadline) {
            vm.expectRevert(SwarmMarket.StillPending.selector);
            market.settle(id);
            return;
        }
        bool blockedParty = imd.blocked(m.creator) || imd.blocked(treasury);
        uint256 cBefore = imd.balanceOf(m.creator);
        uint256 tBefore = imd.balanceOf(treasury);
        market.settle(id);
        (m,) = market.get(id);
        if (ans == 0 || ans == 3 || gIssuedAt[m.requestId] > deadline) {
            assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void), "non-answer voids");
            mTerminal[id] = uint8(SwarmMarket.Phase.Void);
            return;
        }
        bool yes = ans == 1;
        assertEq(uint8(m.phase), uint8(yes ? SwarmMarket.Phase.Yes : SwarmMarket.Phase.No));
        uint256 fee = (yes ? mNo[id] : mYes[id]) * 2 / 100;
        _expectPush(true, m.creator, fee / 2, cBefore);
        _expectPush(true, treasury, fee - fee / 2, tBefore);
        if (!imd.blocked(m.creator)) assertEq(imd.balanceOf(m.creator) - cBefore, fee / 2);
        if (!imd.blocked(treasury)) assertEq(imd.balanceOf(treasury) - tBefore, fee - fee / 2);
        if (blockedParty && fee != 0) settlesPastBlockedParty++;
        mFee[id] = fee;
        mTerminal[id] = uint8(m.phase);
    }

    function claim(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _pick(idSeed, market.count());
        if (id == 0) return;
        address a = _actor(actorSeed);
        uint256 due = expectedClaim(id, a);
        assertEq(market.claimable(id, a), due, "claimable follows the parimutuel rule");
        bool isBlocked = imd.blocked(a);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        if (due == 0) {
            vm.expectRevert(SwarmMarket.NothingToClaim.selector);
            market.claim(id);
            return;
        }
        if (isBlocked) {
            // The claimant's own payout: it waits for the claimant, and the claim stays open.
            vm.expectRevert(SwarmMarket.TransferFailed.selector);
            market.claim(id);
            assertFalse(market.claimed(id, a));
            blockedClaims++;
            return;
        }
        market.claim(id);
        assertEq(imd.balanceOf(a) - before, due);
        mOut[id] += due;
    }

    function expectedClaim(uint256 id, address a) public view returns (uint256) {
        if (market.claimed(id, a)) return 0;
        uint8 t = mTerminal[id];
        if (t == uint8(SwarmMarket.Phase.Void)) return mYesOf[id][a] + mNoOf[id][a];
        if (t == uint8(SwarmMarket.Phase.Yes)) {
            uint256 y = mYesOf[id][a];
            return y == 0 ? 0 : y + y * (mNo[id] - mFee[id]) / mYes[id];
        }
        if (t == uint8(SwarmMarket.Phase.No)) {
            uint256 n = mNoOf[id][a];
            return n == 0 ? 0 : n + n * (mYes[id] - mFee[id]) / mNo[id];
        }
        return 0;
    }

    // ================= wager =================

    function createWager(uint256 actorSeed, bool saysYes, uint256 amount, uint256 joinDelay) external {
        address a = _actor(actorSeed);
        uint96 s = uint96(bound(amount, 1, 100 ether));
        uint64 joinBy = _now() + uint64(bound(joinDelay, 1, 6 hours));
        bool isBlocked = imd.blocked(a);
        vm.prank(a);
        if (isBlocked) {
            vm.expectRevert(SwarmWager.TransferFailed.selector);
            wager.create(BODY, saysYes, s, joinBy, joinBy);
            return;
        }
        uint256 id = wager.create(BODY, saysYes, s, joinBy, joinBy);
        wHeld[id] = uint256(s) + price;
    }

    function joinWager(uint256 actorSeed, uint256 idSeed, uint256 topUp) external {
        uint256 id = _pick(idSeed, wager.count());
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Open || _now() > w.joinBy) return;
        address a = _actor(actorSeed);
        if (a == w.creator) a = parties[(actorSeed % 4 + 1) % 4];
        vm.startPrank(a);
        if (imd.blocked(a)) {
            vm.expectRevert(SwarmWager.TransferFailed.selector);
            wager.join(id);
            vm.stopPrank();
            return;
        }
        wager.join(id);
        uint96 extra = uint96(bound(topUp, 0, 0.3 ether));
        if (extra != 0) wager.topUpFee(id, extra);
        vm.stopPrank();
        wHeld[id] += w.stake + extra;
    }

    function cancelWager(uint256 idSeed) external {
        uint256 id = _pick(idSeed, wager.count());
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Open) return;
        bool isBlocked = imd.blocked(w.creator);
        uint256 before = imd.balanceOf(w.creator);
        vm.prank(w.creator);
        if (isBlocked) {
            // Only the creator's own money is involved, so it waits for the creator.
            vm.expectRevert(SwarmWager.TransferFailed.selector);
            wager.cancel(id);
            return;
        }
        wager.cancel(id);
        assertEq(imd.balanceOf(w.creator) - before, wHeld[id]);
        wHeld[id] = 0;
        wTerminal[id] = uint8(SwarmWager.State.Refunded);
    }

    function resolveWager(uint256 idSeed) external {
        uint256 id = _pick(idSeed, wager.count());
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Matched) return;
        if (_now() > uint256(w.resolveAfter) + wager.ANSWER_WINDOW()) {
            uint256 yb = imd.balanceOf(w.yes);
            uint256 nb = imd.balanceOf(w.no);
            uint256 fee = wHeld[id] - 2 * uint256(w.stake);
            wager.abandon(id); // never waits on either party
            _expectPush(false, w.yes, w.stake + (w.creator == w.yes ? fee : 0), yb);
            _expectPush(false, w.no, w.stake + (w.creator == w.no ? fee : 0), nb);
            wHeld[id] = 0;
            wTerminal[id] = uint8(SwarmWager.State.Refunded);
            (w,) = wager.get(id);
            assertEq(w.fee, 0, "abandon zeroes the fee escrow");
            return;
        }
        if (_now() < w.resolveAfter) vm.warp(w.resolveAfter);
        uint256 before = imd.balanceOf(w.creator);
        uint256 remainder = wHeld[id] - 2 * uint256(w.stake) - price;
        wager.resolve(id);
        _expectPush(false, w.creator, remainder, before);
        wHeld[id] = 2 * uint256(w.stake);
        (w,) = wager.get(id);
        asked.push(w.requestId);
    }

    function settleWager(uint256 idSeed) external {
        uint256 id = _pick(idSeed, wager.count());
        if (id == 0) return;
        (SwarmWager.Wager memory w,) = wager.get(id);
        if (w.state != SwarmWager.State.Asked) return;
        uint8 ans = gAnswer[w.requestId];
        if (ans == 0 && _now() <= uint256(w.askedAt) + wager.ANSWER_WINDOW()) {
            vm.expectRevert(SwarmWager.StillPending.selector);
            wager.settle(id);
            return;
        }
        uint256 yb = imd.balanceOf(w.yes);
        uint256 nb = imd.balanceOf(w.no);
        if (ans == 1 || ans == 2) {
            address winner = ans == 1 ? w.yes : w.no;
            if (imd.blocked(winner)) {
                // The pot is the winner's alone; nobody else's money waits on it.
                vm.expectRevert(SwarmWager.TransferFailed.selector);
                wager.settle(id);
                blockedWinnerSettles++;
                return;
            }
            wager.settle(id);
            assertEq(imd.balanceOf(winner) - (ans == 1 ? yb : nb), 2 * uint256(w.stake), "pot to the winner");
            wTerminal[id] = uint8(SwarmWager.State.Paid);
        } else {
            bool blockedParty = imd.blocked(w.yes) || imd.blocked(w.no);
            wager.settle(id);
            _expectPush(false, w.yes, w.stake, yb);
            _expectPush(false, w.no, w.stake, nb);
            if (blockedParty) settlesPastBlockedParty++;
            wTerminal[id] = uint8(SwarmWager.State.Refunded);
        }
        wHeld[id] = 0;
    }

    // ================= withdrawals =================

    function withdraw(uint256 seed, bool fromMarket) external {
        address a = parties[seed % 5];
        uint256 due = fromMarket ? market.owed(a) : wager.owed(a);
        assertEq(due, fromMarket ? gMarketOwed[a] : gWagerOwed[a], "owed matches the prediction");
        bool isBlocked = imd.blocked(a);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        if (due == 0) {
            if (fromMarket) {
                vm.expectRevert(SwarmMarket.NothingToClaim.selector);
                market.withdraw();
            } else {
                vm.expectRevert(SwarmWager.NothingOwed.selector);
                wager.withdraw();
            }
            return;
        }
        if (isBlocked) {
            vm.expectRevert(fromMarket ? SwarmMarket.TransferFailed.selector : SwarmWager.TransferFailed.selector);
            if (fromMarket) market.withdraw();
            else wager.withdraw();
            blockedWithdrawals++;
            return;
        }
        uint256 got = fromMarket ? market.withdraw() : wager.withdraw();
        assertEq(got, due);
        assertEq(imd.balanceOf(a) - before, due, "withdraw pays exactly what was owed");
        if (fromMarket) gMarketOwed[a] = 0;
        else gWagerOwed[a] = 0;
        withdrawals++;
    }

    // ================= the oracle =================

    /// Mode 0 yes, 1 no (verified, 7 of 9), 2 refused by the panel (failure status 1).
    function deliver(uint256 askSeed, uint256 modeSeed) external {
        uint256 len = asked.length;
        if (len == 0) return;
        bytes32 rid = asked[askSeed % 3 == 0 ? (askSeed >> 8) % len : len - 1];
        if (gAnswer[rid] != 0) return;
        uint8 mode = uint8(modeSeed % 3);
        if (mode == 2) {
            vm.prank(writer);
            assertTrue(
                intake.complete(
                    rid, 1, abi.encode(rid, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
                )
            );
            gAnswer[rid] = 3;
            return;
        }
        uint64 t = _now();
        OracleAttestation memory a = OracleAttestation({
            requestId: keccak256(abi.encode("uuid", rid)),
            chainId: 4663,
            questionHash: keccak256("blocked party"),
            answerType: 0,
            answer: abi.encode(mode == 0),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(0),
            panelJobId: keccak256(abi.encode("job", rid)),
            panelSize: 9,
            quorum: 5,
            agreed: 7,
            issuedAt: t,
            expiresAt: t + 30 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, registry.digest(a));
        vm.prank(writer);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v))), "callback delivered");
        (,, AskSwarmRegistry.Status st) = registry.asks(rid);
        assertEq(uint8(st), uint8(AskSwarmRegistry.Status.Answered));
        gAnswer[rid] = mode == 0 ? 1 : 2;
        gIssuedAt[rid] = t;
    }

    // ================= liabilities =================

    function marketOwesOnOpenBooks() public view returns (uint256 total) {
        uint256 c = market.count();
        for (uint256 id = 1; id <= c; ++id) {
            total += mEscrow[id] + mPools[id] - mFee[id] - mOut[id];
        }
    }

    function wagerOwesOnOpenBooks() public view returns (uint256 total) {
        uint256 c = wager.count();
        for (uint256 id = 1; id <= c; ++id) {
            total += wHeld[id];
        }
    }

    function sumMarketOwed() public view returns (uint256 total) {
        for (uint256 i; i < 5; ++i) {
            total += gMarketOwed[parties[i]];
        }
    }

    function sumWagerOwed() public view returns (uint256 total) {
        for (uint256 i; i < 5; ++i) {
            total += gWagerOwed[parties[i]];
        }
    }
}

contract BlockedPartyInvariantTest is Test {
    uint256 internal constant SIGNING_KEY = 0x4663B10C;
    BlockedPartyHandler public h;
    BlockableIMD internal imd;
    RecordingIntake internal intake;
    AskSwarmRegistry internal registry;
    SwarmMarket internal market;
    SwarmWager internal wager;
    address internal treasury;
    address internal recipient;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_792_300_000);
        treasury = makeAddr("blockable treasury");
        recipient = makeAddr("blockable intake recipient");
        address writer = makeAddr("blockable intake writer");
        imd = new BlockableIMD();
        intake = new RecordingIntake(address(imd), recipient, writer);
        registry = new AskSwarmRegistry(address(intake), address(imd), vm.addr(SIGNING_KEY));
        market = new SwarmMarket(address(registry), address(imd), treasury);
        wager = new SwarmWager(address(registry), address(imd));
        h = new BlockedPartyHandler(imd, intake, registry, market, wager, writer, treasury);
        // The handler is the token's owner, so it can block and unblock parties.
        vm.store(address(imd), bytes32(uint256(3)), bytes32(uint256(uint160(address(h)))));
        assertEq(imd.owner(), address(h));
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](16);
        s[0] = BlockedPartyHandler.toggleBlock.selector;
        s[1] = BlockedPartyHandler.toggleBlock.selector;
        s[2] = BlockedPartyHandler.warp.selector;
        s[3] = BlockedPartyHandler.openMarket.selector;
        s[4] = BlockedPartyHandler.stake.selector;
        s[5] = BlockedPartyHandler.stake.selector;
        s[6] = BlockedPartyHandler.resolveMarket.selector;
        s[7] = BlockedPartyHandler.settleMarket.selector;
        s[8] = BlockedPartyHandler.claim.selector;
        s[9] = BlockedPartyHandler.createWager.selector;
        s[10] = BlockedPartyHandler.joinWager.selector;
        s[11] = BlockedPartyHandler.cancelWager.selector;
        s[12] = BlockedPartyHandler.resolveWager.selector;
        s[13] = BlockedPartyHandler.settleWager.selector;
        s[14] = BlockedPartyHandler.withdraw.selector;
        s[15] = BlockedPartyHandler.deliver.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    /// The market holds exactly its open books plus every credit it owes a blocked party, and each
    /// party's `owed` is exactly what the pushes that party missed add up to.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_marketBalanceIsBooksPlusOwed() public view {
        uint256 owedSum;
        for (uint256 i; i < 5; ++i) {
            address a = h.party(i);
            assertEq(market.owed(a), h.gMarketOwed(a), "market owed per party");
            owedSum += market.owed(a);
        }
        assertEq(imd.balanceOf(address(market)), h.marketOwesOnOpenBooks() + owedSum);
        uint256 c = market.count();
        for (uint256 id = 1; id <= c; ++id) {
            uint8 t = h.mTerminal(id);
            if (t == 0) continue;
            (SwarmMarket.Market memory m,) = market.get(id);
            assertEq(uint8(m.phase), t, "a finished market never reopens");
            assertEq(m.feeEscrow, 0);
        }
    }

    /// The wager holds exactly the open wagers' stakes and fees plus every credit it owes.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_wagerBalanceIsBooksPlusOwed() public view {
        uint256 owedSum;
        for (uint256 i; i < 5; ++i) {
            address a = h.party(i);
            assertEq(wager.owed(a), h.gWagerOwed(a), "wager owed per party");
            owedSum += wager.owed(a);
        }
        assertEq(imd.balanceOf(address(wager)), h.wagerOwesOnOpenBooks() + owedSum);
        uint256 c = wager.count();
        for (uint256 id = 1; id <= c; ++id) {
            uint8 t = h.wTerminal(id);
            if (t == 0) continue;
            (SwarmWager.Wager memory w,) = wager.get(id);
            assertEq(uint8(w.state), t, "a finished wager never reopens");
            assertEq(w.fee, 0, "a finished wager keeps no fee escrow");
        }
    }

    /// Blocking moves no money: everything minted is with a party, a contract or Intake's recipient,
    /// and the registry keeps neither IMD nor an allowance.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyConservedAndRegistryEmpty() public view {
        uint256 sum = imd.balanceOf(address(market)) + imd.balanceOf(address(wager)) + imd.balanceOf(recipient)
            + imd.balanceOf(address(registry));
        for (uint256 i; i < 5; ++i) {
            sum += imd.balanceOf(h.party(i));
        }
        assertEq(sum, h.minted());
        assertEq(imd.balanceOf(address(registry)), 0);
        assertEq(imd.allowance(address(registry), address(intake)), 0);
        assertEq(imd.balanceOf(recipient), h.askedCount() * h.price(), "every ask paid once");
    }

    // ---- the handler reaches the blocked paths (the invariants above are not vacuous) ----

    function test_handlerReachesCreditsAndWithdrawals() public {
        // Market decided Yes while the creator and the treasury are blocked: both fee halves credited.
        h.openMarket(0, 1 hours, 0.2 ether);
        h.stake(1, 1, true, 30 ether);
        h.stake(2, 1, false, 70 ether);
        h.toggleBlock(0); // creator
        h.toggleBlock(4); // treasury
        h.resolveMarket(1, 0); // remainder 0.2 credited to the blocked creator
        h.deliver(1, 0);
        h.settleMarket(1);
        h.claim(1, 1); // yes winner is free
        h.claim(2, 1); // no side gets nothing
        h.withdraw(0, true); // creator still blocked: reverts, stays owed
        h.withdraw(4, true);
        h.toggleBlock(0);
        h.toggleBlock(4);
        h.withdraw(0, true);
        h.withdraw(4, true);
        // Wager refused by the panel while the joiner is blocked: the creator's refund still lands.
        h.createWager(1, true, 10 ether, 1 hours);
        h.joinWager(2, 1, 0.1 ether);
        h.toggleBlock(2);
        h.resolveWager(1);
        h.deliver(1, 2);
        h.settleWager(1);
        // A paid wager whose winner is blocked waits for the winner only.
        h.createWager(3, true, 4 ether, 1 hours);
        h.joinWager(1, 1, 0);
        h.resolveWager(1);
        h.deliver(1, 0);
        h.toggleBlock(3);
        h.settleWager(1);
        h.toggleBlock(3);
        h.settleWager(1);
        h.toggleBlock(2);
        h.withdraw(2, false);
        assertGe(h.credits(), 4);
        assertEq(h.withdrawals(), 3);
        assertEq(h.blockedWithdrawals(), 2);
        assertEq(h.blockedWinnerSettles(), 1);
        assertEq(h.settlesPastBlockedParty(), 2);
        assertEq(market.owed(h.party(0)), 0);
        invariant_marketBalanceIsBooksPlusOwed();
        invariant_wagerBalanceIsBooksPlusOwed();
        invariant_supplyConservedAndRegistryEmpty();
    }
}
