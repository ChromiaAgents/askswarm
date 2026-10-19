// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmWager} from "src/SwarmWager.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

contract SwarmWagerBoundariesTest is RegistryTestSupport {
    uint96 private constant STAKE = 3 ether;
    uint256 private constant FEE = 0.5 ether;
    SwarmWager private wager;

    function setUp() public override {
        super.setUp();
        wager = new SwarmWager(address(registry), address(token));
        vm.prank(alice);
        token.approve(address(wager), type(uint256).max);
        vm.prank(bob);
        token.approve(address(wager), type(uint256).max);
    }

    function test_unavailablePriceDoesNotChargeCreateOrTrapMatchedEscrow() public {
        intake.setRejection(0, true);
        vm.expectRevert(RecordingIntake.PriceUnavailable.selector);
        _create(true, STAKE, bytes("{}"));
        assertEq(wager.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        intake.setRejection(0, false);
        uint256 id = _match(false, STAKE, bytes("{}"));
        vm.warp(START + 2);
        intake.setRejection(0, true);
        vm.expectRevert(RecordingIntake.PriceUnavailable.selector);
        wager.resolve(id);
        _assertUnasked(id);
        vm.warp(START + 2 + 3 days + 1);
        wager.abandon(id);
        _assertRestored(0);
    }

    function test_retiredActionRollsBackApprovalAndCanBeAbandoned() public {
        uint256 id = _match(true, STAKE, bytes("{}"));
        intake.setPrice(0);
        vm.warp(START + 2);
        vm.expectRevert(AskSwarmRegistry.NotSold.selector);
        wager.resolve(id);
        _assertUnasked(id);
        vm.warp(START + 2 + 3 days + 1);
        wager.abandon(id);
        _assertRestored(0);
    }

    /// A body over Intake's 16 KiB cap could be created and joined but never asked, locking the
    /// counterparty until abandon (review finding 8510f4de65d9). It is now refused at create, as
    /// SwarmMarket.open refuses it; exactly MAX_BODY_BYTES is still accepted.
    function test_oversizedBodyRejectedAtCreate() public {
        uint256 before_ = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(new bytes(16_385), false, STAKE, uint64(START + 1), uint64(START + 2));
        assertEq(token.balanceOf(alice), before_);
        assertEq(wager.count(), 0);
        assertEq(wager.MAX_BODY_BYTES(), 16_384);
        vm.prank(alice);
        wager.create(new bytes(16_384), false, STAKE, uint64(START + 1), uint64(START + 2));
        assertEq(wager.count(), 1);
    }

    function test_maximumStakeAndMaximumFeeDoNotNarrowCombinedAmounts() public {
        uint256 maximum = type(uint96).max;
        token.mint(alice, maximum * 2);
        token.mint(bob, maximum);
        intake.setPrice(maximum);
        uint256 id = _match(false, uint96(maximum), bytes("{}"));
        assertEq(token.balanceOf(address(wager)), maximum * 3);
        vm.warp(START + 2);
        wager.resolve(id);
        assertEq(token.balanceOf(address(wager)), maximum * 2);
        _answer(id, abi.encode(true), 0, 3, 2);
        wager.settle(id);
        assertEq(token.balanceOf(address(wager)), 0);
        assertEq(token.balanceOf(recipient), maximum);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 100 ether + maximum * 2);
        assertEq(_w(id).winner, bob);
    }

    function test_zeroAndUnrepresentableFeesRejectBeforeFunding() public {
        intake.setPrice(0);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        _create(true, 1, bytes("{}"));
        intake.setPrice(uint256(type(uint96).max) + 1);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        _create(true, 1, bytes("{}"));
        intake.setPrice(type(uint256).max);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        _create(true, 1, bytes("{}"));
        assertEq(wager.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_failedCreateAndJoinDoNotLeavePhantomPositionsOrParticipants() public {
        vm.prank(alice);
        token.approve(address(wager), STAKE + FEE - 1);
        vm.expectRevert(SwarmWager.TransferFailed.selector);
        _create(true, STAKE, bytes("{}"));
        assertEq(wager.count(), 0);
        (, bytes memory absentBody) = wager.get(1);
        assertEq(absentBody.length, 0);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        token.approve(address(wager), STAKE + FEE);
        uint256 id = _create(true, STAKE, bytes("{}"));
        assertEq(id, 1);
        assertEq(token.allowance(alice, address(wager)), 0);
        vm.prank(bob);
        token.approve(address(wager), STAKE - 1);
        vm.prank(bob);
        vm.expectRevert(SwarmWager.TransferFailed.selector);
        wager.join(id);
        assertEq(_w(id).no, address(0));
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Open));
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(address(wager)), STAKE + FEE);
        vm.prank(bob);
        token.approve(address(wager), STAKE);
        vm.prank(bob);
        wager.join(id);
        assertEq(_w(id).no, bob);
        assertEq(token.allowance(bob, address(wager)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_majorityBoundaryAcrossUint16Range(uint16 rawPanel, bool majority, bool creatorYes, bool answer)
        public
    {
        uint16 panel = uint16(bound(rawPanel, 2, type(uint16).max));
        uint16 votes = panel / 2 + (majority ? 1 : 0);
        uint256 id = _match(creatorYes, STAKE, bytes("{}"));
        vm.warp(START + 2);
        wager.resolve(id);
        _answer(id, abi.encode(answer), 0, panel, votes);
        wager.settle(id);
        if (majority) {
            address winner = creatorYes == answer ? alice : bob;
            assertEq(_w(id).winner, winner);
            assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Paid));
            assertEq(
                token.balanceOf(alice), 100 ether - FEE + (winner == alice ? STAKE : 0) - (winner == bob ? STAKE : 0)
            );
            assertEq(token.balanceOf(bob), 100 ether + (winner == bob ? STAKE : 0) - (winner == alice ? STAKE : 0));
        } else {
            assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Refunded));
            assertEq(_w(id).winner, address(0));
            _assertRestored(FEE);
        }
        assertEq(token.balanceOf(address(wager)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nonBoolTypeCannotPayEvenWithCanonicalBoolBytes(uint8 rawType, bool value) public {
        uint8 answerType = uint8(bound(rawType, 1, type(uint8).max));
        uint256 id = _match(true, STAKE, bytes("{}"));
        vm.warp(START + 2);
        wager.resolve(id);
        _answer(id, abi.encode(value), answerType, 5, 5);
        wager.settle(id);
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Refunded));
        assertEq(_w(id).winner, address(0));
        _assertRestored(FEE);
    }

    function test_sharedQuestionIndexCannotSubstituteAnotherWagersAnswer() public {
        uint256 first = _match(true, STAKE, bytes("first opaque body"));
        uint256 second = _match(false, STAKE, bytes("second opaque body"));
        vm.warp(START + 2);
        wager.resolve(first);
        wager.resolve(second);
        _answer(first, abi.encode(true), 0, 5, 4);
        _answer(second, abi.encode(false), 0, 5, 4);
        assertEq(registry.latestFor(QUESTION), _w(second).requestId);
        assertNotEq(_w(first).requestId, _w(second).requestId);
        // Settle in reverse order: both creators win for different request-specific reasons.
        wager.settle(second);
        wager.settle(first);
        assertEq(_w(first).winner, alice);
        assertEq(_w(second).winner, alice);
        assertEq(token.balanceOf(alice), 100 ether + 2 * STAKE - 2 * FEE);
        assertEq(token.balanceOf(bob), 100 ether - 2 * STAKE);
        assertEq(token.balanceOf(address(wager)), 0);
    }

    function test_missingRegistryRecordUsesTimeoutInsteadOfPayingEmbeddedAnswer() public {
        uint256 id = _match(true, STAKE, bytes("{}"));
        vm.warp(START + 2);
        wager.resolve(id);
        AskSwarmRegistry.Ask memory missing;
        AskSwarmRegistry.Answer memory answer;
        answer.answer = abi.encode(true);
        answer.panelSize = 3;
        answer.agreed = 3;
        answer.verified = true;
        vm.mockCall(address(registry), abi.encodeCall(registry.get, (_w(id).requestId)), abi.encode(missing, answer));
        vm.warp(START + 2 + 3 days);
        vm.expectRevert(SwarmWager.StillPending.selector);
        wager.settle(id);
        vm.warp(START + 2 + 3 days + 1);
        wager.settle(id);
        assertEq(uint8(_w(id).state), uint8(SwarmWager.State.Refunded));
        _assertRestored(FEE);
    }

    function _create(bool yes, uint96 stake, bytes memory body) private returns (uint256) {
        vm.prank(alice);
        return wager.create(body, yes, stake, START + 1, START + 2);
    }

    function _match(bool yes, uint96 stake, bytes memory body) private returns (uint256 id) {
        id = _create(yes, stake, body);
        vm.prank(bob);
        wager.join(id);
    }

    function _w(uint256 id) private view returns (SwarmWager.Wager memory w) {
        (w,) = wager.get(id);
    }

    function _answer(uint256 id, bytes memory value, uint8 answerType, uint16 panel, uint16 votes) private {
        bytes32 rid = _w(id).requestId;
        OracleAttestation memory a = _attestation(rid, value);
        a.answerType = answerType;
        a.panelSize = panel;
        a.quorum = votes;
        a.agreed = votes;
        _deliver(rid, a, _sign(a));
    }

    function _assertUnasked(uint256 id) private view {
        SwarmWager.Wager memory w = _w(id);
        assertEq(uint8(w.state), uint8(SwarmWager.State.Matched));
        assertEq(w.askedAt, 0);
        assertEq(w.requestId, bytes32(0));
        assertEq(w.fee, FEE);
        assertEq(token.balanceOf(address(wager)), 2 * STAKE + FEE);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.allowance(address(wager), address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(registry.asked(), 0);
        assertEq(intake.nonce(), 0);
    }

    function _assertRestored(uint256 spent) private view {
        assertEq(token.balanceOf(alice), 100 ether - spent);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(address(wager)), 0);
    }
}
