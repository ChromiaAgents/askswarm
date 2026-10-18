// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RegistryTestSupport, PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {OracleAttestation} from "../src/IIntake.sol";
import {SwarmWager, IAskSwarmRegistry} from "../src/SwarmWager.sol";

/// Offline integration through the actual registry source and a controllable payment transport.
contract SwarmWagerReviewTest is RegistryTestSupport {
    uint96 constant STAKE = 3 ether;
    uint96 constant FEE = 0.5 ether;
    // Opaque transport fixture: the wager does not parse or manufacture oracle questions.
    bytes constant BODY = "{}";
    SwarmWager wager;

    function setUp() public override {
        super.setUp();
        wager = new SwarmWager(address(registry), address(token));
        vm.prank(alice);
        token.approve(address(wager), type(uint256).max);
        vm.prank(bob);
        token.approve(address(wager), type(uint256).max);
    }

    function _create(bool yes, uint64 joinBy, uint64 resolveAfter) internal returns (uint256 id) {
        vm.prank(alice);
        return wager.create(BODY, yes, STAKE, joinBy, resolveAfter);
    }

    function _match() internal returns (uint256 id) {
        id = _create(true, START + 1 hours, START + 2 hours);
        vm.prank(bob);
        wager.join(id);
    }

    function _open() internal returns (uint256 id) {
        id = _match();
        vm.warp(START + 2 hours);
        wager.resolve(id);
    }

    function _w(uint256 id) internal view returns (SwarmWager.Wager memory w) {
        (w,) = wager.get(id);
    }

    function _bool(uint256 id, bool answer) internal view returns (OracleAttestation memory a) {
        a = _attestation(_w(id).requestId, abi.encode(answer));
        a.answerType = 0;
    }

    function _answer(uint256 id, OracleAttestation memory a) internal {
        _deliver(_w(id).requestId, a, _sign(a));
    }

    function _refunded(uint256 id, bool feeSpent) internal view {
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Refunded));
        assertEq(token.balanceOf(alice), 100 ether - (feeSpent ? FEE : 0));
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_priceRiseRevertsWithoutSpendingStakesAndAbandonStillWorks() public {
        uint256 id = _match();
        intake.setPrice(FEE + 1);
        vm.warp(START + 2 hours);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.resolve(id);
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Matched));
        assertEq(token.balanceOf(address(wager)), 2 * STAKE + FEE);
        assertEq(token.allowance(address(wager), address(registry)), 0);
        assertEq(intake.nonce(), 0);
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.abandon(id);
        vm.warp(START + 2 hours + 3 days + 1);
        wager.abandon(id);
        _refunded(id, false);
    }

    function test_maximumTimestampAndOverlongTermsRejectedBeforePayment() public {
        vm.startPrank(alice);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, STAKE, START + 1 hours, type(uint64).max);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, STAKE, type(uint64).max, type(uint64).max);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, STAKE, START + 1 hours, START + 365 days + 1);
        vm.stopPrank();
        assertEq(wager.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_maximumTermCanStillBeMatchedAndUnwound() public {
        uint64 end = START + wager.MAX_TERM();
        uint256 id = _create(true, end, end);
        vm.prank(bob);
        wager.join(id);
        vm.warp(uint256(end) + wager.ANSWER_WINDOW());
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.abandon(id);
        vm.warp(block.timestamp + 1);
        wager.abandon(id);
        _refunded(id, false);
    }

    function testFuzz_allAcceptedTermsHaveBoundedExit(uint64 rawJoin, uint64 rawResolve, bool matched) public {
        uint64 term = wager.MAX_TERM();
        uint64 joinOffset = uint64(bound(rawJoin, 1, term));
        uint64 resolveOffset = uint64(bound(rawResolve, joinOffset, term));
        uint256 id = _create(true, START + joinOffset, START + resolveOffset);
        if (matched) {
            vm.prank(bob);
            wager.join(id);
        }
        vm.warp(uint256(START) + term + wager.ANSWER_WINDOW() + 1);
        if (matched) wager.abandon(id);
        else wager.cancel(id);
        _refunded(id, false);
    }

    function test_creatorTopUpRecoversWagerAfterPriceRise() public {
        uint256 id = _match();
        intake.setPrice(0.6 ether);
        vm.warp(START + 2 hours);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.resolve(id);
        vm.expectEmit(true, true, false, true, address(wager));
        emit SwarmWager.FeeToppedUp(id, alice, 0.1 ether);
        vm.prank(alice);
        wager.topUpFee(id, 0.1 ether);
        assertEq(_w(id).fee, 0.6 ether);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE + 0.6 ether);
        vm.expectCall(address(token), abi.encodeCall(token.approve, (address(registry), 0.6 ether)));
        wager.resolve(id);
        assertEq(token.balanceOf(recipient), 0.6 ether);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE);
        assertEq(token.allowance(address(wager), address(registry)), 0);
        _answer(id, _bool(id, true));
        wager.settle(id);
        assertEq(token.balanceOf(alice), 100 ether + STAKE - 0.6 ether);
        assertEq(token.balanceOf(bob), 100 ether - STAKE);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_thirdPartyTopUpIsExplicitAndUnusedFeeGoesToCreator() public {
        uint256 id = _match();
        // A permissionless resolver cannot spend its caller's allowance implicitly.
        intake.setPrice(0.6 ether);
        vm.warp(START + 2 hours);
        vm.prank(bob);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.resolve(id);
        assertEq(token.balanceOf(bob), 100 ether - STAKE);
        vm.prank(bob);
        wager.topUpFee(id, 0.2 ether);
        assertEq(token.balanceOf(bob), 100 ether - STAKE - 0.2 ether);
        intake.setPrice(0.4 ether);
        wager.resolve(id);
        assertEq(token.balanceOf(alice), 100 ether - STAKE - FEE + 0.3 ether);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE);
        _answer(id, _bool(id, false));
        wager.settle(id);
        assertEq(token.balanceOf(bob), 100 ether + STAKE - 0.2 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_abandonReturnsAllTopUpsToCreator() public {
        uint256 id = _match();
        vm.prank(bob);
        wager.topUpFee(id, 0.1 ether);
        vm.warp(START + 2 hours + 3 days + 1);
        wager.abandon(id);
        assertEq(token.balanceOf(alice), 100 ether + 0.1 ether);
        assertEq(token.balanceOf(bob), 100 ether - 0.1 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_topUpRefusesUnknownOpenAskedAndTerminalWagers() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.None));
        wager.topUpFee(1, 1);
        uint256 id = _create(true, START + 1 hours, START + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Open));
        wager.topUpFee(id, 1);
        vm.prank(bob);
        wager.join(id);
        vm.warp(START + 2 hours);
        wager.resolve(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Asked));
        wager.topUpFee(id, 1);
        _answer(id, _bool(id, true));
        wager.settle(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Paid));
        wager.topUpFee(id, 1);
        uint256 other = _create(false, START + 3 hours, START + 4 hours);
        vm.prank(alice);
        wager.cancel(other);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Refunded));
        wager.topUpFee(other, 1);
    }

    function test_topUpRefusesZeroOverflowAndRollsBackFailedPayment() public {
        uint256 id = _match();
        vm.prank(alice);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.topUpFee(id, 0);
        vm.prank(alice);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.topUpFee(id, type(uint96).max);
        // A caller without approval cannot credit the escrow or take another wager's funds.
        vm.expectRevert(SwarmWager.TransferFailed.selector);
        wager.topUpFee(id, 1);
        assertEq(_w(id).fee, FEE);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE + FEE);
        token.configure(PaymentToken.Reply.False, PaymentToken.Reply.True, address(0));
        vm.prank(alice);
        vm.expectRevert(SwarmWager.TransferFailed.selector);
        wager.topUpFee(id, 1);
        assertEq(_w(id).fee, FEE);
        assertEq(token.balanceOf(alice), 100 ether - STAKE - FEE);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE + FEE);
    }

    function test_maximumFeeEscrowCanBeFundedAndAbandoned() public {
        uint256 id = _match();
        uint96 amount = type(uint96).max - FEE;
        token.mint(bob, amount);
        vm.prank(bob);
        wager.topUpFee(id, amount);
        assertEq(_w(id).fee, type(uint96).max);
        vm.prank(bob);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.topUpFee(id, 1);
        vm.warp(START + 2 hours + 3 days + 1);
        wager.abandon(id);
        assertEq(token.balanceOf(alice), 100 ether + uint256(amount));
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function testFuzz_topUpFeeConservation(uint96 amount, uint96 rawPrice, bool abandon) public {
        amount = uint96(bound(amount, 1, type(uint96).max - FEE));
        uint96 price = uint96(bound(rawPrice, 1, uint256(FEE) + amount));
        uint256 id = _match();
        token.mint(bob, amount);
        vm.prank(bob);
        wager.topUpFee(id, amount);
        assertEq(_w(id).fee, uint256(FEE) + amount);
        assertEq(token.balanceOf(address(wager)), uint256(2 * STAKE) + FEE + amount);
        if (abandon) {
            vm.warp(START + 2 hours + 3 days + 1);
            wager.abandon(id);
            assertEq(token.balanceOf(alice), 100 ether + uint256(amount));
            assertEq(token.balanceOf(bob), 100 ether);
            assertEq(token.balanceOf(recipient), 0);
        } else {
            intake.setPrice(price);
            vm.warp(START + 2 hours);
            wager.resolve(id);
            assertEq(token.balanceOf(address(wager)), 2 * STAKE);
            _answer(id, _bool(id, true));
            wager.settle(id);
            assertEq(token.balanceOf(alice), 100 ether + uint256(amount) + STAKE - price);
            assertEq(token.balanceOf(bob), 100 ether - STAKE);
            assertEq(token.balanceOf(recipient), price);
        }
        assertEq(token.balanceOf(address(wager)), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.allowance(address(wager), address(registry)), 0);
    }

    function test_priceDecreaseReturnsOnlyRemainderAndApprovesExactPrice() public {
        uint256 id = _match();
        intake.setPrice(0.4 ether);
        vm.warp(START + 2 hours);
        vm.expectCall(address(token), abi.encodeCall(token.approve, (address(registry), 0.4 ether)));
        wager.resolve(id);
        assertEq(_w(id).fee, 0);
        assertEq(token.balanceOf(alice), 100 ether - STAKE - 0.4 ether);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE);
        assertEq(token.balanceOf(recipient), 0.4 ether);
        assertEq(token.allowance(address(wager), address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(intake.lastBody(), BODY);
        (AskSwarmRegistry.Ask memory k,) = registry.get(_w(id).requestId);
        assertEq(k.asker, address(wager));
    }

    function test_badSignatureRefundsBothStakes() public {
        uint256 id = _open();
        OracleAttestation memory a = _bool(id, true);
        _deliver(_w(id).requestId, a, hex"00");
        (AskSwarmRegistry.Ask memory k,) = registry.get(_w(id).requestId);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        wager.settle(id);
        _refunded(id, true);
    }

    function test_expiredAtDeliveryRefundsBothStakes() public {
        uint256 id = _open();
        OracleAttestation memory a = _bool(id, true);
        a.expiresAt = uint64(block.timestamp - 1);
        _answer(id, a);
        wager.settle(id);
        _refunded(id, true);
    }

    function test_lostCallbackRefundsBothStakes() public {
        uint256 id = _open();
        bytes32 rid = _w(id).requestId;
        vm.prank(writer);
        assertFalse(intake.complete(rid, 0, hex"00"));
        registry.markLost(rid);
        wager.settle(id);
        _refunded(id, true);
    }

    function test_lateAnswerBeforeTimeoutSettlementStillPaysWinner() public {
        uint256 id = _open();
        vm.warp(uint256(_w(id).askedAt) + 3 days + 1);
        _answer(id, _bool(id, true));
        wager.settle(id);
        assertEq(_w(id).winner, alice);
        assertEq(token.balanceOf(alice), 100 ether + STAKE - FEE);
        assertEq(token.balanceOf(bob), 100 ether - STAKE);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_timeoutSettlementBeforeLateAnswerRemainsRefunded() public {
        uint256 id = _open();
        vm.warp(uint256(_w(id).askedAt) + 3 days + 1);
        wager.settle(id);
        _answer(id, _bool(id, true));
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Refunded));
        wager.settle(id);
        _refunded(id, true);
    }

    function test_timeoutIsStrictlyAfterAnswerWindow() public {
        uint256 id = _open();
        vm.warp(uint256(_w(id).askedAt) + 3 days);
        vm.expectRevert(SwarmWager.StillPending.selector);
        wager.settle(id);
        vm.warp(block.timestamp + 1);
        wager.settle(id);
        _refunded(id, true);
    }

    function test_resolutionAfterAbandonDeadlineCanWinTheRace() public {
        uint256 id = _match();
        vm.warp(uint256(_w(id).resolveAfter) + 3 days + 1);
        wager.resolve(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Asked));
        wager.abandon(id);
        _answer(id, _bool(id, true));
        wager.settle(id);
        assertEq(_w(id).winner, alice);
    }

    function test_abandonBeforeLateResolvePreventsAnAsk() public {
        uint256 id = _match();
        vm.warp(uint256(_w(id).resolveAfter) + 3 days + 1);
        wager.abandon(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Refunded));
        wager.resolve(id);
        assertEq(intake.nonce(), 0);
        _refunded(id, false);
    }

    function test_exactJoinAndResolveBoundaryRemainsSupported() public {
        uint256 id = _create(true, START + 1, START + 1);
        vm.warp(START + 1);
        vm.prank(bob);
        wager.join(id);
        wager.resolve(id);
        _answer(id, _bool(id, false));
        wager.settle(id);
        assertEq(_w(id).winner, bob);
    }

    function test_resolveWaitsThroughGapAfterJoinDeadline() public {
        uint256 id = _match();
        vm.warp(START + 1 hours + 1);
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.resolve(id);
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.abandon(id);
        vm.warp(START + 2 hours);
        wager.resolve(id);
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Asked));
    }

    function test_resolveCallerChoosesAskTimeForRelativeWindows() public {
        uint256 id = _match();
        uint256 delayed = START + 2 hours + 2 days;
        vm.warp(delayed);
        vm.prank(alice);
        wager.resolve(id);
        assertEq(_w(id).askedAt, delayed);
        (AskSwarmRegistry.Ask memory k,) = registry.get(_w(id).requestId);
        assertEq(k.askedAt, delayed);
        assertEq(intake.lastBody(), BODY, "body is forwarded unchanged at caller-selected time");
    }

    function test_writerPairingOfAnotherQuestionsAnswerIsTrusted() public {
        uint256 idA = _open();
        vm.prank(bob);
        bytes32 ridB = registry.ask(bytes("a different question"));
        OracleAttestation memory answerB = _attestation(ridB, abi.encode(true));
        answerB.answerType = 0;
        answerB.questionHash = keccak256("different question's canonical document");
        // The writer forwards B's valid signature to A's callback; the live registry checks
        // signatures in its own domain, but deliberately trusts this request pairing.
        _deliver(_w(idA).requestId, answerB, _sign(answerB));
        wager.settle(idA);
        assertEq(_w(idA).winner, alice);
        (AskSwarmRegistry.Ask memory k,) = registry.get(ridB);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
    }

    function testFuzz_wrongBoolLengthRefunds(uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 96);
        if (length == 32) length = 33;
        uint256 id = _open();
        OracleAttestation memory a = _bool(id, true);
        a.answer = new bytes(length);
        _answer(id, a);
        wager.settle(id);
        _refunded(id, true);
    }

    function testFuzz_onlyCanonicalMajorityBoolPays(uint256 word, uint16 panel, uint16 agreed) public {
        uint256 id = _open();
        OracleAttestation memory a = _bool(id, false);
        a.answer = abi.encode(word);
        a.panelSize = panel;
        a.agreed = agreed;
        a.quorum = agreed;
        _answer(id, a);
        wager.settle(id);
        if (word <= 1 && uint256(agreed) * 2 > panel) {
            address winner = word == 1 ? alice : bob;
            assertEq(_w(id).winner, winner);
            assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Paid));
        } else {
            _refunded(id, true);
        }
        assertEq(token.balanceOf(address(wager)), 0);
    }
}
