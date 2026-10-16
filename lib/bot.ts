// AskSwarm bot. Stateless on purpose: no DB. The bot's own status message carries the question and,
// once asked, the tx hash; Chromia Pay metadata carries chat/message ids. Runs as Vercel functions.
import { Bot, InlineKeyboard, type Context } from "grammy";
import { privateKeyToAccount } from "viem/accounts";
import { decodeAbiParameters, type Hex } from "viem";
import * as imd from "../packages/imd/src/index";
import * as intake from "../packages/imd/src/intake";
import { ChromiaPay } from "../packages/cpay/src/index";

const env = (k: string, d?: string) => process.env[k] ?? d ?? (() => { throw new Error(`missing env ${k}`); })();

export const ASK_CHAIN = Number(process.env.ASK_CHAIN_ID ?? 11155111) as intake.IntakeChainId;
const PANEL = Number(process.env.IMD_PANEL_SIZE ?? 15);
const PRICE_CHR = process.env.CPAY_PRICE_CHR ?? "2.00";
const MAX_Q = 500;

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
bot.command("ask", async (ctx) => {
  const raw = (ctx.match ?? "").toString().replace(/https?:\/\/\S+/g, "").replace(/[\u0000-\u001f]/g, " ").trim();
  if (!raw) return ctx.reply("Usage: /ask <a factual question>");
  if (raw.length > MAX_Q) return ctx.reply(`Too long, max ${MAX_Q} chars.`);

  const chk = await imd.check(raw, PANEL);
  if (chk.blockers?.length || !chk.request) {
    return ctx.reply(`The swarm won't take that one:\n${esc(chk.blockers?.join("\n") || "no drafted request")}`, { parse_mode: "HTML" });
  }
  const r = chk.request;
  // User pays for the normalized question the panel will actually see, so show that, not their text.
  const text = `❓ ${esc(r.question)}\n<i>${esc(r.answerType)} · panel ${r.panelSize}, quorum ${r.quorum} · ${esc(chk.online ?? "?")} agents online</i>\n\nYou buy the panel, not the answer: ~4% of questions end without consensus and are not refunded.`;
  const kb = new InlineKeyboard();
  if (intake.CHAINS[ASK_CHAIN].free) kb.text("Ask free (Sepolia)", "free");
  const status = await ctx.reply(text, { parse_mode: "HTML", reply_parameters: { message_id: ctx.msg.message_id }, reply_markup: kb });

  const pay = cpay();
  if (pay) {
    const askId = `${ctx.chat.id}:${status.message_id}`;
    const payment = await pay.payments.create({
      amount: PRICE_CHR,
      description: r.question.slice(0, 120),
      successUrl: `https://t.me/${ctx.me.username}`,
      expiresIn: 900,
      idempotencyKey: askId,
      metadata: { askId, chatId: ctx.chat.id, statusMsgId: status.message_id, threadId: ctx.msg.message_thread_id ?? null, question: r.question },
    });
    // Mini App keeps the payer inside Telegram. web_app inline buttons are private-chat only, so groups
    // get the direct-link Mini App (BotFather /newapp, short name "pay") with the checkout's cs_ id as
    // startapp; public/pay.html forwards into the hosted checkout.
    kb.row();
    const csId = payment.checkout_url.split("/").pop()!;
    if (ctx.chat.type === "private") kb.webApp(`Pay ${PRICE_CHR} CHR`, payment.checkout_url);
    else kb.url(`Pay ${PRICE_CHR} CHR`, `https://t.me/${ctx.me.username}/pay?startapp=${csId}`);
    await ctx.api.editMessageReplyMarkup(ctx.chat.id, status.message_id, { reply_markup: kb });
  }
});

