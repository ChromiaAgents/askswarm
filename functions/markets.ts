// GET /api/markets  every SwarmMarket market from its events: question, pools, implied odds, phase.
// ponytail: 60s cache per instance, events are the index.
import { parseAbi, hexToString, type Hex } from "viem";
import { getLogsChunked, getBlockTs } from "../lib/logs";
import { chainList, publicChains, ACTIVE, type ChainCfg } from "../lib/chains";
import * as risk from "../lib/risk";
import { withImd } from "../lib/imdlinks";

export const maxDuration = 30;
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

// One chain's markets, each row tagged with chainId (ids restart at 1 on every chain).
async function chainRows(c: ChainCfg) {
  const logs = await getLogsChunked(c, { address: c.market!, events: abi }, BigInt(c.id === 1 ? process.env.MARKET_FROM_BLOCK ?? c.fromBlock : c.fromBlock));
  const m = new Map<string, any>();
  // Timestamps for the chart: one getBlock per distinct block (few per market).
  const blocks = [...new Set((logs as any[]).map((l) => l.blockNumber as bigint))];
  const ts = new Map<bigint, number>();
  await Promise.all(blocks.map(async (b) => ts.set(b, await getBlockTs(c, b))));
  for (const l of logs as any[]) {
    const a = l.args, id = String(a.id), t = ts.get(l.blockNumber) ?? 0;
    if (l.eventName === "Opened") {
      let body: any = {}; try { body = JSON.parse(hexToString(a.body)); } catch {}
      m.set(id, { id, chainId: c.id, market: c.market, creator: a.creator, closeAt: Number(a.closeAt), resolveAfter: Number(a.resolveAfter), question: body.question ?? "", body, phase: "open", yesPool: 0n, noPool: 0n, stakers: new Set<string>(), openTx: l.transactionHash, openedAt: t, trades: [] as any[], history: [{ t, yesBps: 5000 }], claims: [] as any[], fee: 0n });
    }
    const r = m.get(id); if (!r) continue;
    if (l.eventName === "Staked") {
      a.yes ? (r.yesPool += a.amount) : (r.noPool += a.amount); r.stakers.add(a.user.toLowerCase());
      r.trades.push({ t, user: a.user, side: a.yes ? "yes" : "no", amount: a.amount, tx: l.transactionHash });
      r.history.push({ t, yesBps: Number((r.yesPool * 10000n) / (r.yesPool + r.noPool)) });
    }
    if (l.eventName === "Resolving") Object.assign(r, { phase: "asked", requestId: a.requestId, resolveTx: l.transactionHash, askedAt: t });
    if (l.eventName === "Settled") Object.assign(r, { phase: PHASES[a.phase], fee: a.fee, settleTx: l.transactionHash, settledAt: t, voidReason: a.phase === 5 ? a.reason : undefined });
    if (l.eventName === "Claimed") r.claims.push({ t, user: a.user, amount: a.amount, tx: l.transactionHash });
  }
  return [...m.values()];
}

let cache: { at: number; body: any } | null = null;
export async function GET() {
  if (cache && Date.now() - cache.at < 60_000) return json(cache.body);
  try {
    const all = (await Promise.all(chainList().filter((c) => c.market).map((c) =>
      chainRows(c).catch((e) => { console.error("[markets]", c.name, e?.shortMessage ?? e?.message); return [] as any[]; })))).flat();
    const traders = new Set(all.flatMap((r) => [...(r.stakers as Set<string>)])).size;
    let fees = 0n, volume = 0n;
    for (const r of all) { fees += r.fee; volume += r.yesPool + r.noPool; }
    // Newest first: active chain on top, then by id.
    const rows = all.sort((x, y) => (y.openedAt - x.openedAt) || (Number(y.id) - Number(x.id))).map((r) => {
      const t = r.yesPool + r.noPool;
      // Void risk: the split-risk model trained on the Eval Engine dataset, on this market's exact body.
      let voidRiskBps: number | null = null;
      try { if (r.body?.question) voidRiskBps = Math.round(risk.predict({ question: r.body.question, answerType: r.body.answerType ?? "bool", panelSize: r.body.panelSize ?? 15, quorum: r.body.quorum ?? 11, evidence: r.body.evidence }) * 10000); } catch {}
      return { ...r, stakers: r.stakers.size, oddsYesBps: t === 0n ? 5000 : Number((r.yesPool * 10000n) / t), voidRiskBps };
    });
    await withImd(rows, (r) => r.chainId, (r) => r.resolveTx);
    const body = { active: ACTIVE.id, market: ACTIVE.market ?? null, registry: ACTIVE.registries[0] ?? null, chains: publicChains(), stats: { markets: rows.length, traders, volume, fees }, rows };
    cache = { at: Date.now(), body };
    return json(body);
  } catch (e: any) { return json({ error: String(e?.message ?? e) }, 502); }
}
