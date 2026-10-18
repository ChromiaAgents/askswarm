// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmWager} from "../src/SwarmWager.sol";
import {DeployWager as Deploy} from "../script/DeployWager.s.sol";

contract WagerFactoryProbe {
    function deploy(bytes memory initCode, bytes32 salt, uint256 value) external returns (address created) {
        assembly ("memory-safe") {
            created := create2(value, add(initCode, 32), mload(initCode), salt)
        }
    }
}

contract SwarmWagerDeploymentTest is Test {
    address constant REGISTRY = 0x53e1E2f33f05086086AdF618Ca92c3Cb0ab111CD;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function test_factoryDeploysOnlyWagerOnEmptyChainWithStaticArguments() public {
        vm.chainId(1);
        vm.etch(REGISTRY, "");
        vm.etch(IMD, "");
        vm.expectCall(REGISTRY, "", uint64(0));
        vm.expectCall(IMD, "", uint64(0));
        WagerFactoryProbe factory = new WagerFactoryProbe();
        bytes memory initCode = bytes.concat(type(SwarmWager).creationCode, abi.encode(REGISTRY, IMD));
        bytes32 salt = keccak256("SwarmWager launch rehearsal");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, keccak256(initCode)))))
        );
        SwarmWager wager = SwarmWager(factory.deploy(initCode, salt, 0));
        assertEq(address(wager), predicted);
        assertEq(address(wager.REGISTRY()), REGISTRY);
        assertEq(wager.IMD(), IMD);
        assertEq(wager.count(), 0);
        assertEq(wager.MAX_TERM(), 365 days);
        assertEq(wager.ANSWER_WINDOW(), 3 days);
        assertEq(REGISTRY.code.length, 0, "registry was not deployed");
        assertEq(IMD.code.length, 0, "no token deployment");
        bytes memory code = address(wager).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(initCode.length, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
        (bool hasOwner,) = address(wager).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);
    }

    function test_constructorRejectsZeroDependenciesAndNativeValue() public {
        vm.expectRevert(SwarmWager.ZeroAddress.selector);
        new SwarmWager(address(0), IMD);
        vm.expectRevert(SwarmWager.ZeroAddress.selector);
        new SwarmWager(REGISTRY, address(0));
        WagerFactoryProbe factory = new WagerFactoryProbe();
        vm.deal(address(factory), 1 ether);
        bytes memory initCode = bytes.concat(type(SwarmWager).creationCode, abi.encode(REGISTRY, IMD));
        assertEq(factory.deploy(initCode, bytes32(0), 1), address(0));
        SwarmWager wager = new SwarmWager(REGISTRY, IMD);
        vm.deal(address(this), 1 ether);
        (bool acceptsETH,) = address(wager).call{value: 1}("");
        assertFalse(acceptsETH);
    }

    function test_projectScriptUsesExistingMainnetRegistry() public {
        vm.chainId(1);
        vm.etch(REGISTRY, "");
        vm.etch(IMD, "");
        Deploy script = new Deploy();
        SwarmWager wager = script.run();
        assertEq(address(wager.REGISTRY()), REGISTRY);
        assertEq(wager.IMD(), IMD);
        assertEq(REGISTRY.code.length, 0);
        assertEq(IMD.code.length, 0);
    }

    function test_projectScriptRejectsOtherChains() public {
        vm.chainId(11155111);
        Deploy script = new Deploy();
        vm.expectRevert("Ethereum mainnet only");
        script.run();
    }
}
