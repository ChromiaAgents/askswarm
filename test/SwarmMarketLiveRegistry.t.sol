// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {AskSwarmRegistry} from "src/AskSwarmRegistry.sol";
import {IIntake} from "src/IIntake.sol";

interface LiveMarketToken {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// Optional mainnet integration: run with --fork-url and a block after registry launch #2099.
/// Deploys only SwarmMarket. Never etches/redeploys the registry, token or Intake and never
/// substitutes a production signer. No RPC setting is read or changed by these tests.
contract SwarmMarketLiveRegistryTest is Test {
    address internal constant REGISTRY = 0x53e1E2f33f05086086AdF618Ca92c3Cb0ab111CD;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant TREASURY = 0x571E17B13D8F6492Bbc372A160520B20BfdA320c;
    AskSwarmRegistry internal registry = AskSwarmRegistry(REGISTRY);
    LiveMarketToken internal token = LiveMarketToken(IMD);
    SwarmMarket internal market;
    address internal creator = makeAddr("live market creator");
    address internal yesStaker = makeAddr("live market yes");
    address internal noStaker = makeAddr("live market no");
    uint256 internal price;

    function setUp() public {
        // Offline execution must not masquerade as live coverage by installing local mocks.
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
        }
        assertEq(block.chainid, 1);
        assertGt(REGISTRY.code.length, 0, "fork must include registry launch #2099");
        assertGt(IMD.code.length, 0);
        assertEq(registry.IMD(), IMD);
        price = registry.price();
        assertGt(price, 0);
        market = new SwarmMarket(REGISTRY, IMD, TREASURY);
        address[3] memory users = [creator, yesStaker, noStaker];
        for (uint256 i; i < users.length; ++i) {
            deal(IMD, users[i], price + 100 ether);
            vm.prank(users[i]);
            assertTrue(token.approve(address(market), type(uint256).max));
        }
    }

    function _open(bool both) internal returns (uint256 id) {
        uint64 at = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(creator);
        // Deliberately invalid oracle body: tests exercise transport/payment/refusal, not screening.
        id = market.open("{}", at, at);
        vm.prank(yesStaker);
        market.stake(id, true, 30 ether);
        if (both) {
            vm.prank(noStaker);
            market.stake(id, false, 60 ether);
        }
        vm.warp(at);
    }

    function _request(uint256 id) internal view returns (bytes32) {
        (SwarmMarket.Market memory m,) = market.get(id);
        return m.requestId;
    }

    function test_liveResolvePaysCurrentPriceAndRegistersMarketAsAsker() public {
        bytes32 registryCode = REGISTRY.codehash;
        uint256 countBefore = registry.asked();
        uint256 registryBalance = token.balanceOf(REGISTRY);
        uint256 id = _open(true);
        vm.prank(noStaker);
        market.resolve(id);
        (AskSwarmRegistry.Ask memory k,) = registry.get(_request(id));
        assertEq(k.asker, address(market));
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Pending));
        assertEq(registry.asked(), countBefore + 1);
        assertEq(token.balanceOf(address(market)), 90 ether);
        assertEq(token.balanceOf(REGISTRY), registryBalance);
        assertEq(token.allowance(address(market), REGISTRY), 0);
        assertEq(REGISTRY.codehash, registryCode);
        (address payer, address target,, bool completed) = registry.INTAKE().requests(_request(id));
        assertEq(payer, REGISTRY);
        assertEq(target, REGISTRY);
        assertFalse(completed);
    }

    function test_liveOneSidedMarketRefundsWithoutAskingRegistry() public {
        uint256 countBefore = registry.asked();
        uint256 id = _open(false);
        market.resolve(id);
        assertEq(registry.asked(), countBefore);
        assertEq(_request(id), bytes32(0));
        assertEq(token.balanceOf(creator), price + 100 ether);
        vm.prank(yesStaker);
        assertEq(market.claim(id), 30 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_liveRefusalThroughIntakeVoidsAndPreservesPrincipal() public {
        uint256 id = _open(true);
        market.resolve(id);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        bytes32 rid = _request(id);
        IIntake intake = registry.INTAKE();
        vm.prank(intake.writer());
        intake.complete(
            rid, 1, bytes32(0), "", abi.encode(rid, uint8(1), bytes32("body_invalid"), uint16(0), uint16(0), bytes(""))
        );
        (AskSwarmRegistry.Ask memory k,) = registry.get(rid);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Refused));
        market.settle(id);
        vm.prank(yesStaker);
        assertEq(market.claim(id), 30 ether);
        vm.prank(noStaker);
        assertEq(market.claim(id), 60 ether);
        assertEq(token.balanceOf(address(market)), 0);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(token.balanceOf(creator), 100 ether, "only the oracle fee was spent");
    }
}
