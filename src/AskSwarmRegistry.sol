// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIntake, OracleAttestation} from "./IIntake.sol";

/// @title AskSwarmRegistry: a public, verified memory of what the IMD swarm has attested
/// @notice Anyone pays 0.5 IMD here and the question goes to the swarm through Intake v2 with this
/// contract as the callback. When the panel reaches quorum the plane delivers the EIP-712 signed
/// attestation; the contract checks the signature against the oracle signer and stores the answer
/// under the question hash. Every answer anyone ever bought becomes readable, free, by any contract
/// or client, with the proof that the swarm said it. Refusals and split panels are recorded too,
/// so a reader can tell "no consensus" from "never asked".
///
/// Designed for the IdentityMD hackathon by the AskSwarm team (Chromia / Eval Engine). The Telegram
/// bot and the Pay-with-IMD page route paid questions through `ask`; the bot's free tier reads
/// `answerOf` before charging anyone.
///
/// Invariants:
/// - The contract holds no IMD between calls: `ask` pulls exactly the Intake price and forwards it.
///   Tokens or ETH sent here directly are unrecoverable by design: there is no owner to sweep them.
/// - Only Intake can deliver results, and each ask is settled once: both hooks refuse an ask that
///   is not `Pending`, whatever arguments Intake forwards. A settled record never changes.
/// - A stored answer is `verified` only if the signature recovers to `SIGNER` over the exact
///   EIP-712 digest the plane publishes off chain, so an off-chain reader can re-derive it, the
///   panel's agreement met its quorum, and the attestation was neither expired nor issued more
///   than `ISSUED_AT_TOLERANCE` ahead of the chain clock when it arrived.
///   Verified proves the swarm signed this answer for this contract; the pairing of an answer with
///   the ask that bought it is the writer's, as it is for every Intake consumer.
/// - `latestFor[questionHash]` only indexes an answer a strict majority of its own panel agreed on
///   (`agreed * 2 > panelSize`), and while the one it holds is verified and unexpired it only moves
///   to an answer at least as strong (panel size and agreement), at least as fresh (`issuedAt`) and
///   valid at least as long (`expiresAt`). A weak panel cannot overwrite a strong one, a large
///   panel's minority plurality cannot either, and a short-lived answer cannot cut a long-lived
///   one's validity short. Once the held answer has expired, any eligible answer may take the
///   index: the next delivery does so, and `reindex` lets anyone point it at an answer already on
///   record, so a verified answer is never left dark behind an expired one.
/// - `ask` pulls exactly the price Intake quotes in the same transaction; `askAtMost` lets the
///   caller cap it, so a standing allowance cannot be spent at a price the caller never saw.
/// - An ask settles once, through Intake's hooks or, when Intake has completed the request without
///   reaching either hook, through `markLost`, which anyone may call and which touches no answer.
///
/// Lifecycle: this registry is pinned to Intake v2, the oracle.request action (version oracle-1), and one
/// attester key. If IMD retires the action (`setPrice` to 0) or rotates the attester, `ask` stops
/// or new answers stop verifying; a successor registry is a new deployment and every answer here
/// stays readable. There is no owner because the swarm's audit panel, and this design, want none.
contract AskSwarmRegistry {
    // ---- types ----

    enum Status {
        None,
        Pending,
        Answered, // verified attestation stored
        Refused, // plane refused the ask (status 1)
        NoResult, // panel split or job failed (status 2)
        Unverified, // delivered, but the signature or pairing did not check out; stored for the record
        Lost // Intake completed the request but neither hook settled it here; marked through `markLost`
    }

    struct Ask {
        address asker;
        uint64 askedAt;
        Status status;
    }

    /// @dev Storage form: exactly three slots so `onOracleResult` stays well inside Intake's 200k stipend.
    struct Stored {
        bytes32 questionHash;
        /// Answers of 32 bytes or fewer, left-aligned; for longer answers (address[] lists) the
        /// keccak256 of the answer bytes, with `long` set. The full bytes are in the Answered event.
        bytes32 answer32;
        uint8 answerLen;
        bool long;
        uint8 answerType;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
        bool verified; // signature recovered to SIGNER, agreed >= quorum, not expired and not pre-dated at delivery
        bool stored; // an answer was written here; a record without one reads back with a zero answerHash
    }

    /// @notice Read form.
    struct Answer {
        bytes32 questionHash;
        bytes answer; // empty when `long`
        bytes32 answerHash; // keccak256 of the full answer bytes
        uint8 answerType;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
        bool verified;
    }

    // ---- constants ----

    /// @notice Intake v2 on this chain. Same address on Ethereum, Sepolia, Robinhood and Base.
    IIntake public immutable INTAKE;
    /// @notice The asset Intake is paid in here (IMD on mainnet, IMDtest on Sepolia).
    address public immutable IMD;
    /// @notice The key the plane signs oracle attestations with.
    address public immutable SIGNER;
    /// @notice `oracle.request@oracle-1`, right padded, as Intake names actions.
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    /// @notice Pinned protocol profile, so clients can tell registries apart.
    string public constant VERSION = "askswarm-registry/1 intake-v2 oracle-1";
    /// @dev Answers past this length are not hashed or stored; the delivery is recorded as Unverified
    /// so a hostile payload cannot run the callback out of Intake's stipend and leave the ask Pending.
    uint256 public constant MAX_ANSWER_BYTES = 4096;
    /// @notice How far ahead of this chain's clock an attestation's `issuedAt` may sit and still be
    /// `verified`: the protocol's `OracleAttestationConsumer` tolerance, so a pre-signed answer cannot
    /// be stored as current for longer than the plane allows.
    uint64 public constant ISSUED_AT_TOLERANCE = 5 minutes;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 private immutable DOMAIN_SEPARATOR;

    // ---- storage ----

    mapping(bytes32 requestId => Ask) public asks;
    mapping(bytes32 requestId => Stored) private _answers;
    /// @notice The verified answer this registry holds as canonical for a question hash.
    /// `questionHash` is the plane's, as signed in the attestation: it covers the normalized
    /// question, the resolved block window and the definitions. Asks with a relative window
    /// (`{"hours":N}`) resolve to a different window each time, so they never share a key and the
    /// displacement rule never engages between them; only absolute-window asks
    /// (`{"fromBlock","toBlock"}`) repeat a key, and only for those can a reader compute it ahead
    /// of time. Readers take the key from the `Answered` event or the attestation document.
    mapping(bytes32 questionHash => bytes32 requestId) public latestFor;
    uint256 public asked;

    // ---- events ----

    event Asked(bytes32 indexed requestId, address indexed asker, bytes body);
    event Answered(
        bytes32 indexed requestId,
        bytes32 indexed questionHash,
        uint8 answerType,
        bytes answer,
        uint256 figure,
        uint16 agreed,
        uint16 quorum,
        uint16 panelSize,
        uint64 expiresAt,
        bool verified
    );
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    /// @notice `latestFor[questionHash]` now points at `requestId` (from a delivery or `reindex`).
    event Indexed(bytes32 indexed questionHash, bytes32 indexed requestId);
    /// @notice Intake completed the request without a result or failure reaching this registry.
    event Lost(bytes32 indexed requestId);

    error NotIntake();
    error UnknownAsk(bytes32 requestId);
    error AlreadySettled(bytes32 requestId);
    error TransferFailed();
    error NotSold();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error StillOpen(bytes32 requestId);
    error NotEligible(bytes32 requestId);
    error ZeroAddress();

    constructor(address intake, address imd, address signer) {
        if (intake == address(0) || imd == address(0) || signer == address(0)) revert ZeroAddress();
        INTAKE = IIntake(intake);
        IMD = imd;
        SIGNER = signer;
        // The plane signs for the callback's contract: domain verifyingContract is this address
        // (imd.fun/docs "with no consumer in the body, the answer is signed for the callback's contract").
        DOMAIN_SEPARATOR = _domain(address(this));
        // No external call here: the launch runs constructors on an empty chain. `ask` approves
        // Intake for exactly the price it forwards.
    }

    // ---- ask ----

    /// @notice Current price Intake charges for one oracle request in IMD.
    function price() public view returns (uint256) {
        return INTAKE.priceOf(ACTION, IMD);
    }

    /// @notice Pay the swarm's price and ask. `body` is the oracle.request JSON (same as the HTTP
    /// door): {"v":1,"question":...,"chainId":...,"answerType":...,"panelSize":...,"quorum":...}.
    /// Caller must have approved this contract for `price()` IMD. Pays whatever Intake quotes when the
    /// call is mined; a caller with a standing allowance who wants a ceiling uses `askAtMost`.
    function ask(bytes calldata body) external returns (bytes32 requestId) {
        return _ask(body, type(uint256).max);
    }

    /// @notice Same as `ask`, but reverts `PriceAboveMax` when Intake's price at execution exceeds
    /// `maxPrice`, so an approval larger than one ask (the bot approves twenty) cannot be spent at a
    /// price the caller never saw.
    function askAtMost(bytes calldata body, uint256 maxPrice) external returns (bytes32 requestId) {
        return _ask(body, maxPrice);
    }

    function _ask(bytes calldata body, uint256 maxPrice) internal returns (bytes32 requestId) {
        uint256 p = price();
        if (p == 0) revert NotSold();
        if (p > maxPrice) revert PriceAboveMax(p, maxPrice);
        _call(IMD, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), p));
        // Intake pulls exactly `p`, so the allowance is back to zero after the request.
        _call(IMD, abi.encodeWithSelector(0x095ea7b3, address(INTAKE), p));
        requestId = INTAKE.requestWithFailure(
            ACTION, body, IIntake.Callback(address(this), this.onOracleResult.selector), this.onFailure.selector, IMD, p
        );
        asks[requestId] = Ask({asker: msg.sender, askedAt: uint64(block.timestamp), status: Status.Pending});
        asked++;
        emit Asked(requestId, msg.sender, body);
    }

    // ---- the swarm answers ----

    /// @notice Intake calls this with the signed attestation when the panel reached quorum.
    /// Selector 0x510379c7, the docs' `onOracleResult`; Intake calls whatever selector `ask` registered.
    /// Runs inside Intake's fixed stipend (200k on mainnet, 1M on Sepolia): three fresh storage slots,
    /// one ecrecover, one extra cold read of the currently indexed answer.
    /// Only a `Pending` ask is accepted: Intake v2 forwards a status-0 completion's arguments to the
    /// callback unchecked, so without this guard any other open request could re-deliver a settled id.
    function onOracleResult(bytes32 requestId, OracleAttestation calldata a, bytes calldata signature) external {
        if (msg.sender != address(INTAKE)) revert NotIntake();
        Ask storage k = asks[requestId];
        if (k.asker == address(0)) revert UnknownAsk(requestId);
        if (k.status != Status.Pending) revert AlreadySettled(requestId);
        if (a.answer.length > MAX_ANSWER_BYTES) {
            k.status = Status.Unverified;
            emit Answered(
                requestId,
                a.questionHash,
                a.answerType,
                "",
                a.figure,
                a.agreed,
                a.quorum,
                a.panelSize,
                a.expiresAt,
                false
            );
            return;
        }
        // Verified: the attester signed this exact attestation for this contract (nonzero recovery),
        // the panel's own agreement met quorum (docs: agreed < quorum only when a rerun decided),
        // and the attestation was in its window when it arrived: not expired, and not issued further
        // ahead of the chain clock than the protocol consumer tolerates.
        address rec = _recover(_digest(a), signature);
        bool ok = rec != address(0) && rec == SIGNER && a.agreed >= a.quorum && block.timestamp <= a.expiresAt
            && a.issuedAt <= block.timestamp + ISSUED_AT_TOLERANCE;
        k.status = ok ? Status.Answered : Status.Unverified;
        bool long = a.answer.length > 32;
        _answers[requestId] = Stored({
            questionHash: a.questionHash,
            answer32: long ? keccak256(a.answer) : _left32(a.answer),
            answerLen: uint8(long ? 0 : a.answer.length),
            long: long,
            answerType: a.answerType,
            panelSize: a.panelSize,
            quorum: a.quorum,
            agreed: a.agreed,
            issuedAt: a.issuedAt,
            expiresAt: a.expiresAt,
            verified: ok,
            stored: true
        });
        // Index only verified answers a strict majority of their panel agreed on (the asker picks
        // panelSize and quorum, so quorum alone says nothing), and never let a weaker, staler or
        // shorter-lived answer displace one that is still current (`_mayDisplace`). The held
        // record's fields share one slot, so this is a single extra cold read.
        if (
            ok && uint256(a.agreed) * 2 > a.panelSize
                && _mayDisplace(
                    _answers[latestFor[a.questionHash]], a.panelSize, a.agreed, a.issuedAt, a.expiresAt, false
                )
        ) {
            latestFor[a.questionHash] = requestId;
            emit Indexed(a.questionHash, requestId);
        }
        emit Answered(
            requestId,
            a.questionHash,
            a.answerType,
            a.answer,
            a.figure,
            a.agreed,
            a.quorum,
            a.panelSize,
            a.expiresAt,
            ok
        );
    }

    /// @notice Intake calls this when the plane refused the ask (status 1) or the panel ended
    /// without a result (status 2). `reason` is the plane's short code.
    function onFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answeredCount,
        bytes calldata
    ) external {
        if (msg.sender != address(INTAKE)) revert NotIntake();
        Ask storage k = asks[requestId];
        if (k.asker == address(0)) revert UnknownAsk(requestId);
        if (k.status != Status.Pending) revert AlreadySettled(requestId);
        k.status = status == 1 ? Status.Refused : Status.NoResult;
        emit Failed(requestId, status, reason, agreed, answeredCount);
    }

    // ---- settle and index without Intake ----

    /// @notice Settle a `Pending` ask that Intake has completed without either hook landing here:
    /// a completion whose arguments named another id, calldata the hook could not decode, a callback
    /// that ran out of Intake's stipend, or a failure completion with empty arguments. Intake
    /// completes a request once, so nothing can reach the hooks afterwards and the ask would read
    /// `Pending` forever. Anyone may call it; it reads Intake's own record and touches no answer.
    function markLost(bytes32 requestId) external {
        Ask storage k = asks[requestId];
        if (k.asker == address(0)) revert UnknownAsk(requestId);
        if (k.status != Status.Pending) revert AlreadySettled(requestId);
        (,,, bool completed) = INTAKE.requests(requestId);
        if (!completed) revert StillOpen(requestId);
        k.status = Status.Lost;
        emit Lost(requestId);
    }

    /// @notice Point `latestFor` at an answer already on record. Anyone may call it, under the same
    /// rule a delivery follows: the answer is verified, unexpired and a strict majority of its
    /// panel, and the index either holds nothing current or holds an answer this one beats or
    /// matches on every count (panel, agreement, issuedAt, expiresAt) and beats on at least one.
    /// This is the fallback for an answer that arrived while a stronger but shorter-lived one was
    /// current: once that one expires, the index would otherwise stay dark although a verified
    /// answer is still valid. Exact ties cannot be flipped back and forth: they need a delivery.
    function reindex(bytes32 requestId) external {
        Stored storage s = _answers[requestId];
        bytes32 q = s.questionHash;
        if (
            !s.verified || block.timestamp > s.expiresAt || uint256(s.agreed) * 2 <= s.panelSize
                || !_mayDisplace(_answers[latestFor[q]], s.panelSize, s.agreed, s.issuedAt, s.expiresAt, true)
        ) revert NotEligible(requestId);
        latestFor[q] = requestId;
        emit Indexed(q, requestId);
    }

    /// @dev Whether a candidate (already known to be verified, unexpired and a majority) may take
    /// the index from `cur`: always when `cur` is not a verified, unexpired answer; otherwise only
    /// when the candidate is at least as strong (panel, agreement), as fresh (issuedAt) and as
    /// long-lived (expiresAt). With `strict`, matching on all four is not enough.
    function _mayDisplace(
        Stored storage cur,
        uint16 panelSize,
        uint16 agreed,
        uint64 issuedAt,
        uint64 expiresAt,
        bool strict
    ) internal view returns (bool) {
        if (!cur.verified || block.timestamp > cur.expiresAt) return true;
        if (panelSize < cur.panelSize || agreed < cur.agreed || issuedAt < cur.issuedAt || expiresAt < cur.expiresAt) {
            return false;
        }
        return !strict || panelSize > cur.panelSize || agreed > cur.agreed || issuedAt > cur.issuedAt
            || expiresAt > cur.expiresAt;
    }

    // ---- read ----

    /// @notice Latest verified answer for a question hash. Check `expiresAt`, `panelSize` and
    /// `agreed` against what the value at stake needs; the registry pins nothing about questions.
    function answerOf(bytes32 questionHash) external view returns (bytes32 requestId, Answer memory a) {
        requestId = latestFor[questionHash];
        a = _read(requestId);
    }

    /// @notice Same, filtered: zero request id when the held answer is expired or weaker than asked.
    function answerOf(bytes32 questionHash, uint16 minPanel, uint16 minAgreed)
        external
        view
        returns (bytes32 requestId, Answer memory a)
    {
        requestId = latestFor[questionHash];
        Stored storage s = _answers[requestId];
        if (block.timestamp > s.expiresAt || s.panelSize < minPanel || s.agreed < minAgreed) return (bytes32(0), a);
        a = _read(requestId);
    }

    /// @notice True when the indexed answer for this question is verified and not yet expired.
    function isCurrent(bytes32 questionHash) external view returns (bool) {
        Stored storage s = _answers[latestFor[questionHash]];
        return s.verified && block.timestamp <= s.expiresAt;
    }

    function get(bytes32 requestId) external view returns (Ask memory k, Answer memory a) {
        return (asks[requestId], _read(requestId));
    }

    function _read(bytes32 requestId) internal view returns (Answer memory a) {
        Stored storage s = _answers[requestId];
        bytes memory ans;
        bytes32 h; // stays zero when no answer was stored (Pending, Refused, NoResult, over-cap, unknown)
        if (s.stored) {
            if (s.long) {
                h = s.answer32;
            } else {
                ans = new bytes(s.answerLen);
                bytes32 w = s.answer32;
                assembly {
                    mstore(add(ans, 32), w)
                }
                h = keccak256(ans);
            }
        }
        a = Answer({
            questionHash: s.questionHash,
            answer: ans,
            answerHash: h,
            answerType: s.answerType,
            panelSize: s.panelSize,
            quorum: s.quorum,
            agreed: s.agreed,
            issuedAt: s.issuedAt,
            expiresAt: s.expiresAt,
            verified: s.verified
        });
    }

    /// @notice The EIP-712 digest the plane signs; exposed so clients can cross-check offline.
    function digest(OracleAttestation calldata a) external view returns (bytes32) {
        return _digest(a);
    }

    // ---- internals ----

    function _domain(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, verifyingContract
            )
        );
    }

    function _digest(OracleAttestation calldata a) internal view returns (bytes32) {
        return _digestUnder(a, DOMAIN_SEPARATOR);
    }

    function _digestUnder(OracleAttestation calldata a, bytes32 domainSeparator) internal pure returns (bytes32) {
        // abi.encode of all 16 words, built in two halves to stay within the EVM stack. The bytes are
        // identical to a single abi.encode(...) since every field is a static 32-byte word.
        bytes memory head = abi.encode(
            ATTESTATION_TYPEHASH,
            a.requestId,
            a.chainId,
            a.questionHash,
            a.answerType,
            keccak256(a.answer),
            a.figure,
            a.fromBlock
        );
        bytes memory tail =
            abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt);
        bytes32 structHash = keccak256(bytes.concat(head, tail));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _recover(bytes32 h, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        // Reject high-s so a signature has one canonical form.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(h, v, r, s);
    }

    function _left32(bytes calldata b) private pure returns (bytes32 w) {
        assembly {
            w := calldataload(b.offset)
        }
        // calldataload reads 32 bytes; mask off anything past the answer's own length.
        if (b.length < 32) w &= bytes32(~uint256(0) << (8 * (32 - b.length)));
    }

    /// @dev Minimal safe ERC-20 call: ok if it did not revert and returned nothing or true.
    function _call(address token, bytes memory data) private {
        (bool s, bytes memory ret) = token.call(data);
        if (!s || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
