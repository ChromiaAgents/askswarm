// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";
import {SwarmWager, IAskSwarmRegistry} from "src/SwarmWager.sol";
import {BlockableIMD} from "./mocks/BlockableIMD.sol";

/// Registry stand-in: quotes `price`, pulls it on askAtMost, and returns the record the test sets.
contract BlockStubRegistry {
    BlockableIMD public immutable imd;
    uint256 public price = 0.5 ether;
    IAskSwarmRegistry.Ask internal _k;
    IAskSwarmRegistry.Answer internal _a;

    constructor(BlockableIMD imd_) {
        imd = imd_;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function askAtMost(bytes calldata, uint256 maxPrice) external returns (bytes32) {
        require(maxPrice >= price, "PriceAboveMax");
        require(imd.transferFrom(msg.sender, address(this), price), "pull");
        _k = IAskSwarmRegistry.Ask(msg.sender, uint64(block.timestamp), IAskSwarmRegistry.Status.Pending);
        return keccak256("request");
    }

    function answer(bool yes) external {
        _k.status = IAskSwarmRegistry.Status.Answered;
        _a = IAskSwarmRegistry.Answer({
            questionHash: bytes32(uint256(1)),
            answer: abi.encode(yes),
            answerHash: keccak256(abi.encode(yes)),
            answerType: 0,
            panelSize: 7,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            verified: true
        });
    }

    function get(bytes32) external view returns (IAskSwarmRegistry.Ask memory, IAskSwarmRegistry.Answer memory) {
        return (_k, _a);
    }
}

/// Review findings ad6653d75214 and d4e9fc2df017: Robinhood Chain's IMD can block an address, and a
/// push to one blocked third party must not hold anyone else's money. A refused push is credited to
/// `owed` and the blocked address withdraws it once the token lets it.
contract BlockedThirdPartyTest is Test {
    BlockableIMD imd;
    BlockStubRegistry registry;
    SwarmMarket market;
    SwarmWager wager;
    address treasury = makeAddr("blocked treasury");
    address alice = makeAddr("blocked alice");
    address bob = makeAddr("blocked bob");
    bytes constant BODY = '{"v":1,"question":"q","answerType":"bool","panelSize":7,"quorum":4}';

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_792_300_000);
        imd = new BlockableIMD();
        registry = new BlockStubRegistry(imd);
        market = new SwarmMarket(address(registry), address(imd), treasury);
        wager = new SwarmWager(address(registry), address(imd));
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            imd.mint(users[i], 100 ether);
            vm.startPrank(users[i]);
            imd.approve(address(market), type(uint256).max);
            imd.approve(address(wager), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---- SwarmMarket ----

    function _market(uint128 yesAlice, uint128 noBob) internal returns (uint256 id) {
        uint64 at = uint64(block.timestamp + 1 hours);
        vm.startPrank(alice);
        id = market.open(BODY, at, at);
        market.stake(id, true, yesAlice);
        vm.stopPrank();
        vm.prank(bob);
        market.stake(id, false, noBob);
    }

    function test_marketAbandonVoidsWhileCreatorBlocked() public {
        uint256 id = _market(10 ether, 5 ether);
        imd.setBlocked(alice, true);
        vm.warp(block.timestamp + 1 hours + market.RESOLVE_WINDOW() + 1);
        market.abandon(id);
        vm.prank(bob);
        assertEq(market.claim(id), 5 ether);
        assertEq(imd.balanceOf(bob), 100 ether);
        assertEq(market.owed(alice), 0.5 ether);
        vm.prank(alice);
        vm.expectRevert(SwarmMarket.TransferFailed.selector);
        market.withdraw();
        imd.setBlocked(alice, false);
        vm.startPrank(alice);
        assertEq(market.withdraw(), 0.5 ether);
        assertEq(market.claim(id), 10 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(imd.balanceOf(address(market)), 0);
    }

    function test_marketSettlesWhileCreatorBlocked() public {
        uint256 id = _market(10 ether, 10 ether);
        vm.warp(block.timestamp + 1 hours);
        market.resolve(id);
        registry.answer(false);
        imd.setBlocked(alice, true);
        market.settle(id);
        assertEq(market.owed(alice), 0.1 ether);
        assertEq(imd.balanceOf(treasury), 0.1 ether);
        vm.prank(bob);
        assertEq(market.claim(id), 19.8 ether);
        assertEq(imd.balanceOf(address(market)), 0.1 ether, "only the creator's credit remains");
    }

    function test_marketSettlesWhileTreasuryBlocked() public {
        uint256 id = _market(10 ether, 10 ether);
        vm.warp(block.timestamp + 1 hours);
        market.resolve(id);
        registry.answer(true);
        imd.setBlocked(treasury, true);
        market.settle(id);
        assertEq(market.owed(treasury), 0.1 ether);
        vm.prank(alice);
        assertEq(market.claim(id), 19.8 ether);
        imd.setBlocked(treasury, false);
        vm.prank(treasury);
        market.withdraw();
        assertEq(imd.balanceOf(treasury), 0.1 ether);
        assertEq(imd.balanceOf(address(market)), 0);
    }

    function test_marketResolvesWhileCreatorBlockedAndCreditsRemainder() public {
        uint256 id = _market(10 ether, 10 ether);
        registry.setPrice(0.2 ether);
        vm.warp(block.timestamp + 1 hours);
        imd.setBlocked(alice, true);
        market.resolve(id);
        (SwarmMarket.Market memory m,) = market.get(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Asked));
        assertEq(market.owed(alice), 0.3 ether);
    }

    // ---- SwarmWager ----

    function _wager() internal returns (uint256 id) {
        vm.prank(alice);
        id = wager.create(BODY, true, 3 ether, uint64(block.timestamp + 1 days), uint64(block.timestamp + 1 days));
        vm.prank(bob);
        wager.join(id);
    }

    function test_wagerTimeoutRefundsCounterpartyWhileOtherBlocked() public {
        uint256 id = _wager();
        vm.warp(block.timestamp + 1 days);
        wager.resolve(id);
        imd.setBlocked(alice, true);
        vm.warp(block.timestamp + wager.ANSWER_WINDOW() + 1);
        wager.settle(id);
        assertEq(imd.balanceOf(bob), 100 ether);
        assertEq(wager.owed(alice), 3 ether);
        imd.setBlocked(alice, false);
        vm.prank(alice);
        assertEq(wager.withdraw(), 3 ether);
        assertEq(imd.balanceOf(alice), 99.5 ether);
        assertEq(imd.balanceOf(address(wager)), 0);
        vm.prank(alice);
        vm.expectRevert(SwarmWager.NothingOwed.selector);
        wager.withdraw();
    }

    function test_wagerAbandonRefundsCounterpartyWhileOtherBlocked() public {
        uint256 id = _wager();
        imd.setBlocked(alice, true);
        vm.warp(block.timestamp + 1 days + wager.ANSWER_WINDOW() + 1);
        wager.abandon(id);
        assertEq(imd.balanceOf(bob), 100 ether);
        assertEq(wager.owed(alice), 3.5 ether, "stake and fee escrow credited");
        assertEq(imd.balanceOf(address(wager)), 3.5 ether);
        (SwarmWager.Wager memory w,) = wager.get(id);
        assertEq(uint8(w.state), uint8(SwarmWager.State.Refunded));
        assertEq(w.fee, 0);
    }

    function test_wagerResolvesWhileCreatorBlockedAndCreditsRemainder() public {
        uint256 id = _wager();
        registry.setPrice(0.2 ether);
        vm.warp(block.timestamp + 1 days);
        imd.setBlocked(alice, true);
        wager.resolve(id);
        (SwarmWager.Wager memory w,) = wager.get(id);
        assertEq(uint8(w.state), uint8(SwarmWager.State.Asked));
        assertEq(wager.owed(alice), 0.3 ether);
    }

    /// Review finding 9bcb33ce3798: cancel and abandon return the fee escrow and now zero the field.
    function test_wagerFeeFieldZeroedOnCancelAndAbandon() public {
        vm.prank(alice);
        uint256 id =
            wager.create(BODY, true, 10 ether, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours));
        vm.prank(alice);
        wager.cancel(id);
        (SwarmWager.Wager memory w,) = wager.get(id);
        assertEq(w.fee, 0);
        assertEq(imd.balanceOf(alice), 100 ether);

        id = _wager();
        vm.warp(block.timestamp + 1 days + wager.ANSWER_WINDOW() + 1);
        wager.abandon(id);
        (w,) = wager.get(id);
        assertEq(w.fee, 0);
        assertEq(imd.balanceOf(address(wager)), 0);
    }
}
