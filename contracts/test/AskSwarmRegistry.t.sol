// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";

/// Runs against a mainnet fork: `forge test --fork-url $ETH_RPC_URL`.
/// Intake v2 and IMD are the real contracts; the plane's writer is impersonated to deliver results.
contract AskSwarmRegistryTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    uint256 constant TEST_PK = 0xA11CE;
    address user = makeAddr("user");
    AskSwarmRegistry reg; // signer = test key, so we can mint attestations
    AskSwarmRegistry regReal; // signer = real oracle key, for the compatibility check
    Harness harness;

    bytes constant BODY =
        '{"v":1,"question":"What is the ISO 4217 currency code of the Swiss franc? Answer with the three-letter code only.","chainId":1,"window":{"hours":24},"answerType":"bytes32","evidence":"panel","panelSize":15,"quorum":11,"validForSeconds":86400}';

    function setUp() public {
        reg = new AskSwarmRegistry(INTAKE, IMD, vm.addr(TEST_PK));
        regReal = new AskSwarmRegistry(INTAKE, IMD, ORACLE_SIGNER);
        harness = new Harness(INTAKE, IMD, ORACLE_SIGNER);
        deal(IMD, user, 10 ether);
    }

    /// The attestation the plane published for request a9a6d603 (CHF, 11/15). Our digest must
    /// recover the plane's signer, or onOracleResult would mark every real answer unverified.
    function realAttestation() internal pure returns (OracleAttestation memory a, bytes memory sig) {
        a = OracleAttestation({
            requestId: 0xa9a6d603dc404a9a885aedaed0dd070100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x5469be20bf981ae338c943c2653fa25c5ae801277207ac6e19a7799aef4314d9,
            answerType: 2,
            answer: hex"4348460000000000000000000000000000000000000000000000000000000000",
            figure: 0,
            fromBlock: 26205587,
            toBlock: 26212764,
            blockHash: 0x6406fe64724498f8e878e7a7f353c530c8959bbf595c0924cdfc2b913351150f,
            panelJobId: 0x989b11b909854ce38be2331572ebce2100000000000000000000000000000000,
            panelSize: 15,
            quorum: 11,
            agreed: 11,
            issuedAt: 1792246129,
            expiresAt: 1792332529
        });
        sig =
            hex"2996f85dc582ecaa865d948b1804e559da3b155923d98269856952889d7d33a6249f3d0b0bc8915ccfbd07c436e39058da4f3e5179073afb5923aae3ab2678041b";
    }

    function test_digestMatchesPlaneSignature() public view {
        (OracleAttestation memory a, bytes memory sig) = realAttestation();
        // a9a6d603 was asked without a callback, so the plane signed it under verifyingContract 0.
        bytes32 d = harness.digestUnder(a, address(0));
        (bytes32 r, bytes32 s, uint8 v) = _split(sig);
        assertEq(ecrecover(d, v, r, s), ORACLE_SIGNER, "digest does not recover the oracle signer");
    }

    function test_askPullsPriceAndRegisters() public {
        uint256 p = reg.price();
        assertEq(p, 0.5 ether, "price");
        vm.startPrank(user);
        IERC20Like(IMD).approve(address(reg), p);
        bytes32 id = reg.ask(BODY);
        vm.stopPrank();
        (address payer, address target, bytes4 sel, bool completed) = IIntake(INTAKE).requests(id);
        assertEq(payer, address(reg));
        assertEq(target, address(reg));
        assertEq(sel, reg.onOracleResult.selector);
        assertFalse(completed);
        (AskSwarmRegistry.Ask memory k,) = reg.get(id);
        assertEq(k.asker, user);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
        assertEq(IERC20Like(IMD).balanceOf(address(reg)), 0, "registry must hold nothing");
        assertEq(IERC20Like(IMD).balanceOf(user), 10 ether - p);
    }

    function test_answerDeliveredWithinStipendAndVerified() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x1111, hex"434846", 2, 11);
        bytes memory sig = _sign(reg, a);

        vm.recordLogs();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(id, 0, keccak256("doc"), "https://api.imd.fun/x", abi.encode(id, a, sig));

        // Intake's Completed(...) event carries `delivered`; false would mean our callback reverted
        // or ran past the 200k stipend.
        assertTrue(_delivered(), "callback not delivered within stipend");

        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered));
        assertTrue(ans.verified, "signature should verify");
        assertEq(ans.answer, hex"434846");
        assertEq(ans.answerHash, keccak256(hex"434846"));
        assertEq(ans.agreed, 11);
        (bytes32 latest, AskSwarmRegistry.Answer memory byQ) = reg.answerOf(bytes32(uint256(0x1111)));
        assertEq(latest, id);
        assertEq(byQ.answer, hex"434846");
        assertEq(reg.asked(), 1);
    }

    function test_badSignatureStoredUnverifiedAndNotIndexed() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x2222, hex"01", 0, 9);
        bytes memory sig = _sign(reg, a);
        a.agreed = 10; // tamper after signing
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(id, 0, bytes32(0), "", abi.encode(id, a, sig));
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertFalse(ans.verified);
        (bytes32 latest,) = reg.answerOf(bytes32(uint256(0x2222)));
        assertEq(latest, bytes32(0), "unverified answers must not become the canonical one");
        assertEq(ans.answer, hex"01", "short answers round-trip exactly");
    }

    function test_failureRecorded() public {
        bytes32 id = _ask();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(id, 2, bytes32(0), "", abi.encode(id, uint8(2), bytes32("disagreed"), uint16(10), uint16(14), bytes("")));
        (AskSwarmRegistry.Ask memory k,) = reg.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.NoResult));
    }

    function test_onlyIntakeCanDeliver() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x3333, hex"01", 0, 9);
        vm.expectRevert(AskSwarmRegistry.NotIntake.selector);
        reg.onOracleResult(id, a, "");
        vm.expectRevert(AskSwarmRegistry.NotIntake.selector);
        reg.onFailure(id, 2, 0, 0, 0, "");
    }

    function test_largeAnswerStillWithinStipend() public {
        // address[] answers are the biggest the oracle returns; 10 addresses = 352 bytes.
        bytes32 id = _ask();
        bytes memory big = new bytes(352);
        for (uint256 i; i < big.length; i++) big[i] = bytes1(uint8(i));
        OracleAttestation memory a = _mint(id, 0x4444, big, 4, 11);
        bytes memory sig = _sign(reg, a);
        vm.recordLogs();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(id, 0, bytes32(0), "", abi.encode(id, a, sig));
        assertTrue(_delivered(), "352-byte answer must fit the stipend");
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertTrue(ans.verified);
        assertEq(ans.answer.length, 0, "long answers are not stored inline");
        assertEq(ans.answerHash, keccak256(big), "but their hash is");
        assertEq(ans.agreed, 11);
    }

    function test_domainIsTheCallbackContract() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x6666, hex"01", 0, 11);
        // Signed for verifyingContract 0 instead of the registry: must not verify.
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(TEST_PK, harness.digestUnder(a, address(0)));
        vm.prank(INTAKE);
        reg.onOracleResult(id, a, abi.encodePacked(r, s2, v));
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertFalse(ans.verified, "wrong domain must not verify");
    }

    function test_quorumAndExpiryGateVerified() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x7777, hex"01", 0, 10); // agreed 10 < quorum 11
        bytes memory sig = _sign(reg, a);
        vm.prank(INTAKE);
        reg.onOracleResult(id, a, sig);
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertFalse(ans.verified, "agreed below quorum is not canonical");
        assertEq(ans.agreed, 10, "but is recorded");
    }

    /// Direct measurement of the callback's gas, both the common case and the worst case, so the
    /// margin under Intake's 200k stipend is a number in the test output, not a guess.
    function test_callbackGasMargin() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0x5555, hex"4348460000000000000000000000000000000000000000000000000000000000", 2, 11);
        bytes memory sig = _sign(reg, a);
        vm.prank(INTAKE);
        uint256 g0 = gasleft();
        reg.onOracleResult(id, a, sig);
        uint256 used = g0 - gasleft();
        emit log_named_uint("onOracleResult gas, bytes32 answer", used);
        assertLt(used, 150_000, "need >=50k margin under the 200k stipend");

        bytes32 id2 = _ask();
        bytes memory big = new bytes(352);
        OracleAttestation memory b = _mint(id2, 0x5555, big, 4, 11); // same question hash: warm slot path
        bytes memory sig2 = _sign(reg, b);
        vm.prank(INTAKE);
        g0 = gasleft();
        reg.onOracleResult(id2, b, sig2);
        used = g0 - gasleft();
        emit log_named_uint("onOracleResult gas, 352-byte answer", used);
        assertLt(used, 150_000);
    }

    function _deliver(bytes32 id, OracleAttestation memory a, bytes memory sig) internal {
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(id, 0, bytes32(0), "", abi.encode(id, a, sig));
    }

    /// H1 from review: a 2-of-2 panel must not displace an 11-of-15 answer for the same question;
    /// a 16-of-20 panel may.
    function test_weakPanelCannotOverwriteStrongAnswer() public {
        bytes32 strong = _ask();
        OracleAttestation memory a = _mintP(strong, 0x9999, hex"01", 0, 15, 11, 11, uint64(block.timestamp + 1 days));
        _deliver(strong, a, _sign(reg, a));
        assertEq(reg.latestFor(bytes32(uint256(0x9999))), strong);

        bytes32 weak = _ask();
        OracleAttestation memory w = _mintP(weak, 0x9999, hex"00", 0, 2, 2, 2, uint64(block.timestamp + 1 days));
        _deliver(weak, w, _sign(reg, w));
        assertEq(reg.latestFor(bytes32(uint256(0x9999))), strong, "weak panel must not win");
        (AskSwarmRegistry.Ask memory kw, AskSwarmRegistry.Answer memory aw) = reg.get(weak);
        assertTrue(aw.verified, "still recorded as a verified delivery");
        assertEq(uint8(kw.status), uint8(AskSwarmRegistry.Status.Answered));

        bytes32 stronger = _ask();
        OracleAttestation memory st = _mintP(stronger, 0x9999, hex"00", 0, 20, 14, 16, uint64(block.timestamp + 1 days));
        _deliver(stronger, st, _sign(reg, st));
        assertEq(reg.latestFor(bytes32(uint256(0x9999))), stronger, "stronger panel wins");

        (bytes32 filtered,) = reg.answerOf(bytes32(uint256(0x9999)), 50, 40);
        assertEq(filtered, bytes32(0), "filter above what is held returns nothing");
        (filtered,) = reg.answerOf(bytes32(uint256(0x9999)), 20, 16);
        assertEq(filtered, stronger);
    }

    function test_signatureEdges() public {
        vm.expectRevert(AskSwarmRegistry.ZeroAddress.selector);
        new AskSwarmRegistry(INTAKE, IMD, address(0));

        bytes32 id = _ask();
        OracleAttestation memory a = _mint(id, 0xaaaa, hex"01", 0, 11);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PK, reg.digest(a));
        // high-s malleated twin: must not verify
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(uint256(n) - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        vm.prank(INTAKE);
        reg.onOracleResult(id, a, abi.encodePacked(r, s2, v2));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertFalse(ans.verified, "high-s rejected");
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));

        // 64-byte signature: rejected
        bytes32 id2 = _ask();
        OracleAttestation memory b = _mint(id2, 0xaaab, hex"01", 0, 11);
        (, bytes32 r3, bytes32 s3) = vm.sign(TEST_PK, reg.digest(b));
        vm.prank(INTAKE);
        reg.onOracleResult(id2, b, abi.encodePacked(r3, s3));
        (, ans) = reg.get(id2);
        assertFalse(ans.verified, "64-byte rejected");

        // v given as 0/1: accepted
        bytes32 id3 = _ask();
        OracleAttestation memory c = _mint(id3, 0xaaac, hex"01", 0, 11);
        (uint8 v4, bytes32 r4, bytes32 s4) = vm.sign(TEST_PK, reg.digest(c));
        vm.prank(INTAKE);
        reg.onOracleResult(id3, c, abi.encodePacked(r4, s4, uint8(v4 - 27)));
        (, ans) = reg.get(id3);
        assertTrue(ans.verified, "v 0/1 accepted");
    }

    function test_expiredAtDeliveryAndAnswerBoundaries() public {
        // expired at delivery: verified (signature is good) but never indexed
        bytes32 id = _ask();
        OracleAttestation memory a = _mintP(id, 0xbbbb, hex"01", 0, 15, 11, 11, uint64(block.timestamp + 10));
        bytes memory sig = _sign(reg, a);
        vm.warp(block.timestamp + 11);
        _deliver(id, a, sig);
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertTrue(ans.verified, "signature still good");
        assertEq(reg.latestFor(bytes32(uint256(0xbbbb))), bytes32(0), "expired is not indexed");
        assertFalse(reg.isCurrent(bytes32(uint256(0xbbbb))));

        // answer length boundaries through the real Intake
        uint256[4] memory lens = [uint256(0), 31, 32, 33];
        for (uint256 i; i < 4; i++) {
            bytes memory ansBytes = new bytes(lens[i]);
            for (uint256 j; j < ansBytes.length; j++) ansBytes[j] = bytes1(uint8(0x41 + j));
            bytes32 idn = _ask();
            OracleAttestation memory an = _mint(idn, 0xcc00 + i, ansBytes, 2, 11);
            vm.recordLogs();
            _deliver(idn, an, _sign(reg, an));
            assertTrue(_delivered(), "delivered");
            (, AskSwarmRegistry.Answer memory got) = reg.get(idn);
            assertTrue(got.verified);
            assertEq(got.answerHash, keccak256(ansBytes));
            if (lens[i] <= 32) assertEq(got.answer, ansBytes, "inline round-trip");
            else assertEq(got.answer.length, 0, "33 bytes stored by hash only");
        }

        // a hostile 100 KB answer is recorded Unverified cheaply and still delivered
        bytes32 idh = _ask();
        OracleAttestation memory h = _mint(idh, 0xdddd, new bytes(100_000), 4, 11);
        vm.recordLogs();
        _deliver(idh, h, "");
        assertTrue(_delivered(), "huge answer must not run the callback out of gas");
        (AskSwarmRegistry.Ask memory kh,) = reg.get(idh);
        assertEq(uint8(kh.status), uint8(AskSwarmRegistry.Status.Unverified));
    }

    // ---- helpers ----

    function _ask() internal returns (bytes32 id) {
        vm.startPrank(user);
        IERC20Like(IMD).approve(address(reg), type(uint256).max);
        id = reg.ask(BODY);
        vm.stopPrank();
    }

    function _mint(bytes32 id, uint256 qh, bytes memory answer, uint8 t, uint16 agreed)
        internal
        view
        returns (OracleAttestation memory a)
    {
        return _mintP(id, qh, answer, t, 15, 11, agreed, uint64(block.timestamp + 1 days));
    }

    function _mintP(bytes32 id, uint256 qh, bytes memory answer, uint8 t, uint16 panel, uint16 quorum, uint16 agreed, uint64 expiresAt)
        internal
        view
        returns (OracleAttestation memory a)
    {
        a = OracleAttestation({
            requestId: id,
            chainId: block.chainid,
            questionHash: bytes32(qh),
            answerType: t,
            answer: answer,
            figure: 0,
            fromBlock: uint64(block.number - 10),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: bytes32(uint256(7)),
            panelSize: panel,
            quorum: quorum,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt
        });
    }

    function _sign(AskSwarmRegistry r, OracleAttestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(TEST_PK, r.digest(a));
        return abi.encodePacked(rr, ss, v);
    }

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    function _delivered() internal returns (bool d) {
        // not view: getRecordedLogs drains the recorder
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Completed(bytes32,uint8,bytes32,string,bool)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == INTAKE && logs[i].topics[0] == topic) {
                (,,, d) = abi.decode(logs[i].data, (uint8, bytes32, string, bool));
                return d;
            }
        }
        revert("no Completed event");
    }
}

/// Exposes the digest under an arbitrary verifyingContract, to check hashing against a published attestation.
contract Harness is AskSwarmRegistry {
    constructor(address i, address m, address s) AskSwarmRegistry(i, m, s) {}

    function digestUnder(OracleAttestation calldata a, address vc) external view returns (bytes32) {
        return _digestUnder(a, _domain(vc));
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
