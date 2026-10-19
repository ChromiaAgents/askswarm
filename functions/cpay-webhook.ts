import { isPaid } from "../packages/cpay/src/index";
import { askAndMark, cpay, ASK_CHAIN, bot } from "../lib/bot";

export async function POST(req: Request): Promise<Response> {
  const pay = cpay();
  if (!pay) return new Response("cpay disabled", { status: 503 });
  const raw = await req.text();
  let event;
  try {
    event = pay.webhooks.constructEvent(raw, req.headers.get("chromia-pay-signature") ?? "", process.env.CPAY_WEBHOOK_SECRET!, 300);
  } catch (e: any) {
    return new Response(`bad signature: ${e.message}`, { status: 400 });
  }
  const p = event.data.payment;
  if (!isPaid(p)) return new Response("ignored", { status: 200 }); // only confirmed/overpaid fulfil
  const md = p.metadata as { chatId: number; statusMsgId: number; question: string };
  if (!md?.chatId || !md?.statusMsgId || !md?.question) return new Response("no ask metadata", { status: 200 });
  // De-duplicate without a database: claim the payment by editing the status card to a text that names
  // this payment. Telegram refuses an edit that changes nothing ("message is not modified"), so a
  // redelivery of the same payment, even a concurrent one, fails the claim and is skipped.
  try {
    await bot.api.editMessageText(md.chatId, md.statusMsgId, `❓ ${md.question}\n💳 Paid (${p.id}). Asking the swarm…`);
  } catch (e: any) {
    if (/not modified/i.test(String(e?.description ?? e?.message))) return new Response("duplicate", { status: 200 });
    console.error("claim edit failed", p.id, e?.description ?? e); // card gone or bot removed: still fulfil once
  }
  try {
    await askAndMark(md.chatId, md.statusMsgId, md.question, ASK_CHAIN);
  } catch (e: any) {
    console.error("ask after payment failed", p.id, e);
  }
  return new Response("ok", { status: 200 });
}

export const maxDuration = 300;
