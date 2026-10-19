// GET /api/answers[?q=text][&limit=200]
// Everything AskSwarmRegistry has recorded, read from its events: question (from the ask body),
// decoded answer, panel, agreement, verification flag, expiry, and links. No database: events are
// the index. ponytail: 60s in-memory cache per instance; add KV if the log grows past a few thousand.
import { parseAbi, hexToString, decodeAbiParameters, type Hex } from "viem";
import { getLogsChunked, getBlockTs } from "../lib/logs";
import { chainList, ACTIVE } from "../lib/chains";

export const maxDuration = 30;
const abi = parseAbi([
  "event Asked(bytes32 indexed requestId, address indexed asker, bytes body)",
  "event Answered(bytes32 indexed requestId, bytes32 indexed questionHash, uint8 answerType, bytes answer, uint256 figure, uint16 agreed, uint16 quorum, uint16 panelSize, uint64 expiresAt, bool verified)",
  "event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)",
]);
const TYPES = ["bool", "address", "bytes32", "uint256", "address[]", "bytes32[]"] as const;

export type Row = {
  requestId: Hex; chainId: number; registry: Hex; asker: Hex; askTx: Hex; block: number; t: number; question: string; body: any;
  status: "pending" | "answered" | "refused" | "no result" | "unverified";
  answer?: string; answerRaw?: Hex; answerType?: string; agreed?: number; quorum?: number; panelSize?: number;
  expiresAt?: number; verified?: boolean; questionHash?: Hex; reason?: string; resultTx?: Hex;
};

function decodeAnswer(t: number, raw: Hex, figure: bigint): string {
  try {
    switch (t) {
      // `answer` is abi.encode of the value; `figure` is informational and 0 for bools.
      case 0: return (decodeAbiParameters([{ type: "bool" }], raw)[0] as boolean) ? "Yes" : "No";
      case 3: return (decodeAbiParameters([{ type: "uint256" }], raw)[0] as bigint).toString();
      case 1: return decodeAbiParameters([{ type: "address" }], raw)[0] as string;
      case 2: { const s = hexToString(raw).replace(/\0+$/, ""); return s && /^[\x20-\x7e]+$/.test(s) ? s : raw; }
      case 4: return (decodeAbiParameters([{ type: "address[]" }], raw)[0] as string[]).join(", ");
      case 5: return (decodeAbiParameters([{ type: "bytes32[]" }], raw)[0] as string[]).join(", ");
      default: return raw;
    }
  } catch { return raw; }
}

let cache: { at: number; rows: Row[] } | null = null;
export async function rows(): Promise<Row[]> {
  if (cache && Date.now() - cache.at < 60_000) return cache.rows;
  const out: Row[] = [];
  // Every chain with a registry; one failing chain does not hide the others.
  await Promise.all(chainList().filter((c) => c.registries.length).map(async (c) => {
    let logs: any[] = [];
    try { logs = await getLogsChunked(c, { address: c.registries, events: abi }); } catch (e: any) { console.error("[answers]", c.name, e?.shortMessage ?? e?.message); return; }
    const byId = new Map<Hex, Row>();
    for (const l of logs as any[]) {
      const a = l.args;
      if (l.eventName === "Asked") {
        let body: any = {}; try { body = JSON.parse(hexToString(a.body)); } catch {}
        byId.set(a.requestId, { requestId: a.requestId, chainId: c.id, registry: l.address, asker: a.asker, askTx: l.transactionHash, block: Number(l.blockNumber), t: 0, question: body.question ?? "", body, status: "pending" });
      } else if (l.eventName === "Answered") {
        const r = byId.get(a.requestId); if (!r) continue;
        Object.assign(r, {
          status: a.verified ? "answered" : "unverified", answerRaw: a.answer, answer: decodeAnswer(a.answerType, a.answer, a.figure),
          answerType: TYPES[a.answerType] ?? String(a.answerType), agreed: a.agreed, quorum: a.quorum, panelSize: a.panelSize,
          expiresAt: Number(a.expiresAt), verified: a.verified, questionHash: a.questionHash, resultTx: l.transactionHash,
        });
      } else if (l.eventName === "Failed") {
        const r = byId.get(a.requestId); if (!r) continue;
        Object.assign(r, { status: a.status === 1 ? "refused" : "no result", reason: hexToString(a.reason).replace(/\0+$/, ""), agreed: a.agreed, resultTx: l.transactionHash });
      }
    }
    const rs = [...byId.values()];
    await Promise.all(rs.map(async (r) => { try { r.t = await getBlockTs(c, BigInt(r.block)); } catch {} }));
    out.push(...rs);
  }));
  out.sort((x, y) => y.t - x.t);
  cache = { at: Date.now(), rows: out };
  return out;
}

export async function GET(req: Request) {
  const u = new URL(req.url);
  const q = (u.searchParams.get("q") ?? "").toLowerCase();
  const limit = Math.min(Number(u.searchParams.get("limit") ?? 200), 1000);
  let all: Row[];
  try { all = await rows(); } catch (e: any) { return new Response(JSON.stringify({ error: String(e?.message ?? e) }), { status: 502, headers: { "content-type": "application/json" } }); }
  const hit = q ? all.filter((r) => r.question.toLowerCase().includes(q) || (r.answer ?? "").toLowerCase().includes(q)) : all;
  const body = { active: ACTIVE.id, registries: chainList().flatMap((c) => c.registries.map((r) => ({ chainId: c.id, address: r }))), count: hit.length, verified: all.filter((r) => r.verified).length, rows: hit.slice(0, limit) };
  return new Response(JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)), {
    headers: { "content-type": "application/json", "cache-control": "public, max-age=60", "access-control-allow-origin": "*" },
  });
}
