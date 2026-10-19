// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";
import {IIntake, OracleAttestation} from "../src/IIntake.sol";
import {SwarmMarket} from "../src/SwarmMarket.sol";
import {SwarmWager} from "../src/SwarmWager.sol";
import {MockIntake, MockERC20} from "./mocks/IntakeMocks.sol";

/// @dev Stands in for the project factory: deploys every application of the launch in one call,
/// each with CREATE2 and zero value, as `ProjectFactory.launchContracts` does in one transaction.
contract LaunchFactoryProbe {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
        }
    }
}

interface IERC20RH {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title Robinhood Chain (4663) launch rehearsal for the three AskSwarm contracts
/// @notice Deploys AskSwarmRegistry, SwarmMarket and SwarmWager in the launch's order with the
/// launch's exact constructor arguments, on an empty chain 4663 (no Intake, IMD, signer or treasury
/// code), through one factory call. Then checks what the launch reference requires of each: static
/// arguments only, no external call from any constructor, no child contract, runtime within
/// EIP-170, no DELEGATECALL/CALLCODE/SELFDESTRUCT, no owner. A second set of tests pins the
/// registry's EIP-712 domain to chain 4663 and runs the whole market and wager lifecycle at the
/// real Intake and IMD addresses with mocks etched there, since the contracts are otherwise
/// unchanged from the Ethereum launches.
contract RobinhoodChainLaunchTest is Test {
    uint256 constant CHAIN_ID = 4663;
    // Launch arguments (contracts/LAUNCH-RH.md). The attester and Intake v2 are the same on every chain.
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant TREASURY = 0x571E17B13D8F6492Bbc372A160520B20BfdA320c;
    // The mainnet IMD, which has no code on Robinhood Chain: a registry pointed at it could never ask.
    address constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    function setUp() public {
        vm.chainId(CHAIN_ID);
        vm.warp(1_792_300_000);
        vm.roll(26_300_000);
    }

    // ---- the launch itself ----

    function _initCodes() internal view returns (bytes[] memory codes, address[] memory predicted, address factory) {
        factory = address(uint160(uint256(keccak256("factory address is fixed for prediction"))));
        codes = new bytes[](3);
        predicted = new address[](3);
        bytes32[3] memory salts = [keccak256("AskSwarmRegistry"), keccak256("SwarmMarket"), keccak256("SwarmWager")];
        codes[0] = bytes.concat(type(AskSwarmRegistry).creationCode, abi.encode(INTAKE, IMD, SIGNER));
        predicted[0] = _create2(factory, salts[0], codes[0]);
        // $contract:AskSwarmRegistry resolves to the address the first deployment will take.
        codes[1] = bytes.concat(type(SwarmMarket).creationCode, abi.encode(predicted[0], IMD, TREASURY));
        predicted[1] = _create2(factory, salts[1], codes[1]);
        codes[2] = bytes.concat(type(SwarmWager).creationCode, abi.encode(predicted[0], IMD));
        predicted[2] = _create2(factory, salts[2], codes[2]);
    }

    function _create2(address deployer, bytes32 salt, bytes memory code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, keccak256(code))))));
    }

    function test_factoryDeploysAllThreeInOrderOnEmptyChain4663() public {
        assertEq(block.chainid, CHAIN_ID);
        assertEq(INTAKE.code.length, 0);
        assertEq(IMD.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        assertEq(TREASURY.code.length, 0);
        // No constructor may call any dependency: the launch checks run on an empty chain.
        vm.expectCall(INTAKE, "", uint64(0));
        vm.expectCall(IMD, "", uint64(0));
        vm.expectCall(SIGNER, "", uint64(0));
        vm.expectCall(TREASURY, "", uint64(0));

        (bytes[] memory codes, address[] memory predicted, address factory) = _initCodes();
        vm.etch(factory, address(new LaunchFactoryProbe()).code);
        bytes32[] memory salts = new bytes32[](3);
        salts[0] = keccak256("AskSwarmRegistry");
        salts[1] = keccak256("SwarmMarket");
        salts[2] = keccak256("SwarmWager");
        for (uint256 i; i < 3; ++i) {
            assertLe(codes[i].length, 49_152, "init code too large for the factory");
        }
        address[] memory deployed = LaunchFactoryProbe(factory).deployAll(codes, salts);

        AskSwarmRegistry registry = AskSwarmRegistry(deployed[0]);
        SwarmMarket market = SwarmMarket(deployed[1]);
        SwarmWager wager = SwarmWager(deployed[2]);
        for (uint256 i; i < 3; ++i) {
            assertEq(deployed[i], predicted[i], "address prediction");
            assertEq(vm.getNonce(deployed[i]), 1, "constructor created no contract");
            assertEq(deployed[i].balance, 0);
            _assertRuntimeIsLaunchable(deployed[i]);
            (bool hasOwner,) = deployed[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(hasOwner, "no owner");
        }

        assertEq(address(registry.INTAKE()), INTAKE);
        assertEq(registry.IMD(), IMD);
        assertEq(registry.SIGNER(), SIGNER);
        assertEq(registry.asked(), 0);
        assertEq(registry.ACTION(), bytes32("oracle.request@oracle-1"));

        assertEq(address(market.REGISTRY()), address(registry));
        assertEq(market.IMD(), IMD);
        assertEq(market.TREASURY(), TREASURY);
        assertEq(market.count(), 0);
        assertEq(market.MAX_TERM(), 365 days);
        assertEq(market.RESOLVE_WINDOW(), 1 hours);
        assertEq(market.ANSWER_WINDOW(), 3 days);
        assertEq(market.MIN_PANEL(), 7);
        assertEq(market.FEE_BPS(), 200);

        assertEq(address(wager.REGISTRY()), address(registry));
        assertEq(wager.IMD(), IMD);
        assertEq(wager.count(), 0);
        assertEq(wager.MAX_TERM(), 365 days);

        // Nothing else appeared on the chain.
        assertEq(INTAKE.code.length, 0);
        assertEq(IMD.code.length, 0);
    }

    function test_deploymentSendsNoValueAndRejectsEth() public {
        (bytes[] memory codes,,) = _initCodes();
        LaunchFactoryProbe factory = new LaunchFactoryProbe();
        vm.deal(address(this), 3 ether);
        for (uint256 i; i < 3; ++i) {
            bytes memory code = codes[i];
            address paid;
            assembly ("memory-safe") {
                paid := create(1, add(code, 32), mload(code))
            }
            assertEq(paid, address(0), "constructor is nonpayable");
        }
        bytes32[] memory salts = new bytes32[](3);
        salts[0] = bytes32(uint256(1));
        salts[1] = bytes32(uint256(2));
        salts[2] = bytes32(uint256(3));
        address[] memory deployed = factory.deployAll(codes, salts);
        for (uint256 i; i < 3; ++i) {
            (bool accepted,) = deployed[i].call{value: 1}("");
            assertFalse(accepted, "no ETH handling");
        }
    }

    function _assertRuntimeIsLaunchable(address app) internal view {
        bytes memory code = app.code;
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    // ---- the registry's domain is this chain and this registry ----

    function _vector(bytes32 rid) internal view returns (OracleAttestation memory a) {
        a = OracleAttestation({
            requestId: rid,
            chainId: CHAIN_ID,
            questionHash: keccak256("robinhood question"),
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: keccak256("closing block"),
            panelJobId: keccak256("panel job"),
            panelSize: 15,
            quorum: 11,
            agreed: 12,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 days)
        });
    }

    function _digestUnder(OracleAttestation memory a, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), chainId, verifyingContract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// The registry caches its EIP-712 domain at construction from `block.chainid`: deployed on
    /// 4663 with the launch arguments, it signs for chain 4663 and its own address, and not for the
    /// same address on Ethereum.
    function test_registryDomainIsChain4663AndItsOwnAddress() public {
        AskSwarmRegistry registry = new AskSwarmRegistry(INTAKE, IMD, SIGNER);
        OracleAttestation memory a = _vector(keccak256("rid"));
        bytes32 expected = _digestUnder(a, CHAIN_ID, address(registry));
        assertEq(registry.digest(a), expected, "domain is not (4663, registry)");
        assertTrue(registry.digest(a) != _digestUnder(a, 1, address(registry)), "domain must not be chain 1");
        assertTrue(registry.digest(a) != _digestUnder(a, CHAIN_ID, address(this)), "domain must be the registry itself");
        // Changing the chain after deployment does not move the cached domain (no fork protection
        // is claimed; answers would simply stop verifying on a forked chain).
        vm.chainId(1);
        assertEq(registry.digest(a), expected);
    }

    // ---- whole lifecycle at the real addresses, mocks etched there ----

    uint256 constant TEST_KEY = 0xB0B;
    address writer = makeAddr("writer");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _installMocks() internal {
        vm.etch(IMD, address(new MockERC20()).code);
        vm.etch(INTAKE, address(new MockIntake(writer, IMD)).code);
    }

    function _signedDelivery(AskSwarmRegistry registry, bytes32 rid, bool answer, uint256 key) internal {
        OracleAttestation memory a = _vector(rid);
        a.answer = abi.encode(answer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.digest(a));
        vm.prank(writer);
        IIntake(INTAKE).complete(rid, 0, bytes32(0), "", abi.encode(rid, a, abi.encodePacked(r, s, v)));
    }

    function _fundAndApprove(address user, address spender) internal {
        deal(IMD, user, 1000 ether);
        vm.prank(user);
        IERC20RH(IMD).approve(spender, type(uint256).max);
    }

    /// The system works end to end on chain 4663 at the launch's dependency addresses: the
    /// registry asks Intake and pays exactly its 0.5 IMD price in Robinhood IMD, the market settles
    /// from the verified answer with the 2% fee split creator/treasury, and the wager pays the pot.
    /// A test key stands in for the attester; the real signer's key is never needed.
    function test_marketAndWagerLifecycleOnChain4663() public {
        _installMocks();
        AskSwarmRegistry registry = new AskSwarmRegistry(INTAKE, IMD, vm.addr(TEST_KEY));
        SwarmMarket market = new SwarmMarket(address(registry), IMD, TREASURY);
        SwarmWager wager = new SwarmWager(address(registry), IMD);
        assertEq(registry.price(), 0.5 ether, "Intake sells oracle.request for Robinhood IMD");
        _fundAndApprove(creator, address(market));
        _fundAndApprove(alice, address(market));
        _fundAndApprove(bob, address(market));

        // Market: 40 yes vs 60 no, Yes wins.
        vm.prank(creator);
        uint256 id = market.open(
            "opaque body", uint64(vm.getBlockTimestamp() + 1 hours), uint64(vm.getBlockTimestamp() + 2 hours)
        );
        vm.prank(alice);
        market.stake(id, true, 40 ether);
        vm.prank(bob);
        market.stake(id, false, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        market.resolve(id);
        (SwarmMarket.Market memory m,) = market.get(id);
        assertEq(IERC20RH(IMD).balanceOf(INTAKE), 0.5 ether, "the registry forwarded exactly the price");
        assertEq(IERC20RH(IMD).balanceOf(address(registry)), 0);
        _signedDelivery(registry, m.requestId, true, TEST_KEY);
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = registry.get(m.requestId);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Answered), "callback landed under 200k");
        assertTrue(ans.verified);
        market.settle(id);
        assertEq(IERC20RH(IMD).balanceOf(TREASURY), 0.6 ether, "treasury half of 2% of the losing pool");
        assertEq(IERC20RH(IMD).balanceOf(creator), 1000 ether - 0.5 ether + 0.6 ether);
        vm.prank(alice);
        assertEq(market.claim(id), 40 ether + 58.8 ether);
        assertEq(market.claimable(id, bob), 0);
        assertEq(IERC20RH(IMD).balanceOf(address(market)), 0);

        // Wager: alice says yes, bob takes no, No wins.
        _fundAndApprove(alice, address(wager));
        _fundAndApprove(bob, address(wager));
        vm.prank(alice);
        uint256 w = wager.create(
            "opaque body",
            true,
            10 ether,
            uint64(vm.getBlockTimestamp() + 1 hours),
            uint64(vm.getBlockTimestamp() + 1 hours)
        );
        vm.prank(bob);
        wager.join(w);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        wager.resolve(w);
        (SwarmWager.Wager memory wg,) = wager.get(w);
        _signedDelivery(registry, wg.requestId, false, TEST_KEY);
        uint256 bobBefore = IERC20RH(IMD).balanceOf(bob);
        wager.settle(w);
        assertEq(IERC20RH(IMD).balanceOf(bob), bobBefore + 20 ether);
        assertEq(IERC20RH(IMD).balanceOf(address(wager)), 0);
        assertEq(IERC20RH(IMD).balanceOf(INTAKE), 1 ether, "two asks, two prices, nothing else");
    }

    /// A signature made under Ethereum's domain for the same registry address is not accepted on
    /// Robinhood Chain: the record is stored Unverified and the market voids rather than paying.
    function test_signatureUnderAnotherChainsDomainIsUnverified() public {
        _installMocks();
        AskSwarmRegistry registry = new AskSwarmRegistry(INTAKE, IMD, vm.addr(TEST_KEY));
        SwarmMarket market = new SwarmMarket(address(registry), IMD, TREASURY);
        _fundAndApprove(creator, address(market));
        _fundAndApprove(alice, address(market));
        _fundAndApprove(bob, address(market));
        vm.prank(creator);
        uint256 id = market.open(
            "opaque body", uint64(vm.getBlockTimestamp() + 1 hours), uint64(vm.getBlockTimestamp() + 1 hours)
        );
        vm.prank(alice);
        market.stake(id, true, 40 ether);
        vm.prank(bob);
        market.stake(id, false, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        market.resolve(id);
        (SwarmMarket.Market memory m,) = market.get(id);

        OracleAttestation memory a = _vector(m.requestId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_KEY, _digestUnder(a, 1, address(registry)));
        vm.prank(writer);
        IIntake(INTAKE).complete(m.requestId, 0, bytes32(0), "", abi.encode(m.requestId, a, abi.encodePacked(r, s, v)));
        (AskSwarmRegistry.Ask memory k, AskSwarmRegistry.Answer memory ans) = registry.get(m.requestId);
        assertEq(uint8(k.status), uint8(AskSwarmRegistry.Status.Unverified));
        assertFalse(ans.verified);
        market.settle(id);
        (m,) = market.get(id);
        assertEq(uint8(m.phase), uint8(SwarmMarket.Phase.Void));
        assertEq(market.claimable(id, alice), 40 ether);
        assertEq(market.claimable(id, bob), 60 ether);
        assertEq(IERC20RH(IMD).balanceOf(TREASURY), 0, "no fee on a void");
    }

    /// Audit note e842ddc10fde: the Ethereum manifest's IMD has no code on Robinhood Chain and
    /// Intake does not sell oracle.request for it there, so a registry built with it has price 0
    /// and every ask reverts NotSold. The launch must use the Robinhood IMD, as LAUNCH-RH.md does.
    function test_mainnetImdWouldMakeTheRegistryInertOnChain4663() public {
        _installMocks();
        assertEq(MAINNET_IMD.code.length, 0);
        AskSwarmRegistry wrong = new AskSwarmRegistry(INTAKE, MAINNET_IMD, SIGNER);
        assertEq(wrong.price(), 0, "Intake quotes nothing for the mainnet IMD here");
        vm.prank(alice);
        vm.expectRevert(AskSwarmRegistry.NotSold.selector);
        wrong.ask("opaque body");
        SwarmMarket market = new SwarmMarket(address(wrong), MAINNET_IMD, TREASURY);
        vm.prank(creator);
        vm.expectRevert(SwarmMarket.BadTerms.selector);
        market.open("opaque body", uint64(vm.getBlockTimestamp() + 1 hours), uint64(vm.getBlockTimestamp() + 1 hours));

        AskSwarmRegistry right = new AskSwarmRegistry(INTAKE, IMD, SIGNER);
        assertEq(right.price(), 0.5 ether);
    }
}
