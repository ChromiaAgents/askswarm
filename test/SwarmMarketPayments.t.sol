// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmMarket} from "src/SwarmMarket.sol";
import {OracleAttestation} from "src/IIntake.sol";
import {RegistryTestSupport, PaymentToken} from "./helpers/RegistryTestSupport.sol";

/// Fault injection tests for atomicity. Outgoing token faults are scoped to the exact transfer;
/// all earlier transfers execute normally, so a revert must undo their real balance changes.
contract SwarmMarketPaymentsTest is RegistryTestSupport {
    SwarmMarket internal market;
    address internal creator;
    address internal treasury;

    function setUp() public override {
        super.setUp();
        creator = makeAddr("payment market creator");
        treasury = makeAddr("payment market treasury");
        market = new SwarmMarket(address(registry), address(token), treasury);
        address[3] memory users = [creator, alice, bob];
        for (uint256 i; i < users.length; ++i) {
            token.mint(users[i], 1000 ether);
            vm.prank(users[i]);
            token.approve(address(market), type(uint256).max);
        }
    }

    function _open() internal returns (uint256 id) {
        uint64 at = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(creator);
        id = market.open("opaque payment fixture", at, at);
    }

    function _funded() internal returns (uint256 id) {
        id = _open();
        vm.prank(alice);
        market.stake(id, true, 30 ether);
        vm.prank(bob);
        market.stake(id, false, 60 ether);
    }

    function _get(uint256 id) internal view returns (SwarmMarket.Market memory m) {
        (m,) = market.get(id);
    }

    function _resolve(uint256 id) internal {
        vm.warp(_get(id).resolveAfter);
        market.resolve(id);
    }

    function _answer(uint256 id, bool yes) internal {
        bytes32 rid = _get(id).requestId;
        OracleAttestation memory a = _attestation(rid, abi.encode(yes));
        a.answerType = 0;
        _deliver(rid, a, _sign(a));
    }

    function _fingerprint(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(_get(id), market.bodyOf(id)));
    }

    function _badTransfer(address to, uint256 amount, uint8 mode) internal {
        bytes memory data = abi.encodeCall(PaymentToken.transfer, (to, amount));
        if (mode == 0) {
            vm.mockCall(address(token), data, abi.encode(false));
        } else if (mode == 1) {
            vm.mockCallRevert(address(token), data, abi.encodeWithSelector(PaymentToken.TokenRejected.selector));
        } else if (mode == 2) {
            vm.mockCall(address(token), data, hex"01");
        } else {
            vm.mockCall(address(token), data, abi.encode(uint256(2)));
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedPullOrApprovalIsAtomicAndRetryable(uint8 modeSeed, uint8 operationSeed) public {
        uint256 id = _funded();
        uint256 untouched = _funded();
        uint8 operation = operationSeed % 4;
        PaymentToken.Reply[4] memory modes = [
            PaymentToken.Reply.False, PaymentToken.Reply.Revert, PaymentToken.Reply.Short, PaymentToken.Reply.NonBoolean
        ];
        PaymentToken.Reply mode = modes[modeSeed % 4];
        if (operation == 3) vm.warp(_get(id).resolveAfter);
        bytes32 before_ = _fingerprint(id);
        bytes32 otherBefore = _fingerprint(untouched);
        uint256 held = token.balanceOf(address(market));
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 aliceBefore = token.balanceOf(alice);
        token.configure(
            operation == 3 ? PaymentToken.Reply.True : mode, operation == 3 ? mode : PaymentToken.Reply.True, address(0)
        );
        address caller = operation == 0 ? creator : alice;
        bytes memory callData;
        if (operation == 0) {
            uint64 at = uint64(vm.getBlockTimestamp() + 1 hours);
            callData = abi.encodeCall(market.open, (bytes("another body"), at, at));
        } else if (operation == 1) {
            callData = abi.encodeCall(market.stake, (id, true, uint128(7 ether)));
        } else if (operation == 2) {
            callData = abi.encodeCall(market.topUpFee, (id, uint96(7 ether)));
        } else {
            callData = abi.encodeCall(market.resolve, (id));
        }

        vm.prank(caller);
        (bool ok, bytes memory reason) = address(market).call(callData);
        assertFalse(ok, "failed ERC20 operation was accepted");
        if (mode == PaymentToken.Reply.False || mode == PaymentToken.Reply.Revert) {
            assertEq(reason, abi.encodeWithSelector(SwarmMarket.TransferFailed.selector));
        }
        assertEq(_fingerprint(id), before_);
        assertEq(_fingerprint(untouched), otherBefore);
        assertEq(market.count(), 2);
        assertEq(market.bodyOf(3).length, 0);
        assertEq(market.yesStake(id, alice), 30 ether);
        assertEq(token.balanceOf(address(market)), held);
        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.allowance(caller, address(market)), type(uint256).max);
        assertEq(token.allowance(address(market), address(registry)), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(registry.asked(), 0);
        assertEq(intake.nonce(), 0);

        token.configure(PaymentToken.Reply.True, PaymentToken.Reply.True, address(0));
        vm.prank(caller);
        (ok,) = address(market).call(callData);
        assertTrue(ok, "payment failure prevented retry");
        if (operation == 0) assertEq(market.count(), 3);
        if (operation == 1) assertEq(market.yesStake(id, alice), 37 ether);
        if (operation == 2) assertEq(_get(id).feeEscrow, 7.5 ether);
        if (operation == 3) {
            assertEq(uint8(_get(id).phase), uint8(SwarmMarket.Phase.Asked));
            assertEq(token.balanceOf(recipient), 0.5 ether);
        }
        assertEq(_fingerprint(untouched), otherBefore);
    }

    function test_noReturnPullsAndApprovalsReachAnOrdinaryPayout() public {
        token.configure(PaymentToken.Reply.Empty, PaymentToken.Reply.Empty, address(0));
        uint256 id = _funded();
        vm.prank(bob);
        market.topUpFee(id, 1);
        _resolve(id);
        _answer(id, false);
        market.settle(id);
        vm.prank(bob);
        assertEq(market.claim(id), 89.4 ether);
        assertEq(token.balanceOf(address(market)), 0);
        assertEq(token.balanceOf(treasury), 0.3 ether);
        assertEq(token.allowance(address(market), address(registry)), 0);
    }

    /// A refused remainder push (the creator is blocked on Robinhood IMD) no longer undoes the ask:
    /// the market is asked and the remainder is credited to the creator, who withdraws it later.
    /// Before finding ad6653d75214 the whole resolve reverted, so a blocked creator could stop it.
    function test_refusedRemainderRefundIsCreditedAndAskStands() public {
        uint256 id = _funded();
        intake.setPrice(0.25 ether);
        vm.warp(_get(id).resolveAfter);
        _badTransfer(creator, 0.25 ether, 1);
        market.resolve(id);
        assertEq(uint8(_get(id).phase), uint8(SwarmMarket.Phase.Asked));
        assertEq(market.owed(creator), 0.25 ether);
        assertEq(token.balanceOf(recipient), 0.25 ether);
        assertEq(token.balanceOf(address(market)), 90.25 ether);
        assertEq(token.balanceOf(creator), 999.5 ether);
        assertEq(intake.nonce(), 1);
        vm.clearMockedCalls();
        vm.prank(creator);
        assertEq(market.withdraw(), 0.25 ether);
        assertEq(market.owed(creator), 0);
        assertEq(token.balanceOf(creator), 999.75 ether);
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.NothingToClaim.selector);
        market.withdraw();
    }

    /// A `false` (or malformed) reply on a third-party push still reverts the whole call: it cannot
    /// show whether tokens moved, so crediting it could pay twice.
    function test_malformedRemainderReplyRollsBackAlreadyPaidOracle() public {
        uint256 id = _funded();
        intake.setPrice(0.25 ether);
        vm.warp(_get(id).resolveAfter);
        bytes32 before_ = _fingerprint(id);
        _badTransfer(creator, 0.25 ether, 0);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.resolve(id);
        assertEq(_fingerprint(id), before_);
        assertEq(token.balanceOf(address(market)), 90.5 ether);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(intake.nonce(), 0);
        assertEq(market.owed(creator), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_treasuryFeeTransferFailure(uint8 mode) public {
        uint256 id = _funded();
        _resolve(id);
        _answer(id, true);
        bytes32 before_ = _fingerprint(id);
        uint256 creatorBefore = token.balanceOf(creator);
        mode = mode % 4;
        _badTransfer(treasury, 0.6 ether, mode);
        (bool ok,) = address(market).call(abi.encodeCall(market.settle, (id)));
        if (mode != 1) {
            // false or malformed reply: rolled back as before, retry once the token behaves
            assertFalse(ok);
            assertEq(_fingerprint(id), before_);
            assertEq(token.balanceOf(creator), creatorBefore, "first fee transfer must roll back");
            assertEq(market.claimable(id, alice), 0);
            vm.clearMockedCalls();
            market.settle(id);
            assertEq(token.balanceOf(treasury), 0.6 ether);
        } else {
            // reverted (a blocked treasury): settled anyway, the treasury's half is credited
            assertTrue(ok);
            assertEq(uint8(_get(id).phase), uint8(SwarmMarket.Phase.Yes));
            assertEq(market.owed(treasury), 0.6 ether);
            assertEq(token.balanceOf(treasury), 0);
            vm.clearMockedCalls();
            vm.prank(treasury);
            assertEq(market.withdraw(), 0.6 ether);
        }
        assertEq(token.balanceOf(creator), creatorBefore + 0.6 ether);
        assertEq(token.balanceOf(treasury), 0.6 ether);
        vm.prank(alice);
        assertEq(market.claim(id), 88.8 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_failedClaimPreservesEntitlementAndDoesNotBlockAnotherWinner() public {
        uint256 id = _funded();
        vm.prank(bob);
        market.stake(id, true, 30 ether);
        _resolve(id);
        _answer(id, true);
        market.settle(id);
        uint256 aliceBefore = token.balanceOf(alice);
        _badTransfer(alice, 59.4 ether, 1);
        vm.prank(alice);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.claim(id);
        assertFalse(market.claimed(id, alice));
        assertEq(market.claimable(id, alice), 59.4 ether);
        assertEq(token.balanceOf(alice), aliceBefore);
        vm.prank(bob);
        assertEq(market.claim(id), 59.4 ether);
        vm.clearMockedCalls();
        vm.prank(alice);
        assertEq(market.claim(id), 59.4 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    /// A refused escrow refund to the creator no longer blocks the void: stakers claim at once
    /// and the creator withdraws the escrow later (finding ad6653d75214).
    function test_refusedAbandonRefundIsCreditedAndStakersClaim() public {
        uint256 id = _funded();
        vm.warp(uint256(_get(id).resolveAfter) + 1 hours + 1);
        _badTransfer(creator, 0.5 ether, 1);
        market.abandon(id);
        assertEq(uint8(_get(id).phase), uint8(SwarmMarket.Phase.Void));
        assertEq(market.owed(creator), 0.5 ether);
        vm.prank(alice);
        assertEq(market.claim(id), 30 ether);
        vm.prank(bob);
        assertEq(market.claim(id), 60 ether);
        assertEq(token.balanceOf(address(market)), 0.5 ether);
        vm.clearMockedCalls();
        vm.prank(creator);
        market.withdraw();
        assertEq(token.balanceOf(creator), 1000 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    /// The withdrawal itself is an ordinary push: a failure reverts and keeps the credit.
    function test_failedWithdrawKeepsCredit() public {
        uint256 id = _funded();
        vm.warp(uint256(_get(id).resolveAfter) + 1 hours + 1);
        _badTransfer(creator, 0.5 ether, 1);
        market.abandon(id);
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.withdraw();
        assertEq(market.owed(creator), 0.5 ether);
        vm.clearMockedCalls();
        vm.prank(creator);
        assertEq(market.withdraw(), 0.5 ether);
    }

    function test_poolOverflowCannotChargeOrChangeAnUnrelatedMarket() public {
        uint256 id = _open();
        uint256 other = _funded();
        token.mint(alice, type(uint128).max);
        vm.prank(alice);
        market.stake(id, true, type(uint128).max);
        bytes32 before_ = _fingerprint(id);
        bytes32 otherBefore = _fingerprint(other);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        market.stake(id, true, 1);
        assertEq(token.balanceOf(bob), bobBefore);
        assertEq(market.yesStake(id, bob), 0);
        assertEq(_fingerprint(id), before_);
        assertEq(_fingerprint(other), otherBefore);
        _resolve(id); // one-sided full-width pool remains refundable
        vm.prank(alice);
        assertEq(market.claim(id), type(uint128).max);
        assertEq(token.balanceOf(address(market)), 90.5 ether);
    }
}
