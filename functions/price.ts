// GET /api/price?pair=ETH-USD&from=<unix>&to=<unix>
// Underlying price for markets whose question names a Coinbase pair: candles over the range plus the
// latest trade. Display only; markets settle on the swarm's answer, never on this feed.
// ponytail: 10s in-memory cache per (pair, range bucket); Coinbase public API, no key.
export const maxDuration = 15;
const PAIR = /^[A-Z0-9]{2,10}-(USD|USDC|USDT|EUR)$/;
const cache = new Map<string, { at: number; body: string }>();

const json = (body: string, status = 200) =>
  new Response(body, { status, headers: { "content-type": "application/json", "cache-control": "public, max-age=10", "access-control-allow-origin": "*" } });

export async function GET(req: Request) {
  const u = new URL(req.url);
  const pair = (u.searchParams.get("pair") ?? "").toUpperCase();
  if (!PAIR.test(pair)) return json(JSON.stringify({ error: "bad_pair" }), 400);
  const now = Math.floor(Date.now() / 1000);
  const to = Math.min(Number(u.searchParams.get("to") ?? now) || now, now);
  const from = Math.max(Number(u.searchParams.get("from") ?? to - 3600) || to - 3600, to - 365 * 86400);
  const span = Math.max(to - from, 60);
  // Coinbase returns at most 300 candles; pick the finest granularity that covers the range.
  const gran = [60, 300, 900, 3600, 21600, 86400].find((g) => span / g <= 300) ?? 86400;
  const key = `${pair}:${gran}:${Math.floor(from / gran)}:${Math.floor(to / 10)}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < 10_000) return json(hit.body);
  const H = { "user-agent": "askswarm" };
  try {
    const start = new Date(Math.max(from, to - gran * 299) * 1000).toISOString(), end = new Date(to * 1000).toISOString();
    const [c, t] = await Promise.all([
      fetch(`https://api.exchange.coinbase.com/products/${pair}/candles?granularity=${gran}&start=${start}&end=${end}`, { headers: H, signal: AbortSignal.timeout(6000) }).then((r) => r.json()),
      fetch(`https://api.exchange.coinbase.com/products/${pair}/ticker`, { headers: H, signal: AbortSignal.timeout(6000) }).then((r) => r.json()),
    ]);
    if (!Array.isArray(c)) return json(JSON.stringify({ error: "no_candles", detail: c?.message }), 502);
    // [time, low, high, open, close, volume], newest first
    const points = c.map((k: number[]) => ({ t: k[0], v: k[4] })).sort((a: any, b: any) => a.t - b.t);
    const current = Number(t?.price);
    if (Number.isFinite(current)) points.push({ t: now, v: current });
    const body = JSON.stringify({ pair, granularity: gran, current, points });
    cache.set(key, { at: Date.now(), body });
    return json(body);
  } catch (e: any) {
    return json(JSON.stringify({ error: String(e?.message ?? e) }), 502);
  }
}
