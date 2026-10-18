// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMarket} from "src/SwarmMarket.sol";

contract MarketDeploymentProbe {
    function deploy(bytes32 salt, address registry, address imd, address treasury) external returns (SwarmMarket) {
        return new SwarmMarket{salt: salt}(registry, imd, treasury);
    }
}

contract SwarmMarketDeploymentTest is Test {
    address constant REGISTRY = 0x53e1E2f33f05086086AdF618Ca92c3Cb0ab111CD;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant TREASURY = 0x571E17B13D8F6492Bbc372A160520B20BfdA320c;

    function test_factoryDeploysOnlyMarketWithStaticArgsOnEmptyChain() public {
        vm.chainId(1);
        vm.etch(REGISTRY, "");
        vm.etch(IMD, "");
        vm.etch(TREASURY, "");
        MarketDeploymentProbe factory = new MarketDeploymentProbe();
        bytes32 salt = keccak256("SwarmMarket deployment rehearsal");
        bytes memory init = abi.encodePacked(type(SwarmMarket).creationCode, abi.encode(REGISTRY, IMD, TREASURY));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(init)))))
        );
        assertLe(init.length, 49_152);
        SwarmMarket market = factory.deploy(salt, REGISTRY, IMD, TREASURY);
        assertEq(address(market), predicted);
        assertEq(address(market.REGISTRY()), REGISTRY);
        assertEq(market.IMD(), IMD);
        assertEq(market.TREASURY(), TREASURY);
        assertEq(market.count(), 0);
        assertEq(address(market).balance, 0);
        assertEq(REGISTRY.code.length, 0, "registry was not created by deployment");
        assertEq(IMD.code.length, 0);
        assertEq(vm.getNonce(address(market)), 1, "market constructor created no contracts");
        bytes memory code = address(market).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
        (bool hasOwner,) = address(market).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);
    }

    function test_zeroDependenciesAndEthAreRejected() public {
        vm.expectRevert(SwarmMarket.ZeroAddress.selector);
        new SwarmMarket(address(0), IMD, TREASURY);
        vm.expectRevert(SwarmMarket.ZeroAddress.selector);
        new SwarmMarket(REGISTRY, address(0), TREASURY);
        vm.expectRevert(SwarmMarket.ZeroAddress.selector);
        new SwarmMarket(REGISTRY, IMD, address(0));
        SwarmMarket market = new SwarmMarket(REGISTRY, IMD, TREASURY);
        vm.deal(address(this), 2 wei);
        (bool accepted,) = address(market).call{value: 1}("");
        assertFalse(accepted);
        bytes memory init = abi.encodePacked(type(SwarmMarket).creationCode, abi.encode(REGISTRY, IMD, TREASURY));
        address paidDeployment;
        assembly ("memory-safe") {
            paidDeployment := create(1, add(init, 32), mload(init))
        }
        assertEq(paidDeployment, address(0), "constructor is nonpayable");
    }
}
