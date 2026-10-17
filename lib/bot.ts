// AskSwarm bot. Stateless on purpose: no DB. The bot's own status message carries the question and,
// once asked, the tx hash; Chromia Pay metadata carries chat/message ids. Runs as Vercel functions.
import { Bot, InlineKeyboard, type Context } from "grammy";
import { privateKeyToAccount } from "viem/accounts";
import { decodeAbiParameters, hexToString, type Hex } from "viem";
import { waitUntil } from "@vercel/functions";
import { createHmac, timingSafeEqual } from "node:crypto";
import * as imd from "../packages/imd/src/index";
import * as intake from "../packages/imd/src/intake";
import { ChromiaPay } from "../packages/cpay/src/index";
import * as risk from "./risk";
import { recall } from "./recall";
import { quickTake } from "./quick";

const env = (k: string, d?: string) => process.env[k] ?? d ?? (() => { throw new Error(`missing env ${k}`); })();

export const ASK_CHAIN = Number(process.env.ASK_CHAIN_ID ?? 11155111) as intake.IntakeChainId;
const PANEL = Number(process.env.IMD_PANEL_SIZE ?? 15);
const PRICE_CHR = process.env.CPAY_PRICE_CHR ?? "2.00";
const MAX_Q = 500;
// Telegram user or chat ids that may ask without paying (house wallet pays IMD). For internal testing
// on mainnet; empty in production. Find ids with /id.
const FREE_IDS = new Set((process.env.ASK_FREE_IDS ?? "").split(",").map((s) => s.trim()).filter(Boolean));
const canAskFree = (ctx: Context) => intake.CHAINS[ASK_CHAIN].free || FREE_IDS.has(String(ctx.from?.id)) || FREE_IDS.has(String(ctx.chat?.id));

// Spot prices for labels only, never for the charge. ponytail: 60s cache per instance, blank on failure.
// CHR from CoinGecko; IMD from DexScreener (CoinGecko has no entry for it).
const IMD_TOKEN = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7";
const priceCache: Record<string, { v: number; at: number }> = {};
async function spot(key: "chr" | "imd"): Promise<number | null> {
  const c = priceCache[key];
  if (c && Date.now() - c.at < 60_000) return c.v;
  try {
    const opt = { signal: AbortSignal.timeout(2500) };
    const v = key === "chr"
      ? Number((await (await fetch("https://api.coingecko.com/api/v3/simple/price?ids=chromaway&vs_currencies=usd", opt)).json()).chromaway.usd)
      : Number((await (await fetch(`https://api.dexscreener.com/latest/dex/tokens/${IMD_TOKEN}`, opt)).json()).pairs?.[0]?.priceUsd);
    if (!Number.isFinite(v) || v <= 0) return null;
    priceCache[key] = { v, at: Date.now() };
    return v;
  } catch { return null; }
}
const usd = (n: number) => `$${n < 0.1 ? n.toFixed(3) : n.toFixed(2)}`;
async function priceLabel(): Promise<string> {
  const p = await spot("chr");
  return p ? `Pay ${PRICE_CHR} CHR (~${usd(Number(PRICE_CHR) * p)})` : `Pay ${PRICE_CHR} CHR`;
}
/** "0.5 IMD (~$2.89, IMD $5.78)" or "0.5 IMD" when the price lookup fails. */
async function imdCostLine(): Promise<string> {
  const p = await spot("imd");
  return p ? `0.5 IMD (~${usd(0.5 * p)}, IMD ${usd(p)})` : "0.5 IMD";
}

// Pay-with-IMD link: the page gets chat/message ids and the question in the URL, signed so only the bot
// can mint one. Reuses the webhook secret rather than adding another env var.
export const BASE_URL = process.env.PUBLIC_URL ?? "https://askswarm-nine.vercel.app";
export const sign = (chatId: number | string, msgId: number, question: string) =>
  createHmac("sha256", env("TELEGRAM_WEBHOOK_SECRET")).update(`${chatId}\n${msgId}\n${question}`).digest("hex").slice(0, 32);
export const verifySig = (chatId: string, msgId: number, question: string, sig: string) => {
  const want = new TextEncoder().encode(sign(chatId, msgId, question)), got = new TextEncoder().encode(sig ?? "");
  return want.length === got.length && timingSafeEqual(want, got);
};
export const imdPayUrl = (chatId: number | string, msgId: number, question: string) =>
  `${BASE_URL}/imd?c=${chatId}&m=${msgId}&q=${encodeURIComponent(question)}&s=${sign(chatId, msgId, question)}`;

export const account = () => privateKeyToAccount(env("EVM_PRIVATE_KEY") as Hex);
export const cpay = () => process.env.CPAY_SECRET_KEY ? new ChromiaPay(process.env.CPAY_SECRET_KEY, { baseUrl: process.env.CPAY_API_URL }) : null;

