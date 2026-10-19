// Keeper: Vercel cron every 10 minutes (vercel.json). SwarmMarket only accepts `resolve` within
// RESOLVE_WINDOW (1 hour) of a market's deadline, so somebody has to call it on time; this does,
// from the house wallet (gas only; the swarm fee comes from each market's own escrow). It also
// settles anything the swarm has answered and unwinds what can no longer resolve. Every call it
// makes is permissionless: anyone can run the same loop.
// ponytail: scans all ids each run; fine below a few hundred markets, index by events beyond that.
import { createPublicClient, createWalletClient, http, parseAbi, erc20Abi, stringToHex, hexToString, parseEther, type Hex } from "viem";
import * as imd from "../packages/imd/src/index";
import { announceOpened, announceSettled } from "../lib/announce";
import { getLogsChunked } from "../lib/logs";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

export const maxDuration = 300;
const marketAbi = parseAbi([
  "function count() view returns (uint256)",
  "function RESOLVE_WINDOW() view returns (uint64)",
  "function get(uint256 id) view returns ((address creator,uint64 closeAt,uint64 resolveAfter,uint64 askedAt,uint8 phase,uint96 feeEscrow,uint128 yesPool,uint128 noPool,uint128 winnersShare,bytes32 requestId) m, bytes body)",
  "function resolve(uint256 id)", "function settle(uint256 id)", "function abandon(uint256 id)",
  "function open(bytes body, uint64 closeAt, uint64 resolveAfter) returns (uint256)",
  "function stake(uint256 id, bool yes, uint128 amount)",
  "event Opened(uint256 indexed id, address indexed creator, uint64 closeAt, uint64 resolveAfter, bytes body)",
]);
const IMD_TOKEN = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Hex;
// Daily "up or down" rounds, like HIP-4's daily markets: target = the Coinbase price when the round
// opens, settled by the swarm on that day's close. The house seeds both sides so every round is live.
const DAILY = (process.env.DAILY_PAIRS ?? "ETH-USD,BTC-USD").split(",").map((s) => s.trim()).filter(Boolean);
// Precheck codes that do not mean "bad question": the future (asked after the close) and IMD's own
// infra being briefly down (the onchain request is recorded and answered when it recovers).
const SOFT = new Set(["not_answerable", "chain_unavailable"]);
const SEED = parseEther(process.env.DAILY_SEED_IMD ?? "0.1");
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
export const dailyQuestion = (pair: string, day: Date, target: number) =>
  `Was the Coinbase ${pair} daily close on ${day.getUTCDate()} ${MONTHS[day.getUTCMonth()]} ${day.getUTCFullYear()} (UTC) above ${Math.round(target).toLocaleString("en-US")} US dollars?`;
const dailyPrefix = (pair: string, day: Date) => `Was the Coinbase ${pair} daily close on ${day.getUTCDate()} ${MONTHS[day.getUTCMonth()]} ${day.getUTCFullYear()} (UTC)`;
const wagerAbi = parseAbi([
  "function count() view returns (uint256)",
  "function get(uint256 id) view returns ((address yes,address no,address creator,uint96 stake,uint96 fee,uint64 joinBy,uint64 resolveAfter,uint64 askedAt,uint8 state,bytes32 requestId,address winner) w, bytes body)",
  "function resolve(uint256 id)", "function settle(uint256 id)", "function cancel(uint256 id)", "function abandon(uint256 id)",
]);

type Act = { contract: "market" | "wager"; id: number; fn: string; tx?: Hex; skipped?: string };

