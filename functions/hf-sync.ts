// Daily Vercel cron (vercel.json) and manual trigger: push registry answers to the HF dataset.
// Vercel calls crons with Authorization: Bearer <CRON_SECRET>; a manual call must send the same.
import { syncToHuggingFace } from "../lib/hfsync";

export const maxDuration = 60;
export async function GET(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) return new Response("unauthorized", { status: 401 });
  try {
    const r = await syncToHuggingFace();
    return new Response(JSON.stringify(r ?? { skipped: "HF_TOKEN not set" }), { status: 200, headers: { "content-type": "application/json" } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: String(e?.message ?? e) }), { status: 502, headers: { "content-type": "application/json" } });
  }
}
