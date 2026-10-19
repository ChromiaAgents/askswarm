Audit and deploy the three AskSwarm contracts on Robinhood Chain (chainId 4663), unchanged if they pass review. Foundry project at the repo root. These exact contracts were each audited and deployed on Ethereum mainnet through earlier IMD launches (#2099 AskSwarmRegistry, #2190 SwarmMarket, #2189 SwarmWager); their adaptation notes are in contracts/ADAPTATION-2099.md, ADAPTATION-2190.md and ADAPTATION-2189.md. This launch puts the same system on Robinhood Chain.

Deploy in this order, in one launch:
1. AskSwarmRegistry (src/AskSwarmRegistry.sol), constructor (address intake, address imd, address signer) = (0xa43e6f75ee006411f79ac1c84120606c2330de82, 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127, 0x5598aa9146215bc13eb26f2c692ad1461fd32982). Intake v2 and the oracle attester are the same on Robinhood Chain; 0x5f7b… is IMD on Robinhood Chain.
2. SwarmMarket (src/SwarmMarket.sol), constructor (address registry, address imd, address treasury) = ($contract:AskSwarmRegistry, 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127, 0x571e17b13d8f6492bbc372a160520b20bfda320c). The treasury is AskSwarm's operating wallet, which pays for free asks.
3. SwarmWager (src/SwarmWager.sol), constructor (address registry, address imd) = ($contract:AskSwarmRegistry, 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127).

What they do: the registry pays Intake v2 for an oracle.request with itself as callback, verifies the attester's EIP-712 signature under its own domain (chain id 4663, the registry's address), requires agreed >= quorum and a strict majority, and stores answers by questionHash. SwarmMarket runs parimutuel yes/no markets settled only from the registry's verified bool answers, 2% fee on the losing pool split creator/treasury, 1h resolve window, voids on any non-answer. SwarmWager runs 1v1 yes/no bets settled the same way. None has an owner, admin, upgrade path or ETH handling; constructors make no external calls; tests are in test/.

Part of AskSwarm (github.com/ChromiaAgents/askswarm).