// Native fetch: grammy defaults to node-fetch v2 on Node, which breaks when bundled and hangs every call.
export const bot = new Bot(env("TELEGRAM_BOT_TOKEN"), { client: { fetch: globalThis.fetch as any } });

const esc = (s: unknown) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);
const chainName = (id: number) => (id === 1 ? "Ethereum" : "Sepolia");
const txUrl = (id: number, tx: string) => `https://${id === 1 ? "" : "sepolia."}etherscan.io/tx/${tx}`;

// ---- message <-> state -------------------------------------------------------------------------
// Line 1 of every status message is "❓ <question>". After asking, a line "tx <chain> <0x...>" is added.
const parseQuestion = (text = "") => text.split("\n")[0]?.replace(/^❓\s*/, "").trim() ?? "";
const parseTx = (text = "") => {
  const m = text.match(/tx (Ethereum|Sepolia) (0x[0-9a-fA-F]{64})/);
  return m ? { chainId: (m[1] === "Ethereum" ? 1 : 11155111) as intake.IntakeChainId, tx: m[2] as Hex } : null;
};

// ---- /ask ---------------------------------------------------------------------------------------
bot.command("ask", (ctx) => ask(ctx, (ctx.match ?? "").toString(), ctx.msg.message_id));

// Curated demo questions. Order matters for a live demo: free recall hit, then a fresh paid one,
// then a bool, then one the swarm refuses, then one the risk model flags.
export const EXAMPLES: { label: string; q: string }[] = [
  { label: "Swiss franc ISO code · free, already attested", q: "What is the ISO 4217 currency code of the Swiss franc? Answer with the three-letter code only." },
  { label: "AT&T ticker · free, already attested", q: "What is AT&T's NYSE ticker symbol? Answer with the ticker symbol only." },
  { label: "Black Monday year · fresh paid ask", q: "In what year did the Black Monday crash occur, when the Dow fell about 22.6% in a single day? Answer with the four-digit year only." },
  { label: "Argentina won 2022 World Cup? · yes/no", q: "Did Argentina win the 2022 FIFA World Cup?" },
  { label: "gasUsed of block 26210851 · onchain lookup", q: "On Ethereum mainnet, how much gas was used in total by block 26210851 (the block's gasUsed field)? Answer with the whole number only." },
  { label: "Population of Springfield · swarm refuses", q: "What is the population of Springfield?" },
];
bot.command("examples", (ctx) => {
  const kb = new InlineKeyboard();
  EXAMPLES.forEach((e, i) => kb.text(e.label, `ex:${i}`).row());
  return ctx.reply("Tap one to ask it:", { reply_markup: kb });
});
bot.callbackQuery(/^ex:(\d+)$/, async (ctx) => {
  const e = EXAMPLES[Number(ctx.match[1])];
  if (!e) return ctx.answerCallbackQuery("gone");
  await ctx.answerCallbackQuery();
  await ask(ctx, e.q);
});

