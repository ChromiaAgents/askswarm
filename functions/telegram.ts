import { bot } from "../lib/bot";

export const maxDuration = 60;

// Plain handler instead of grammy's std/http adapter: the adapter hung on Vercel's Request while
// passing locally, and these six lines are easier to reason about than its promise plumbing.
export async function POST(req: Request): Promise<Response> {
  const t0 = Date.now();
  const log = (s: string) => console.log(`[telegram +${Date.now() - t0}ms] ${s}`);
  if (req.headers.get("x-telegram-bot-api-secret-token") !== process.env.TELEGRAM_WEBHOOK_SECRET) {
    log("bad secret");
    return new Response("unauthorized", { status: 401 });
  }
  const text = await req.text();
  log(`body ${text.length}b`);
  let update: any;
  try { update = JSON.parse(text); } catch { return new Response("bad json", { status: 400 }); }
  await bot.init();
  log(`init ok @${bot.botInfo.username}`);
  // Telegram retries on non-2xx; handler errors are logged, not surfaced, so one bad update cannot loop.
  try { await bot.handleUpdate(update); log("handled"); }
  catch (e: any) { console.error("[telegram] handleUpdate failed", e?.message ?? e); }
  return new Response("ok", { status: 200 });
}
