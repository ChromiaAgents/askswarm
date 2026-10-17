// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AskSwarmRegistry} from "../src/AskSwarmRegistry.sol";

/// forge script script/Deploy.s.sol --rpc-url $RPC --private-key $PK --broadcast --verify
/// Intake v2 is at the same address on every chain; IMD differs (IMDtest on Sepolia).
contract Deploy is Script {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function run() external {
        address imd = block.chainid == 11155111
            ? 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A
            : 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        vm.startBroadcast();
        AskSwarmRegistry r = new AskSwarmRegistry(INTAKE, imd, ORACLE_SIGNER);
        vm.stopBroadcast();
        console.log("AskSwarmRegistry", address(r), "chain", block.chainid);
        console.log("price (wei IMD)", r.price());
    }
}
