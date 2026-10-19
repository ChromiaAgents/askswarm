// GET /api/wagers            every SwarmWager wager, from its events plus current state
// GET /api/wagers?draft=<q>  free precheck of a yes/no question; returns the oracle body to stake on
// ponytail: 60s cache per instance, events are the index.
import { createPublicClient, http, parseAbi, hexToString, type Hex } from "viem";
import { mainnet } from "viem/chains";
import * as imd from "../packages/imd/src/index";

export const maxDuration = 30;
const WAGER = (process.env.WAGER_ADDRESS ?? "").toLowerCase() as Hex;
const FROM_BLOCK = BigInt(process.env.WAGER_FROM_BLOCK ?? "26214000");
const abi = parseAbi([
  "event Created(uint256 indexed id, address indexed creator, bool creatorSaysYes, uint256 stake, uint64 joinBy, uint64 resolveAfter, bytes body)",
  "event Joined(uint256 indexed id, address indexed counterparty)",
  "event Resolving(uint256 indexed id, bytes32 indexed requestId)",
  "event Paid(uint256 indexed id, address indexed winner, bool answer, uint256 amount)",
  "event Refunded(uint256 indexed id, uint8 reason)",
]);
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b, (_, v) => (typeof v === "bigint" ? v.toString() : v)), {
    status, headers: { "content-type": "application/json", "cache-control": "public, max-age=30", "access-control-allow-origin": "*" },
  });

let cache: { at: number; rows: any[] } | null = null;
async function rows() {
  if (cache && Date.now() - cache.at < 60_000) return cache.rows;
  if (!WAGER) return [];
  const pub = createPublicClient({ chain: mainnet, transport: http(process.env.ETH_RPC_URL) });
  const logs = await pub.getLogs({ address: WAGER, events: abi, fromBlock: FROM_BLOCK, toBlock: await pub.getBlockNumber() });
  const m = new Map<string, any>();
  for (const l of logs as any[]) {
    const a = l.args, id = String(a.id);
    if (l.eventName === "Created") {
      let body: any = {}; try { body = JSON.parse(hexToString(a.body)); } catch {}
      m.set(id, { id, creator: a.creator, creatorSaysYes: a.creatorSaysYes, stake: a.stake.toString(), joinBy: Number(a.joinBy), resolveAfter: Number(a.resolveAfter), question: body.question ?? "", body, state: "open", createTx: l.transactionHash });
    }
    const w = m.get(id); if (!w) continue;
    if (l.eventName === "Joined") Object.assign(w, { counterparty: a.counterparty, state: "matched" });
    if (l.eventName === "Resolving") Object.assign(w, { requestId: a.requestId, state: "asked", resolveTx: l.transactionHash });
    if (l.eventName === "Paid") Object.assign(w, { winner: a.winner, answer: a.answer ? "Yes" : "No", pot: a.amount.toString(), state: "paid", settleTx: l.transactionHash });
    if (l.eventName === "Refunded") Object.assign(w, { refundReason: a.reason, state: "refunded", settleTx: l.transactionHash });
  }
  const out = [...m.values()].sort((x, y) => Number(y.id) - Number(x.id));
  cache = { at: Date.now(), rows: out };
  return out;
}

export async function GET(req: Request) {
  const u = new URL(req.url);
  const draft = u.searchParams.get("draft");
  if (draft) {
    const q = draft.replace(/https?:\/\/\S+/g, "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 500);
    if (!q) return json({ error: "empty" }, 400);
    const chk = await imd.check(q, Number(process.env.IMD_PANEL_SIZE ?? 15));
    // A bet is about something that has not happened yet, so the swarm's precheck says
    // not_answerable today. That is the only blocker we accept: the swarm is asked after the
    // deadline, and if it still refuses then, the contract refunds everyone.
    const blockers = chk.blockers ?? [];
    const futureOnly = blockers.length > 0 && blockers.every((b) => b.code === "not_answerable" || b.code === "chain_unavailable");
    if (!chk.request || (blockers.length && !futureOnly)) return json({ error: "blocked", blockers }, 409);
    if (chk.request.answerType !== "bool") return json({ error: "not_yes_no", answerType: chk.request.answerType }, 409);
    return json({ request: chk.request, future: futureOnly, wager: WAGER, registry: process.env.REGISTRY_ADDRESS, imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" });
  }
  try { return json({ wager: WAGER, rows: await rows() }); }
  catch (e: any) { return json({ error: String(e?.message ?? e) }, 502); }
}