// ---- ask the swarm (shared by free button and paid webhook) --------------------------------------
export async function askAndMark(chatId: number | string, msgId: number, question: string, chainId: intake.IntakeChainId) {
  const chk = await imd.check(question, PANEL);
  if (!chk.request || chk.blockers?.length) throw new Error(`check failed: ${chk.blockers?.join("; ")}`);
  if (intake.CHAINS[chainId].free) await intake.ensureAllowance(chainId, account());
  const tx = await intake.ask(chainId, account(), chk.request);
  await bot.api.editMessageText(chatId, msgId,
    `❓ ${esc(question)}\n⏳ Asked the swarm on ${chainName(chainId)}. Panel of ${chk.request.panelSize} is assessing, usually 1–3 min.\ntx ${chainName(chainId)} ${tx}\n<a href="${txUrl(chainId, tx)}">etherscan</a>`,
    { parse_mode: "HTML", link_preview_options: { is_disabled: true }, reply_markup: new InlineKeyboard().text("Check status", "chk") });
  return tx;
}

bot.callbackQuery("free", async (ctx) => {
  const msg = ctx.callbackQuery.message;
  if (!msg || !intake.CHAINS[ASK_CHAIN].free) return ctx.answerCallbackQuery("not available");
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
      case "bytes32": return String(m.answer);
      default: return String(m.answer);
    }
  } catch { return String(m.answer); }
}

bot.callbackQuery("chk", async (ctx) => {
  const msg = ctx.callbackQuery.message;
  const st = msg && parseTx(msg.text);
  if (!st) return ctx.answerCallbackQuery("no tx on this message");
  try {
    const rec = await intake.readIntake(st.chainId, st.tx);
    const requestId = intake.oracleRequestIdFrom(rec);
    if (!requestId) return ctx.answerCallbackQuery(`plane state: ${rec?.entries?.[0]?.state ?? "not indexed yet"}`);
    const s = await imd.oracleStatus(requestId);
    if (["assessing", "reproducing", "pending", "queued"].includes(s.status) || !["attested", "disagreed", "blocked", "mismatch", "refused", "failed"].includes(s.status)) {
      return ctx.answerCallbackQuery(`panel ${s.status}, agreed ${s.agreement?.agreed ?? 0}`);
    }
    const q = parseQuestion(msg.text);
    const jobLink = s.jobUrl ? `\n<a href="${esc(s.jobUrl)}">swarm job</a>` : "";
    if (s.status !== "attested") {
      await ctx.editMessageText(`❓ ${esc(q)}\n⚠️ Panel ended <b>${esc(s.status)}</b>, no consensus. ${esc(JSON.stringify(s.failure ?? "")).slice(0, 200)}\ntx ${chainName(st.chainId)} ${st.tx}${jobLink}`, { parse_mode: "HTML", link_preview_options: { is_disabled: true } });
      return ctx.answerCallbackQuery();
    }
    const att = await imd.attestation(requestId);
    if (!att) return ctx.answerCallbackQuery("attested, signature not published yet");
    const valid = await imd.verifyAttestation(att);
    const m = att.message;
    await ctx.editMessageText(
      `❓ ${esc(q)}\n✅ <b>${esc(decodeAnswer(m))}</b>\n<i>${m.agreed}/${m.panelSize} agreed (quorum ${m.quorum}) · EIP-712 ${valid ? "verified" : "INVALID"} · signer ${esc(String(att.signer).slice(0, 10))}…</i>\ntx ${chainName(st.chainId)} ${st.tx}\n<a href="${imd.IMD_API}/oracle/requests/${requestId}/attestation">attestation</a>${jobLink} · <a href="${txUrl(st.chainId, st.tx)}">etherscan</a>`,
      { parse_mode: "HTML", link_preview_options: { is_disabled: true } });
    await ctx.answerCallbackQuery("answered");
  } catch (e: any) {
    await ctx.answerCallbackQuery(`error: ${String(e.message).slice(0, 150)}`);
  }
});

bot.command("start", (ctx) => ctx.reply("Ask the IMD swarm a factual question:\n/ask Did Argentina win the 2022 FIFA World Cup?"));
bot.catch((e) => console.error("bot error", e.error));