async function ask(ctx: Context, input: string, replyTo?: number) {
  const raw = input.replace(/https?:\/\/\S+/g, "").replace(/[\u0000-\u001f]/g, " ").trim();
  if (!raw) return ctx.reply("Usage: /ask <a factual question>\nOr /examples to pick one.");
  if (raw.length > MAX_Q) return ctx.reply(`Too long, max ${MAX_Q} chars.`);

  const chk = await imd.check(raw, PANEL);
  if (chk.blockers?.length || !chk.request) {
    const why = chk.blockers?.map((b) => `• ${esc(b.detail)}`).join("\n") || "• no drafted request";
    return ctx.reply(`The swarm won't take that one:\n${why}`, { parse_mode: "HTML" });
  }
  const r = chk.request;
  // User pays for the normalized question the panel will actually see, so show that, not their text.
  // Disagreement risk from the Eval Engine dataset (evalengine/imd-oracle-outcomes): shown before the
  // user pays, since a split panel is not refunded.
  const p = risk.predict(r), lvl = risk.riskLabel(p), why = risk.hints(r);
  const riskLine = `${lvl === "low" ? "🟢" : lvl === "medium" ? "🟡" : "🔴"} Split risk ${lvl} (${Math.round(p * 100)}%)` +
    (why.length && lvl !== "low" ? `\n<i>${why.map(esc).join("; ")}</i>` : "");
  // Free tiers first: a prior signed swarm answer from the Eval Engine dataset, then an unsigned
  // one-liner from a single model. The paid swarm below is the escalation, not the default.
  const [cost, prior, quick] = await Promise.all([imdCostLine(), Promise.resolve(recall(r.question)), quickTake(r.question)]);
  const free = [
    prior ? `✅ <b>${esc(prior.a)}</b>  <i>free, instant</i>\n<i>Swarm attested this on ${prior.at.slice(0, 10)}, ${prior.agreed}/${prior.panel} agreed · <a href="${imd.IMD_API}/oracle/requests/${prior.id}/attestation">signed attestation</a></i>` : "",
    quick ? `💬 <b>${esc(quick)}</b>  <i>free, unsigned AI guess</i>` : "",
  ].filter(Boolean).join("\n");
  const text = `❓ ${esc(r.question)}\n<i>${esc(r.answerType)} · panel ${r.panelSize}, quorum ${r.quorum} · ${esc(chk.online ?? "?")} agents online</i>\n${free ? `\n${free}\n` : ""}\n${riskLine}\n${free ? "Want a fresh signed verdict instead? " : ""}You buy the panel, not the answer: it costs ${esc(cost)} and a split panel is not refunded.`;
  const kb = new InlineKeyboard();
  if (canAskFree(ctx)) {
    const p = await spot("imd");
    kb.text(intake.CHAINS[ASK_CHAIN].free ? "Ask free (Sepolia)" : `Ask free (house pays${p ? ` ~${usd(0.5 * p)}` : ""})`, "free");
  }
  const status = await ctx.reply(text, { parse_mode: "HTML", link_preview_options: { is_disabled: true }, reply_parameters: replyTo ? { message_id: replyTo } : undefined, reply_markup: kb });
  const pay = cpay();
  if (pay) {
    const askId = `${ctx.chat!.id}:${status.message_id}`;
    const payment = await pay.payments.create({
      amount: PRICE_CHR,
      description: r.question.slice(0, 120),
      successUrl: `https://t.me/${ctx.me.username}`,
      expiresIn: 900,
      idempotencyKey: askId,
      metadata: { askId, chatId: ctx.chat!.id, statusMsgId: status.message_id, threadId: ctx.msg?.message_thread_id ?? null, question: r.question },
    });
    // Mini App keeps the payer inside Telegram. web_app inline buttons are private-chat only, so groups
    // get the direct-link Mini App (BotFather /newapp, short name "pay") with the checkout's cs_ id as
    // startapp; public/pay.html forwards into the hosted checkout.
    kb.row();
    const csId = payment.checkout_url.split("/").pop()!;
    const label = await priceLabel();
    if (ctx.chat!.type === "private") kb.webApp(label, payment.checkout_url);
    else kb.url(label, `https://t.me/${ctx.me.username}/pay?startapp=${csId}`);
  }
  // Pay in IMD from the user's own wallet: attestation is then addressed to them, not the house.
  if (ASK_CHAIN === 1) {
    const p = await spot("imd");
    kb.row().url(`Pay 0.5 IMD${p ? ` (~${usd(0.5 * p)})` : ""} from your wallet`, imdPayUrl(ctx.chat!.id, status.message_id, r.question));
  }
  if (pay || ASK_CHAIN === 1) await ctx.api.editMessageReplyMarkup(ctx.chat!.id, status.message_id, { reply_markup: kb });
}

// ---- ask the swarm (shared by free button and paid webhook) --------------------------------------
export async function markAsked(chatId: number | string, msgId: number, question: string, chainId: intake.IntakeChainId, tx: Hex, panelSize: number, who = "") {
  await bot.api.editMessageText(chatId, msgId,
    `❓ ${esc(question)}\n⏳ Asked the swarm on ${chainName(chainId)}${who}. Panel of ${panelSize} is assessing, usually 1–3 min.\ntx ${chainName(chainId)} ${tx}\n<a href="${txUrl(chainId, tx)}">etherscan</a>`,
    { parse_mode: "HTML", link_preview_options: { is_disabled: true }, reply_markup: new InlineKeyboard().text("Check status", "chk") });
  watch(chatId, msgId, question, chainId, tx);
}

export async function askAndMark(chatId: number | string, msgId: number, question: string, chainId: intake.IntakeChainId) {
  const chk = await imd.check(question, PANEL);
  if (!chk.request || chk.blockers?.length) throw new Error(`check failed: ${chk.blockers?.map((b) => b.code).join("; ")}`);
  if (intake.CHAINS[chainId].free) await intake.ensureAllowance(chainId, account());
  const tx = await intake.ask(chainId, account(), chk.request);
  await markAsked(chatId, msgId, question, chainId, tx, chk.request.panelSize);
  return tx;
}

bot.callbackQuery("free", async (ctx) => {
  const msg = ctx.callbackQuery.message;
  if (!msg || !canAskFree(ctx)) return ctx.answerCallbackQuery("not available");
  if (parseTx(msg.text)) return ctx.answerCallbackQuery("already asked");
  await ctx.answerCallbackQuery("asking…");
  try { await askAndMark(msg.chat.id, msg.message_id, parseQuestion(msg.text), ASK_CHAIN); }
  catch (e: any) { await ctx.api.editMessageText(msg.chat.id, msg.message_id, `${msg.text}\n\n❌ ${esc(e.message).slice(0, 300)}`); }
});

