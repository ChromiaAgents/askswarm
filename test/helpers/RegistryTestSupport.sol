// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "src/IIntake.sol";

/// Test-only ERC20 with configurable return data and failures on either payment leg.
/// It never mints during a transfer, so the tests can independently account for supply.
contract PaymentToken {
    enum Reply {
        True,
        False,
        Revert,
        Empty,
        Short,
        NonBoolean
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    Reply public pullReply;
    Reply public approveReply;
    address public rejectedSpender;

    error TokenRejected();
    error InsufficientBalance();
    error InsufficientAllowance();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configure(Reply pull, Reply approval, address rejected) external {
        pullReply = pull;
        approveReply = approval;
        rejectedSpender = rejected;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _reply(approveReply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender == rejectedSpender) revert TokenRejected();
        uint256 permitted = allowance[from][msg.sender];
        if (permitted < amount) revert InsufficientAllowance();
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _move(from, to, amount);
        return _reply(pullReply);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    // Return after changing state deliberately: a caller rejecting this return must roll back
    // the transfer/approval as well, not merely report a payment failure.
    function _reply(Reply mode) internal pure returns (bool) {
        if (mode == Reply.Revert) revert TokenRejected();
        if (mode == Reply.Empty) {
            assembly { return(0, 0) }
        }
        if (mode == Reply.Short) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == Reply.NonBoolean) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode != Reply.False;
    }
}

/// Offline transport model, not a replacement for live integration testing. It records every
/// request argument, forwards the exact payment, and attempts the selected callback once at 200k.
contract RecordingIntake {
    struct Request {
        address payer;
        IIntake.Callback callback;
        bytes4 failure;
        bool completed;
        bool delivered;
    }

    address public immutable asset;
    address public immutable recipient;
    address public immutable writer;
    uint256 public currentPrice = 0.5 ether;
    uint256 public nonce;
    uint8 public rejectionStage;
    bool public rejectPrice;
    mapping(bytes32 => Request) private _requests;

    bytes32 public lastAction;
    bytes public lastBody;
    address public lastAsset;
    uint256 public lastAmount;

    error NotSold();
    error PriceUnavailable();
    error RequestRejected();
    error PaymentRejected();
    error NotWriter();
    error UnknownRequest();
    error AlreadyCompleted();
    error EmptyBody();
    error BodyTooLong();
    error FailureArgsMismatch();

    constructor(address token, address payee, address writer_) {
        asset = token;
        recipient = payee;
        writer = writer_;
    }

    function setPrice(uint256 value) external {
        currentPrice = value;
    }

    function setRejection(uint8 stage, bool priceReverts) external {
        rejectionStage = stage;
        rejectPrice = priceReverts;
    }

    function priceOf(bytes32 action, address token) external view returns (uint256) {
        if (rejectPrice) revert PriceUnavailable();
        return action == bytes32("oracle.request@oracle-1") && token == asset ? currentPrice : 0;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        IIntake.Callback calldata callback,
        bytes4 onFailure,
        address token,
        uint256 amount
    ) external payable returns (bytes32 id) {
        if (rejectionStage == 1) revert RequestRejected();
        if (
            currentPrice == 0 || action != bytes32("oracle.request@oracle-1") || token != asset || amount < currentPrice
                || msg.value != 0
        ) revert NotSold();
        if (body.length == 0) revert EmptyBody();
        if (body.length > 16_384) revert BodyTooLong();
        id = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        _requests[id] = Request(msg.sender, callback, onFailure, false, false);
        (bool ok, bytes memory result) =
            token.call(abi.encodeCall(PaymentToken.transferFrom, (msg.sender, recipient, amount)));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert PaymentRejected();
        if (rejectionStage == 2) revert RequestRejected();
        lastAction = action;
        lastBody = body;
        lastAsset = token;
        lastAmount = amount;
    }

    function requestInfo(bytes32 id) external view returns (Request memory) {
        return _requests[id];
    }

    /// The live Intake's public getter, as its verified ABI declares it (four words).
    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        Request storage r = _requests[id];
        return (r.payer, r.callback.target, r.callback.selector, r.completed);
    }

    function complete(bytes32 id, uint8 status, bytes calldata args) external returns (bool delivered) {
        if (msg.sender != writer) revert NotWriter();
        Request storage r = _requests[id];
        if (r.payer == address(0)) revert UnknownRequest();
        if (r.completed) revert AlreadyCompleted();
        r.completed = true;
        bytes4 selector = status == 0 ? r.callback.selector : r.failure;
        if (status != 0) {
            if (selector == bytes4(0) || args.length == 0) return false;
            if (args.length < 64 || bytes32(args[0:32]) != id || uint256(bytes32(args[32:64])) != status) {
                revert FailureArgsMismatch();
            }
        }
        (delivered,) = r.callback.target.call{gas: 200_000}(abi.encodePacked(selector, args));
        r.delivered = delivered;
    }
}

abstract contract RegistryTestSupport is Test {
    // Fixture keys are used only for locally deployed consumers; never the production signer.
    uint256 internal constant SIGNING_KEY = 0xA11CE;
    uint256 internal constant OTHER_KEY = 0xB0B;
    uint64 internal constant START = 1_800_000_000;
    bytes32 internal constant QUESTION = keccak256("registry test question");
    PaymentToken internal token;
    RecordingIntake internal intake;
    AskSwarmRegistry internal registry;
    address internal alice;
    address internal bob;
    address internal recipient;
    address internal writer;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(START);
        vm.roll(26_300_000);
        alice = makeAddr("payment alice");
        bob = makeAddr("payment bob");
        recipient = makeAddr("intake payment recipient");
        writer = makeAddr("intake writer");
        token = new PaymentToken();
        intake = new RecordingIntake(address(token), recipient, writer);
        registry = new AskSwarmRegistry(address(intake), address(token), vm.addr(SIGNING_KEY));
        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
        vm.prank(alice);
        token.approve(address(registry), type(uint256).max);
        vm.prank(bob);
        token.approve(address(registry), type(uint256).max);
    }

    function _ask(address actor, bytes memory body) internal returns (bytes32 id) {
        vm.prank(actor);
        id = registry.ask(body);
    }

    function _ask() internal returns (bytes32 id) {
        return _ask(alice, bytes("{}"));
    }

    function _attestation(bytes32 id, bytes memory answer) internal view returns (OracleAttestation memory a) {
        uint64 timestamp = uint64(vm.getBlockTimestamp());
        a = OracleAttestation({
            requestId: keccak256(abi.encode("oracle UUID, distinct from intake id", id)),
            chainId: 1,
            questionHash: QUESTION,
            answerType: 2,
            answer: answer,
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: keccak256("closing block"),
            panelJobId: keccak256(abi.encode("panel job", id)),
            panelSize: 15,
            quorum: 11,
            agreed: 11,
            issuedAt: timestamp,
            expiresAt: timestamp + 1 days
        });
    }

    function _sign(OracleAttestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, registry.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 id, OracleAttestation memory a, bytes memory signature) internal {
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, a, signature)), "callback exceeded 200k or reverted");
    }

    function _fail(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered) internal {
        vm.prank(writer);
        assertTrue(
            intake.complete(id, status, abi.encode(id, status, reason, agreed, answered, bytes(""))),
            "failure hook exceeded 200k or reverted"
        );
    }

    function _assertUnverified(bytes32 id, bytes memory answer) internal view {
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        assertFalse(a.verified);
        assertEq(a.answerHash, keccak256(answer));
        if (answer.length <= 32) assertEq(a.answer, answer);
    }
}