export async function runKeeper(): Promise<Act[]> {
  const transport = http(process.env.ETH_RPC_URL);
  const pub = createPublicClient({ chain: mainnet, transport });
  const account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex);
  const wallet = createWalletClient({ account, chain: mainnet, transport });
  const now = BigInt(Math.floor(Date.now() / 1000));
  const acts: Act[] = [];

  // Simulate first: a revert (StillPending, TooEarly, WrongPhase) just means "not yet".
  async function tryCall(contract: "market" | "wager", address: Hex, abi: any, fn: string, id: bigint) {
    try {
      const { request } = await pub.simulateContract({ account, address, abi, functionName: fn, args: [id] });
      const tx = await wallet.writeContract(request);
      await pub.waitForTransactionReceipt({ hash: tx });
      acts.push({ contract, id: Number(id), fn, tx });
    } catch (e: any) {
      acts.push({ contract, id: Number(id), fn, skipped: e?.shortMessage?.slice(0, 80) ?? "reverted" });
    }
  }

  const M = process.env.MARKET_ADDRESS as Hex | undefined;
  if (M && DAILY.length) await ensureDaily(M);

  async function ensureDaily(M: Hex) {
    const d = new Date(), hour = d.getUTCHours();
    if (hour >= 18) return; // keep at least ~5h of betting per round
    const day = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
    const logs = await getLogsChunked(pub as any, { address: M, event: marketAbi.find((x: any) => x.name === "Opened") as any }, BigInt(process.env.MARKET_FROM_BLOCK ?? "26222300"));
    const qs = logs.map((l: any) => { try { return JSON.parse(hexToString(l.args.body)).question as string; } catch { return ""; } });
    for (const pair of DAILY) {
      if (qs.some((q) => q.startsWith(dailyPrefix(pair, day)))) continue;
      try {
        const t = await (await fetch(`https://api.exchange.coinbase.com/products/${pair}/ticker`, { headers: { "user-agent": "askswarm" }, signal: AbortSignal.timeout(8000) })).json();
        const price = Number(t.price); if (!Number.isFinite(price)) continue;
        const chk = await Promise.race([
          imd.check(dailyQuestion(pair, day, price), Number(process.env.IMD_PANEL_SIZE ?? 15)),
          new Promise<never>((_, rej) => setTimeout(() => rej(new Error("precheck timeout")), 20_000)),
        ]);
        if (!chk.request || chk.request.answerType !== "bool" || (chk.blockers ?? []).some((b) => !SOFT.has(b.code))) { acts.push({ contract: "market", id: 0, fn: `daily ${pair}`, skipped: "precheck" }); continue; }
        const closeAt = BigInt(day.getTime() / 1000 + 23 * 3600), after = BigInt(day.getTime() / 1000 + 24 * 3600 + 15 * 60);
        const send = async (r: any) => { const h = await wallet.writeContract({ account, ...r }); await pub.waitForTransactionReceipt({ hash: h }); return h; };
        await send({ address: IMD_TOKEN, abi: erc20Abi, functionName: "approve", args: [M, 500000000000000000n + 2n * SEED] });
        const h = await send({ address: M, abi: marketAbi, functionName: "open", args: [stringToHex(JSON.stringify(chk.request)), closeAt, after] });
        const rc = await pub.getTransactionReceipt({ hash: h });
        const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === M.toLowerCase())!.topics[1]!);
        if (SEED > 0n) { await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, true, SEED] }); await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, false, SEED] }); }
        acts.push({ contract: "market", id: Number(id), fn: `daily ${pair} > ${Math.round(price)}`, tx: h });
        await announceOpened(Number(id), chk.request.question, Number(closeAt), true);
      } catch (e: any) { acts.push({ contract: "market", id: 0, fn: `daily ${pair}`, skipped: String(e?.shortMessage ?? e?.message).slice(0, 80) }); }
    }
  }
  if (M) {
    const n = await pub.readContract({ address: M, abi: marketAbi, functionName: "count" });
    const win = await pub.readContract({ address: M, abi: marketAbi, functionName: "RESOLVE_WINDOW" });
    for (let i = 1n; i <= n; i++) {
      const [m] = await pub.readContract({ address: M, abi: marketAbi, functionName: "get", args: [i] });
      if (m.phase === 1) { // Open
        if (now >= m.resolveAfter && now <= m.resolveAfter + win) await tryCall("market", M, marketAbi, "resolve", i);
        else if (now > m.resolveAfter + win) await tryCall("market", M, marketAbi, "abandon", i);
      } else if (m.phase === 2) await tryCall("market", M, marketAbi, "settle", i); // Asked
      const done = acts[acts.length - 1];
      if (done && done.contract === "market" && done.id === Number(i) && done.tx && (done.fn === "settle" || done.fn === "abandon" || done.fn === "resolve")) {
        const [after, body] = await pub.readContract({ address: M, abi: marketAbi, functionName: "get", args: [i] });
        let q = ""; try { q = JSON.parse(hexToString(body)).question; } catch {}
        const yes = Number(after.yesPool) / 1e18, no = Number(after.noPool) / 1e18;
        if (after.phase === 3 || after.phase === 4) await announceSettled(Number(i), q, after.phase === 3 ? "yes" : "no", `Pool ${(yes + no).toFixed(2)} IMD.`);
        else if (after.phase === 5) await announceSettled(Number(i), q, "void", yes === 0 || no === 0 ? "only one side bet" : "the swarm did not reach a verdict");
      }
    }
  }
  const W = process.env.WAGER_ADDRESS as Hex | undefined;
  if (W) {
    const n = await pub.readContract({ address: W, abi: wagerAbi, functionName: "count" });
    for (let i = 1n; i <= n; i++) {
      const [w] = await pub.readContract({ address: W, abi: wagerAbi, functionName: "get", args: [i] });
      if (w.state === 1 && now > w.joinBy) await tryCall("wager", W, wagerAbi, "cancel", i); // Open, nobody joined
      else if (w.state === 2 && now >= w.resolveAfter) await tryCall("wager", W, wagerAbi, "resolve", i); // Matched
      else if (w.state === 3) await tryCall("wager", W, wagerAbi, "settle", i); // Asked
    }
  }
  return acts.filter((a) => a.tx || !/StillPending|TooEarly/.test(a.skipped ?? ""));
}

export async function GET(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) return new Response("unauthorized", { status: 401 });
  try {
    return new Response(JSON.stringify({ acts: await runKeeper() }), { headers: { "content-type": "application/json" } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: String(e?.message ?? e) }), { status: 502, headers: { "content-type": "application/json" } });
  }
}
