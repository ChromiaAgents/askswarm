// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {SwarmMarket} from "../src/SwarmMarket.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

interface IERC20M {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Offline by default; on a mainnet fork uses real Intake v2 and IMD, a fresh registry signed by
/// a test key, and the impersonated writer. Uses the same offline transport as the registry tests.
/// `forge test --fork-url $ETH_RPC_URL --match-path test/SwarmMarket.t.sol`
contract SwarmMarketTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant PK = 0xB0B;

    AskSwarmRegistry reg;
    SwarmMarket mkt;
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address y1 = makeAddr("y1");
    address y2 = makeAddr("y2");
    address n1 = makeAddr("n1");
    bytes constant BODY =
        '{"v":1,"question":"Did Argentina win the 2022 FIFA World Cup?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":15,"quorum":11,"validForSeconds":86400}';

    function setUp() public {
        if (INTAKE.code.length == 0) {
            vm.chainId(1);
            vm.roll(26_300_000);
            vm.warp(1_792_300_000);
            vm.etch(IMD, address(new MockERC20()).code);
            vm.etch(INTAKE, address(new MockIntake(makeAddr("writer"), IMD)).code);
        }
        reg = new AskSwarmRegistry(INTAKE, IMD, vm.addr(PK));
        mkt = new SwarmMarket(address(reg), IMD, treasury);
        address[4] memory us = [creator, y1, y2, n1];
        for (uint256 i; i < 4; i++) {
            deal(IMD, us[i], 1000 ether);
            vm.prank(us[i]);
            IERC20M(IMD).approve(address(mkt), type(uint256).max);
        }
    }

    function _bal(address u) internal view returns (uint256) {
        return IERC20M(IMD).balanceOf(u);
    }

    function _openAndStake() internal returns (uint256 id) {
        vm.prank(creator);
        id = mkt.open(BODY, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.prank(y1);
        mkt.stake(id, true, 30 ether);
        vm.prank(y2);
        mkt.stake(id, true, 10 ether);
        vm.prank(n1);
        mkt.stake(id, false, 60 ether);
    }

    function _resolve(uint256 id) internal returns (bytes32 rid) {
        (SwarmMarket.Market memory beforeResolve,) = mkt.get(id);
        vm.warp(beforeResolve.resolveAfter);
        mkt.resolve(id);
        (SwarmMarket.Market memory m,) = mkt.get(id);
        rid = m.requestId;
    }

    function _answer(bytes32 rid, bytes memory ans, uint8 t, uint16 panel, uint16 agreed) internal {
        OracleAttestation memory a = OracleAttestation({
            requestId: rid,
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
            quorum: 11,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, reg.digest(a));
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(rid, 0, bytes32(0), "", abi.encode(rid, a, abi.encodePacked(r, s, v)));
    }

    function _fail(bytes32 rid) internal {
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE)
            .complete(
                rid,
                2,
                bytes32(0),
                "",
                abi.encode(rid, uint8(2), bytes32("disagreed"), uint16(10), uint16(14), bytes(""))
            );
    }

    function test_yesWinsProRataWithFee() public {
        uint256 id = _openAndStake();
        assertEq(mkt.oddsYesBps(id), 4000, "40 yes / 100 total");
        bytes32 rid = _resolve(id);
        _answer(rid, abi.encode(true), 0, 15, 12);
        mkt.settle(id);
        // losers 60, fee 2% = 1.2, winners share 58.8 over a yes pool of 40
        assertEq(_bal(treasury), 0.6 ether, "treasury half of the fee");
        assertEq(_bal(creator), 1000 ether - 0.5 ether + 0.6 ether, "creator paid the swarm, earned half the fee");
        vm.prank(y1);
        assertEq(mkt.claim(id), 30 ether + 30 ether * 58.8 ether / 40 ether);
        vm.prank(y2);
        assertEq(mkt.claim(id), 10 ether + 10 ether * 58.8 ether / 40 ether);
        vm.prank(n1);
        vm.expectRevert(SwarmMarket.NothingToClaim.selector);
        mkt.claim(id);
        assertLe(_bal(address(mkt)), 2, "only rounding dust left");
    }

    function test_noWins() public {
        uint256 id = _openAndStake();
        bytes32 rid = _resolve(id);
        _answer(rid, abi.encode(false), 0, 15, 11);
        mkt.settle(id);
        vm.prank(n1);
        uint256 got = mkt.claim(id);
        assertEq(got, 60 ether + 40 ether * 98 / 100, "stake plus losers minus 2%");
        assertEq(_bal(treasury), 0.4 ether);
    }

    function test_splitPanelVoidsAndRefundsEveryone() public {
        uint256 id = _openAndStake();
        bytes32 rid = _resolve(id);
        _fail(rid);
        mkt.settle(id);
        vm.prank(y1);
        assertEq(mkt.claim(id), 30 ether);
        vm.prank(n1);
        assertEq(mkt.claim(id), 60 ether);
        assertEq(_bal(treasury), 0, "no fee on a void market");
    }

    function test_oneSidedMarketVoidsWithoutSpendingFee() public {
        vm.prank(creator);
        uint256 id = mkt.open(BODY, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours));
        vm.prank(y1);
        mkt.stake(id, true, 5 ether);
        vm.warp(block.timestamp + 1 hours);
        mkt.resolve(id);
        assertEq(_bal(creator), 1000 ether, "fee escrow back, swarm never asked");
        vm.prank(y1);
        assertEq(mkt.claim(id), 5 ether);
    }

