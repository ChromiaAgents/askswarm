// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {RegistryTestSupport, PaymentToken, RecordingIntake} from "./helpers/RegistryTestSupport.sol";

contract AskSwarmRegistryPaymentsTest is RegistryTestSupport {
    event Asked(bytes32 indexed requestId, address indexed asker, bytes body);

    function test_constructorRejectsEveryZeroDependency() public {
        vm.expectRevert(AskSwarmRegistry.ZeroAddress.selector);
        new AskSwarmRegistry(address(0), address(token), vm.addr(SIGNING_KEY));
        vm.expectRevert(AskSwarmRegistry.ZeroAddress.selector);
        new AskSwarmRegistry(address(intake), address(0), vm.addr(SIGNING_KEY));
        vm.expectRevert(AskSwarmRegistry.ZeroAddress.selector);
        new AskSwarmRegistry(address(intake), address(token), address(0));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactPriceIsForwardedAndBodyIsUnchanged(uint128 rawPrice, bytes memory rawBody) public {
        if (rawBody.length > 16_382) {
            assembly { mstore(rawBody, 16382) }
        }
        bytes memory body = bytes.concat(hex"7b", rawBody, hex"7d");
        uint256 p = bound(rawPrice, 1, type(uint128).max);
        intake.setPrice(p);
        token.mint(alice, p);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(registry), p);

        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(intake), uint256(1)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit Asked(expectedId, alice, body);
        bytes32 id = _ask(alice, body);

        assertEq(id, expectedId);
        assertEq(token.balanceOf(alice), beforeBalance - p);
        assertEq(token.balanceOf(recipient), p);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(alice, address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastAsset(), address(token));
        assertEq(intake.lastAmount(), p);
        RecordingIntake.Request memory r = intake.requestInfo(id);
        assertEq(r.payer, address(registry));
        assertEq(r.callback.target, address(registry));
        assertEq(r.callback.selector, registry.onOracleResult.selector);
        assertEq(r.failure, registry.onFailure.selector);
        assertFalse(r.completed);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory answer) = registry.get(id);
        assertEq(k.asker, alice);
        assertEq(k.askedAt, block.timestamp);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
        assertFalse(answer.verified);
        assertEq(registry.asked(), 1);
    }

    function test_oneWeiPrice() public {
        intake.setPrice(1);
        bytes32 id = _ask(alice, "{}");
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(intake.lastBody(), "{}");
        assertEq(intake.requestInfo(id).payer, address(registry));
    }

    function test_intakeBodyBoundsRollBackThePayment() public {
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.EmptyBody.selector);
        registry.ask("");
        _assertUntouched(type(uint256).max);
        bytes memory tooLong = new bytes(16_385);
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.BodyTooLong.selector);
        registry.ask(tooLong);
        _assertUntouched(type(uint256).max);
    }

    function test_fullCallerBalanceAndMaximumBody() public {
        intake.setPrice(token.balanceOf(alice));
        bytes memory body = new bytes(16_384);
        body[0] = 0x7b;
        body[body.length - 1] = 0x7d;
        _ask(alice, body);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(recipient), 100 ether);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(intake.lastBody(), body);
    }

    function test_priceChangesAreReadOnEveryAsk() public {
        bytes32 first = _ask();
        intake.setPrice(7);
        bytes32 second = _ask(bob, "{}");
        assertNotEq(first, second);
        assertEq(token.balanceOf(recipient), 0.5 ether + 7);
        assertEq(token.balanceOf(alice), 99.5 ether);
        assertEq(token.balanceOf(bob), 100 ether - 7);
        assertEq(registry.asked(), 2);
        assertEq(token.allowance(address(registry), address(intake)), 0);
    }

    function test_notSoldDoesNotChargeOrRegister() public {
        intake.setPrice(0);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.NotSold.selector);
        registry.ask("{}");
        _assertUntouched(type(uint256).max);
    }

    function test_priceLookupFailureDoesNotChargeOrRegister() public {
        intake.setRejection(0, true);
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.PriceUnavailable.selector);
        registry.ask("{}");
        _assertUntouched(type(uint256).max);
    }

    function test_insufficientBalanceRollsBackConsumedAllowance() public {
        intake.setPrice(100 ether + 1);
        vm.prank(alice);
        token.approve(address(registry), 100 ether + 1);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.TransferFailed.selector);
        registry.ask("{}");
        _assertUntouched(100 ether + 1);
    }

    function test_noApprovalAndOneWeiShortApprovalBothRevert() public {
        vm.prank(alice);
        token.approve(address(registry), 0);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.TransferFailed.selector);
        registry.ask("{}");
        _assertUntouched(0);

        vm.prank(alice);
        token.approve(address(registry), 0.5 ether - 1);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.TransferFailed.selector);
        registry.ask("{}");
        _assertUntouched(0.5 ether - 1);
    }

    function test_priceIncreaseBeyondApprovalCannotChargeOldQuote() public {
        vm.prank(alice);
        token.approve(address(registry), 0.5 ether);
        intake.setPrice(0.5 ether + 1);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.TransferFailed.selector);
        registry.ask("{}");
        _assertUntouched(0.5 ether);
    }

    /// Both malformed ABI returns and explicit token failures must roll back token state.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_badTokenReturnRollsBackBothPaymentLegs(uint8 rawMode, bool duringApproval) public {
        PaymentToken.Reply[4] memory modes = [
            PaymentToken.Reply.False, PaymentToken.Reply.Revert, PaymentToken.Reply.Short, PaymentToken.Reply.NonBoolean
        ];
        PaymentToken.Reply mode = modes[bound(rawMode, 0, modes.length - 1)];
        token.configure(
            duringApproval ? PaymentToken.Reply.True : mode, duringApproval ? mode : PaymentToken.Reply.True, address(0)
        );
        vm.prank(alice);
        // Short/non-bool return data fails ABI decoding; false/revert is TransferFailed.
        (bool ok,) = address(registry).call(abi.encodeCall(registry.ask, (bytes("{}"))));
        assertFalse(ok, "malformed or unsuccessful token call must fail the ask");
        _assertUntouched(type(uint256).max);
    }

    function test_noReturnTokenIsSupportedOnTransferAndApproval() public {
        token.configure(PaymentToken.Reply.Empty, PaymentToken.Reply.Empty, address(0));
        _ask();
        assertEq(token.balanceOf(alice), 99.5 ether);
        assertEq(token.balanceOf(recipient), 0.5 ether);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(registry.asked(), 1);
    }

    function test_rejectionBeforeIntakePullRollsBackCallerPayment() public {
        intake.setRejection(1, false);
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.RequestRejected.selector);
        registry.ask("{}");
        _assertUntouched(type(uint256).max);
    }

    function test_rejectionAfterIntakePullRollsBackRecipientPayment() public {
        intake.setRejection(2, false);
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.RequestRejected.selector);
        registry.ask("{}");
        _assertUntouched(type(uint256).max);
    }

    function test_tokenRejectsOnlyIntakePullAndEntireAskRollsBack() public {
        token.configure(PaymentToken.Reply.True, PaymentToken.Reply.True, address(intake));
        vm.prank(alice);
        vm.expectRevert(RecordingIntake.PaymentRejected.selector);
        registry.ask("{}");
        _assertUntouched(type(uint256).max);
    }

    function test_donationCannotSubsidizeAnUnfundedAsk() public {
        vm.prank(bob);
        token.transfer(address(registry), 1 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.TransferFailed.selector);
        registry.ask("{}");
        assertEq(token.balanceOf(address(registry)), 1 ether);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(registry.asked(), 0);
    }

    function test_askDoesNotSpendPreexistingDonation() public {
        vm.prank(bob);
        token.transfer(address(registry), 1 ether);
        _ask();
        assertEq(token.balanceOf(address(registry)), 1 ether, "only unsolicited donation remains");
        assertEq(token.balanceOf(alice), 99.5 ether);
        assertEq(token.balanceOf(recipient), 0.5 ether);
        assertEq(token.allowance(address(registry), address(intake)), 0);
    }

    function test_plainEthAndPayableAskAreRejectedWithoutTakingFunds() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool plain,) = address(registry).call{value: 1}("");
        assertFalse(plain);
        vm.prank(alice);
        (bool paid,) = address(registry).call{value: 1}(abi.encodeCall(registry.ask, (bytes("{}"))));
        assertFalse(paid);
        assertEq(alice.balance, 1 ether);
        assertEq(address(registry).balance, 0);
        _assertUntouched(type(uint256).max);
    }

    function _assertUntouched(uint256 userAllowance) internal view {
        assertEq(token.balanceOf(alice), 100 ether, "caller payment rolled back");
        assertEq(token.balanceOf(bob), 100 ether, "other caller unchanged");
        assertEq(token.balanceOf(recipient), 0, "recipient payment rolled back");
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(alice, address(registry)), userAllowance);
        assertEq(token.allowance(address(registry), address(intake)), 0);
        assertEq(intake.nonce(), 0);
        assertEq(registry.asked(), 0);
        bytes32 wouldBeId = keccak256(abi.encode(block.chainid, address(intake), uint256(1)));
        (AskSwarmRegistry.Ask memory k,) = registry.get(wouldBeId);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.None));
        assertEq(k.asker, address(0));
    }
}
