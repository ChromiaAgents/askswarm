// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {SwarmWager} from "../src/SwarmWager.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

interface IERC20W {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Offline by default; on a mainnet fork uses real Intake v2 and IMD. A fresh test-only registry
/// accepts fixture signatures; the production registry is never redeployed by the launch.
abstract contract SwarmWagerTestBase is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant PK = 0xB0B;
    uint96 constant STAKE = 3 ether;

    AskSwarmRegistry reg;
    SwarmWager wager;
    address alice = makeAddr("alice"); // creator
    address bob = makeAddr("bob"); // counterparty
    bytes constant BODY =
        '{"v":1,"question":"Did Argentina win the 2022 FIFA World Cup?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":15,"quorum":11,"validForSeconds":86400}';

    function setUp() public virtual {
        if (INTAKE.code.length == 0) {
            vm.chainId(1);
            vm.roll(26_300_000);
            vm.warp(1_792_300_000);
            vm.etch(IMD, address(new MockERC20()).code);
            vm.etch(INTAKE, address(new MockIntake(makeAddr("writer"), IMD)).code);
        }
        reg = new AskSwarmRegistry(INTAKE, IMD, vm.addr(PK));
        wager = new SwarmWager(address(reg), IMD);
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            deal(IMD, u, 10 ether);
            vm.prank(u);
            IERC20W(IMD).approve(address(wager), type(uint256).max);
        }
    }

    // ---- helpers ----

    function _open(bool aliceSaysYes) internal returns (uint256 id) {
        vm.prank(alice);
        id = wager.create(
            BODY, aliceSaysYes, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours)
        );
        vm.prank(bob);
        wager.join(id);
        vm.warp(block.timestamp + 1 hours);
        wager.resolve(id);
    }

    function _rid(uint256 id) internal view returns (bytes32 r) {
        (SwarmWager.Wager memory w,) = wager.get(id);
        r = w.requestId;
    }

    function _answer(uint256 id, bytes memory ans, uint8 t, uint16 panel, uint16 quorum, uint16 agreed) internal {
        OracleAttestation memory a = _attestation(id, ans, t, panel, quorum, agreed);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, reg.digest(a));
        _deliver(id, a, abi.encodePacked(r, s, v));
    }

    function _attestation(uint256 id, bytes memory ans, uint8 t, uint16 panel, uint16 quorum, uint16 agreed)
        internal
        view
        returns (OracleAttestation memory a)
    {
        a = OracleAttestation({
            requestId: _rid(id),
            chainId: block.chainid,
            questionHash: keccak256(BODY),
            answerType: t,
            answer: ans,
            figure: 0,
            fromBlock: uint64(block.number - 10),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: bytes32(uint256(1)),
            panelSize: panel,
            quorum: quorum,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _deliver(uint256 id, OracleAttestation memory a, bytes memory signature) internal {
        bytes32 rid = _rid(id);
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(rid, 0, bytes32(0), "", abi.encode(rid, a, signature));
        (AskSwarmRegistry.Ask memory k,) = reg.get(rid);
        assertTrue(k.status != AskSwarmRegistry.Status.Pending, "registry callback did not land");
    }

    function _fail(uint256 id, uint8 status) internal {
        bytes32 rid = _rid(id);
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE)
            .complete(
                rid,
                status,
                bytes32(0),
                "",
                abi.encode(rid, status, bytes32("disagreed"), uint16(10), uint16(14), bytes(""))
            );
    }

    function _bal(address u) internal view returns (uint256) {
        return IERC20W(IMD).balanceOf(u);
    }
}

contract SwarmWagerTest is SwarmWagerTestBase {
    // ---- outcomes ----

    function test_yesWins() public {
        uint256 id = _open(true); // alice says yes
        _answer(id, abi.encode(true), 0, 15, 11, 12);
        wager.settle(id);
        assertEq(_bal(alice), 10 ether - 0.5 ether + STAKE, "alice wins bob's stake, paid the fee");
        assertEq(_bal(bob), 10 ether - STAKE);
        assertEq(_bal(address(wager)), 0, "nothing left behind");
        (SwarmWager.Wager memory w,) = wager.get(id);
        assertEq(uint8(w.state), uint8(SwarmWager.State.Paid));
        assertEq(w.winner, alice);
    }

    function test_noWins() public {
        uint256 id = _open(true);
        _answer(id, abi.encode(false), 0, 15, 11, 11);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether + STAKE);
        assertEq(_bal(address(wager)), 0);
    }

    function test_splitPanelRefunds() public {
        uint256 id = _open(true);
        _fail(id, 2);
        wager.settle(id);
        assertEq(_bal(alice), 10 ether - 0.5 ether, "stake back, fee spent on the panel");
        assertEq(_bal(bob), 10 ether);
        assertEq(_bal(address(wager)), 0);
    }

    function test_refusedRefunds() public {
        uint256 id = _open(false);
        _fail(id, 1);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether);
    }

    function test_nonBoolAnswerRefunds() public {
        uint256 id = _open(true);
        _answer(id, abi.encode(uint256(2022)), 3, 15, 11, 12);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether, "a uint answer settles nothing");
    }

    function test_minorityAnswerRefunds() public {
        // 11 of 25 meets a quorum of 11 but is not a majority of the panel
        uint256 id = _open(true);
        _answer(id, abi.encode(true), 0, 25, 11, 11);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether);
    }

    function test_nonCanonicalBoolRefunds() public {
        uint256 id = _open(true);
        _answer(id, abi.encode(uint256(7)), 0, 15, 11, 12);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether);
    }

    function test_pendingThenTimeoutRefunds() public {
        uint256 id = _open(true);
        vm.expectRevert(SwarmWager.StillPending.selector);
        wager.settle(id);
        vm.warp(block.timestamp + 3 days + 1);
        wager.settle(id);
        assertEq(_bal(bob), 10 ether);
    }

    // ---- lifecycle guards ----

    function test_cancelUnmatched() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.prank(bob);
        vm.expectRevert(SwarmWager.NotCreator.selector);
        wager.cancel(id);
        vm.prank(alice);
        wager.cancel(id);
        assertEq(_bal(alice), 10 ether, "stake and fee back");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Refunded));
        wager.join(id);
    }

    function test_anyoneCancelsAfterJoinBy() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob);
        vm.expectRevert(SwarmWager.TooLate.selector);
        wager.join(id);
        wager.cancel(id);
        assertEq(_bal(alice), 10 ether);
    }

    function test_creatorCannotTakeBothSides() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.prank(alice);
        vm.expectRevert(SwarmWager.SameParty.selector);
        wager.join(id);
    }

    function test_resolveWaitsAndOnlyOnce() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 5 hours));
        vm.prank(bob);
        wager.join(id);
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.resolve(id);
        vm.warp(block.timestamp + 5 hours);
        wager.resolve(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Asked));
        wager.resolve(id);
        assertEq(IERC20W(IMD).balanceOf(address(wager)), 2 * STAKE, "only stakes left, fee paid to the swarm");
    }

    function test_settleOnlyOnce() public {
        uint256 id = _open(true);
        _answer(id, abi.encode(true), 0, 15, 11, 12);
        wager.settle(id);
        vm.expectRevert(abi.encodeWithSelector(SwarmWager.WrongState.selector, SwarmWager.State.Paid));
        wager.settle(id);
    }

    function test_abandonWhenNeverResolved() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, STAKE, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours));
        vm.prank(bob);
        wager.join(id);
        vm.warp(block.timestamp + 1 hours + 3 days);
        vm.expectRevert(SwarmWager.TooEarly.selector);
        wager.abandon(id);
        vm.warp(block.timestamp + 1);
        wager.abandon(id);
        assertEq(_bal(alice), 10 ether, "stake and unspent fee back");
        assertEq(_bal(bob), 10 ether);
    }

    function test_badTerms() public {
        vm.startPrank(alice);
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create("", true, STAKE, uint64(block.timestamp + 1), uint64(block.timestamp + 1));
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, 0, uint64(block.timestamp + 1), uint64(block.timestamp + 1));
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, STAKE, uint64(block.timestamp), uint64(block.timestamp + 1));
        vm.expectRevert(SwarmWager.BadTerms.selector);
        wager.create(BODY, true, STAKE, uint64(block.timestamp + 10), uint64(block.timestamp + 5));
        vm.stopPrank();
        vm.expectRevert(SwarmWager.ZeroAddress.selector);
        new SwarmWager(address(0), IMD);
    }
}
