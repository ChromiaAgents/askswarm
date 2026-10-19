// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The read and ask surface of AskSwarmRegistry this contract uses.
interface IAskSwarmRegistry {
    enum Status {
        None,
        Pending,
        Answered,
        Refused,
        NoResult,
        Unverified,
        Lost
    }

    struct Ask {
        address asker;
        uint64 askedAt;
        Status status;
    }

    struct Answer {
        bytes32 questionHash;
        bytes answer;
        bytes32 answerHash;
        uint8 answerType;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
        bool verified;
    }

    function price() external view returns (uint256);
    function askAtMost(bytes calldata body, uint256 maxPrice) external returns (bytes32 requestId);
    function get(bytes32 requestId) external view returns (Ask memory k, Answer memory a);
}

/// @title SwarmWager: two people bet on a yes/no question, the IMD swarm settles it
/// @notice A creator writes a yes/no oracle question (the same JSON body AskSwarmRegistry takes),
/// picks a side and stakes IMD, plus the swarm's fee. A counterparty takes the other side with an
/// equal stake. After `resolveAfter`, anyone calls `resolve`: the contract buys the question through
/// AskSwarmRegistry, which verifies the swarm's EIP-712 attestation onchain. Anyone then calls
/// `settle`: a verified strict-majority bool answer pays the whole pot to the right side. Anything
/// else (refused, split panel, unverified, lost, wrong answer type, still pending after timeout) refunds both
/// stakes. Both parties must agree on a fixed fact and observation window before staking: the
/// caller of `resolve` chooses when the body is sent, which can affect time-varying questions.
///
/// The registry is the only source of truth: this contract never reads a signature or a price feed.
/// It trusts the Intake writer's pairing of the request and signed question, and the oracle signer.
/// It is the smallest useful example of a protocol building on the registry's verified memory.
///
/// Invariants:
/// - The contract only ever holds open stakes and unspent fees; each wager pays out exactly once.
/// - The fee is paid to the swarm at most once per wager, and only through `resolve`.
/// - A wager can always be unwound: unmatched by `cancel`, unresolvable by `abandon`, unanswered by
///   `settle` after `ANSWER_WINDOW`.
/// - One party's refund never depends on another's transfer: refunds and the creator's fee are
///   pushed if the token accepts them, else credited to `owed` for that address to `withdraw`
///   (Robinhood Chain's IMD can block an address).
/// - No owner, no admin, no upgrade path, no ETH. Constructor makes no external call.
contract SwarmWager {
    enum State {
        None,
        Open, // created, waiting for a counterparty
        Matched, // both stakes in, waiting for resolveAfter
        Asked, // question bought, waiting for the swarm
        Paid, // winner paid
        Refunded // both stakes returned (or the creator's, if never matched)
    }

    struct Wager {
        address yes;
        address no;
        address creator;
        uint96 stake; // per side, in IMD wei
        uint96 fee; // unspent request-fee escrow, including voluntary top-ups
        uint64 joinBy;
        uint64 resolveAfter;
        uint64 askedAt;
        State state;
        bytes32 requestId; // AskSwarmRegistry request, once asked
        address winner;
    }

    /// @notice How long a pending request must wait after `resolve` before `settle` may refund.
    uint64 public constant ANSWER_WINDOW = 3 days;
    /// @notice Latest permitted resolution time, measured from creation. Also bounds `joinBy`.
    uint64 public constant MAX_TERM = 365 days;
    /// @notice Largest body Intake accepts; a longer one could never be asked.
    uint256 public constant MAX_BODY_BYTES = 16_384;
    /// @notice Answer type the registry reports for a bool question.
    uint8 internal constant BOOL = 0;

    IAskSwarmRegistry public immutable REGISTRY;
    address public immutable IMD;

    uint256 public count;
    mapping(uint256 id => Wager) public wagers;
    mapping(uint256 id => bytes body) public bodyOf;
    /// @notice IMD credited to an address whose push the token refused (e.g. a blocked address).
    mapping(address user => uint256) public owed;

    event Created(
        uint256 indexed id,
        address indexed creator,
        bool creatorSaysYes,
        uint256 stake,
        uint64 joinBy,
        uint64 resolveAfter,
        bytes body
    );
    event Joined(uint256 indexed id, address indexed counterparty);
    event FeeToppedUp(uint256 indexed id, address indexed payer, uint256 amount);
    event Resolving(uint256 indexed id, bytes32 indexed requestId);
    event Paid(uint256 indexed id, address indexed winner, bool answer, uint256 amount);
    event Refunded(uint256 indexed id, uint8 reason);
    event Owed(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    error ZeroAddress();
    error BadTerms();
    error WrongState(State have);
    error TooLate();
    error TooEarly();
    error SameParty();
    error NotCreator();
    error StillPending();
    error TransferFailed();
    error NothingOwed();

    constructor(address registry, address imd) {
        if (registry == address(0) || imd == address(0)) revert ZeroAddress();
        REGISTRY = IAskSwarmRegistry(registry);
        IMD = imd;
    }

    // ---- lifecycle ----

    /// @notice Open a wager. Pulls `stake` plus the registry's current price from the caller.
    /// @param body The oracle.request JSON for a bool question, as AskSwarmRegistry.ask takes it.
    ///        Both parties see it before staking; it decides panel size, quorum and wording.
    function create(bytes calldata body, bool creatorSaysYes, uint96 stake, uint64 joinBy, uint64 resolveAfter)
        external
        returns (uint256 id)
    {
        if (
            body.length == 0 || body.length > MAX_BODY_BYTES || stake == 0 || joinBy <= block.timestamp
                || resolveAfter < joinBy || uint256(resolveAfter) > block.timestamp + MAX_TERM
        ) revert BadTerms();
        uint256 p = REGISTRY.price();
        if (p == 0 || p > type(uint96).max) revert BadTerms();
        id = ++count;
        wagers[id] = Wager({
            yes: creatorSaysYes ? msg.sender : address(0),
            no: creatorSaysYes ? address(0) : msg.sender,
            creator: msg.sender,
            stake: stake,
            fee: uint96(p),
            joinBy: joinBy,
            resolveAfter: resolveAfter,
            askedAt: 0,
            state: State.Open,
            requestId: bytes32(0),
            winner: address(0)
        });
        bodyOf[id] = body;
        _pull(msg.sender, uint256(stake) + p);
        emit Created(id, msg.sender, creatorSaysYes, stake, joinBy, resolveAfter, body);
    }

    /// @notice Take the open side with an equal stake, before `joinBy`.
    function join(uint256 id) external {
        Wager storage w = wagers[id];
        if (w.state != State.Open) revert WrongState(w.state);
        if (block.timestamp > w.joinBy) revert TooLate();
        if (msg.sender == w.creator) revert SameParty();
        if (w.yes == address(0)) w.yes = msg.sender;
        else w.no = msg.sender;
        w.state = State.Matched;
        _pull(msg.sender, w.stake);
        emit Joined(id, msg.sender);
    }

    /// @notice Unmatched wager: the creator may withdraw any time; anyone may after `joinBy`.
    function cancel(uint256 id) external {
        Wager storage w = wagers[id];
        if (w.state != State.Open) revert WrongState(w.state);
        if (msg.sender != w.creator && block.timestamp <= w.joinBy) revert NotCreator();
        w.state = State.Refunded;
        uint256 fee = w.fee;
        w.fee = 0;
        _push(w.creator, uint256(w.stake) + fee);
        emit Refunded(id, 0);
    }

    /// @notice Add IMD to a matched wager's fee escrow if the registry price has risen.
    /// Anyone may contribute; this is a gift to the creator's fee escrow. All unused fees go to
    /// the creator on `resolve` or `abandon`, including contributions from other callers.
    function topUpFee(uint256 id, uint96 amount) external {
        Wager storage w = wagers[id];
        if (w.state != State.Matched) revert WrongState(w.state);
        if (amount == 0 || uint256(w.fee) + amount > type(uint96).max) revert BadTerms();
        w.fee += amount;
        _pull(msg.sender, amount);
        emit FeeToppedUp(id, msg.sender, amount);
    }

    /// @notice Buy the question from the swarm. Anyone, once both sides are in and `resolveAfter` passed.
    /// Pays the registry's current price from the escrowed fee and returns any remainder to the
    /// creator. If the price rose above the escrow it reverts; anyone can `topUpFee`, or `abandon`
    /// unwinds later. After the abandonment deadline, the first of `resolve` or `abandon` wins.
    function resolve(uint256 id) external {
        Wager storage w = wagers[id];
        if (w.state != State.Matched) revert WrongState(w.state);
        if (block.timestamp < w.resolveAfter) revert TooEarly();
        uint256 p = REGISTRY.price(); // what askAtMost pulls in this same transaction
        if (p > w.fee) revert BadTerms(); // top up explicitly, or wait then `abandon`
        uint256 remainder = w.fee - p;
        w.state = State.Asked;
        w.askedAt = uint64(block.timestamp);
        w.fee = 0;
        _approve(address(REGISTRY), p);
        bytes32 rid = REGISTRY.askAtMost(bodyOf[id], p);
        w.requestId = rid;
        _pushOrCredit(w.creator, remainder);
        emit Resolving(id, rid);
    }

    /// @notice Matched but never resolvable (e.g. the swarm's price rose above the escrow):
    /// anyone may unwind it `ANSWER_WINDOW` after `resolveAfter`. Stakes back, fee back to creator.
    function abandon(uint256 id) external {
        Wager storage w = wagers[id];
        if (w.state != State.Matched) revert WrongState(w.state);
        if (block.timestamp <= uint256(w.resolveAfter) + ANSWER_WINDOW) revert TooEarly();
        w.state = State.Refunded;
        uint256 fee = w.fee;
        w.fee = 0;
        _pushOrCredit(w.yes, w.stake);
        _pushOrCredit(w.no, w.stake);
        _pushOrCredit(w.creator, fee);
        emit Refunded(id, 1);
    }

    /// @notice Pay out from the registry's record of the swarm's answer. Anyone may call.
    /// Pays the pot only on a verified bool answer a strict majority of its panel agreed on;
    /// refunds both stakes on any other terminal outcome, or if still pending after ANSWER_WINDOW.
    /// A usable answer recorded before this call wins even after the timeout; an earlier timeout
    /// refund is final. The registry records no delivery timestamp, so this is a race to settlement.
    function settle(uint256 id) external {
        Wager storage w = wagers[id];
        if (w.state != State.Asked) revert WrongState(w.state);
        (IAskSwarmRegistry.Ask memory k, IAskSwarmRegistry.Answer memory a) = REGISTRY.get(w.requestId);

        if (k.status == IAskSwarmRegistry.Status.Pending || k.status == IAskSwarmRegistry.Status.None) {
            if (block.timestamp <= uint256(w.askedAt) + ANSWER_WINDOW) revert StillPending();
            return _refund(w, id, 2);
        }
        bool usable = k.status == IAskSwarmRegistry.Status.Answered && a.verified && a.answerType == BOOL
            && a.answer.length == 32 && uint256(a.agreed) * 2 > a.panelSize;
        if (!usable) return _refund(w, id, uint8(k.status) + 10);

        uint256 word = uint256(bytes32(a.answer));
        if (word > 1) return _refund(w, id, 20); // not a canonical abi-encoded bool
        bool yes = word == 1;
        address winner = yes ? w.yes : w.no;
        w.state = State.Paid;
        w.winner = winner;
        uint256 pot = uint256(w.stake) * 2;
        _push(winner, pot);
        emit Paid(id, winner, yes, pot);
    }

    /// @notice Collect IMD credited to the caller because the token refused a push to it.
    function withdraw() external returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        _push(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---- views ----

    function get(uint256 id) external view returns (Wager memory w, bytes memory body) {
        return (wagers[id], bodyOf[id]);
    }

    // ---- internals ----

    function _refund(Wager storage w, uint256 id, uint8 reason) private {
        w.state = State.Refunded;
        _pushOrCredit(w.yes, w.stake);
        _pushOrCredit(w.no, w.stake);
        emit Refunded(id, reason);
    }

    function _pull(address from, uint256 amount) private {
        _call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
    }

    function _push(address to, uint256 amount) private {
        if (amount != 0) _call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    /// @dev Push to a party without letting its refusal revert the caller: a failed transfer
    /// (a revert) is credited to `owed[to]` instead, so the other party's refund never waits on that address.
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
