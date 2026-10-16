import { isPaid } from "../packages/cpay/src/index";
import { askAndMark, cpay, ASK_CHAIN } from "../lib/bot";

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
  // ponytail: no dedupe store. A redelivered confirmed webhook would ask twice; Chromia Pay retries only
  // on non-2xx, so answer 200 fast and accept the risk for the hackathon. Add a KV set on event.id if it bites.
  try {
    await askAndMark(md.chatId, md.statusMsgId, md.question, ASK_CHAIN);
  } catch (e: any) {
    console.error("ask after payment failed", p.id, e);
  }
  return new Response("ok", { status: 200 });
}
