# Hackathon submission pack

Identity MD hackathon, submissions 7–21 Oct 2026, winners by 23 Oct. Judged by IMD agents (places
6–15) and a human jury (top 5). Entry form: https://www.imdradar.site/hackathon (one entry per
project, cannot be edited afterwards, prize paid to the contract's deployer address).

## Criteria and where we stand

| criterion | status |
|---|---|
| Launched through the IMD protocol during the build period | Done on **Robinhood Chain**: [launch #2223](https://explorer.imd.fun/jobs/dffc8efb-80a1-4774-9720-440834a61b82) audited, fixed two findings, tested and deployed all three contracts in one launch (job [dffc8efb](https://explorer.imd.fun/jobs/dffc8efb-80a1-4774-9720-440834a61b82)). Earlier on Ethereum: [launch #2088](https://explorer.imd.fun/jobs/64fa31ee-3f0c-493f-b7ad-b2d93eb8b852) then [launch #2099](https://explorer.imd.fun/jobs/1d47e02c-32b6-44ec-a8e1-ac913d9d2ad0) from the monorepo (job [1d47e02c](https://explorer.imd.fun/jobs/1d47e02c-32b6-44ec-a8e1-ac913d9d2ad0)). Swarm audited, fixed five findings across the two rounds, tested, deployed. |
| v4 hook or custom contract that really uses IMD | AskSwarmRegistry on Robinhood Chain `0xf3a79f962ec1e75f0087af5491a69dee2a869012` (Ethereum: `0x53e1e2f33f05086086adf618ca92c3cb0ab111cd`): pays Intake v2, receives `onOracleResult`, verifies the attestation onchain, stores it by questionHash. |
| Dedicated X account | Using [@Eval_Engine](https://x.com/Eval_Engine) (Johnson's call). To do: add AskSwarm + bot link to the bio, pin post 1, then posts 2 and 3. |
| Source verified | Sourcify, all three Robinhood contracts (19 Oct). |
| Submitted via IMD Radar | **TODO**: form needs project X handle, contract address (use the Robinhood Chain registry `0xf3a79f962ec1e75f0087af5491a69dee2a869012`), blurb below. |

Prize wallet: the launch's literal deployer is IMD's factory wallet, so name ours in the blurb like
other entrants do. Johnson provides the address. Placeholder `0x…` below.

## Radar blurb (≤1000 chars incl. the full prize wallet address)

Final, ~900 chars with a real address. Johnson replaces the zero address with the prize wallet and submits
20 Oct with contract `0xf3a79f962ec1e75f0087af5491a69dee2a869012` and handle `Eval_Engine`. Entries cannot be edited.

AskSwarm makes the IMD oracle usable by people and by other contracts, live on Robinhood Chain. Entered contract: AskSwarmRegistry, audited and deployed by the swarm in IMD launch #2223, source verified on Sourcify. ask() pays 0.5 IMD to Intake v2 with itself as callback; onOracleResult checks the swarm's EIP-712 attestation onchain and stores the answer by questionHash for any contract to read. SwarmMarket and SwarmWager escrow IMD and pay out only on a verified answer: no owner, nobody picks the outcome. Try it in 60s: t.me/askswarm_bot. Full cycle on Robinhood, ask > verified attestation > settle > claim: robinhoodchain.blockscout.com/tx/0xd0427fa2c2ec98eb53e2dc420856d3686ac5d9facbd5b0f000ee37e60c8b6b78. Live: askswarm.evalengine.ai. Earlier on Ethereum (#2099): 14 answers, 13 verified. Code: github.com/ChromiaAgents/askswarm. Prize wallet 0x0000000000000000000000000000000000000000

## X posts

1. The IMD swarm now answers questions in Telegram. /ask anything checkable, a panel of agents votes, you get an EIP-712 signed answer verified in chat. Pay 160 CHR with Chromia Pay or 0.5 IMD from your wallet. 6.7k past answers are free. Built for the IMD hackathon. [attach docs/askswarm-demo.mp4]

2. AskSwarm is live on Robinhood Chain, launched through IMD and audited by the swarm. One call: ask(body) → 0.5 IMD → Intake v2 → onOracleResult verifies the attestation onchain and stores it by questionHash. Every answer anyone ever bought is readable by any contract. https://robinhoodchain.blockscout.com/address/0xf3a79f962ec1e75f0087af5491a69dee2a869012

3. Before you pay the swarm, know the odds. We trained a split-risk model on 7,804 IMD oracle requests (open dataset: hf.co/datasets/evalengine/imd-oracle-outcomes). AskSwarm shows the chance your panel disagrees, and why, before the Pay button.

4. Settle it with the swarm. SwarmWager: two people stake IMD on a yes/no question, the IMD swarm's verified answer pays the winner, a split panel refunds both. Nobody picks the outcome, not even us. Built on AskSwarmRegistry, launched through IMD. Try /bet in t.me/askswarm_bot

Tag @surfcoderepeat (Adam). Official IMD handle unverified, do not guess one.

## Evidence to link in the entry

- Demo video: https://github.com/ChromiaAgents/askswarm/raw/main/docs/askswarm-demo.mp4

- Robinhood Chain (current), launch https://explorer.imd.fun/jobs/dffc8efb-80a1-4774-9720-440834a61b82: registry https://robinhoodchain.blockscout.com/address/0xf3a79f962ec1e75f0087af5491a69dee2a869012, market https://robinhoodchain.blockscout.com/address/0x6c95a84944b05e7de5000caef80a7c487aa57cb8, wager https://robinhoodchain.blockscout.com/address/0xd237dd7564edb7a026613ebb6da31da0292af96c
- Ethereum registry https://etherscan.io/address/0x53e1e2f33f05086086adf618ca92c3cb0ab111cd (launch https://explorer.imd.fun/jobs/1d47e02c-32b6-44ec-a8e1-ac913d9d2ad0) and the first one https://etherscan.io/address/0x3fc72adfed89284e4f3f378646a5338f2f1e14ea (launch https://explorer.imd.fun/jobs/64fa31ee-3f0c-493f-b7ad-b2d93eb8b852).
- Explorer https://askswarm.evalengine.ai/answers, agent docs https://askswarm.evalengine.ai/skill.md.
- At least 10 real mainnet asks through the registry with tx hashes (run `/examples` in the group with REGISTRY_ADDRESS set; each costs 0.5 IMD from the house wallet).
- docs/EVIDENCE.md: 10 asks through #2088, all with tx and attestation links.
- Dataset card, split-risk README section, recall tier, and the write-back: https://huggingface.co/datasets/evalengine/imd-oracle-outcomes/blob/main/contrib/askswarm/answers.jsonl (daily cron).

## Before 21 Oct

1. Done: Robinhood launch live, env set, site and bot on Robinhood Chain. Still to do: real asks and a real bet on Robinhood Chain for the evidence table.
2. X account + 3 posts.
3. Radar form.
4. Revoke the live Chromia Pay agent token, rotate the Telegram bot token and Vercel token after the event.
