# AskSwarm

Telegram bot: ask a factual question in chat, the [IMD](https://imd.fun) agent swarm answers it
with an EIP-712 signed attestation, verified by the bot and linked back to the swarm job and the
onchain transaction. Pay in CHR through Chromia Pay, or ask free on Sepolia.

Built by EVAL Engine for the Identity MD hackathon, October 2026.

## How it works

```
/ask <question>        Telegram
   │  POST /requests/check            free, returns the normalized question the panel will see
   ▼
status message         "❓ question · bool · panel 15, quorum 11"   [Ask free (Sepolia)] [Pay 2 CHR]
   │  Chromia Pay checkout → payment.confirmed webhook   (or the free button)
   ▼
Intake.request(...)    one tx on Sepolia or Ethereum, 0.5 IMD, no API token, no x402
   │  GET /intake/:chainId/:tx  → oracle requestId
   │  GET /oracle/requests/:id  → attested | disagreed | ...
   │  GET /oracle/requests/:id/attestation → EIP-712, verified offline with viem
   ▼
"✅ Yes · 15/15 agreed · EIP-712 verified · signer 0x5598aa91…"   [attestation] [swarm job] [etherscan]
```

No database. The status message carries the question and the tx hash; Chromia Pay metadata carries
the chat and message ids. Runs as two Vercel functions: `api/telegram.ts`, `api/cpay-webhook.ts`.

Honest framing: this is a relay. The house wallet pays IMD, the attestation is addressed to it, and
IMD refunds nothing when a panel ends without consensus (~4% live). The bot says so before payment.

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
lib/bot.ts                  grammy handlers: /ask, free, chk
api/telegram.ts             Telegram webhook
api/cpay-webhook.ts         Chromia Pay webhook → ask the swarm
packages/imd/src/index.ts   HTTP door: check, quote, x402 pay, poll, attestation verify
packages/imd/src/intake.ts  onchain door: mint test IMD, approve, request, read /intake
packages/cpay/src/index.ts  Chromia Pay Node SDK (vendored, MIT)
scripts/                    spike-sepolia.ts (free gate), spike.ts (mainnet), dry-run.ts, approve-permit2.ts
```

## Security

- Telegram webhook checks `X-Telegram-Bot-Api-Secret-Token`. Chromia Pay webhook verifies the HMAC on the raw body, fulfils only `confirmed` / `overpaid`.
- Question text goes verbatim to the panel: capped at 500 chars, URLs and control chars stripped, and the user sees the normalized question and answer type before paying. Chat text never sets panel size, quorum, consumer or guards.
- Hot wallet holds only gas and test IMD. The only transactions it sends are `approve` and `request`.
- Known gap: no webhook dedupe store, see comment in `api/cpay-webhook.ts`.
