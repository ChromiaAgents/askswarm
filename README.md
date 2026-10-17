# AskSwarm

![What AskSwarm does: ask in Telegram, pay in CHR, the IMD swarm votes, you get an EIP-712 signed answer](docs/askswarm.png)

Telegram bot: ask a factual question in chat, the [IMD](https://imd.fun) agent swarm answers it
with an EIP-712 signed attestation, verified by the bot and linked back to the swarm job and the
onchain transaction. Pay in CHR through Chromia Pay, or ask free on Sepolia.

Built by EVAL Engine for the Identity MD hackathon, October 2026.

## How it works

```mermaid
sequenceDiagram
    autonumber
    actor U as User (Telegram)
    participant B as AskSwarm bot<br/>(Vercel functions)
    participant P as Chromia Pay
    participant R as AskSwarmRegistry<br/>(Ethereum, launched through IMD)
    participant I as IMD Intake v2
    participant S as IMD swarm<br/>(api.imd.fun)

    U->>B: /ask What is the ISO 4217 code of the Swiss franc?
    B->>S: POST /requests/check (free)
    S-->>B: normalized question, answerType, panel 15 / quorum 11
    B->>B: split-risk score · recall of 6.7k prior attestations
    B-->>U: ❓ card: ✅ prior answer if known · risk · [Pay 160 CHR] [Pay 0.5 IMD]
    alt Pay in CHR
        B->>P: payments.create(metadata{chatId,msgId,question})
        P-->>U: hosted checkout, own wallet
        P->>B: webhook payment.confirmed (HMAC)
        B->>R: ask(body) from the house wallet
    else Pay in IMD
        U->>R: ask(body) from own wallet (signed link page)
    end
    R->>I: requestWithFailure(oracle.request, body, callback=R, 0.5 IMD)
    I-->>S: Requested event
    B-->>U: ⏳ asked, tx 0x…  (auto-updates)
    S->>S: panel assesses, quorum vote
    S->>I: complete(requestId, attestation, signature)
    I->>R: onOracleResult: verify EIP-712 onchain, store by questionHash
    B->>S: GET /oracle/requests/:id/attestation
    B->>B: verifyTypedData, pin signer
    B-->>U: ✅ CHF · 11/15 agreed · verified  [attestation] [swarm job] [etherscan]
```

### Architecture

```mermaid
flowchart LR
    subgraph TG[Telegram]
        U[User]
    end
    subgraph V[Vercel, two functions]
        T[api/telegram.ts<br/>grammy webhook]
        W[api/cpay-webhook.ts<br/>HMAC verify]
        L[lib/bot.ts<br/>stateless handlers]
        T --> L
        W --> L
    end
    subgraph CP[Chromia Pay]
        C[Hosted checkout]
        H[Signed webhooks]
    end
    subgraph ETH[Ethereum / Sepolia]
        K[(Hot wallet<br/>gas + IMD only)]
        IN["Intake v2<br/>0xa43e…de82"]
    end
    subgraph IMD[IMD control plane]
        CHK["/requests/check"]
        RD["/intake/:chain/:tx"]
        OR["/oracle/requests/:id"]
        AT["/attestation<br/>EIP-712"]
    end
    U <-->|/ask, buttons| T
    L -->|payments.create| C
    H -->|payment.confirmed| W
    L -->|"request(...)"| IN
    K -. signs .-> IN
    IN -->|Requested event| RD
    L --> CHK
    L --> RD
    L --> OR
    L --> AT
    L -->|verifyTypedData| L
```

### State lives in the message, not a database

```mermaid
stateDiagram-v2
    [*] --> Drafted: /ask → check ok
    Drafted --> Asked: free button or payment.confirmed → Intake tx
    Drafted --> Refused: check blockers
    Asked --> Assessing: plane indexes tx, requestId known
    Assessing --> Attested: quorum reached, signature published
    Assessing --> NoConsensus: disagreed / blocked / mismatch / failed
    Attested --> [*]: ✅ answer + verified signature posted
    NoConsensus --> [*]: ⚠️ no refund, shown before paying
```

Line 1 of the status message is `❓ <question>`; once asked, a line `tx <chain> <0x…>` is appended.
Every button handler re-derives its state from those two lines.

No database. The status message carries the question and the tx hash; Chromia Pay metadata carries
the chat and message ids. Runs as two Vercel functions: `api/telegram.ts`, `api/cpay-webhook.ts`.

Honest framing: this is a relay. The house wallet pays IMD, the attestation is addressed to it, and
IMD refunds nothing when a panel ends without consensus. The bot says so before payment.

### Split risk, from the Eval Engine dataset

Before the Pay button, the card shows the chance this exact request ends without consensus, scored
by a model trained on [evalengine/imd-oracle-outcomes](https://huggingface.co/datasets/evalengine/imd-oracle-outcomes)
(7.8k IMD oracle requests, label = attested or disagreed). Hashed logistic regression over request
shape only (answer type, panel size, quorum ratio, length, moving-target and future wording, missing
answer format). Word n-grams were dropped: they overfit (test AUC 0.55 vs 0.75).

| split (2026-10-13) | n | disagreed | AUC |
|---|---|---|---|
| validation | 1349 | 6 | 0.81 |
| test | 381 | 70 | 0.56 |

Caveat worth knowing before trusting the test number on the dataset card: most disagreed rows in
the test split share one `validForSeconds=86400` setting from a single batch of bad questions. A
model that keys on that field scores test AUC 0.73, and IMD's check now defaults every live draft
to 86400, so it marked every real question high-risk. The field is excluded here. What remains is
a weak but honest prior, zero runtime cost, 50 KB of weights. High risk also prints why: no answer format, asks two things,
moving target, future date. Retrain: `bun run train:risk <dir with the snapshot jsonl files>`.

## Run the gate

```sh
cp .env.example .env     # EVM_PRIVATE_KEY = fresh hot wallet, holds only Sepolia ETH / test IMD
bun install
bun scripts/spike-sepolia.ts "Did Argentina win the 2022 FIFA World Cup?"   # free, needs Sepolia ETH for gas
```

Mainnet path (0.5 real IMD per question, x402 + Permit2 through the HTTP door) is in
`scripts/spike.ts` and `packages/imd/src/index.ts`. Dry run with an empty wallet passes every server
shape and signature check and fails only `permit2_insufficient_balance`.

## Deploy

Vercel project `askswarm`, team ChromaWay. Env:

| var | note |
|---|---|
| `TELEGRAM_BOT_TOKEN` | from @BotFather |
| `TELEGRAM_WEBHOOK_SECRET` | random, also passed to `setWebhook` |
| `EVM_PRIVATE_KEY` | hot wallet, never the IMD NFT / node key |
| `SEPOLIA_RPC_URL`, `ETH_RPC_URL` | any RPC |
| `ASK_CHAIN_ID` | `11155111` free demo, `1` real IMD |
| `CPAY_SECRET_KEY`, `CPAY_WEBHOOK_SECRET`, `CPAY_PRICE_CHR` | optional, enables the Pay button |

```sh
vercel deploy --prod
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -d url=https://<deployment>/api/telegram -d secret_token=$TELEGRAM_WEBHOOK_SECRET \
  -d allowed_updates='["message","callback_query"]'
```

Chromia Pay: create a store on pay-merchant.chromia.com, add webhook `https://<deployment>/api/cpay-webhook`
for `payment.confirmed` and `payment.overpaid`, paste the key and `whsec_` into Vercel.

## Layout

```
lib/bot.ts                  grammy handlers: /ask, /examples, free, chk; auto-updating cards
lib/risk.ts                 split-risk model (features, predict, hints); weights in lib/risk-model.json
lib/recall.ts               free tier 1: prior attested answers (lib/answers.json)
lib/quick.ts                free tier 2: unsigned one-liner, needs ANTHROPIC_API_KEY
functions/telegram.ts       Telegram webhook (bundled by `bun run build` into api/*.mjs for Vercel)
functions/cpay-webhook.ts   Chromia Pay webhook → ask the swarm
functions/imd.ts            Pay-with-IMD: signed draft + tx verification behind public/imd.html
src/AskSwarmRegistry.sol    the onchain memory: pays Intake, verifies the attestation, stores by questionHash
src/IIntake.sol             the slice of Intake v2 it calls, and the OracleAttestation struct
test/, script/              mainnet-fork tests (forge test --fork-url $ETH_RPC_URL), deploy script
contracts/LAUNCH.md         the brief given to the swarm for the evm_contracts launch; contracts/lib vendored forge-std
docs/brand/                 infographic source (HTML + Chromia brand fonts), rendered to docs/askswarm.png
docs/SUBMISSION.md          hackathon criteria status, Radar blurb, X posts, evidence list
packages/imd/src/index.ts   HTTP door: check, quote, x402 pay, poll, attestation verify
packages/imd/src/intake.ts  onchain door: registry or Intake ask, read /intake, registry reads
packages/cpay/src/index.ts  Chromia Pay Node SDK (vendored, MIT)
scripts/                    spike-sepolia.ts, spike.ts, train-risk.ts, build-answers.ts, launch.ts (hire the swarm)
```

### Pay with IMD from your own wallet

Mainnet cards carry a second button, "Pay 0.5 IMD (your wallet)". It opens `public/imd.html` with a
link the bot signed over (chat, message, question). The page fetches the drafted request from
`api/imd`, has the user's wallet approve 0.5 IMD and call `Intakev2.request` directly, then posts
the tx hash back. The endpoint checks the tx on chain (to Intakev2, `oracle.request`, same question)
before marking the card. The attestation is then addressed to the payer, not the house wallet.

### Free before paid

Two free tiers sit above the paid swarm on every card:

1. **Recall.** `lib/answers.json` holds 6,729 questions the swarm already attested (from the raw
   oracle records in the Eval Engine dataset). An exact or near-exact match (token Jaccard ≥ 0.9)
   shows that signed answer, its agreement count and the attestation link at no cost. Rebuild with
   `bun scripts/build-answers.ts <oracle-requests.jsonl>`.
2. **Quick take.** One unsigned line from a single model (`claude-haiku-5-5`), only when
   `ANTHROPIC_API_KEY` is set. Labelled unsigned on the card; replies "unsure" rather than guess.

The paid swarm is the escalation: when the answer has to be signed, fresh, or settle something.

### Onchain memory: AskSwarmRegistry

Paid answers do not stop in the chat. With `REGISTRY_ADDRESS` set, every paid ask goes through
[AskSwarmRegistry](src/AskSwarmRegistry.sol): the contract pays Intake v2
with itself as callback, verifies the swarm's EIP-712 attestation onchain, and stores the answer by
question hash. Any contract or client can then read what the swarm attested, free, with the proof.
The registry was launched through the IMD protocol itself: [launch #2088](https://explorer.imd.fun/launches/11fd096c-23fe-45a1-a957-20dd29747efa)
(swarm audit of the import, adaptation, tests, four specialist audits, judge, deploy), job
[64fa31ee](https://explorer.imd.fun/jobs/64fa31ee-3f0c-493f-b7ad-b2d93eb8b852). What the swarm changed
and why is in [contracts/ADAPTATION.md](contracts/ADAPTATION.md); `src/` and `test/` here are the
accepted versions.

| chain | AskSwarmRegistry |
|---|---|
| Ethereum mainnet (swarm-deployed, verified) | [`0x3fc72adfed89284e4f3f378646a5338f2f1e14ea`](https://etherscan.io/address/0x3fc72adfed89284e4f3f378646a5338f2f1e14ea) |
| Sepolia (self-deployed, pre-audit build) | `0x1d57A9aa2479fd115E3a1F545Ed5B8660548b900` |

## Pricing

IMD sets the floor. One `oracle.request` is a flat 0.5 IMD whatever the panel size, and IMD trades
around $5.78 (Uniswap, 17 Oct 2026), so the house pays about $2.89 plus gas per question. The bot
charges 160 CHR (~$3.16 at $0.0198) through Chromia Pay, which covers that with a thin margin. Change
`CPAY_PRICE_CHR` and rerun `scripts/vercel-env.sh` if either price moves. The Pay button shows the
live USD equivalent from CoinGecko, display only; the charge is always the CHR amount.

## Security

- Telegram webhook checks `X-Telegram-Bot-Api-Secret-Token`. Chromia Pay webhook verifies the HMAC on the raw body, fulfils only `confirmed` / `overpaid`.
- Question text goes verbatim to the panel: capped at 500 chars, URLs and control chars stripped, and the user sees the normalized question and answer type before paying. Chat text never sets panel size, quorum, consumer or guards.
- Hot wallet holds only gas and test IMD. The only transactions it sends are `approve` and `request`.
- Known gap: no webhook dedupe store, see comment in `api/cpay-webhook.ts`.
