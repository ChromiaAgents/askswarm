// GET /api/og-stats: 1200x630 preview image for /stats, rendered from the same numbers as the page.
// Crawlers fetch it once per share and cache it themselves, so s-maxage keeps us from re-reading
// the chain on every unfurl without letting the picture go stale for long.
import { ImageResponse } from "@vercel/og";
import { statsBody } from "./stats";

export const maxDuration = 30;

const INK = "#1F1A23", MUTED = "#5a5260", BG = "#F5EEEE", BAR = "#CC91F0";

// Satori takes plain element objects, so no JSX build step is needed.
const h = (type: string, style: Record<string, unknown>, children?: unknown) => ({ type, props: { style: { display: "flex", ...style }, children } });

const fmt = (n: number | null | undefined, dp = 0) =>
  n == null ? "–" : n.toLocaleString("en-US", { maximumFractionDigits: dp, minimumFractionDigits: 0 });

const card = (value: string, label: string) =>
  h("div", { flexDirection: "column", flex: 1, background: "#fff", border: `3px solid ${INK}`, borderRadius: 22, padding: "20px 24px", boxShadow: `6px 6px 0 ${INK}` }, [
    h("div", { fontSize: 64, fontWeight: 700, lineHeight: 1 }, value),
    h("div", { fontSize: 24, color: MUTED, marginTop: 10 }, label),
  ]);

export async function GET(req: Request) {
  const origin = new URL(req.url).origin;
  const font = (f: string) => fetch(`${origin}/fonts/og/${f}`).then((r) => r.arrayBuffer());
  const [s, regular, bold] = await Promise.all([statsBody(), font("NB_International_Regular.ttf"), font("NB_International_Bold.ttf")]);

  // Last 14 days of onchain activity, oldest first, zero-filled so quiet days still take a slot.
  const byDay = new Map(s.onchainDaily.map((d) => [d.day, d.asks + d.bets]));
  const days = Array.from({ length: 14 }, (_, i) => new Date(Date.now() - (13 - i) * 86400_000).toISOString().slice(0, 10));
  const activity = days.map((d) => byDay.get(d) ?? 0);
  const peak = Math.max(1, ...activity);
  const updated = new Date().toUTCString().slice(5, 22) + " UTC";

  const tree = h("div", { width: 1200, height: 630, flexDirection: "column", background: BG, color: INK, fontFamily: "NB", padding: "52px 60px" }, [
    h("div", { flexDirection: "column" }, [
      h("div", { fontSize: 60, fontWeight: 700 }, "AskSwarm stats"),
      h("div", { fontSize: 24, color: MUTED, marginTop: 6 }, `Live from the chain · ${updated}`),
    ]),
    h("div", { gap: 22, marginTop: 36 }, [
      card(fmt(s.asks.total), "questions asked"),
      card(fmt(s.asks.answered), "verified answers"),
      card(fmt(s.markets.bets), "bets"),
      card(fmt(s.markets.volumeImd, 2), "IMD staked"),
    ]),
    h("div", { gap: 22, marginTop: 22 }, [
      card(fmt(s.markets.total), "markets"),
      card(fmt(s.asks.askers), "unique askers"),
      card(fmt(s.markets.bettors), "unique bettors"),
      card(fmt(s.bot?.users), "bot users"),
    ]),
    h("div", { marginTop: "auto", alignItems: "flex-end", justifyContent: "space-between" }, [
      h("div", { fontSize: 24, color: MUTED }, "askswarm.evalengine.ai/stats"),
      h("div", { alignItems: "flex-end", gap: 14 }, [
        h("div", { fontSize: 20, color: MUTED }, "asks + bets, 14 days"),
        h("div", { alignItems: "flex-end", height: 56, gap: 5 },
          activity.map((v) => h("div", { width: 12, height: Math.max(4, Math.round((v / peak) * 56)), background: BAR, borderRadius: 6 }))),
      ]),
    ]),
  ]);

  return new ImageResponse(tree as any, {
    width: 1200,
    height: 630,
    fonts: [
      { name: "NB", data: regular, weight: 400, style: "normal" },
      { name: "NB", data: bold, weight: 700, style: "normal" },
    ],
    headers: { "cache-control": "public, max-age=300, s-maxage=600, stale-while-revalidate=3600" },
  });
}