// ---- status / answer -----------------------------------------------------------------------------
function decodeAnswer(m: Record<string, any>): string {
  try {
    switch (m.answerType) {
      case "bool": return BigInt(m.figure) === 1n ? "Yes" : "No";
      case "uint256": return String(m.figure);
      case "address": return decodeAbiParameters([{ type: "address" }], m.answer)[0] as string;
      case "bytes32": {
        const t = hexToString(m.answer as Hex).replace(/\0+$/, "");
        return t && /^[\x20-\x7e]+$/.test(t) ? t : String(m.answer);
      }
      default: return String(m.answer);
    }
  } catch { return String(m.answer); }
}

/** Reads plane + oracle state for a card and edits it when terminal. Returns a short status note. */
export async function refresh(chatId: number | string, msgId: number, question: string, chainId: intake.IntakeChainId, tx: Hex): Promise<{ done: boolean; note: string }> {
  const rec = await intake.readIntake(chainId, tx);
  const requestId = intake.oracleRequestIdFrom(rec);
  if (!requestId) return { done: false, note: `plane: ${rec?.entries?.[0]?.state ?? "indexing, ~1 min"}` };
  const s = await imd.oracleStatus(requestId);
  if (!["attested", "disagreed", "blocked", "mismatch", "refused", "failed"].includes(s.status)) {
    return { done: false, note: `panel ${s.status}, agreed ${s.agreement?.agreed ?? 0}` };
  }
  const edit = (html: string) => bot.api.editMessageText(chatId, msgId, html, { parse_mode: "HTML", link_preview_options: { is_disabled: true } });
  const jobLink = s.jobUrl ? `\n<a href="${esc(s.jobUrl)}">swarm job</a>` : "";
  if (s.status !== "attested") {
    await edit(`❓ ${esc(question)}\n⚠️ Panel ended <b>${esc(s.status)}</b>, no consensus. ${esc(JSON.stringify(s.failure ?? "")).slice(0, 200)}\ntx ${chainName(chainId)} ${tx}${jobLink}`);
    return { done: true, note: s.status };
  }
  const att = await imd.attestation(requestId);
  if (!att) return { done: false, note: "attested, signature not published yet" };
  const valid = await imd.verifyAttestation(att);
  const m = att.message;
  await edit(
    `❓ ${esc(question)}\n✅ <b>${esc(decodeAnswer(m))}</b>\n<i>${m.agreed}/${m.panelSize} agreed (quorum ${m.quorum}) · EIP-712 ${valid ? "verified" : "INVALID"} · signer ${esc(String(att.signer).slice(0, 10))}…</i>\ntx ${chainName(chainId)} ${tx}\n<a href="${imd.IMD_API}/oracle/requests/${requestId}/attestation">attestation</a>${jobLink} · <a href="${txUrl(chainId, tx)}">etherscan</a>`);
  return { done: true, note: "answered" };
}

// Keeps the function alive after the HTTP response (Vercel waitUntil) and polls until the panel is
// terminal or the budget runs out. The Check status button stays as the manual fallback.
// ponytail: no queue, no cron; if the instance dies the user taps Check status.
export function watch(chatId: number | string, msgId: number, question: string, chainId: intake.IntakeChainId, tx: Hex, budgetMs = 270_000) {
  const t0 = Date.now();
  waitUntil((async () => {
    while (Date.now() - t0 < budgetMs) {
      await new Promise((r) => setTimeout(r, 10_000));
      try { if ((await refresh(chatId, msgId, question, chainId, tx)).done) return; }
      catch (e: any) { console.error("[watch]", e?.message ?? e); }
    }
  })());
}

bot.callbackQuery("chk", async (ctx) => {
  const msg = ctx.callbackQuery.message;
  const st = msg && parseTx(msg.text);
  if (!st) return ctx.answerCallbackQuery("no tx on this message");
  try { await ctx.answerCallbackQuery((await refresh(msg.chat.id, msg.message_id, parseQuestion(msg.text), st.chainId, st.tx)).note); }
  catch (e: any) { await ctx.answerCallbackQuery(`error: ${String(e.message).slice(0, 150)}`); }
});

bot.command("id", (ctx) => ctx.reply(`user ${ctx.from?.id}\nchat ${ctx.chat.id}`));
bot.command("start", (ctx) => ctx.reply("Ask the IMD swarm a factual question:\n/ask Did Argentina win the 2022 FIFA World Cup?\n\nOr /examples to pick one."));
bot.catch((e) => console.error("bot error", e.error));
