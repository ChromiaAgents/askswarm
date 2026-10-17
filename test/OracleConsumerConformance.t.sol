// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {OracleAttestation} from "../src/IIntake.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

/// @notice The oracle-consumer skill's conformance test, adapted to AskSwarmRegistry: the protocol's
/// vector values, digest and signature (made by `oracle-eip712.ts`) tie the registry's struct, type
/// string and domain to what the oracle actually signs. The registry is a same-chain consumer, so the
/// caller is a mock Intake and the `IntakeDelivery` case is dropped, as the skill says.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address writer = makeAddr("writer");
    address user = makeAddr("user");
    MockERC20 imd;
    MockIntake intake;
    AskSwarmRegistry consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        imd = new MockERC20();
        intake = new MockIntake(writer, address(imd));
        deployCodeTo(
            "AskSwarmRegistry.sol:AskSwarmRegistry", abi.encode(address(intake), address(imd), SIGNER), VECTOR_CONSUMER
        );
        consumer = AskSwarmRegistry(VECTOR_CONSUMER);
        deal(address(imd), user, 10 ether);
    }

    function vector() internal pure returns (OracleAttestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function _ask() internal returns (bytes32 id) {
        vm.startPrank(user);
        imd.approve(address(consumer), type(uint256).max);
        id = consumer.ask('{"v":1,"question":"q"}');
        vm.stopPrank();
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(consumer.digest(vector()), VECTOR_DIGEST, "struct, type string or domain differs from the protocol's");
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))), "callback parameters differ");
    }

    function test_acceptsTheProtocolSignatureAsDelivered() public {
        bytes32 id = _ask();
        vm.prank(writer);
        intake.complete(id, 0, bytes32(0), "", abi.encode(id, vector(), VECTOR_SIGNATURE));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory a) = consumer.get(id);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered), "not delivered or not verified under 200k");
        assertTrue(a.verified);
        assertEq(consumer.latestFor(vector().questionHash), id);
    }

    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        bytes32 id = _ask();
        OracleAttestation memory a = vector();
        a.requestId = keccak256("another request");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.digest(a));
        vm.prank(address(intake));
        consumer.onOracleResult(id, a, abi.encodePacked(r, s, v));
        (, AskSwarmRegistry.Answer memory got) = consumer.get(id);
        assertTrue(got.verified);
    }
}
