# Evidence

## Robinhood Chain (current)

[IMD launch #2223](https://explorer.imd.fun/jobs/dffc8efb-80a1-4774-9720-440834a61b82) deployed all three contracts in one transaction, [`0xf3de9749…`](https://robinhoodchain.blockscout.com/tx/0xf3de97499688c53dffa1970fbd38a65d85413b985f91724f6332be3b4f291566) (block 92654033), after the swarm's audit fixed two findings ([notes](../contracts/ADAPTATION-2223.md)).

| contract | address | checked onchain |
|---|---|---|
| AskSwarmRegistry | [`0xf3a79f962ec1e75f0087af5491a69dee2a869012`](https://robinhoodchain.blockscout.com/address/0xf3a79f962ec1e75f0087af5491a69dee2a869012) | INTAKE Intake v2, IMD `0x5f7b…7127`, SIGNER `0x5598…2982`, price 0.5 IMD |
| SwarmMarket | [`0x6c95a84944b05e7de5000caef80a7c487aa57cb8`](https://robinhoodchain.blockscout.com/address/0x6c95a84944b05e7de5000caef80a7c487aa57cb8) | REGISTRY = the registry above, MAX_TERM 365 days |
| SwarmWager | [`0xd237dd7564edb7a026613ebb6da31da0292af96c`](https://robinhoodchain.blockscout.com/address/0xd237dd7564edb7a026613ebb6da31da0292af96c) | REGISTRY = the registry above, MAX_BODY_BYTES 16,384 |

First activity, opened by the keeper on its own, each seeded 0.1 IMD per side by the house wallet:

| market | question | open tx |
|---|---|---|
| #1 | Was the Coinbase ETH-USD daily close on 19 October 2026 (UTC) above 2,404 US dollars? | [`0xfb96eb2d…`](https://robinhoodchain.blockscout.com/tx/0xfb96eb2d80b693cb5586777d29f5e1f888ae4e978a558f18c90ad77495e9b798) |
| #2 | Was the Coinbase BTC-USD daily close on 19 October 2026 (UTC) above 82,095 US dollars? | [`0x5a844c9e…`](https://robinhoodchain.blockscout.com/tx/0x5a844c9e7bd6d11a9dd8dbb1b0b3813d9f6887cd0e9ebcb51c3b6da561079f19) |

First user bet, recorded for the hands-on video ([docs/askswarm-handson.mp4](askswarm-handson.mp4)): the demo wallet `0xbDFf…8f02` staked 0.1 IMD on YES in market #1 through the live site, [`0xc84498b6…`](https://robinhoodchain.blockscout.com/tx/0xc84498b61b7df4356783892f7cd727dd7cd14304d6156b9aa60d6be6cf788621); odds moved from 50/50 to 67/33.

Funds reached Robinhood Chain through the canonical bridges: ETH through the Arbitrum Delayed Inbox, IMD through its own LayerZero OFT (`scripts/bridge-eth.ts`, `scripts/bridge-imd.ts`).

## Ethereum (first deployment)

### Real mainnet asks through AskSwarmRegistry

Registry #2088 `0x3fc72adfed89284e4f3f378646a5338f2f1e14ea` (the current registry is #2099 `0x53e1e2f33f05086086adf618ca92c3cb0ab111cd`; both show in the explorer), each row is one `ask(body)` paid in 0.5 IMD by the house wallet, answered by the swarm and verified onchain in `onOracleResult`.

| # | question | ask tx | oracle request | outcome | onchain verified |
|---|---|---|---|---|---|
| 1 | What is the ISO 4217 currency code of the British pound? Answer with the three-letter code only. | [0x738b4341…](https://etherscan.io/tx/0x738b43410c6a2474eca81e19802aa264b1108a9cc78d7480058511639ef56ede) | [0d6f8aa9](https://api.imd.fun/oracle/requests/0d6f8aa9-4738-447d-90cf-7cd7dcfbeac9/attestation) | disagreed | NoResult · `0x01b4c9be…` |
| 2 | In what year did the Black Monday crash occur, when the Dow fell about 22.6% in a single day? Answer with the four-digit year only. | [0xc03d3bc2…](https://etherscan.io/tx/0xc03d3bc24264116fd742e5b11931330d27dcac2dcb4aa7271f66f8830b9dc783) | [46165fda](https://api.imd.fun/oracle/requests/46165fda-3b55-4dad-8d27-4197dc85b8b6/attestation) | attested | verified ✅ · `0xeb3a342e…` |
| 3 | Did Argentina win the 2022 FIFA World Cup? | [0xc9c61801…](https://etherscan.io/tx/0xc9c6180152d2da57763fce0b5ddec29abc4cda3630416227d30a782a9e0f109e) | [43a20eb4](https://api.imd.fun/oracle/requests/43a20eb4-f9ce-4751-8a62-9c8851b12565/attestation) | attested | verified ✅ · `0x2043b2c5…` |
| 4 | What is the NASDAQ ticker symbol of Apple Inc.? Answer with the ticker symbol only. | [0x3d110892…](https://etherscan.io/tx/0x3d1108924705fbb95f1e1885341502d0e0b1222c974e37cee01d95bd9428fe9f) | [10e1bed0](https://api.imd.fun/oracle/requests/10e1bed0-7968-4c26-b2d0-0023db90aae1/attestation) | attested · AAPL | verified ✅ · `0x6e966903…` |
| 5 | In what year was Ethereum's genesis block mined? Answer with the four-digit year only. | [0xf195935e…](https://etherscan.io/tx/0xf195935e263c4da7ea8bed2ebf738442cfbe9c99baa5a13d7137b764b3dbd72a) | [606e9a7b](https://api.imd.fun/oracle/requests/606e9a7b-1eaa-494f-be78-c3f6c7832862/attestation) | attested | verified ✅ · `0x10f9f0c8…` |
| 6 | What is the ISO 3166-1 alpha-3 country code of Japan? Answer with the three-letter code only. | [0x5be21a4f…](https://etherscan.io/tx/0x5be21a4fd6fb1f1d6339e6a136c6c3ec7e9c4e2b529faa673f37d0c2af925b38) | [3a3f4d88](https://api.imd.fun/oracle/requests/3a3f4d88-053b-46d1-9156-a93056f08316/attestation) | attested · JPN | verified ✅ · `0x5210e5bc…` |
| 7 | How many players does each team field in a standard association football match? Answer with the whole number only. | [0xfe9b8d31…](https://etherscan.io/tx/0xfe9b8d319aca41cb4c4caa7e93b74eaf9f61d4fbbc3fea2a08c29d05be96ee09) | [217c642d](https://api.imd.fun/oracle/requests/217c642d-3267-4e6b-85d5-ad89a738201e/attestation) | attested | verified ✅ · `0x91f2abcf…` |
| 8 | What is the atomic number of gold? Answer with the whole number only. | [0x63577a40…](https://etherscan.io/tx/0x63577a4093e3645cfbe0bc56fde926cf6e61cc3d733928bdc29a1b57eb3cb594) | [44eab9dc](https://api.imd.fun/oracle/requests/44eab9dc-aca0-42e4-b2bf-098c59cbd887/attestation) | attested | verified ✅ · `0xeac0c02b…` |
| 9 | Did Bitcoin's genesis block get mined in January 2009? | [0x3b28c112…](https://etherscan.io/tx/0x3b28c112577dcfb827bc415f187ef07321d63cb43d3817ca5f86bc60a0eade98) | [a03ae889](https://api.imd.fun/oracle/requests/a03ae889-4a5d-4300-982a-e4bcf59ecf98/attestation) | attested | verified ✅ · `0x7636ca5b…` |

### Contracts built on the registry, live on mainnet

| contract | id | question | outcome | txs |
|---|---|---|---|---|
| SwarmWager `0xc0b13031…99bbe6` (launch #2189) | wager 1 | Did Argentina win the 2022 FIFA World Cup? | swarm answered Yes, verified; Yes side paid 2 IMD | [create](https://etherscan.io/tx/0x5cca3d27050d609c85e07eab6cc448bb668cc0f4ac95a1747edc5d42f4412042) · [resolve](https://etherscan.io/tx/0xaf65e50958fb4b0cbaaef1ea5f87289ccd439337ec644f7004e2a27b3f1bcc5f) · [settle](https://etherscan.io/tx/0x02cf1df7a1cef4938a272dfb4e31d787b4df9875babe30804122e96c47707c96) |
| SwarmMarket `0x4964d5f0…8afa55` (launch #2190) | market 1 | Did Argentina win the 2022 FIFA World Cup? | 2 traders, 1.1 IMD staked; keeper resolved and settled; resolved YES; winner claimed 1.098 IMD; 0.002 IMD fee | [open](https://etherscan.io/tx/0x7e1c50de365e35f811fa550a0baf738c285c950ea8b1e19d1d35475d17d8b5ef) · [claim](https://etherscan.io/tx/0x8b669b23fda263bc72998b78e44d0619c6de3ec74d7baab1cffb6018a0409fce) |

Both were opened between the AskSwarm house wallet and a second test wallet to prove the full loop;
markets opened by others show up at https://askswarm-nine.vercel.app/market.

## Robinhood Chain: 2026-10-19 batch

Registry [`0xf3a79f962ec1e75f0087af5491a69dee2a869012`](https://robinhoodchain.blockscout.com/address/0xf3a79f962ec1e75f0087af5491a69dee2a869012), each row is one `ask(body)` paid in 0.5 IMD by the house wallet, answered by the swarm and verified onchain in `onOracleResult`.

| # | question | ask tx | oracle request | outcome | onchain verified |
|---|---|---|---|---|---|
| 1 | What is the Nasdaq ticker symbol of Robinhood Markets, Inc.? Answer with the ticker symbol only. | [0x63485085…](https://robinhoodchain.blockscout.com/tx/0x6348508568e723ca9ed29c6c78ab895536174923c33626fa2fe839dfe29706f2) | [260e33e8](https://api.imd.fun/oracle/requests/260e33e8-6dfd-451b-b9fe-535f3b6f7cc9/attestation) | attested · HOOD | Pending |
| 2 | In what year did Robinhood Markets, Inc. list its shares on the Nasdaq? Answer with the four-digit year only. | [0x1ffb7b2a…](https://robinhoodchain.blockscout.com/tx/0x1ffb7b2a85957331e792870f0517084928e1eb6a89c63f0191da2e131f972190) | [23752859](https://api.imd.fun/oracle/requests/23752859-f062-49ad-b34d-df72b675fd9f/attestation) | attested | Pending |
| 3 | Did Ethereum switch from proof of work to proof of stake (the Merge) in 2022? | [0x35b8aef8…](https://robinhoodchain.blockscout.com/tx/0x35b8aef821770347dece8123505dbeee68c8db09e7a48a34d7d274e7e1e6b778) | [ba3c19fe](https://api.imd.fun/oracle/requests/ba3c19fe-8870-462f-849a-625fe16f757e/attestation) | attested | Pending |
| 4 | How many satoshis make up one bitcoin? Answer with the whole number only. | [0x5feb871f…](https://robinhoodchain.blockscout.com/tx/0x5feb871fe9a1124a86f4dc92e51f2fadf489a03b08c674584619dc8bbf17e80b) | [d9ce2caf](https://api.imd.fun/oracle/requests/d9ce2caf-1824-4d91-a748-906afd40a61c/attestation) | attested | Pending |
| 5 | What is the ISO 4217 currency code of the Swiss franc? Answer with the three-letter code only. | [0xae8a9938…](https://robinhoodchain.blockscout.com/tx/0xae8a9938f115d3abd9fbd18be911ce746f996b87f3f9094e7d740e8fb9b42926) | [3b7b891b](https://api.imd.fun/oracle/requests/3b7b891b-4bfa-4cf5-b66c-9dc8a016bdb8/attestation) | attested · CHF | Pending |

## Robinhood Chain: first full cycle, ask → attestation → settle → claim (19 Oct 2026)

Market #3 on SwarmMarket `0x6c95a84944b05e7de5000caef80a7c487aa57cb8`: "Was Bitcoin's genesis block mined in January 2009?"
Opened by the house wallet with the swarm's fee escrowed, house staked NO 0.1 IMD, the demo wallet staked YES 0.1 IMD.
`resolve` bought the question through AskSwarmRegistry `0xf3a79f962ec1e75f0087af5491a69dee2a869012` (its first ask on Robinhood Chain),
the swarm answered Yes (11 of 15 agreed), the registry verified the attestation onchain, the keeper settled and the winner claimed.

| step | tx |
|---|---|
| open | [0xe98732af…](https://robinhoodchain.blockscout.com/tx/0xe98732af201046d2725828486e4d0b11a8a3b96ccfb85e68eb30b07aa64469c6) |
| stake NO 0.1 (house) | [0x79558b6b…](https://robinhoodchain.blockscout.com/tx/0x79558b6be4ee8f2653497f29591713eea3553e1cd21ad5f7a731b3a37f8e2c81) |
| stake YES 0.1 (demo wallet) | [0x1e9b8d83…](https://robinhoodchain.blockscout.com/tx/0x1e9b8d8337c68ed12fa0b8a5b53b9e4e60aa2740cf175d220b5dd04e4060b86a) |
| resolve = registry ask, 0.5 IMD to Intake v2 | [0xd0427fa2…](https://robinhoodchain.blockscout.com/tx/0xd0427fa2c2ec98eb53e2dc420856d3686ac5d9facbd5b0f000ee37e60c8b6b78) |
| swarm job / attestation | [explorer job](https://explorer.imd.fun/jobs/8491065c-e0c5-44be-b34c-29ce69545f81) · [attestation](https://api.imd.fun/oracle/requests/4f3a459d-5732-4229-8479-04c1249e5f76/attestation) |
| Intake completion → onOracleResult (verified) | [0xcd1682a3…](https://robinhoodchain.blockscout.com/tx/0xcd1682a327b7170c63afc01d86ce5e5ac9b23b408829cce536aaf24631d71b71) |
| settle: Yes | [0xd67f3ca3…](https://robinhoodchain.blockscout.com/tx/0xd67f3ca3912ad4aaf0f502df4b579f83c76835701fa0ab6c5f395eaac2aa9ccd) |
| claim 0.2 IMD (demo wallet) | [0xfa833582…](https://robinhoodchain.blockscout.com/tx/0xfa833582590612abf77804120b44f1f73f5865ff3bdaafd21faf7dfe4ce15e79) |

Also from Telegram on 19 Oct: two 0.1 IMD YES bets on market #1 by the demo wallet through the Mini App
([0x7ad2ead9…](https://robinhoodchain.blockscout.com/tx/0x7ad2ead955a8d0f6da24868639f915d048676888f9bb7f57feb6a5994eef6698)), recorded for docs/askswarm-demo.mp4.
