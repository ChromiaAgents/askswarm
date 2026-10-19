// Live bot + Chromia Pay fulfilment test against production, in a private chat.
//   bun scripts/e2e-tg.ts <chatId>
// 1) sends /markets and /start as real webhook updates; 2) creates a status card and fires a correctly
// signed payment.confirmed webhook for it, which makes the bot ask the swarm through the registry
// (0.5 IMD from the house wallet) and edit the card when the answer lands.
import { createHmac } from "node:crypto";
const chat = Number(process.argv[2]);
const BASE = "https://askswarm-nine.vercel.app", TG = `https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}`;
const upd = (text: string, id: number) => ({ update_id: Date.now() % 1e9 + id, message: { message_id: 1, date: Math.floor(Date.now() / 1000), chat: { id: chat, type: "private" }, from: { id: chat, is_bot: false, first_name: "Test" }, text, entities: [{ type: "bot_command", offset: 0, length: text.split(" ")[0].length }] } });
for (const [i, t] of ["/start", "/markets"].entries()) {
  const r = await fetch(`${BASE}/api/telegram`, { method: "POST", headers: { "content-type": "application/json", "x-telegram-bot-api-secret-token": process.env.TELEGRAM_WEBHOOK_SECRET! }, body: JSON.stringify(upd(t, i)) });
  console.log(t, r.status, await r.text());
}
const q = process.env.E2E_Q ?? "What is the ISO 4217 currency code of the Danish krone? Answer with the three-letter code only.";
const card = await (await fetch(`${TG}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id: chat, text: `❓ ${q}\n(test: paid with CHR via Chromia Pay sandbox, webhook simulated)` }) })).json();
if (!card.ok) { console.log("cannot message this chat:", card.description); process.exit(1); }
const event = { id: "evt_test_" + Date.now(), object: "event", type: "payment.confirmed", created: Math.floor(Date.now() / 1000),
  data: { payment: { id: "pay_test_" + Date.now(), object: "payment", status: "confirmed", amount: "160", currency: "CHR", metadata: { askId: `${chat}:${card.result.message_id}`, chatId: chat, statusMsgId: card.result.message_id, threadId: null, question: q } } } };
const raw = JSON.stringify(event), t = Math.floor(Date.now() / 1000);
const sig = createHmac("sha256", process.env.CPAY_WEBHOOK_SECRET!).update(`${t}.${raw}`).digest("hex");
const r = await fetch(`${BASE}/api/cpay-webhook`, { method: "POST", headers: { "content-type": "application/json", "chromia-pay-signature": `t=${t},v1=${sig}` }, body: raw });
console.log("cpay webhook", r.status, await r.text(), "card message", card.result.message_id);
process.exit(0);
