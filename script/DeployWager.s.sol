// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwarmWager} from "../src/SwarmWager.sol";

/// Optional local simulation of this launch's sole application. IMD deploys through its factory.
/// AskSwarmRegistry is already live from launch #2099 and must never be redeployed here.
contract DeployWager is Script {
    address constant REGISTRY = 0x53e1E2f33f05086086AdF618Ca92c3Cb0ab111CD;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function run() external returns (SwarmWager wager) {
        require(block.chainid == 1, "Ethereum mainnet only");
        vm.startBroadcast();
        wager = new SwarmWager(REGISTRY, IMD);
        vm.stopBroadcast();
        console.log("SwarmWager", address(wager), "chain", block.chainid);
    }
}
