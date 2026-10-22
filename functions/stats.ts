// GET /api/stats: usage at a glance for /stats. Onchain numbers come from the registry and market
// events (all history); bot numbers from the Redis counters in lib/subs.ts (since they were added).
// Aggregates only: no chat ids or addresses leave this endpoint.
import { rows } from "./answers";
import { marketRows } from "./markets";
import { botStats } from "../lib/subs";
import { formatEther } from "viem";

export const maxDuration = 30;
const day = (t: number) => new Date(t * 1000).toISOString().slice(0, 10);

export async function GET() {
  return new Response(JSON.stringify(await statsBody()), { headers: { "content-type": "application/json", "cache-control": "public, max-age=60" } });
}

// Shared with /api/og-stats so the preview image and the page read the same numbers.
export async function statsBody() {
  const [answers, markets, bot] = await Promise.all([rows().catch(() => []), marketRows().catch(() => []), botStats().catch(() => null)]);
  const byDay: Record<string, { asks: number; bets: number }> = {};
  const at = (t: number) => (byDay[day(t)] ??= { asks: 0, bets: 0 });
  for (const r of answers) if (r.t) at(r.t).asks++;
  const trades = markets.flatMap((m: any) => m.trades);
  for (const t of trades) if (t.t) at(t.t).bets++;
  const status = (s: string) => answers.filter((r) => r.status === s).length;
  return {
    asks: { total: answers.length, answered: status("answered"), noResult: status("no result"), refused: status("refused"), pending: status("pending"), askers: new Set(answers.map((r) => r.asker.toLowerCase())).size },
    markets: { total: markets.length, open: markets.filter((m: any) => m.phase === "open").length, bets: trades.length,
      bettors: new Set(trades.map((t: any) => t.user.toLowerCase())).size,
      volumeImd: Number(formatEther(markets.reduce((s: bigint, m: any) => s + m.yesPool + m.noPool, 0n))) },
    bot,
    onchainDaily: Object.entries(byDay).sort(([a], [b]) => a.localeCompare(b)).slice(-30).map(([d, v]) => ({ day: d, ...v })),
  };
}
