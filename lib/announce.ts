// Posts market news to every subscribed chat (lib/subs.ts: users who talked to the bot, groups it is in)
// plus BROADCAST_CHATS, with a button that opens the market inside the `pay` Mini App
// (t.me/<bot>/pay?startapp=m<id>). Plain Bot API fetch, so the keeper can use it without the whole bot.
import { subscribers, unsubscribe } from "./subs";
const BOT = process.env.BOT_USERNAME ?? "askswarm_bot";
const CHATS = (process.env.BROADCAST_CHATS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const MONTHS: Record<string, string> = { January: "Jan", February: "Feb", March: "Mar", April: "Apr", May: "May", June: "Jun", July: "Jul", August: "Aug", September: "Sep", October: "Oct", November: "Nov", December: "Dec" };

export const miniAppLink = (start: string) => `https://t.me/${BOT}/pay?startapp=${start}`;
const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);

/** Same plain-English title the market page shows. `daily` marks a keeper round opened that day. */
export function marketTitle(question: string, daily = false) {
  const m = question.match(/^Was the Coinbase (\w+)-USD daily close on (\d+) (\w+) (\d{4}) \(UTC\) above ([\d,.]+) US dollars\?$/)
    ?? question.match(/^Was the closing price of \w+ \((\w+)\) on (\d+) (\w+) (\d{4}), as listed on CoinMarketCap historical data, above ([\d,.]+) US dollars\?$/);
  if (!m) return question;
  const day = `${MONTHS[m[3]] ?? m[3]} ${m[2]}`;
  return daily ? `${m[1]} up or down today? · ${day} · vs $${m[5]}` : `Will ${m[1]} close above $${m[5]} on ${day}?`;
}

export async function announce(html: string, button: { text: string; start: string }) {
  if (!process.env.TELEGRAM_BOT_TOKEN) return;
  const subs = await subscribers().catch((e) => { console.error("[announce] subs", e?.message ?? e); return [] as string[]; });
  const to = [...new Set([...CHATS, ...subs])];
  const reply_markup = { inline_keyboard: [[{ text: button.text, url: miniAppLink(button.start) }]] };
  // Telegram allows ~30 messages a second overall: send in batches of 25 a second.
  for (let i = 0; i < to.length; i += 25) {
    await Promise.all(to.slice(i, i + 25).map(async (chat_id) => {
      const priv = !chat_id.startsWith("-"); // private chats get the way out; groups don't need it
      try {
        const r = await fetch(`https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
          method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(8000),
          body: JSON.stringify({ chat_id, text: priv ? `${html}\n<i>/stop to turn off these updates</i>` : html, parse_mode: "HTML", link_preview_options: { is_disabled: true }, reply_markup }),
        });
        // Blocked by the user, or removed from the group: stop sending there (not a /stop, so no mute).
        if (r.status === 403 && !CHATS.includes(chat_id)) await unsubscribe(chat_id, false);
      } catch (e: any) { console.error("[announce]", chat_id, e?.message ?? e); }
    }));
    if (i + 25 < to.length) await new Promise((r) => setTimeout(r, 1000));
  }
}

/** "6h 5m" style countdown; timezone-free, so every reader in the group sees the same thing. */
export function inTime(sec: number) {
  if (sec <= 0) return "now";
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}
const utc = (t: number) => { const d = new Date(t * 1000); return `${d.toISOString().slice(11, 16)} UTC ${d.getUTCDate()} ${Object.values(MONTHS)[d.getUTCMonth()]}`; };

// Mini App start param: "m3" = Ethereum market 3 (old links), "m3_4663" = Robinhood Chain market 3.
const mStart = (id: number, chainId = 1) => chainId === 1 ? `m${id}` : `m${id}_${chainId}`;
const chainTag = (chainId = 1) => chainId === 4663 ? " on Robinhood Chain" : " on Ethereum";

export const announceOpened = (id: number, question: string, closeAt: number, daily: boolean, chainId = 1) =>
  announce(`🎲 <b>${esc(marketTitle(question, daily))}</b>\nBetting closes in <b>${inTime(closeAt - Date.now() / 1000)}</b> (${utc(closeAt)}). Pick Yes or No; 1,000 AI agents from the IMD swarm settle it onchain${chainTag(chainId)}.`, { text: "Bet in Telegram", start: mStart(id, chainId) });

export const announceSettled = (id: number, question: string, outcome: "yes" | "no" | "void", detail: string, chainId = 1) =>
  announce(outcome === "void"
    ? `↩️ <b>${esc(marketTitle(question))}</b>\nNo verdict (${esc(detail)}). Everyone gets their stake back.`
    : `✅ <b>${esc(marketTitle(question))}</b>\nResolved <b>${outcome.toUpperCase()}</b>. ${esc(detail)} Winners can claim now.`, { text: outcome === "void" ? "Claim refund" : "See result", start: mStart(id, chainId) });
