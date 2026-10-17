// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

/// Runs against a mainnet fork (`forge test --fork-url $ETH_RPC_URL`), where Intake v2 and IMD are the
/// real contracts and the plane's writer is impersonated to deliver results. Without a fork (plain
/// `forge test`, no network) the same tests run against mocks of Intake v2 and IMD etched at the real
/// addresses, on chain id 1 with a mainnet-like block and timestamp.
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
        if (INTAKE.code.length == 0) {
            vm.chainId(1);
            vm.roll(26_300_000);
            vm.warp(1_792_300_000);
            vm.etch(IMD, address(new MockERC20()).code);
            vm.etch(INTAKE, address(new MockIntake(makeAddr("writer"), IMD)).code);
        }
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
        IIntake(INTAKE)
            .complete(
                id, 2, bytes32(0), "", abi.encode(id, uint8(2), bytes32("disagreed"), uint16(10), uint16(14), bytes(""))
            );
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
        for (uint256 i; i < big.length; i++) {
            big[i] = bytes1(uint8(i));
        }
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
        OracleAttestation memory a =
            _mint(id, 0x5555, hex"4348460000000000000000000000000000000000000000000000000000000000", 2, 11);
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
        // expired at delivery: not verified, recorded Unverified, never indexed (audit finding c2c8fea2;
        // this test used to assert verified == true, the behaviour the brief rules out)
        bytes32 id = _ask();
        OracleAttestation memory a = _mintP(id, 0xbbbb, hex"01", 0, 15, 11, 11, uint64(block.timestamp + 10));
        bytes memory sig = _sign(reg, a);
        vm.warp(block.timestamp + 11);
        vm.recordLogs();
        _deliver(id, a, sig);
        assertTrue(_delivered(), "delivered");
        (AskSwarmRegistry.Ask memory ke, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertFalse(ans.verified, "expired at delivery is not verified");
        assertEq(uint8(ke.status), uint8(AskSwarmRegistry.Status.Unverified));
        assertEq(reg.latestFor(bytes32(uint256(0xbbbb))), bytes32(0), "expired is not indexed");
        assertFalse(reg.isCurrent(bytes32(uint256(0xbbbb))));

        // answer length boundaries through the real Intake
        uint256[4] memory lens = [uint256(0), 31, 32, 33];
        for (uint256 i; i < 4; i++) {
            bytes memory ansBytes = new bytes(lens[i]);
            for (uint256 j; j < ansBytes.length; j++) {
                ansBytes[j] = bytes1(uint8(0x41 + j));
            }
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

    /// Audit finding c2c8fea2, boundary: an attestation delivered exactly at `expiresAt` is still valid.
    function test_expiryBoundaryAtDelivery() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mintP(id, 0xbbbc, hex"01", 0, 15, 11, 11, uint64(block.timestamp + 10));
        bytes memory sig = _sign(reg, a);
        vm.warp(block.timestamp + 10);
        _deliver(id, a, sig);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        assertTrue(ans.verified, "valid at expiresAt");
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered));
        assertEq(reg.latestFor(bytes32(uint256(0xbbbc))), id);
    }

    /// Audit finding ddc3dd9c, as reported: a 100-seat, quorum-2 panel whose plurality got 11 votes
    /// must not displace an 11-of-15 answer.
    function test_minorityOfLargePanelCannotDisplaceSupermajority() public {
        bytes32 qh = bytes32(uint256(0xeeee));
        bytes32 strong = _ask();
        OracleAttestation memory a = _mintP(strong, 0xeeee, "CHF", 2, 15, 11, 11, uint64(block.timestamp + 1 days));
        _deliver(strong, a, _sign(reg, a));
        assertEq(reg.latestFor(qh), strong);

        bytes32 weak = _ask();
        OracleAttestation memory w = _mintP(weak, 0xeeee, "EUR", 2, 100, 2, 11, uint64(block.timestamp + 1 days));
        _deliver(weak, w, _sign(reg, w));
        assertEq(reg.latestFor(qh), strong, "11% answer must not displace a 73% one");
        (, AskSwarmRegistry.Answer memory held) = reg.answerOf(qh);
        assertEq(held.answer, bytes("CHF"));
        (AskSwarmRegistry.Ask memory kw, AskSwarmRegistry.Answer memory aw) = reg.get(weak);
        assertTrue(aw.verified, "still a verified delivery, for the record");
        assertEq(uint8(kw.status), uint8(AskSwarmRegistry.Status.Answered));

        // a majority of the larger panel still displaces it
        bytes32 maj = _ask();
        OracleAttestation memory m = _mintP(maj, 0xeeee, "EUR", 2, 100, 2, 51, uint64(block.timestamp + 1 days));
        _deliver(maj, m, _sign(reg, m));
        assertEq(reg.latestFor(qh), maj);
    }

    /// Audit finding ddc3dd9c: with nothing held, a minority answer is not indexed either; exactly half is not a majority.
    function test_minorityAnswerNotIndexedEvenWhenNothingHeld() public {
        bytes32 id = _ask();
        OracleAttestation memory a = _mintP(id, 0xef01, hex"01", 0, 20, 2, 10, uint64(block.timestamp + 1 days));
        _deliver(id, a, _sign(reg, a));
        assertEq(reg.latestFor(bytes32(uint256(0xef01))), bytes32(0), "10 of 20 is not a majority");
        assertFalse(reg.isCurrent(bytes32(uint256(0xef01))));

        bytes32 id2 = _ask();
        OracleAttestation memory b = _mintP(id2, 0xef01, hex"01", 0, 20, 2, 11, uint64(block.timestamp + 1 days));
        _deliver(id2, b, _sign(reg, b));
        assertEq(reg.latestFor(bytes32(uint256(0xef01))), id2, "11 of 20 is");
    }

    /// Whatever the panel shape, an indexed answer is verified, in its window (not expired, not issued
    /// more than the tolerance ahead of the clock) and a strict majority of its panel.
    function testFuzz_indexedAnswersAreMajorities(
        uint16 panel,
        uint16 quorum,
        uint16 agreed,
        uint32 ttl,
        uint32 late,
        uint32 ahead
    ) public {
        panel = uint16(bound(panel, 2, 100));
        quorum = uint16(bound(quorum, 1, panel));
        agreed = uint16(bound(agreed, 0, panel));
        uint64 issuedAt = uint64(block.timestamp + bound(ahead, 0, 10 minutes));
        uint64 expiresAt = uint64(block.timestamp + bound(ttl, 0, 30 days));
        bytes32 id = _ask();
        OracleAttestation memory a = _mintP(id, 0xf00d, hex"01", 0, panel, quorum, agreed, expiresAt);
        a.issuedAt = issuedAt;
        bytes memory sig = _sign(reg, a);
        vm.warp(block.timestamp + bound(late, 0, 31 days));
        _deliver(id, a, sig);
        (, AskSwarmRegistry.Answer memory ans) = reg.get(id);
        bool inWindow = block.timestamp <= expiresAt && issuedAt <= block.timestamp + 5 minutes;
        assertEq(ans.verified, agreed >= quorum && inWindow);
        bool isIndexed = reg.latestFor(bytes32(uint256(0xf00d))) == id;
        assertEq(isIndexed, ans.verified && uint256(agreed) * 2 > panel);
    }

    /// Audit finding 1b549341 through the mock etched at the real Intake address: a second open ask
    /// cannot carry a re-delivery of a settled id, and the settled record is untouched.
    function test_settledAskRefusesRedeliveryThroughAnotherOpenAsk() public {
        bytes32 first = _ask();
        OracleAttestation memory a = _mint(first, 0x4242, "CHF", 2, 11);
        _deliver(first, a, _sign(reg, a));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = reg.get(first);
        bytes32 before = keccak256(abi.encode(k, ans));

        bytes32 second = _ask();
        OracleAttestation memory b = _mint(first, 0x4242, "EUR", 2, 11);
        bytes memory sig = _sign(reg, b);
        vm.recordLogs();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(second, 0, bytes32(0), "", abi.encode(first, b, sig));
        assertFalse(_delivered(), "re-delivery of a settled id must be refused");
        (k, ans) = reg.get(first);
        assertEq(keccak256(abi.encode(k, ans)), before, "settled record changed");
        assertEq(ans.answer, bytes("CHF"));
        assertEq(reg.latestFor(bytes32(uint256(0x4242))), first);

        vm.prank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, first));
        reg.onOracleResult(first, b, sig);
        vm.prank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, first));
        reg.onFailure(first, 2, bytes32("disagreed"), 0, 0, "");
    }

    /// Review finding 8f2c2abc through the mock etched at the real Intake address, whose `requests`
    /// getter has the live ABI's shape: an ask Intake completed without delivering can be marked Lost.
    function test_markLostReadsIntakeCompletionRecord() public {
        bytes32 first = _ask();
        OracleAttestation memory a = _mint(first, 0x4343, "CHF", 2, 11);
        _deliver(first, a, _sign(reg, a));
        bytes32 second = _ask();
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.StillOpen.selector, second));
        reg.markLost(second);

        OracleAttestation memory b = _mint(first, 0x4343, "EUR", 2, 11);
        bytes memory sig = _sign(reg, b);
        vm.recordLogs();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(second, 0, bytes32(0), "", abi.encode(first, b, sig));
        assertFalse(_delivered());
        (,,, bool completed) = IIntake(INTAKE).requests(second);
        assertTrue(completed);

        reg.markLost(second);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = reg.get(second);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Lost));
        assertEq(ans.answerHash, bytes32(0));
        assertEq(reg.latestFor(bytes32(uint256(0x4343))), first);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.AlreadySettled.selector, second));
        reg.markLost(second);
    }

    /// Review finding a97feadf through the mock at the real address: the index keeps the answer
    /// valid longest among equals, and `reindex` recovers a valid answer once the held one expires.
    function test_indexRespectsValidityWindowAndReindexRecovers() public {
        bytes32 q = bytes32(uint256(0x7a97));
        bytes32 strong = _ask();
        OracleAttestation memory s = _mintP(strong, 0x7a97, hex"00", 0, 15, 11, 11, uint64(block.timestamp + 30 days));
        _deliver(strong, s, _sign(reg, s));
        bytes32 brief = _ask();
        OracleAttestation memory b = _mintP(brief, 0x7a97, hex"00", 0, 15, 11, 11, uint64(block.timestamp + 60));
        _deliver(brief, b, _sign(reg, b));
        assertEq(reg.latestFor(q), strong, "60 s answer must not evict a 30-day one");

        bytes32 bigger = _ask();
        OracleAttestation memory g = _mintP(bigger, 0x7a97, hex"01", 0, 20, 14, 16, uint64(block.timestamp + 1 days));
        _deliver(bigger, g, _sign(reg, g));
        assertEq(reg.latestFor(q), strong, "stronger but shorter-lived does not displace");
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, bigger));
        reg.reindex(bigger);

        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(reg.isCurrent(q));
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.NotEligible.selector, bigger));
        reg.reindex(bigger); // expired by now too
        bytes32 late = _ask();
        OracleAttestation memory l = _mintP(late, 0x7a97, hex"01", 0, 2, 2, 2, uint64(block.timestamp + 1 days));
        _deliver(late, l, _sign(reg, l));
        assertEq(reg.latestFor(q), late, "after expiry the next eligible delivery takes the index");
    }

    /// Review finding 7b194c37 against the mock at the real address: the ceiling is enforced.
    function test_askAtMostAgainstTheQuotedPrice() public {
        uint256 p = reg.price();
        vm.startPrank(user);
        IERC20Like(IMD).approve(address(reg), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.PriceAboveMax.selector, p, p - 1));
        reg.askAtMost(BODY, p - 1);
        bytes32 id = reg.askAtMost(BODY, p);
        vm.stopPrank();
        (AskSwarmRegistry.Ask memory k,) = reg.get(id);
        assertEq(k.asker, user);
        assertEq(IERC20Like(IMD).balanceOf(user), 10 ether - p);
    }

    /// Launch rule: the constructor calls no other contract, so it deploys on an empty chain, and
    /// `ask` approves Intake for exactly the price, leaving no allowance or balance behind.
    function test_constructorMakesNoCallsAndAskLeavesNoAllowance() public {
        address noCode = makeAddr("noCode");
        vm.record();
        AskSwarmRegistry fresh = new AskSwarmRegistry(noCode, noCode, noCode);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(noCode);
        assertEq(reads.length + writes.length, 0);
        assertEq(address(fresh.INTAKE()), noCode);

        assertEq(MockERC20Like(IMD).allowance(address(reg), INTAKE), 0, "no standing approval");
        _ask();
        assertEq(MockERC20Like(IMD).allowance(address(reg), INTAKE), 0, "Intake consumed exactly the approval");
        assertEq(IERC20Like(IMD).balanceOf(address(reg)), 0, "registry holds nothing");
    }

    /// Only the plane's writer can complete, and each request is answered once.
    function test_failureHookStatusesAndUnknownIds() public {
        bytes32 id = _ask();
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE)
            .complete(
                id,
                1,
                bytes32(0),
                "",
                abi.encode(id, uint8(1), bytes32("body_invalid"), uint16(0), uint16(0), bytes(""))
            );
        (AskSwarmRegistry.Ask memory k,) = reg.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Refused));

        bytes32 unknown = keccak256("not asked here");
        vm.startPrank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, unknown));
        reg.onFailure(unknown, 2, 0, 0, 0, "");
        OracleAttestation memory a = _mint(unknown, 0x1234, hex"01", 0, 11);
        vm.expectRevert(abi.encodeWithSelector(AskSwarmRegistry.UnknownAsk.selector, unknown));
        reg.onOracleResult(unknown, a, "");
        vm.stopPrank();
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

    function _mintP(
        bytes32 id,
        uint256 qh,
        bytes memory answer,
        uint8 t,
        uint16 panel,
        uint16 quorum,
        uint16 agreed,
        uint64 expiresAt
    ) internal view returns (OracleAttestation memory a) {
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

interface MockERC20Like {
    function allowance(address, address) external view returns (uint256);
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
