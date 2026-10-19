// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RegistryTestSupport, PaymentToken} from "./helpers/RegistryTestSupport.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {SwarmWager} from "src/SwarmWager.sol";

/// Uses the actual registry and its signed, 200k-gas callback path with the existing offline
/// token/Intake model. Opaque bodies are transport fixtures, not production oracle questions.
contract SwarmMarketReviewTest is RegistryTestSupport {
    SwarmMarket internal market;
    address internal creator;
    address internal treasury;
    address internal carol;
    uint256 internal constant FUNDS = 100_000 ether;

    event Settled(
        uint256 indexed id, SwarmMarket.Phase phase, uint256 yesPool, uint256 noPool, uint256 fee, uint8 reason
    );
    event FeeToppedUp(uint256 indexed id, address indexed funder, uint256 amount);

    function setUp() public override {
        super.setUp();
        creator = makeAddr("market creator");
        treasury = makeAddr("market treasury");
        carol = makeAddr("market carol");
        market = new SwarmMarket(address(registry), address(token), treasury);
        _fund(creator, FUNDS);
        _fund(alice, FUNDS);
        _fund(bob, FUNDS);
        _fund(carol, FUNDS);
    }

    function _fund(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(market), type(uint256).max);
    }

    function _open() internal returns (uint256 id) {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        vm.prank(creator);
        id = market.open("opaque market body", now_ + 1 hours, now_ + 2 hours);
    }

    function _stake(uint256 id, address user, bool yes, uint128 amount) internal {
        vm.prank(user);
        market.stake(id, yes, amount);
    }

    function _fundedMarket() internal returns (uint256 id) {
        id = _open();
        _stake(id, alice, true, 30 ether);
        _stake(id, bob, false, 60 ether);
    }

    function _market(uint256 id) internal view returns (SwarmMarket.Market memory m) {
        (m,) = market.get(id);
    }

    function _resolve(uint256 id) internal returns (bytes32 rid) {
        vm.warp(_market(id).resolveAfter);
        market.resolve(id);
        return _market(id).requestId;
    }

    function _answer(bytes32 rid, bytes memory answer, uint8 answerType, uint16 panel, uint16 quorum, uint16 agreed)
        internal
    {
        OracleAttestation memory a = _attestation(rid, answer);
        a.answerType = answerType;
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        _deliver(rid, a, _sign(a));
    }

    function _yes(bytes32 rid) internal {
        _answer(rid, abi.encode(true), 0, 15, 11, 12);
    }

    function _assertVoid(uint256 id) internal view {
        SwarmMarket.Market memory m = _market(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));
        assertEq(m.winnersShare, 0);
        assertEq(m.feeEscrow, 0);
        assertEq(market.claimable(id, alice), 30 ether);
        assertEq(market.claimable(id, bob), 60 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_resolveRejectsEarlyAndAfterOneHour() public {
        uint256 id = _fundedMarket();
        uint256 at = _market(id).resolveAfter;
        vm.warp(at - 1);
        vm.expectRevert(SwarmMarket.TooEarly.selector);
        market.resolve(id);
        vm.warp(at + 1 hours + 1);
        vm.expectRevert(SwarmMarket.TooLate.selector);
        market.resolve(id);
        vm.warp(at + 41 hours);
        vm.expectRevert(SwarmMarket.TooLate.selector);
        market.resolve(id);
        vm.warp(at + 3 days + 1);
        vm.expectRevert(SwarmMarket.TooLate.selector);
        market.resolve(id);
        assertEq(intake.nonce(), 0);
        assertEq(_market(id).feeEscrow, 0.5 ether);
    }

    function test_resolveAtLastSecondPreservesBodyAndChargesExactlyOnce() public {
        uint256 id = _fundedMarket();
        vm.warp(uint256(_market(id).resolveAfter) + market.RESOLVE_WINDOW());
        vm.expectRevert(SwarmMarket.TooEarly.selector);
        market.abandon(id);
        vm.expectCall(address(token), abi.encodeCall(PaymentToken.approve, (address(registry), 0.5 ether)));
        market.resolve(id);
        assertEq(intake.lastBody(), "opaque market body");
        assertEq(intake.lastAmount(), 0.5 ether);
        assertEq(intake.lastAsset(), address(token));
        assertEq(token.allowance(address(market), address(registry)), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(recipient), 0.5 ether);
        assertEq(token.balanceOf(address(market)), 90 ether);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.Asked));
        market.resolve(id);
    }

    function testFuzz_resolveAndAbandonWindowsNeverOverlap(uint32 elapsed) public {
        uint256 id = _fundedMarket();
        elapsed = uint32(bound(elapsed, 0, 4 days));
        vm.warp(uint256(_market(id).resolveAfter) + elapsed);
        if (elapsed <= market.RESOLVE_WINDOW()) {
            vm.expectRevert(SwarmMarket.TooEarly.selector);
            market.abandon(id);
            market.resolve(id);
            assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Asked));
        } else {
            vm.expectRevert(SwarmMarket.TooLate.selector);
            market.resolve(id);
            market.abandon(id);
            _assertVoid(id);
            assertEq(token.balanceOf(creator), FUNDS);
        }
    }

    function test_abandonAfterWindowIgnoresOracleOutageAndRefundsEscrow() public {
        uint256 id = _fundedMarket();
        intake.setRejection(0, true);
        vm.warp(uint256(_market(id).resolveAfter) + market.RESOLVE_WINDOW() + 1);
        market.abandon(id);
        _assertVoid(id);
        assertEq(token.balanceOf(creator), FUNDS);
        assertEq(intake.nonce(), 0);
    }

    function test_oneWeiPriceRiseCanBeFundedByAnyoneAfterStakingCloses() public {
        uint256 id = _fundedMarket();
        vm.warp(_market(id).resolveAfter);
        intake.setPrice(0.5 ether + 1);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.resolve(id);
        uint256 before = token.balanceOf(carol);
        vm.expectEmit(true, true, false, true, address(market));
        emit FeeToppedUp(id, carol, 1);
        vm.prank(carol);
        market.topUpFee(id, 1);
        assertEq(token.balanceOf(carol), before - 1);
        assertEq(market.yesStake(id, carol), 0);
        assertEq(market.noStake(id, carol), 0);
        assertEq(_market(id).feeEscrow, 0.5 ether + 1);
        market.resolve(id);
        assertEq(token.balanceOf(recipient), 0.5 ether + 1);
        assertEq(token.balanceOf(address(market)), 90 ether);
        assertEq(_market(id).feeEscrow, 0);
        assertEq(token.allowance(address(market), address(registry)), 0);
        _yes(_market(id).requestId);
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Yes));
    }

    function test_topUpSurplusAndPriceDecreaseReturnOnlyRemainderToCreator() public {
        uint256 id = _fundedMarket();
        vm.prank(carol);
        market.topUpFee(id, 1 ether);
        intake.setPrice(0.25 ether);
        _resolve(id);
        assertEq(token.balanceOf(creator), FUNDS + 0.75 ether);
        assertEq(token.balanceOf(carol), FUNDS - 1 ether);
        assertEq(token.balanceOf(recipient), 0.25 ether);
        assertEq(token.balanceOf(address(market)), 90 ether);
        assertEq(token.allowance(address(market), address(registry)), 0);
    }

    function test_topUpOnAbandonReturnsDonationToCreator() public {
        uint256 id = _fundedMarket();
        vm.prank(carol);
        market.topUpFee(id, 1 ether);
        vm.warp(uint256(_market(id).resolveAfter) + market.RESOLVE_WINDOW() + 1);
        market.abandon(id);
        _assertVoid(id);
        assertEq(token.balanceOf(creator), FUNDS + 1 ether);
        assertEq(token.balanceOf(carol), FUNDS - 1 ether);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_oneSidedMarketReturnsTopUpWithoutAsking() public {
        uint256 id = _open();
        _stake(id, alice, false, 30 ether);
        vm.prank(carol);
        market.topUpFee(id, 1 ether);
        intake.setPrice(0); // No price read is needed for a one-sided void.
        _resolve(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Void));
        assertEq(token.balanceOf(creator), FUNDS + 1 ether);
        assertEq(intake.nonce(), 0);
        vm.prank(alice);
        assertEq(market.claim(id), 30 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_retiredActionCanBeAbandonedWithoutSpendingStakes() public {
        uint256 id = _fundedMarket();
        vm.warp(_market(id).resolveAfter);
        intake.setPrice(0);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.resolve(id);
        assertEq(token.allowance(address(market), address(registry)), 0);
        assertEq(token.balanceOf(address(market)), 90.5 ether);
        vm.warp(vm.getBlockTimestamp() + market.RESOLVE_WINDOW() + 1);
        market.abandon(id);
        _assertVoid(id);
    }

    function test_topUpGuardsZeroOverflowUnknownExpiredAndAskedMarkets() public {
        uint256 id = _fundedMarket();
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.topUpFee(id, 0);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        market.topUpFee(id, type(uint96).max);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.None));
        market.topUpFee(0, 1);
        uint256 expired = _fundedMarket();
        _resolve(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.Asked));
        market.topUpFee(id, 1);
        vm.warp(uint256(_market(expired).resolveAfter) + market.RESOLVE_WINDOW() + 1);
        vm.expectRevert(SwarmMarket.TooLate.selector);
        market.topUpFee(expired, 1);
    }

    function test_topUpAcceptsLastSecondButNotAfter() public {
        uint256 id = _fundedMarket();
        vm.warp(uint256(_market(id).resolveAfter) + market.RESOLVE_WINDOW());
        vm.prank(carol);
        market.topUpFee(id, 1);
        assertEq(_market(id).feeEscrow, 0.5 ether + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        vm.expectRevert(SwarmMarket.TooLate.selector);
        market.topUpFee(id, 1);
    }

    function test_topUpFailedTransferRollsBackEscrowBalancesAndAllowance() public {
        uint256 id = _fundedMarket();
        uint256 before = token.balanceOf(carol);
        vm.prank(carol);
        token.approve(address(market), 1 ether);
        token.configure(PaymentToken.Reply.False, PaymentToken.Reply.True, address(0));
        vm.prank(carol);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.topUpFee(id, 1 ether);
        assertEq(_market(id).feeEscrow, 0.5 ether);
        assertEq(token.balanceOf(carol), before);
        assertEq(token.allowance(carol, address(market)), 1 ether);
        assertEq(token.balanceOf(address(market)), 90.5 ether);
    }

    function test_topUpWithoutApprovalCannotUseAnotherMarketsFunds() public {
        uint256 id = _fundedMarket();
        uint256 other = _fundedMarket();
        vm.prank(carol);
        token.approve(address(market), 0);
        vm.prank(carol);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.topUpFee(id, 1 ether);
        assertEq(_market(id).feeEscrow, 0.5 ether);
        assertEq(_market(other).feeEscrow, 0.5 ether);
        assertEq(token.balanceOf(address(market)), 181 ether);
    }

    function test_registryRejectionRollsBackResolutionAndCanRetry() public {
        uint256 id = _fundedMarket();
        intake.setRejection(2, false);
        vm.warp(_market(id).resolveAfter);
        vm.expectRevert(bytes4(keccak256("RequestRejected()")));
        market.resolve(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Open));
        assertEq(_market(id).feeEscrow, 0.5 ether);
        assertEq(_market(id).requestId, bytes32(0));
        assertEq(token.allowance(address(market), address(registry)), 0);
        assertEq(token.balanceOf(recipient), 0);
        intake.setRejection(0, false);
        market.resolve(id);
        assertEq(token.balanceOf(recipient), 0.5 ether);
    }

    function test_twoSeatPanelVoidsWithDistinctReasonAndNoFee() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        _answer(rid, abi.encode(true), 0, 2, 2, 2);
        vm.expectEmit(true, false, false, true, address(market));
        emit Settled(id, SwarmMarket.Phase.Void, 30 ether, 60 ether, 0, 21);
        market.settle(id);
        _assertVoid(id);
        assertEq(token.balanceOf(creator), FUNDS - 0.5 ether);
        vm.prank(alice);
        assertEq(market.claim(id), 30 ether);
        vm.prank(bob);
        assertEq(market.claim(id), 60 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_sixSeatUnanimousPanelVoidsButSevenWithFourAgreedSettles() public {
        uint256 id = _fundedMarket();
        _answer(_resolve(id), abi.encode(true), 0, 6, 6, 6);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), abi.encode(false), 0, 7, 4, 4);
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.No));
        assertEq(token.balanceOf(treasury), 0.3 ether);
    }

    function test_minimumPanelStillNeedsStrictMajorityAndQuorum() public {
        uint256 id = _fundedMarket();
        _answer(_resolve(id), abi.encode(true), 0, 7, 3, 3);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), abi.encode(true), 0, 8, 4, 4);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), abi.encode(true), 0, 7, 5, 4);
        market.settle(id);
        _assertVoid(id);
    }

    function test_pendingAtExactDeadlineThenVoidOneSecondLater() public {
        uint256 id = _fundedMarket();
        _resolve(id);
        uint256 end = uint256(_market(id).askedAt) + market.ANSWER_WINDOW();
        vm.warp(end);
        vm.expectRevert(SwarmMarket.StillPending.selector);
        market.settle(id);
        vm.warp(end + 1);
        market.settle(id);
        _assertVoid(id);
    }

    function test_answerCanSettleAtExactDeadlineAndClaimsHaveNoDeadline() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        vm.warp(uint256(_market(id).askedAt) + market.ANSWER_WINDOW());
        _yes(rid);
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Yes));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(alice);
        assertEq(market.claim(id), 88.8 ether);
    }

    function test_lateCompletionBeforeOrAfterSettleAlwaysVoids() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        vm.warp(uint256(_market(id).askedAt) + market.ANSWER_WINDOW() + 1);
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        market.settle(id);
        _yes(rid);
        _assertVoid(id);
        assertTrue(vm.revertToState(snapshot));
        _yes(rid);
        vm.prank(bob);
        market.settle(id);
        _assertVoid(id);
        assertEq(token.balanceOf(creator), FUNDS - 0.5 ether);
    }

    /// Finding c7f7d6ef887a: an answer that arrived inside the window decides the market however
    /// late the first settle call is, so a loser gains nothing by staying silent.
    function test_answerDeliveredInWindowSettlesAfterDeadline() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _yes(rid);
        vm.warp(uint256(_market(id).askedAt) + market.ANSWER_WINDOW() + 30 days);
        vm.expectEmit(address(market));
        emit Settled(id, SwarmMarket.Phase.Yes, 30 ether, 60 ether, 1.2 ether, 0);
        vm.prank(bob);
        market.settle(id);
        assertEq(market.claimable(id, alice), 88.8 ether);
        assertEq(market.claimable(id, bob), 0);
        assertEq(token.balanceOf(treasury), 0.6 ether);
        assertEq(token.balanceOf(creator), FUNDS - 0.5 ether + 0.6 ether);
    }

    /// The window is on the signed issuedAt, not on delivery: an answer issued at the deadline and
    /// delivered later still decides; one issued a second later voids with reason 22.
    function test_issuedAtBoundsTheAnswerWindow() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        uint64 end = uint64(uint256(_market(id).askedAt) + market.ANSWER_WINDOW());
        vm.warp(end + 2 hours);
        OracleAttestation memory a = _attestation(rid, abi.encode(false));
        a.answerType = 0;
        a.issuedAt = end;
        _deliver(rid, a, _sign(a));
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.No));

        id = _fundedMarket();
        rid = _resolve(id);
        end = uint64(uint256(_market(id).askedAt) + market.ANSWER_WINDOW());
        vm.warp(end + 2 hours);
        a = _attestation(rid, abi.encode(false));
        a.answerType = 0;
        a.issuedAt = end + 1;
        _deliver(rid, a, _sign(a));
        vm.expectEmit(address(market));
        emit Settled(id, SwarmMarket.Phase.Void, 30 ether, 60 ether, 0, 22);
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Void));
        assertEq(market.claimable(id, alice), 30 ether);
        assertEq(market.claimable(id, bob), 60 ether);
    }

    /// settle reads the registry before applying the deadline, so it waits for a readable record.
    function test_settleNeedsRegistryRecordThenVoidsPendingAfterDeadline() public {
        uint256 id = _fundedMarket();
        _resolve(id);
        vm.mockCallRevert(address(registry), abi.encodeWithSelector(registry.get.selector), "registry unavailable");
        vm.warp(uint256(_market(id).askedAt) + market.ANSWER_WINDOW() + 1);
        vm.expectRevert("registry unavailable");
        market.settle(id);
        vm.clearMockedCalls();
        vm.expectEmit(address(market));
        emit Settled(id, SwarmMarket.Phase.Void, 30 ether, 60 ether, 0, 3);
        market.settle(id);
        _assertVoid(id);
    }

    /// Advisory a6554325c3be: a body Intake would refuse cannot open a market.
    function test_openRejectsBodyLongerThanIntakeAccepts() public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        bytes memory body = new bytes(market.MAX_BODY_BYTES() + 1);
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open(body, now_ + 1 hours, now_ + 2 hours);

        body = new bytes(market.MAX_BODY_BYTES());
        vm.prank(creator);
        uint256 id = market.open(body, now_ + 1 hours, now_ + 2 hours);
        _stake(id, alice, true, 30 ether);
        _stake(id, bob, false, 60 ether);
        _resolve(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Asked));
    }

    function test_terminalFailureStatusesRefundStakesWithoutProtocolFee() public {
        uint256 id = _fundedMarket();
        _fail(_resolve(id), 1, bytes32("body_refused"), 0, 0);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _fail(_resolve(id), 2, bytes32("disagreed"), 3, 7);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        bytes32 rid = _resolve(id);
        vm.prank(writer);
        assertFalse(intake.complete(rid, 2, ""));
        registry.markLost(rid);
        market.settle(id);
        _assertVoid(id);
    }

    function test_wrongTypeShortLongAndNonBooleanWordsVoid() public {
        uint256 id = _fundedMarket();
        _answer(_resolve(id), abi.encode(true), 3, 15, 11, 12);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), hex"01", 0, 15, 11, 12);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), new bytes(33), 0, 15, 11, 12);
        market.settle(id);
        _assertVoid(id);
        id = _fundedMarket();
        _answer(_resolve(id), abi.encode(uint256(2)), 0, 15, 11, 12);
        market.settle(id);
        _assertVoid(id);
    }

    function test_writerQuestionPairingIsExplicitTrustAssumption() public {
        uint256 id = _fundedMarket();
        bytes32 rid = _resolve(id);
        OracleAttestation memory a = _attestation(rid, abi.encode(true));
        a.answerType = 0;
        a.questionHash = keccak256("a different question signed by the configured fixture signer");
        _deliver(rid, a, _sign(a));
        market.settle(id);
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Yes));
    }

    function test_unknownIdsAndTerminalMarketsRejectLifecycleCalls() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.None));
        market.resolve(0);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.None));
        market.settle(0);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.None));
        market.abandon(0);
        uint256 id = _fundedMarket();
        _yes(_resolve(id));
        market.settle(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.Yes));
        market.settle(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.Yes));
        market.abandon(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmMarket.WrongPhase.selector, SwarmMarket.Phase.Yes));
        market.topUpFee(id, 1);
        vm.prank(alice);
        market.claim(id);
        vm.prank(alice);
        vm.expectRevert(SwarmMarket.NothingToClaim.selector);
        market.claim(id);
    }

    function test_claimArithmeticAtMaximumUint128Pools() public {
        uint256 id = _open();
        uint128 maximum = type(uint128).max;
        _fund(alice, maximum);
        _fund(bob, maximum);
        _stake(id, alice, true, maximum);
        _stake(id, bob, false, maximum);
        _yes(_resolve(id));
        market.settle(id);
        uint256 fee = uint256(maximum) * market.FEE_BPS() / 10_000;
        vm.prank(alice);
        assertEq(market.claim(id), uint256(maximum) * 2 - fee);
        assertEq(token.balanceOf(address(market)), 0);
    }

    /// Two simultaneously funded markets, repeated stakes on both sides, top-ups, a changing
    /// price, either winning side or a void, arbitrary claim order, and independent dust bounds.
    function testFuzz_multiMarketConservation(uint128 y, uint128 n, uint96 extra, uint8 outcome, bool reverse) public {
        y = uint128(bound(y, 3, 1000 ether));
        n = uint128(bound(n, 3, 1000 ether));
        extra = uint96(bound(extra, 1, 1 ether));
        uint256 first = _open();
        uint256 second = _open();
        _stake(first, alice, true, y / 3);
        _stake(first, alice, true, y - y / 3);
        _stake(first, alice, false, n / 3);
        _stake(first, bob, false, n - n / 3);
        _stake(second, carol, true, y);
        _stake(second, bob, false, n);
        vm.prank(carol);
        market.topUpFee(first, extra);
        intake.setPrice(0.5 ether + extra);
        bytes32 rid = _resolve(first);
        uint256 secondLiability = uint256(y) + n + 0.5 ether;
        if (outcome % 3 == 0) {
            _answer(rid, abi.encode(true), 0, 2, 2, 2);
        } else {
            _answer(rid, abi.encode(outcome % 3 == 1), 0, 15, 11, 12);
        }
        market.settle(first);
        address a = reverse ? bob : alice;
        address b = reverse ? alice : bob;
        uint256 paid = _claimIfOwed(first, a) + _claimIfOwed(first, b);
        uint256 fee = outcome % 3 == 0 ? 0 : uint256(outcome % 3 == 1 ? n : y) * 200 / 10_000;
        uint256 dust = uint256(y) + n - fee - paid;
        assertLe(dust, 1);
        assertEq(token.balanceOf(address(market)), secondLiability + dust);
        assertEq(token.balanceOf(treasury), fee - fee / 2);
        assertEq(token.balanceOf(creator), FUNDS - 1 ether + fee / 2);
        vm.warp(uint256(_market(second).resolveAfter) + market.RESOLVE_WINDOW() + 1);
        market.abandon(second);
        assertEq(_claimIfOwed(second, bob), n);
        assertEq(_claimIfOwed(second, carol), y);
        assertEq(token.balanceOf(address(market)), dust);
        assertEq(token.balanceOf(recipient), 0.5 ether + extra);
        assertEq(token.allowance(address(market), address(registry)), 0);
    }

    function _claimIfOwed(uint256 id, address user) internal returns (uint256 amount) {
        uint256 owed = market.claimable(id, user);
        if (owed == 0) return 0;
        uint256 before = token.balanceOf(user);
        vm.prank(user);
        amount = market.claim(id);
        assertEq(amount, owed);
        assertEq(token.balanceOf(user), before + owed);
        assertEq(market.claimable(id, user), 0);
    }

    // ---- finding f8ec801b0e44 (Robinhood Chain launch): resolveAfter beyond any reachable time ----

    function wagerMaxTerm() internal returns (uint64) {
        return new SwarmWager(address(registry), address(token)).MAX_TERM();
    }

    /// `open` used to accept `resolveAfter = type(uint64).max`: stakes closed at `closeAt`, and
    /// `resolve` and `abandon` both reverted TooEarly at every timestamp a chain will ever produce.
    /// Now the terms are refused before any token moves, the same bound SwarmWager applies.
    function test_openRejectsResolveAfterBeyondMaxTerm() public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        uint256 before = token.balanceOf(creator);
        uint64 maxTerm = market.MAX_TERM();
        assertEq(maxTerm, 365 days);
        assertEq(maxTerm, wagerMaxTerm(), "same horizon as SwarmWager");

        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque market body", now_ + 1 hours, type(uint64).max);

        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque market body", now_ + 1 hours, now_ + maxTerm + 1);

        // closeAt is bounded through resolveAfter >= closeAt.
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque market body", type(uint64).max, type(uint64).max);

        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque market body", now_ + maxTerm + 1, now_ + maxTerm + 1);

        assertEq(market.count(), 0, "no market opened");
        assertEq(token.balanceOf(creator), before, "a refused open pulls nothing");
        assertEq(token.balanceOf(address(market)), 0);
    }

    /// The limit is inclusive and relative to the opening block: exactly MAX_TERM is accepted, and
    /// the market it opens can still be abandoned once its resolve window has passed.
    function test_openAcceptsExactMaxTermAndMarketStillUnwinds() public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        uint64 limit = now_ + market.MAX_TERM();
        vm.prank(creator);
        uint256 id = market.open("opaque market body", now_ + 1 hours, limit);
        assertEq(_market(id).resolveAfter, limit);
        _stake(id, alice, true, 30 ether);
        _stake(id, bob, false, 60 ether);

        // Still Open and locked through the whole term and the resolve window.
        vm.warp(uint256(limit) + market.RESOLVE_WINDOW());
        vm.expectRevert(SwarmMarket.TooEarly.selector);
        market.abandon(id);
        market.resolve(id); // the registry is reachable here, so resolve is the normal exit
        assertEq(uint8(_market(id).phase), uint8(SwarmMarket.Phase.Asked));
    }

    function test_maxTermMarketAbandonsAfterResolveWindow() public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        uint64 limit = now_ + market.MAX_TERM();
        vm.prank(creator);
        uint256 id = market.open("opaque market body", limit, limit);
        _stake(id, alice, true, 30 ether);
        _stake(id, bob, false, 60 ether);
        vm.warp(uint256(limit) + market.RESOLVE_WINDOW() + 1);
        market.abandon(id);
        _assertVoid(id);
        assertEq(_claimIfOwed(id, alice), 30 ether);
        assertEq(_claimIfOwed(id, bob), 60 ether);
        assertEq(token.balanceOf(address(market)), 0, "every token left the contract");
        assertEq(token.balanceOf(creator), FUNDS, "unspent escrow returned");
    }

    /// Every pair of terms `open` accepts can be unwound by anyone no later than
    /// MAX_TERM + RESOLVE_WINDOW + 1 after opening, whatever the registry does: the horizon is
    /// bounded by the contract, not by the creator.
    function testFuzz_acceptedTermsAlwaysUnwindWithinHorizon(uint64 closeDelay, uint64 resolveDelay, uint8 priceMode)
        public
    {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        closeDelay = uint64(bound(closeDelay, 1, market.MAX_TERM()));
        resolveDelay = uint64(bound(resolveDelay, closeDelay, market.MAX_TERM()));
        vm.prank(creator);
        uint256 id = market.open("opaque market body", now_ + closeDelay, now_ + resolveDelay);
        _stake(id, alice, true, 30 ether);
        _stake(id, bob, false, 60 ether);
        // The registry may be unreachable, retired or repriced: abandon must not depend on it.
        if (priceMode % 3 == 1) intake.setPrice(0);
        if (priceMode % 3 == 2) intake.setRejection(0, true);

        uint256 horizon = uint256(now_) + market.MAX_TERM() + market.RESOLVE_WINDOW() + 1;
        vm.warp(horizon);
        market.abandon(id);
        _assertVoid(id);
        assertEq(_claimIfOwed(id, alice) + _claimIfOwed(id, bob), 90 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function testFuzz_openRejectsEveryResolveAfterPastMaxTerm(uint64 resolveAfter, uint64 closeDelay) public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        resolveAfter = uint64(bound(resolveAfter, uint256(now_) + market.MAX_TERM() + 1, type(uint64).max));
        uint64 closeAt = uint64(bound(closeDelay, uint256(now_) + 1, resolveAfter));
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque market body", closeAt, resolveAfter);
        assertEq(market.count(), 0);
        assertEq(token.balanceOf(creator), FUNDS);
    }
}
