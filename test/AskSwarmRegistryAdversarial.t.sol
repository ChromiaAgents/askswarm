// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport} from "./helpers/RegistryTestSupport.sol";

/// Asks on behalf of whoever calls it, so the registry's asker is this contract, not tx.origin.
contract AskingContract {
    function approveAndAsk(AskSwarmRegistry registry, address imd, uint256 amount, bytes calldata body)
        external
        returns (bytes32)
    {
        (bool ok,) = imd.call(abi.encodeWithSignature("approve(address,uint256)", address(registry), amount));
        require(ok);
        return registry.ask(body);
    }
}

/// Calls a target with Intake's 200k stipend and reports the gas the call consumed.
contract StipendProbe {
    function call200k(address target, bytes calldata data) external returns (bool ok, uint256 used) {
        uint256 before = gasleft();
        (ok,) = target.call{gas: 200_000}(data);
        used = before - gasleft();
    }
}

/// Inputs the earlier suites did not drive: hostile answer sizes far past the cap, the worst-case
/// storage path at the cap, unexpected failure status codes, the full verification predicate under
/// one fuzzed attestation, and a contract (not an EOA) as the asker.
contract AskSwarmRegistryAdversarialTest is RegistryTestSupport {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    event Asked(bytes32 indexed requestId, address indexed asker, bytes body);

    /// A writer relaying an answer of any size past the cap must not strand the ask Pending by
    /// running the callback out of Intake's 200k stipend: the over-cap branch never touches the bytes.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_oversizedAnswersOfAnySizeSettleInsideStipend(uint24 rawLength) public {
        uint256 length = bound(rawLength, 4097, 64 * 1024);
        bytes32 held = _held();
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, new bytes(length));
        a.panelSize = 100;
        a.quorum = 100;
        a.agreed = 100;
        vm.cool(address(registry));
        _deliver(id, a, _sign(a));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory stored) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        assertFalse(stored.verified);
        assertEq(stored.answerHash, bytes32(0), "over-cap bytes were hashed or stored");
        assertEq(stored.questionHash, bytes32(0));
        assertEq(registry.latestFor(QUESTION), held, "over-cap answer moved the index");
    }

    /// The most expensive accepted path: a 4096-byte verified majority that displaces a held answer,
    /// with every registry slot cold. It must be delivered, stored and indexed.
    function test_maximumAnswerDisplacingAHeldAnswerFitsColdStipend() public {
        _held();
        bytes memory answer = new bytes(4096);
        for (uint256 i; i < answer.length; ++i) {
            answer[i] = bytes1(uint8(i));
        }
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, answer);
        a.panelSize = 100;
        a.quorum = 51;
        a.agreed = 100;
        bytes memory signature = _sign(a);
        vm.cool(address(registry));
        _deliver(id, a, signature);
        assertEq(registry.latestFor(QUESTION), id);
        (, AskSwarmRegistry.Answer memory stored) = registry.get(id);
        assertTrue(stored.verified);
        assertEq(stored.answerHash, keccak256(answer));
        assertEq(stored.answer.length, 0, "long answers are only hashed in storage");
    }

    /// Callback gas measured where Intake spends it: a probe etched at the Intake address makes the
    /// 200k call itself, so the caller's own encoding is not counted. Every registry slot is cold and
    /// the question is fresh (the costliest index write). The brief quotes ~105k for the common case.
    function test_callbackGasAtTheStipendBoundary() public {
        (bool ok, uint256 used) = _measure(abi.encode(true), keccak256("fresh one-word question"));
        emit log_named_uint("onOracleResult gas, one-word answer, cold", used);
        assertTrue(ok);
        assertLt(used, 130_000, "common case lost its margin under the 200k stipend");

        bytes memory answer = new bytes(4096);
        for (uint256 i; i < answer.length; ++i) {
            answer[i] = 0xff;
        }
        (ok, used) = _measure(answer, keccak256("fresh maximum question"));
        emit log_named_uint("onOracleResult gas, 4096-byte answer, cold", used);
        assertTrue(ok);
        assertLt(used, 180_000, "maximum accepted answer within 20k of the stipend");
    }

    function _measure(bytes memory answer, bytes32 question) internal returns (bool ok, uint256 used) {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, answer);
        a.questionHash = question;
        bytes memory data = abi.encodeCall(registry.onOracleResult, (id, a, _sign(a)));
        bytes memory intakeCode = address(intake).code;
        vm.etch(address(intake), address(new StipendProbe()).code);
        vm.cool(address(registry));
        (ok, used) = StipendProbe(address(intake)).call200k(address(registry), data);
        vm.etch(address(intake), intakeCode);
        assertEq(registry.latestFor(question), id);
    }

    /// Intake v2 documents failure statuses 1 and 2 only. Whatever status a writer passes, the
    /// registry settles the ask once: 1 is a refusal, anything else no-result, and never verified.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_unexpectedFailureStatusesSettleAsNoResult(uint8 rawStatus, bytes32 reason, uint16 votes) public {
        uint8 status = uint8(bound(rawStatus, 1, 255));
        bytes32 held = _held();
        bytes32 id = _ask();
        vm.expectEmit(true, false, false, true, address(registry));
        emit AskSwarmRegistry.Failed(id, status, reason, votes, votes);
        _fail(id, status, reason, votes, votes);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        assertEq(
            uint8(k.status), uint8(status == 1 ? AskSwarmRegistry.Status.Refused : AskSwarmRegistry.Status.NoResult)
        );
        assertFalse(a.verified);
        assertEq(a.answerHash, bytes32(0));
        assertEq(registry.latestFor(QUESTION), held);

        // Settled: neither hook accepts it again, directly from Intake.
        OracleAttestation memory late = _attestation(id, hex"01");
        bytes memory signature = _sign(late);
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, id));
        registry.onOracleResult(id, late, signature);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, id));
        registry.onFailure(id, 1, reason, 0, 0, "");
        vm.stopPrank();
    }

    /// The whole verification predicate on one fuzzed attestation: `verified` holds exactly when the
    /// configured signer signed it under this registry's domain, agreed >= quorum, it is not expired,
    /// and it was not issued more than five minutes ahead. Each condition is driven on both sides.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_verifiedExactlyWhenEveryConditionHolds(
        uint16 rawPanel,
        uint16 rawQuorum,
        uint16 rawAgreed,
        uint32 rawExpiryOffset,
        uint32 rawIssuedOffset,
        uint8 signerChoice
    ) public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, hex"2a");
        a.panelSize = uint16(bound(rawPanel, 2, 100));
        a.quorum = uint16(bound(rawQuorum, 1, a.panelSize));
        a.agreed = uint16(bound(rawAgreed, 0, a.panelSize));
        // expiresAt and issuedAt straddle the clock by up to a day either way.
        int256 expiryOffset = int256(bound(rawExpiryOffset, 0, 2 days)) - 1 days;
        int256 issuedOffset = int256(bound(rawIssuedOffset, 0, 2 days)) - 1 days;
        a.expiresAt = uint64(uint256(int256(uint256(START)) + expiryOffset));
        a.issuedAt = uint64(uint256(int256(uint256(START)) + issuedOffset));

        uint256 choice = signerChoice % 3;
        bytes memory signature;
        if (choice == 0) {
            signature = _sign(a);
        } else if (choice == 1) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_KEY, registry.digest(a));
            signature = abi.encodePacked(r, s, v);
        } else {
            // Right key, wrong verifying contract.
            AskSwarmRegistry other = new AskSwarmRegistry(address(intake), address(token), vm.addr(SIGNING_KEY));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, other.digest(a));
            signature = abi.encodePacked(r, s, v);
        }
        _deliver(id, a, signature);

        bool expected = choice == 0 && a.agreed >= a.quorum && START <= a.expiresAt
            && a.issuedAt <= START + registry.ISSUED_AT_TOLERANCE();
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory stored) = registry.get(id);
        assertEq(stored.verified, expected);
        assertEq(
            uint8(k.status), uint8(expected ? AskSwarmRegistry.Status.Answered : AskSwarmRegistry.Status.Unverified)
        );
        assertEq(stored.answerHash, keccak256(a.answer), "every in-cap delivery is stored for the record");
        bool isIndexed = expected && uint256(a.agreed) * 2 > a.panelSize;
        assertEq(registry.latestFor(QUESTION), isIndexed ? id : bytes32(0));
        assertEq(registry.isCurrent(QUESTION), isIndexed);
    }

    /// The high-s twin of a valid signature, and both encodings of v, from the right key.
    function test_highSTwinIsUnverifiedWhileZeroOneVAreNormalised() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, hex"01");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, registry.digest(a));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        _deliver(id, a, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        _assertUnverified(id, a.answer);

        bytes32 second = _ask();
        OracleAttestation memory b = _attestation(second, hex"01");
        (v, r, s) = vm.sign(SIGNING_KEY, registry.digest(b));
        _deliver(second, b, abi.encodePacked(r, s, v - 27));
        (, AskSwarmRegistry.Answer memory stored) = registry.get(second);
        assertTrue(stored.verified, "0/1 recovery id is the same signature");
    }

    /// A contract that asks is the recorded asker and the sole payer; tx.origin is ignored.
    function test_contractAskerIsRecordedNotTxOrigin() public {
        AskingContract asker = new AskingContract();
        token.mint(address(asker), 1 ether);
        address origin = makeAddr("origin");
        bytes memory body = bytes("{\"v\":1}");
        uint256 originBalance = token.balanceOf(origin);
        vm.expectEmit(false, true, false, true, address(registry));
        emit Asked(bytes32(0), address(asker), body);
        vm.prank(alice, origin);
        bytes32 id = asker.approveAndAsk(registry, address(token), 0.5 ether, body);
        (address recorded, uint64 askedAt, AskSwarmRegistry.Status status) = registry.asks(id);
        assertEq(recorded, address(asker));
        assertEq(askedAt, START);
        assertEq(uint8(status), uint8(AskSwarmRegistry.Status.Pending));
        assertEq(token.balanceOf(address(asker)), 0.5 ether);
        assertEq(token.balanceOf(origin), originBalance);
        assertEq(token.allowance(address(asker), address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
    }

    /// Two asks from one caller with an identical body are two separate requests, each paid.
    function test_identicalBodiesAreDistinctPaidAsks() public {
        uint256 before = token.balanceOf(alice);
        bytes32 first = _ask(alice, bytes("same"));
        bytes32 second = _ask(alice, bytes("same"));
        assertTrue(first != second);
        assertEq(registry.asked(), 2);
        assertEq(before - token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(recipient), 1 ether);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    /// Reads never revert, even for a question or id nothing ever touched, and filtered reads with
    /// zero minimums still refuse a question that has no answer.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_readsOfUntouchedKeysAreEmpty(bytes32 key, uint16 minPanel, uint16 minAgreed) public view {
        (bytes32 id, AskSwarmRegistry.Answer memory a) = registry.answerOf(key);
        assertEq(id, bytes32(0));
        assertFalse(a.verified);
        assertEq(a.answerHash, bytes32(0));
        (id,) = registry.answerOf(key, minPanel, minAgreed);
        assertEq(id, bytes32(0));
        assertFalse(registry.isCurrent(key));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory b) = registry.get(key);
        assertEq(k.asker, address(0));
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.None));
        assertEq(b.answerHash, bytes32(0));
    }

    function _held() internal returns (bytes32 id) {
        id = _ask();
        OracleAttestation memory a = _attestation(id, "held");
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        _deliver(id, a, _sign(a));
        assertEq(registry.latestFor(QUESTION), id);
    }
}
