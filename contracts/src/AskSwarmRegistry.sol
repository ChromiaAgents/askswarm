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
/// - Only Intake can deliver results, and only once per request (Intake enforces both).
/// - A stored answer is `verified` only if the signature recovers to `SIGNER` over the exact
///   EIP-712 digest the plane publishes off chain, so an off-chain reader can re-derive it.
///   Verified proves the swarm signed this answer for this contract; the pairing of an answer with
///   the ask that bought it is the writer's, as it is for every Intake consumer.
/// - `latestFor[questionHash]` only moves to an answer at least as strong as the one it holds
///   (panel size and agreement), unless the held one has expired. A weak panel cannot overwrite
///   a strong one; replacing a strong answer costs a stronger panel.
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
        Unverified // delivered, but the signature or pairing did not check out; stored for the record
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
        bool verified; // signature recovered to SIGNER and agreed >= quorum; expiry is the reader's check
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

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 private immutable DOMAIN_SEPARATOR;

    // ---- storage ----

    mapping(bytes32 requestId => Ask) public asks;
    mapping(bytes32 requestId => Stored) private _answers;
    /// @notice Latest verified answer for a question hash (keccak256 of the normalized question,
    /// as the plane computes it and puts in the attestation).
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

    error NotIntake();
    error UnknownAsk(bytes32 requestId);
    error TransferFailed();
    error NotSold();
    error ZeroAddress();

    constructor(address intake, address imd, address signer) {
        if (intake == address(0) || imd == address(0) || signer == address(0)) revert ZeroAddress();
        INTAKE = IIntake(intake);
        IMD = imd;
        SIGNER = signer;
        // The plane signs for the callback's contract: domain verifyingContract is this address
        // (imd.fun/docs "with no consumer in the body, the answer is signed for the callback's contract").
        DOMAIN_SEPARATOR = _domain(address(this));
        // One approval for the contract's life: Intake pulls exactly the price per request.
        _call(imd, abi.encodeWithSelector(0x095ea7b3, intake, type(uint256).max));
    }

    // ---- ask ----

    /// @notice Current price Intake charges for one oracle request in IMD.
    function price() public view returns (uint256) {
        return INTAKE.priceOf(ACTION, IMD);
    }

    /// @notice Pay the swarm's price and ask. `body` is the oracle.request JSON (same as the HTTP
    /// door): {"v":1,"question":...,"chainId":...,"answerType":...,"panelSize":...,"quorum":...}.
    /// Caller must have approved this contract for `price()` IMD.
    function ask(bytes calldata body) external returns (bytes32 requestId) {
        uint256 p = price();
        if (p == 0) revert NotSold();
        _call(IMD, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), p));
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
    function onOracleResult(bytes32 requestId, OracleAttestation calldata a, bytes calldata signature) external {
        if (msg.sender != address(INTAKE)) revert NotIntake();
        Ask storage k = asks[requestId];
        if (k.asker == address(0)) revert UnknownAsk(requestId);
        if (a.answer.length > MAX_ANSWER_BYTES) {
            k.status = Status.Unverified;
            emit Answered(requestId, a.questionHash, a.answerType, "", a.figure, a.agreed, a.quorum, a.panelSize, a.expiresAt, false);
            return;
        }
        // Verified: the attester signed this exact attestation for this contract (nonzero recovery),
        // and the panel's own agreement met quorum (docs: agreed < quorum only when a rerun decided).
        address rec = _recover(_digest(a), signature);
        bool ok = rec != address(0) && rec == SIGNER && a.agreed >= a.quorum;
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
            verified: ok
        });
        // Index only verified, unexpired answers, and never let a weaker panel displace a stronger
        // one that is still current. Strength = panel size and agreement, both at least as large.
        if (ok && block.timestamp <= a.expiresAt) {
            Stored storage cur = _answers[latestFor[a.questionHash]];
            bool held = cur.verified && block.timestamp <= cur.expiresAt;
            if (!held || (a.panelSize >= cur.panelSize && a.agreed >= cur.agreed)) latestFor[a.questionHash] = requestId;
        }
        emit Answered(requestId, a.questionHash, a.answerType, a.answer, a.figure, a.agreed, a.quorum, a.panelSize, a.expiresAt, ok);
    }

    /// @notice Intake calls this when the plane refused the ask (status 1) or the panel ended
    /// without a result (status 2). `reason` is the plane's short code.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answeredCount, bytes calldata)
        external
    {
        if (msg.sender != address(INTAKE)) revert NotIntake();
        Ask storage k = asks[requestId];
        if (k.asker == address(0)) revert UnknownAsk(requestId);
        k.status = status == 1 ? Status.Refused : Status.NoResult;
        emit Failed(requestId, status, reason, agreed, answeredCount);
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
        bytes32 h;
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
        bytes memory tail = abi.encode(
            a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
        );
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