    function test_minorityAndNonBoolVoid() public {
        uint256 id = _openAndStake();
        bytes32 rid = _resolve(id);
        _answer(rid, abi.encode(true), 0, 25, 11); // 11/25 is not a majority
        mkt.settle(id);
        (SwarmMarket.Market memory m,) = mkt.get(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));

        uint256 id2 = _openAndStake();
        bytes32 rid2 = _resolve(id2);
        _answer(rid2, abi.encode(uint256(2022)), 3, 15, 12);
        mkt.settle(id2);
        (m,) = mkt.get(id2);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));
    }

    function test_pendingThenTimeoutVoids() public {
        uint256 id = _openAndStake();
        _resolve(id);
        vm.expectRevert(SwarmMarket.StillPending.selector);
        mkt.settle(id);
        vm.warp(block.timestamp + 3 days + 1);
        mkt.settle(id);
        vm.prank(n1);
        assertEq(mkt.claim(id), 60 ether);
    }

    function test_stakingClosesAndClaimsOnce() public {
        uint256 id = _openAndStake();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(y1);
        vm.expectRevert(SwarmMarket.Closed.selector);
        mkt.stake(id, true, 1 ether);
        bytes32 rid = _resolve(id);
        _answer(rid, abi.encode(true), 0, 15, 12);
        mkt.settle(id);
        vm.startPrank(y1);
        mkt.claim(id);
        vm.expectRevert(SwarmMarket.NothingToClaim.selector);
        mkt.claim(id);
        vm.stopPrank();
    }

    function test_bothSidesSameUser() public {
        vm.prank(creator);
        uint256 id = mkt.open(BODY, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours));
        vm.startPrank(y1);
        mkt.stake(id, true, 10 ether);
        mkt.stake(id, false, 10 ether);
        vm.stopPrank();
        vm.prank(n1);
        mkt.stake(id, false, 10 ether);
        vm.warp(block.timestamp + 1 hours);
        mkt.resolve(id);
        (SwarmMarket.Market memory m,) = mkt.get(id);
        _answer(m.requestId, abi.encode(true), 0, 15, 12);
        mkt.settle(id);
        vm.prank(y1);
        assertEq(mkt.claim(id), 10 ether + 20 ether * 98 / 100, "y1 alone on yes takes the no pool less fee");
    }

    function test_guards() public {
        vm.startPrank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        mkt.open("", uint64(block.timestamp + 1), uint64(block.timestamp + 1));
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        mkt.open(BODY, uint64(block.timestamp), uint64(block.timestamp + 1));
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        mkt.open(BODY, uint64(block.timestamp + 10), uint64(block.timestamp + 5));
        uint256 id = mkt.open(BODY, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        mkt.stake(id, true, 0);
        vm.expectRevert(SwarmMarket.TooEarly.selector);
        mkt.resolve(id);
        vm.stopPrank();
        vm.expectRevert(SwarmMarket.ZeroAddress.selector);
        new SwarmMarket(address(reg), IMD, address(0));
    }

    function test_abandon() public {
        uint256 id = _openAndStake();
        (SwarmMarket.Market memory m,) = mkt.get(id);
        vm.warp(uint256(m.resolveAfter) + mkt.RESOLVE_WINDOW());
        vm.expectRevert(SwarmMarket.TooEarly.selector);
        mkt.abandon(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        mkt.abandon(id);
        assertEq(_bal(creator), 1000 ether, "fee escrow back");
        vm.prank(y2);
        assertEq(mkt.claim(id), 10 ether);
    }

    /// Solvency under arbitrary stakes: every winner can claim and the contract never pays out
    /// more than it holds.
    function testFuzz_solvent(uint96 a, uint96 b, uint96 c, bool yesWins) public {
        a = uint96(bound(a, 1, 30 ether));
        b = uint96(bound(b, 1, 30 ether));
        c = uint96(bound(c, 1, 30 ether));
        vm.prank(creator);
        uint256 id = mkt.open(BODY, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours));
        vm.prank(y1);
        mkt.stake(id, true, a);
        vm.prank(y2);
        mkt.stake(id, true, b);
        vm.prank(n1);
        mkt.stake(id, false, c);
        vm.warp(block.timestamp + 1 hours);
        mkt.resolve(id);
        (SwarmMarket.Market memory m,) = mkt.get(id);
        _answer(m.requestId, abi.encode(yesWins), 0, 15, 12);
        mkt.settle(id);
        if (yesWins) {
            vm.prank(y1);
            mkt.claim(id);
            vm.prank(y2);
            mkt.claim(id);
        } else {
            vm.prank(n1);
            mkt.claim(id);
        }
        assertLe(_bal(address(mkt)), 2, "dust only");
    }
}
