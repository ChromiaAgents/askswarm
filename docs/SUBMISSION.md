# Hackathon submission pack

Identity MD hackathon, submissions 7–21 Oct 2026, winners by 23 Oct. Judged by IMD agents (places
6–15) and a human jury (top 5). Entry form: https://www.imdradar.site/hackathon (one entry per
project, cannot be edited afterwards, prize paid to the contract's deployer address).

## Criteria and where we stand

| criterion | status |
|---|---|
| Launched through the IMD protocol during the build period | Done, twice: [launch #2088](https://explorer.imd.fun/launches/11fd096c-23fe-45a1-a957-20dd29747efa) then [launch #2099](https://explorer.imd.fun/launches/503c2f1a-6479-4fbb-856a-4d57361698fb) from the monorepo (job [1d47e02c](https://explorer.imd.fun/jobs/1d47e02c-32b6-44ec-a8e1-ac913d9d2ad0)). Swarm audited, fixed five findings across the two rounds, tested, deployed. |
| v4 hook or custom contract that really uses IMD | AskSwarmRegistry on Ethereum `0x53e1e2f33f05086086adf618ca92c3cb0ab111cd`: pays Intake v2, receives `onOracleResult`, verifies the attestation onchain, stores it by questionHash. |
| Dedicated X account | Using [@Eval_Engine](https://x.com/Eval_Engine) (Johnson's call). To do: add AskSwarm + bot link to the bio, pin post 1, then posts 2 and 3. |
| Submitted via IMD Radar | **TODO after launch is live**: form needs project X handle, contract address (mainnet registry), blurb below. |

Prize wallet: the launch's literal deployer is IMD's factory wallet, so name ours in the blurb like
other entrants do. Johnson provides the address. Placeholder `0x…` below.

## Radar blurb (≤1000 chars, fill in the two addresses)

AskSwarm puts the IMD oracle in a Telegram chat and keeps what it says onchain. /ask a question: the bot drafts it through /requests/check, shows panel, quorum and a split-risk score from a model trained on 7.8k past IMD requests (evalengine/imd-oracle-outcomes, public on HF), then you pay 160 CHR via Chromia Pay or 0.5 IMD from your own wallet. 6,729 already-attested answers are free. The EIP-712 attestation is verified and posted in chat. AskSwarmRegistry (Ethereum, launched through IMD, swarm-audited, no owner): ask(body) pulls 0.5 IMD, calls Intake v2 with itself as callback, verifies the attester's signature in its own domain, requires agreed ≥ quorum, and stores every answer by questionHash with a stronger-panel-wins rule, so any contract can read what the swarm attested. Refusals and split panels are recorded too. Registry: 0x53e1e2f33f05086086adf618ca92c3cb0ab111cd (IMD launch #2099; #2088 at 0x3fc72adf… holds the first 10 answers). Explorer: askswarm-nine.vercel.app/answers. Code: github.com/ChromiaAgents/askswarm. Bot: t.me/askswarm_bot. Prize wallet: 0x…

## X posts

1. The IMD swarm now answers questions in Telegram. /ask anything checkable, a panel of agents votes, you get an EIP-712 signed answer verified in chat. Pay 160 CHR with Chromia Pay or 0.5 IMD from your wallet. 6.7k past answers are free. Built for the IMD hackathon. [screen recording of /examples → ✅]

2. AskSwarmRegistry is live on Ethereum, launched through IMD and audited by the swarm. One call: ask(body) → 0.5 IMD → Intake v2 → onOracleResult verifies the attestation onchain and stores it by questionHash. Every answer anyone ever bought is readable by any contract. [etherscan link]

3. Before you pay the swarm, know the odds. We trained a split-risk model on 7,804 IMD oracle requests (open dataset: hf.co/datasets/evalengine/imd-oracle-outcomes). AskSwarm shows the chance your panel disagrees, and why, before the Pay button.

Tag @surfcoderepeat (Adam). Official IMD handle unverified, do not guess one.

## Evidence to link in the entry

- Registry https://etherscan.io/address/0x53e1e2f33f05086086adf618ca92c3cb0ab111cd (launch https://explorer.imd.fun/launches/503c2f1a-6479-4fbb-856a-4d57361698fb) and the first one https://etherscan.io/address/0x3fc72adfed89284e4f3f378646a5338f2f1e14ea (launch https://explorer.imd.fun/launches/11fd096c-23fe-45a1-a957-20dd29747efa).
- Explorer https://askswarm-nine.vercel.app/answers, agent docs https://askswarm-nine.vercel.app/skill.md.
- At least 10 real mainnet asks through the registry with tx hashes (run `/examples` in the group with REGISTRY_ADDRESS set; each costs 0.5 IMD from the house wallet).
- docs/EVIDENCE.md: 10 asks through #2088, all with tx and attestation links.
- Dataset card, split-risk README section, recall tier, and the write-back: https://huggingface.co/datasets/evalengine/imd-oracle-outcomes/blob/main/contrib/askswarm/answers.jsonl (daily cron).

## Before 21 Oct

1. Launch live → set `REGISTRY_ADDRESS` in .env, rerun `scripts/vercel-env.sh`, run 10 asks.
2. X account + 3 posts.
3. Radar form.
4. Revoke the live Chromia Pay agent token, rotate the Telegram bot token and Vercel token after the event.
