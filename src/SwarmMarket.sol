// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAskSwarmRegistry} from "./SwarmWager.sol";

/// @title SwarmMarket: yes/no prediction markets settled by the IMD swarm
/// @notice Anyone opens a market on a yes/no oracle question (the JSON body AskSwarmRegistry takes),
/// escrowing the swarm's fee. Anyone stakes IMD on Yes or No until `closeAt`. After `resolveAfter`
/// anyone calls `resolve` within RESOLVE_WINDOW, which buys the question through AskSwarmRegistry,
/// then `settle`, which reads the registry's record: a verified bool answer issued within
/// ANSWER_WINDOW and agreed by a strict majority of a panel of at least MIN_PANEL decides the
/// market. Winners `claim` their stake plus a pro-rata share of the losing pool, less a 2% fee on the
/// losing pool split between the market's creator and the protocol treasury. Any other outcome
/// (refused, split panel, unverified, lost, wrong type, no answer within ANSWER_WINDOW, or a side
/// nobody took) makes the market void: everyone claims their full stake back and no fee is taken.
///
/// Revenue: the fee is only taken from losers' stakes and only when the swarm settles the market.
/// Creators earn half of it for writing good questions; the treasury half funds AskSwarm's free asks.
///
/// Invariants:
/// - Paid out per market never exceeds staked: winners' claims plus fees sum to at most the pool.
/// - Each address claims at most once per market. Claims are pulled; there are no loops.
/// - A market can always be unwound: void if one side is empty, void if the swarm never answers,
///   `abandon` if it can never be resolved. `resolveAfter` is at most MAX_TERM from opening, so
///   that moment always comes.
/// - The fee escrow pays the swarm at most once, through `resolve`; unspent fee returns to the creator.
/// - No call that makes stakes claimable depends on a third party's transfer: the creator's escrow
///   and fee and the treasury's fee are pushed if the token accepts them, else credited to `owed`
///   for that address to `withdraw` (Robinhood Chain's IMD can block an address).
/// - Rounding of winners' shares is down; the remainder (under one wei per winner) stays in the contract.
/// - No owner, no admin, no upgrade path, no ETH. Constructor makes no external call.
contract SwarmMarket {
    enum Phase {
        None,
        Open, // taking stakes until closeAt
        Asked, // question bought, waiting for the swarm
        Yes, // settled: Yes won
        No, // settled: No won
        Void // refunds for everyone, no fee
    }

    struct Market {
        address creator;
        uint64 closeAt;
        uint64 resolveAfter;
        uint64 askedAt;
        Phase phase;
        uint96 feeEscrow; // swarm price escrowed at create; zeroed once spent or returned
        uint128 yesPool;
        uint128 noPool;
        uint128 winnersShare; // losing pool minus protocol fee, set at settle
        bytes32 requestId;
    }

    /// @notice Time allowed to buy the question after resolveAfter. The last second is inclusive.
    uint64 public constant RESOLVE_WINDOW = 1 hours;
    /// @notice Time allowed for the swarm's answer after asking, inclusive. A market still pending
    /// after it, or answered with a later issuedAt, voids.
    uint64 public constant ANSWER_WINDOW = 3 days;
    /// @notice Latest permitted `resolveAfter`, measured from the opening block's timestamp,
    /// inclusive. Also bounds `closeAt`, since `closeAt <= resolveAfter`. Without it a creator could
    /// open a market whose `resolveAfter` no chain ever reaches, so neither `resolve` nor `abandon`
    /// would ever be allowed and every stake would be held forever (audit finding f8ec801b0e44).
    /// Same bound as SwarmWager.MAX_TERM: at the maximum, `abandon` opens strictly after
    /// MAX_TERM + RESOLVE_WINDOW.
    uint64 public constant MAX_TERM = 365 days;
    /// @notice Smallest panel allowed to decide a market; strict majority is also required.
    uint16 public constant MIN_PANEL = 7;
    /// @notice Fee on the losing pool, in basis points, taken only when the swarm settles the market.
    uint256 public constant FEE_BPS = 200;
    /// @notice Largest body Intake accepts; a longer one could never be asked.
    uint256 public constant MAX_BODY_BYTES = 16_384;
    uint8 internal constant BOOL = 0;

    IAskSwarmRegistry public immutable REGISTRY;
    address public immutable IMD;
    address public immutable TREASURY;

    uint256 public count;
    mapping(uint256 id => Market) public markets;
    mapping(uint256 id => bytes body) public bodyOf;
    mapping(uint256 id => mapping(address user => uint128)) public yesStake;
    mapping(uint256 id => mapping(address user => uint128)) public noStake;
    mapping(uint256 id => mapping(address user => bool)) public claimed;
    /// @notice IMD credited to an address whose push the token refused (e.g. a blocked address).
    mapping(address user => uint256) public owed;

    event Opened(uint256 indexed id, address indexed creator, uint64 closeAt, uint64 resolveAfter, bytes body);
    event Staked(uint256 indexed id, address indexed user, bool yes, uint256 amount);
    event FeeToppedUp(uint256 indexed id, address indexed funder, uint256 amount);
    event Resolving(uint256 indexed id, bytes32 indexed requestId);
    event Settled(uint256 indexed id, Phase phase, uint256 yesPool, uint256 noPool, uint256 fee, uint8 reason);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event Owed(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    error ZeroAddress();
    error BadTerms();
    error WrongPhase(Phase have);
    error Closed();
    error TooEarly();
    error TooLate();
    error StillPending();
    error NothingToClaim();
    error TransferFailed();

    constructor(address registry, address imd, address treasury) {
        if (registry == address(0) || imd == address(0) || treasury == address(0)) revert ZeroAddress();
        REGISTRY = IAskSwarmRegistry(registry);
        IMD = imd;
        TREASURY = treasury;
    }

    // ---- lifecycle ----

    /// @notice Open a market. Pulls the registry's current price from the caller as the fee escrow.
    /// Terms: `closeAt` in the future, `resolveAfter` at or after `closeAt` and at most MAX_TERM
    /// from now, so the market can always be resolved or abandoned within a bounded horizon.
    function open(bytes calldata body, uint64 closeAt, uint64 resolveAfter) external returns (uint256 id) {
        if (
            body.length == 0 || body.length > MAX_BODY_BYTES || closeAt <= block.timestamp || resolveAfter < closeAt
                || uint256(resolveAfter) > block.timestamp + MAX_TERM
        ) {
            revert BadTerms();
        }
        uint256 p = REGISTRY.price();
        if (p == 0 || p > type(uint96).max) revert BadTerms();
        id = ++count;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.closeAt = closeAt;
        m.resolveAfter = resolveAfter;
        m.phase = Phase.Open;
        m.feeEscrow = uint96(p);
        bodyOf[id] = body;
        _pull(msg.sender, p);
        emit Opened(id, msg.sender, closeAt, resolveAfter, body);
    }

    /// @notice Stake on Yes or No until `closeAt`. May be called repeatedly, on either side.
    function stake(uint256 id, bool yes, uint128 amount) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp >= m.closeAt) revert Closed();
        if (amount == 0) revert BadTerms();
        if (yes) {
            m.yesPool += amount;
            yesStake[id][msg.sender] += amount;
        } else {
            m.noPool += amount;
            noStake[id][msg.sender] += amount;
        }
        _pull(msg.sender, amount);
        emit Staked(id, msg.sender, yes, amount);
    }

    /// @notice Donate to an open market's oracle escrow if the price rises. Unspent contributions,
    /// like the original escrow, return to the creator, not the donor. No stake or payout is added.
    function topUpFee(uint256 id, uint96 amount) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp > uint256(m.resolveAfter) + RESOLVE_WINDOW) revert TooLate();
        if (amount == 0) revert BadTerms();
        m.feeEscrow += amount;
        _pull(msg.sender, amount);
        emit FeeToppedUp(id, msg.sender, amount);
    }

    /// @notice From `resolveAfter` through `resolveAfter + RESOLVE_WINDOW`, buy the question.
    /// If a side is empty there is nothing to decide: void without spending the fee. For moving
    /// facts, creators must use absolute evidence windows ending before resolveAfter: the caller
    /// still chooses the ask time within this window, and the oracle processes it asynchronously.
    function resolve(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp < m.resolveAfter) revert TooEarly();
        if (block.timestamp > uint256(m.resolveAfter) + RESOLVE_WINDOW) revert TooLate();
        if (m.yesPool == 0 || m.noPool == 0) return _void(m, id, 1);
        uint256 p = REGISTRY.price();
        if (p == 0 || p > m.feeEscrow) revert BadTerms(); // top up a shortfall, or abandon after the window
        uint256 remainder = m.feeEscrow - p;
        m.phase = Phase.Asked;
        m.askedAt = uint64(block.timestamp);
        m.feeEscrow = 0;
        _approve(address(REGISTRY), p);
        m.requestId = REGISTRY.askAtMost(bodyOf[id], p);
        _pushOrCredit(m.creator, remainder);
        emit Resolving(id, m.requestId);
    }

    /// @notice Void an open market once its resolution window has expired. At that point resolve
    /// is always forbidden, so a caller cannot race an otherwise valid resolve with abandonment.
    function abandon(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp <= uint256(m.resolveAfter) + RESOLVE_WINDOW) revert TooEarly();
        _void(m, id, 2);
    }

    /// @notice Decide from the registry's record. Anyone may call, at any time after the ask.
    /// Still pending after ANSWER_WINDOW voids (reason 3). An answer whose signed issuedAt is after
    /// the window voids (reason 22) whether it reached the registry before or after this call.
    function settle(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Asked) revert WrongPhase(m.phase);
        uint256 deadline = uint256(m.askedAt) + ANSWER_WINDOW;
        (IAskSwarmRegistry.Ask memory k, IAskSwarmRegistry.Answer memory a) = REGISTRY.get(m.requestId);
        if (k.status == IAskSwarmRegistry.Status.Pending || k.status == IAskSwarmRegistry.Status.None) {
            if (block.timestamp <= deadline) revert StillPending();
            return _void(m, id, 3);
        }
        bool usable = k.status == IAskSwarmRegistry.Status.Answered && a.verified && a.answerType == BOOL
            && a.answer.length == 32 && uint256(a.agreed) * 2 > a.panelSize;
        if (!usable) return _void(m, id, uint8(k.status) + 10);
        if (a.panelSize < MIN_PANEL) return _void(m, id, 21);
        if (a.issuedAt > deadline) return _void(m, id, 22);
        uint256 word = uint256(bytes32(a.answer));
        if (word > 1) return _void(m, id, 20);

        bool yes = word == 1;
        uint256 losers = yes ? m.noPool : m.yesPool;
        uint256 fee = losers * FEE_BPS / 10_000;
        m.phase = yes ? Phase.Yes : Phase.No;
        m.winnersShare = uint128(losers - fee);
        uint256 toCreator = fee / 2;
        _pushOrCredit(m.creator, toCreator);
        _pushOrCredit(TREASURY, fee - toCreator);
        emit Settled(id, m.phase, m.yesPool, m.noPool, fee, 0);
    }

    /// @notice Collect: winners get stake plus their share of the losing pool; on a void market
    /// everyone gets every stake back.
    function claim(uint256 id) external returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[id][msg.sender] = true;
        _push(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Collect IMD credited to the caller because the token refused a push to it.
    function withdraw() external returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        owed[msg.sender] = 0;
        _push(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---- views ----

    function claimable(uint256 id, address user) public view returns (uint256) {
        Market storage m = markets[id];
        if (claimed[id][user]) return 0;
        uint256 y = yesStake[id][user];
        uint256 n = noStake[id][user];
        if (m.phase == Phase.Void) return y + n;
        if (m.phase == Phase.Yes) return y == 0 ? 0 : y + y * m.winnersShare / m.yesPool;
        if (m.phase == Phase.No) return n == 0 ? 0 : n + n * m.winnersShare / m.noPool;
        return 0;
    }

    /// @notice Implied probability of Yes from the pools, in basis points (5000 when empty).
    function oddsYesBps(uint256 id) external view returns (uint256) {
        Market storage m = markets[id];
        uint256 t = uint256(m.yesPool) + m.noPool;
        return t == 0 ? 5000 : uint256(m.yesPool) * 10_000 / t;
    }

    function get(uint256 id) external view returns (Market memory m, bytes memory body) {
        return (markets[id], bodyOf[id]);
    }

    // ---- internals ----

    function _void(Market storage m, uint256 id, uint8 reason) private {
        m.phase = Phase.Void;
        uint256 fee = m.feeEscrow; // unspent escrow (never asked) goes back to the creator
        m.feeEscrow = 0;
        _pushOrCredit(m.creator, fee);
        emit Settled(id, Phase.Void, m.yesPool, m.noPool, 0, reason);
    }

    function _pull(address from, uint256 amount) private {
        _call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
    }

    function _push(address to, uint256 amount) private {
        if (amount != 0) _call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    /// @dev Push to a third party without letting its refusal revert the caller: a failed transfer
    /// (a revert) is credited to `owed[to]` instead, so other users' funds never wait on that address.
    function _pushOrCredit(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = IMD.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (ok) {
            // A reply of `false` or a malformed one cannot show whether tokens moved, so it still
            // reverts the whole call as `_call` does; only a reverted transfer is known not to have.
            if (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (uint256)) == 1)) return;
            revert TransferFailed();
        }
        owed[to] += amount;
        emit Owed(to, amount);
    }

    function _approve(address spender, uint256 amount) private {
        _call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = IMD.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
