// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAskSwarmRegistry} from "./SwarmWager.sol";

/// @title SwarmMarket: yes/no prediction markets settled by the IMD swarm
/// @notice Anyone opens a market on a yes/no oracle question (the JSON body AskSwarmRegistry takes),
/// escrowing the swarm's fee. Anyone stakes IMD on Yes or No until `closeAt`. After `resolveAfter`
/// anyone calls `resolve`, which buys the question through AskSwarmRegistry, then `settle`, which reads
/// the registry's record: a verified bool answer agreed by a strict majority of its panel decides the
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
///   `abandon` if it can never be resolved.
/// - The fee escrow pays the swarm at most once, through `resolve`; unspent fee returns to the creator.
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

    uint64 public constant ANSWER_WINDOW = 3 days;
    /// @notice Fee on the losing pool, in basis points, taken only when the swarm settles the market.
    uint256 public constant FEE_BPS = 200;
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

    event Opened(uint256 indexed id, address indexed creator, uint64 closeAt, uint64 resolveAfter, bytes body);
    event Staked(uint256 indexed id, address indexed user, bool yes, uint256 amount);
    event Resolving(uint256 indexed id, bytes32 indexed requestId);
    event Settled(uint256 indexed id, Phase phase, uint256 yesPool, uint256 noPool, uint256 fee, uint8 reason);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);

    error ZeroAddress();
    error BadTerms();
    error WrongPhase(Phase have);
    error Closed();
    error TooEarly();
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
    function open(bytes calldata body, uint64 closeAt, uint64 resolveAfter) external returns (uint256 id) {
        if (body.length == 0 || closeAt <= block.timestamp || resolveAfter < closeAt) revert BadTerms();
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

    /// @notice After `resolveAfter`, buy the question from the swarm. If a side is empty there is
    /// nothing to decide: the market goes void without spending the fee.
    function resolve(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp < m.resolveAfter) revert TooEarly();
        if (m.yesPool == 0 || m.noPool == 0) return _void(m, id, 1);
        uint256 p = REGISTRY.price();
        if (p > m.feeEscrow) revert BadTerms(); // price rose above the escrow: `abandon` later
        uint256 remainder = m.feeEscrow - p;
        m.phase = Phase.Asked;
        m.askedAt = uint64(block.timestamp);
        m.feeEscrow = 0;
        _approve(address(REGISTRY), p);
        m.requestId = REGISTRY.askAtMost(bodyOf[id], p);
        _push(m.creator, remainder);
        emit Resolving(id, m.requestId);
    }

    /// @notice An open market that could never be resolved: void it `ANSWER_WINDOW` after `resolveAfter`.
    function abandon(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Open) revert WrongPhase(m.phase);
        if (block.timestamp <= uint256(m.resolveAfter) + ANSWER_WINDOW) revert TooEarly();
        _void(m, id, 2);
    }

    /// @notice Decide the market from the registry's record. Anyone may call.
    function settle(uint256 id) external {
        Market storage m = markets[id];
        if (m.phase != Phase.Asked) revert WrongPhase(m.phase);
        (IAskSwarmRegistry.Ask memory k, IAskSwarmRegistry.Answer memory a) = REGISTRY.get(m.requestId);
        if (k.status == IAskSwarmRegistry.Status.Pending || k.status == IAskSwarmRegistry.Status.None) {
            if (block.timestamp <= uint256(m.askedAt) + ANSWER_WINDOW) revert StillPending();
            return _void(m, id, 3);
        }
        bool usable = k.status == IAskSwarmRegistry.Status.Answered && a.verified && a.answerType == BOOL
            && a.answer.length == 32 && uint256(a.agreed) * 2 > a.panelSize;
        if (!usable) return _void(m, id, uint8(k.status) + 10);
        uint256 word = uint256(bytes32(a.answer));
        if (word > 1) return _void(m, id, 20);

        bool yes = word == 1;
        uint256 losers = yes ? m.noPool : m.yesPool;
        uint256 fee = losers * FEE_BPS / 10_000;
        m.phase = yes ? Phase.Yes : Phase.No;
        m.winnersShare = uint128(losers - fee);
        uint256 toCreator = fee / 2;
        _push(m.creator, toCreator);
        _push(TREASURY, fee - toCreator);
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
        _push(m.creator, fee);
        emit Settled(id, Phase.Void, m.yesPool, m.noPool, 0, reason);
    }

    function _pull(address from, uint256 amount) private {
        _call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
    }

    function _push(address to, uint256 amount) private {
        if (amount != 0) _call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _approve(address spender, uint256 amount) private {
        _call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = IMD.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
