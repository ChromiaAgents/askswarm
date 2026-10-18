// GET /api/markets  every SwarmMarket market from its events: question, pools, implied odds, phase.
// ponytail: 60s cache per instance, events are the index.
import { createPublicClient, http, parseAbi, hexToString, type Hex } from "viem";
import { mainnet } from "viem/chains";

export const maxDuration = 30;
const MARKET = (process.env.MARKET_ADDRESS ?? "").toLowerCase() as Hex;
const FROM_BLOCK = BigInt(process.env.MARKET_FROM_BLOCK ?? "26214000");
const abi = parseAbi([
  "event Opened(uint256 indexed id, address indexed creator, uint64 closeAt, uint64 resolveAfter, bytes body)",
  "event Staked(uint256 indexed id, address indexed user, bool yes, uint256 amount)",
  "event Resolving(uint256 indexed id, bytes32 indexed requestId)",
  "event Settled(uint256 indexed id, uint8 phase, uint256 yesPool, uint256 noPool, uint256 fee, uint8 reason)",
  "event Claimed(uint256 indexed id, address indexed user, uint256 amount)",
]);
const PHASES = ["none", "open", "asked", "yes", "no", "void"];
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b, (_, v) => (typeof v === "bigint" ? v.toString() : v)), {
    status, headers: { "content-type": "application/json", "cache-control": "public, max-age=30", "access-control-allow-origin": "*" },
  });

let cache: { at: number; body: any } | null = null;
export async function GET() {
  if (cache && Date.now() - cache.at < 60_000) return json(cache.body);
  if (!MARKET) return json({ market: null, rows: [] });
  try {
    const pub = createPublicClient({ chain: mainnet, transport: http(process.env.ETH_RPC_URL) });
    const logs = await pub.getLogs({ address: MARKET, events: abi, fromBlock: FROM_BLOCK, toBlock: await pub.getBlockNumber() });
    const m = new Map<string, any>();
    let fees = 0n, volume = 0n;
    for (const l of logs as any[]) {
      const a = l.args, id = String(a.id);
      if (l.eventName === "Opened") {
        let body: any = {}; try { body = JSON.parse(hexToString(a.body)); } catch {}
        m.set(id, { id, creator: a.creator, closeAt: Number(a.closeAt), resolveAfter: Number(a.resolveAfter), question: body.question ?? "", body, phase: "open", yesPool: 0n, noPool: 0n, stakers: new Set<string>(), openTx: l.transactionHash });
      }
      const r = m.get(id); if (!r) continue;
      if (l.eventName === "Staked") { a.yes ? (r.yesPool += a.amount) : (r.noPool += a.amount); r.stakers.add(a.user.toLowerCase()); volume += a.amount; }
      if (l.eventName === "Resolving") Object.assign(r, { phase: "asked", requestId: a.requestId });
      if (l.eventName === "Settled") { Object.assign(r, { phase: PHASES[a.phase], fee: a.fee, settleTx: l.transactionHash }); fees += a.fee; }
    }
    const rows = [...m.values()].sort((x, y) => Number(y.id) - Number(x.id)).map((r) => {
      const t = r.yesPool + r.noPool;
      return { ...r, stakers: r.stakers.size, oddsYesBps: t === 0n ? 5000 : Number((r.yesPool * 10000n) / t) };
    });
    const traders = new Set(rows.flatMap((r: any) => [...(m.get(r.id).stakers as Set<string>)])).size;
    const body = { market: MARKET, registry: process.env.REGISTRY_ADDRESS, stats: { markets: rows.length, traders, volume, fees }, rows };
    cache = { at: Date.now(), body };
    return json(body);
  } catch (e: any) { return json({ error: String(e?.message ?? e) }, 502); }
}
