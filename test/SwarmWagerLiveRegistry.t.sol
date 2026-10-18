// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmWagerTestBase, IERC20W} from "./SwarmWager.t.sol";
import {SwarmWager, IAskSwarmRegistry} from "../src/SwarmWager.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake} from "../src/IIntake.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

/// With --fork-url, uses the existing #2099 registry, never a fresh deployment. Offline, installs
/// the accepted source at that address as a fixture. Both paths exercise the launch's exact inputs.
contract SwarmWagerLiveRegistryTest is SwarmWagerTestBase {
    address constant LIVE_REGISTRY = 0x53e1E2f33f05086086AdF618Ca92c3Cb0ab111CD;
    address constant LIVE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function setUp() public override {
        if (INTAKE.code.length == 0) {
            vm.chainId(1);
            vm.roll(26_300_000);
            vm.warp(1_792_300_000);
            vm.etch(IMD, address(new MockERC20()).code);
            vm.etch(INTAKE, address(new MockIntake(makeAddr("writer"), IMD)).code);
        }
        if (LIVE_REGISTRY.code.length == 0) {
            deployCodeTo("AskSwarmRegistry.sol:AskSwarmRegistry", abi.encode(INTAKE, IMD, LIVE_SIGNER), LIVE_REGISTRY);
        }
        reg = AskSwarmRegistry(LIVE_REGISTRY);
        wager = new SwarmWager(LIVE_REGISTRY, IMD);
        deal(IMD, alice, 10 ether);
        deal(IMD, bob, 10 ether);
        vm.prank(alice);
        IERC20W(IMD).approve(address(wager), type(uint256).max);
        vm.prank(bob);
        IERC20W(IMD).approve(address(wager), type(uint256).max);
    }

    function test_launchAddressesAndLiveAskGetAndUnverifiedRefund() public {
        assertEq(block.chainid, 1);
        assertEq(address(wager.REGISTRY()), LIVE_REGISTRY);
        assertEq(wager.IMD(), IMD);
        assertEq(address(reg.INTAKE()), INTAKE);
        assertEq(reg.IMD(), IMD);
        assertEq(reg.SIGNER(), LIVE_SIGNER);
        uint256 price = reg.price();
        uint256 id = _open(true);
        bytes32 rid = _rid(id);
        (IAskSwarmRegistry.Ask memory k, IAskSwarmRegistry.Answer memory a) = wager.REGISTRY().get(rid);
        assertEq(k.asker, address(wager));
        assertEq(uint8(k.status), uint8(IAskSwarmRegistry.Status.Pending));
        assertEq(a.answerHash, bytes32(0));
        (address payer, address target, bytes4 selector, bool completed) = IIntake(INTAKE).requests(rid);
        assertEq(payer, LIVE_REGISTRY);
        assertEq(target, LIVE_REGISTRY);
        assertEq(selector, reg.onOracleResult.selector);
        assertFalse(completed);
        assertEq(_bal(address(wager)), 2 * STAKE);
        assertEq(_bal(alice), 10 ether - STAKE - price);
        // A fixture key is not the live oracle key. This must be Unverified and refund stakes.
        _answer(id, abi.encode(true), 0, 15, 11, 12);
        (k, a) = wager.REGISTRY().get(rid);
        assertEq(uint8(k.status), uint8(IAskSwarmRegistry.Status.Unverified));
        assertFalse(a.verified);
        assertEq(a.answer, abi.encode(true));
        assertEq(a.answerType, 0);
        assertEq(a.panelSize, 15);
        assertEq(a.quorum, 11);
        assertEq(a.agreed, 12);
        wager.settle(id);
        assertEq(_bal(alice), 10 ether - price);
        assertEq(_bal(bob), 10 ether);
        assertEq(_bal(address(wager)), 0);
    }

    function test_liveLostOutcomeRefunds() public {
        uint256 price = reg.price();
        uint256 id = _open(false);
        bytes32 rid = _rid(id);
        vm.prank(IIntake(INTAKE).writer());
        IIntake(INTAKE).complete(rid, 0, bytes32(0), "", hex"00");
        reg.markLost(rid);
        (IAskSwarmRegistry.Ask memory k,) = wager.REGISTRY().get(rid);
        assertEq(uint8(k.status), uint8(IAskSwarmRegistry.Status.Lost));
        wager.settle(id);
        assertEq(_bal(alice), 10 ether - price);
        assertEq(_bal(bob), 10 ether);
        assertEq(_bal(address(wager)), 0);
    }
}
