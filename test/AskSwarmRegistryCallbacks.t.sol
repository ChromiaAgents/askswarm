// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

contract AskSwarmRegistryCallbacksTest is RegistryTestSupport {
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

    function test_eachOfTheFifteenFieldsIsBoundByTheSignature() public {
        for (uint8 field; field < 15; ++field) {
            bytes32 id = _ask();
            OracleAttestation memory a = _attestation(id, abi.encode(uint256(42)));
            bytes memory signature = _sign(a);
            if (field == 0) a.requestId ^= bytes32(uint256(1));
            else if (field == 1) a.chainId ^= 1;
            else if (field == 2) a.questionHash ^= bytes32(uint256(1));
            else if (field == 3) a.answerType ^= 1;
            else if (field == 4) a.answer[0] ^= 0x01;
            else if (field == 5) a.figure ^= 1;
            else if (field == 6) a.fromBlock ^= 1;
            else if (field == 7) a.toBlock ^= 1;
            else if (field == 8) a.blockHash ^= bytes32(uint256(1));
            else if (field == 9) a.panelJobId ^= bytes32(uint256(1));
            else if (field == 10) a.panelSize ^= 1;
            else if (field == 11) a.quorum ^= 1;
            else if (field == 12) a.agreed ^= 1;
            else if (field == 13) a.issuedAt ^= 1;
            else a.expiresAt ^= 1;
            _deliver(id, a, signature);
            _assertUnverified(id, a.answer);
            assertEq(registry.latestFor(a.questionHash), bytes32(0), "tampered field indexed");
        }
    }

    function test_wrongSignerCannotReplaceHeldAnswer() public {
        bytes32 held = _store("held", 15, 11, 11, START + 1 days);
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, bytes("forged"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_KEY, registry.digest(a));
        _deliver(id, a, abi.encodePacked(r, s, v));
        _assertUnverified(id, a.answer);
        assertEq(registry.latestFor(QUESTION), held);
    }

    function test_signatureForAnotherConsumerIsNotReusable() public {
        AskSwarmRegistry other = new AskSwarmRegistry(address(intake), address(token), vm.addr(SIGNING_KEY));
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, bytes("answer"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, other.digest(a));
        _deliver(id, a, abi.encodePacked(r, s, v));
        _assertUnverified(id, a.answer);
        assertEq(registry.latestFor(QUESTION), bytes32(0));
    }

    function test_wrongDomainChainNameAndVersionAreRejected() public {
        for (uint8 variant; variant < 3; ++variant) {
            bytes32 id = _ask();
            OracleAttestation memory a = _attestation(id, bytes("answer"));
            bytes32 domain = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(variant == 0 ? "Incorrect Oracle" : "IdentityMD Oracle")),
                    keccak256(bytes(variant == 1 ? "1" : "2")),
                    variant == 2 ? uint256(8453) : uint256(1),
                    address(registry)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, _digestUnder(a, domain));
            _deliver(id, a, abi.encodePacked(r, s, v));
            _assertUnverified(id, a.answer);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_non65ByteSignaturesNeverVerify(uint16 rawLength, bytes32 contents) public {
        uint256 length = bound(rawLength, 0, 512);
        if (length == 65) length = 66;
        bytes memory signature = new bytes(length);
        for (uint256 i; i < length; ++i) {
            signature[i] = contents[i % 32];
        }
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, hex"01");
        _deliver(id, a, signature);
        _assertUnverified(id, a.answer);
        assertEq(registry.latestFor(QUESTION), bytes32(0));
    }

    function test_invalidVAndZeroRecoveryAreRejected() public {
        uint8[5] memory invalidVs = [uint8(2), 26, 29, 35, 255];
        for (uint256 i; i < invalidVs.length; ++i) {
            bytes32 id = _ask();
            OracleAttestation memory a = _attestation(id, hex"01");
            (, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, registry.digest(a));
            _deliver(id, a, abi.encodePacked(r, s, invalidVs[i]));
            _assertUnverified(id, a.answer);
        }
        bytes32 zeroId = _ask();
        OracleAttestation memory zero = _attestation(zeroId, hex"01");
        _deliver(zeroId, zero, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        _assertUnverified(zeroId, zero.answer);
    }

    function test_falseIsAVerifiedAnswerAndNotAFailure() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, abi.encode(false));
        a.answerType = 0;
        _deliver(id, a, _sign(a));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory answer) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered));
        assertTrue(answer.verified);
        assertFalse(abi.decode(answer.answer, (bool)));
        assertEq(registry.latestFor(QUESTION), id);
        assertTrue(registry.isCurrent(QUESTION));
    }

    function test_intakeAndOracleRequestIdsMayDiffer() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, abi.encode(uint256(9)));
        assertNotEq(id, a.requestId);
        _deliver(id, a, _sign(a));
        (, AskSwarmRegistry.Answer memory answer) = registry.get(id);
        assertTrue(answer.verified, "oracle UUID is deliberately not the intake id");
        (AskSwarmRegistry.Ask memory oracleIdRecord,) = registry.get(a.requestId);
        assertEq(uint8(oracleIdRecord.status), uint8(AskSwarmRegistry.Status.None));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_shortAnswerRoundTripsIncludingZeros(bytes32 word, uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 32);
        bytes memory expected = new bytes(length);
        for (uint256 i; i < length; ++i) {
            expected[i] = word[i];
        }
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, expected);
        _deliver(id, a, _sign(a));
        _assertStored(id, a);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_longAnswerHashAndEventPreserveEveryByte(uint16 rawLength, bytes32 word) public {
        uint256 length = bound(rawLength, 33, 4096);
        bytes memory expected = new bytes(length);
        for (uint256 i; i < length; ++i) {
            expected[i] = word[i % 32];
        }
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, expected);
        a.answerType = 5;
        bytes memory signature = _sign(a);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Answered(
            id, a.questionHash, a.answerType, expected, a.figure, a.agreed, a.quorum, a.panelSize, a.expiresAt, true
        );
        _deliver(id, a, signature);
        _assertStored(id, a);
    }

    function test_maximumAcceptedAnswerFitsColdCallbackStipend() public {
        bytes memory answer = new bytes(4096);
        for (uint256 i; i < answer.length; ++i) {
            answer[i] = 0xff;
        }
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, answer);
        bytes memory signature = _sign(a);
        vm.cool(address(registry));
        _deliver(id, a, signature);
        _assertStored(id, a);
    }

    function test_firstByteOverCapIsUnverifiedAndDoesNotDisplaceHeldAnswer() public {
        bytes32 held = _store("held", 15, 11, 11, START + 1 days);
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, new bytes(4097));
        bytes memory signature = _sign(a);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Answered(
            id, a.questionHash, a.answerType, "", a.figure, a.agreed, a.quorum, a.panelSize, a.expiresAt, false
        );
        _deliver(id, a, signature);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory answer) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        assertFalse(answer.verified);
        assertEq(registry.latestFor(QUESTION), held);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_nonzeroAbiPaddingCannotLeakIntoShortAnswer() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, hex"ab");
        bytes memory data = abi.encodeCall(registry.onOracleResult, (id, a, _sign(a)));
        uint256 tupleOffset;
        uint256 answerOffset;
        assembly {
            tupleOffset := mload(add(data, 68)) // selector + first argument
            answerOffset := mload(add(add(data, 36), add(tupleOffset, 128))) // a.answer
        }
        uint256 answerStart = 4 + tupleOffset + answerOffset + 32;
        assertEq(uint8(data[answerStart]), 0xab, "fixture located the answer");
        for (uint256 i = 1; i < 32; ++i) {
            data[answerStart + i] = 0xff;
        }
        vm.prank(address(intake));
        (bool ok,) = address(registry).call{gas: 200_000}(data);
        assertTrue(ok);
        _assertStored(id, a);
    }

    function test_bothFailureStatusesPreserveFeeAndEmitReasonAndCounts() public {
        bytes32 held = _store("held", 15, 11, 11, START + 1 days);
        uint256 paidBefore = token.balanceOf(recipient);
        for (uint8 status = 1; status <= 2; ++status) {
            bytes32 id = _ask();
            bytes32 reason = status == 1 ? bytes32("body_refused") : bytes32("disagreed");
            uint16 agreed = status == 1 ? 0 : 10;
            uint16 answered = status == 1 ? 0 : 14;
            vm.expectEmit(true, false, false, true, address(registry));
            emit Failed(id, status, reason, agreed, answered);
            _fail(id, status, reason, agreed, answered);
            (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
            assertEq(
                uint8(k.status), uint8(status == 1 ? AskSwarmRegistry.Status.Refused : AskSwarmRegistry.Status.NoResult)
            );
            assertFalse(a.verified);
            assertEq(k.asker, alice);
            assertEq(k.askedAt, START);
            assertEq(registry.latestFor(QUESTION), held);
        }
        assertEq(token.balanceOf(recipient), paidBefore + 1 ether, "failure does not refund the fee");
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_thirdPartyCannotCompleteOrCallEitherHook() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _attestation(id, hex"01");
        bytes memory signature = _sign(a);
        vm.prank(bob);
        vm.expectRevert(RecordingIntake.NotWriter.selector);
        intake.complete(id, 0, abi.encode(id, a, signature));
        vm.prank(bob);
        vm.expectRevert(AskSwarmRegistry.NotIntake.selector);
        registry.onOracleResult(id, a, signature);
        vm.prank(bob);
        vm.expectRevert(AskSwarmRegistry.NotIntake.selector);
        registry.onFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        (AskSwarmRegistry.Ask memory k,) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
        assertFalse(intake.requestInfo(id).completed);
    }

    function test_registeredCallbackWithForeignRequestIdCannotCreateAnAsk() public {
        bytes32 foreignId = keccak256("paid outside this registry");
        OracleAttestation memory a = _attestation(foreignId, hex"01");
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, foreignId));
        registry.onOracleResult(foreignId, a, signature);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, foreignId));
        registry.onFailure(foreignId, 2, bytes32("disagreed"), 1, 2, "");
        assertEq(registry.asked(), 0);
        assertEq(registry.latestFor(QUESTION), bytes32(0));
    }

    /// This is the Intake transport's once-only guarantee, not a claim that the registry has
    /// a local Pending guard. The transport records completion before attempting a callback.
    function test_transportWillNotRetrySuccessOrFailure() public {
        bytes32 successful = _store("answer", 15, 11, 11, START + 1 days);
        bytes32 failed = _ask();
        _fail(failed, 1, bytes32("body_invalid"), 0, 0);
        bytes32[2] memory ids = [successful, failed];
        for (uint256 i; i < ids.length; ++i) {
            OracleAttestation memory a = _attestation(ids[i], bytes("replacement"));
            bytes memory signature = _sign(a);
            vm.prank(writer);
            vm.expectRevert(RecordingIntake.AlreadyCompleted.selector);
            intake.complete(ids[i], 0, abi.encode(ids[i], a, signature));
        }
        (, AskSwarmRegistry.Answer memory saved) = registry.get(successful);
        assertEq(saved.answer, bytes("answer"));
        (AskSwarmRegistry.Ask memory refusal,) = registry.get(failed);
        assertEq(uint8(refusal.status), uint8(AskSwarmRegistry.Status.Refused));
    }

    function test_timeAndMinimumFiltersDoNotDeleteHistoricalRecord() public {
        bytes32 id = _store("history", 15, 11, 11, START + 10);
        (bytes32 exact,) = registry.answerOf(QUESTION, 15, 11);
        assertEq(exact, id);
        (bytes32 panelTooHigh, AskSwarmRegistry.Answer memory empty) = registry.answerOf(QUESTION, 16, 11);
        assertEq(panelTooHigh, bytes32(0));
        assertFalse(empty.verified);
        (bytes32 agreementTooHigh,) = registry.answerOf(QUESTION, 15, 12);
        assertEq(agreementTooHigh, bytes32(0));
        vm.warp(START + 10);
        assertTrue(registry.isCurrent(QUESTION));
        (exact,) = registry.answerOf(QUESTION, 15, 11);
        assertEq(exact, id, "valid at expiry");
        vm.warp(START + 11);
        assertFalse(registry.isCurrent(QUESTION));
        (bytes32 expired,) = registry.answerOf(QUESTION, 0, 0);
        assertEq(expired, bytes32(0));
        (bytes32 historical, AskSwarmRegistry.Answer memory saved) = registry.answerOf(QUESTION);
        assertEq(historical, id);
        assertEq(saved.answer, bytes("history"));
        assertTrue(saved.verified, "verified describes delivery, isCurrent describes freshness");
    }

    function test_unknownReadsDoNotLookAnswered() public view {
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(keccak256("unknown"));
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.None));
        assertEq(k.asker, address(0));
        assertFalse(a.verified);
        assertEq(a.answer.length, 0);
        assertFalse(registry.isCurrent(QUESTION));
        (bytes32 id,) = registry.answerOf(QUESTION);
        assertEq(id, bytes32(0));
        (id,) = registry.answerOf(QUESTION, 1, 1);
        assertEq(id, bytes32(0));
    }

    function test_bothPanelSizeAndAgreementMustBeAtLeastAsStrong() public {
        bytes32 held = _store("held", 15, 11, 11, START + 1 days);
        _store("bigger panel but fewer agreeing", 17, 10, 10, START + 1 days);
        assertEq(registry.latestFor(QUESTION), held);
        _store("more agreeing but smaller panel", 14, 12, 12, START + 1 days);
        assertEq(registry.latestFor(QUESTION), held);
        bytes32 equal = _store("same strength", 15, 11, 11, START + 1 days);
        assertEq(registry.latestFor(QUESTION), equal);
        bytes32 stronger = _store("stronger", 17, 12, 12, START + 1 days);
        assertEq(registry.latestFor(QUESTION), stronger);
    }

    function test_weakerMajorityCanReplaceOnlyAfterHeldAnswerExpires() public {
        bytes32 held = _store("held", 15, 11, 11, START + 10);
        vm.warp(START + 10);
        _store("weak at expiry", 2, 2, 2, START + 1 days);
        assertEq(registry.latestFor(QUESTION), held);
        vm.warp(START + 11);
        bytes32 fresh = _store("weak after expiry", 2, 2, 2, START + 1 days);
        assertEq(registry.latestFor(QUESTION), fresh);
        assertTrue(registry.isCurrent(QUESTION));
        (, AskSwarmRegistry.Answer memory old) = registry.get(held);
        assertEq(old.answer, bytes("held"));
    }

    function _store(bytes memory answer, uint16 panel, uint16 quorum, uint16 agreed, uint64 expiry)
        internal
        returns (bytes32 id)
    {
        id = _ask();
        OracleAttestation memory a = _attestation(id, answer);
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        a.expiresAt = expiry;
        _deliver(id, a, _sign(a));
    }

    function _assertStored(bytes32 id, OracleAttestation memory expected) internal view {
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = registry.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered));
        assertEq(k.asker, alice);
        assertEq(k.askedAt, START);
        assertTrue(a.verified);
        assertEq(a.questionHash, expected.questionHash);
        assertEq(a.answerHash, keccak256(expected.answer));
        if (expected.answer.length <= 32) assertEq(a.answer, expected.answer);
        else assertEq(a.answer.length, 0);
        assertEq(a.answerType, expected.answerType);
        assertEq(a.panelSize, expected.panelSize);
        assertEq(a.quorum, expected.quorum);
        assertEq(a.agreed, expected.agreed);
        assertEq(a.issuedAt, expected.issuedAt);
        assertEq(a.expiresAt, expected.expiresAt);
        assertEq(registry.latestFor(expected.questionHash), id);
    }

    // Canonical protocol hash fields, used only to produce deliberately wrong domains. Positive
    // compatibility is independently anchored by OracleConsumerConformance.t.sol's fixed vector.
    function _digestUnder(OracleAttestation memory a, bytes32 domain) internal pure returns (bytes32) {
        bytes32 typeHash = keccak256(
            "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    typeHash,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
