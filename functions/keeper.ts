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
import { chainList, ACTIVE, type ChainCfg, transportFor } from "../lib/chains";
import { subsEnabled, subscribers } from "../lib/subs";

export const maxDuration = 300;
const marketAbi = parseAbi([
  "function count() view returns (uint256)",
  "function RESOLVE_WINDOW() view returns (uint64)",
  "function get(uint256 id) view returns ((address creator,uint64 closeAt,uint64 resolveAfter,uint64 askedAt,uint8 phase,uint96 feeEscrow,uint128 yesPool,uint128 noPool,uint128 winnersShare,bytes32 requestId) m, bytes body)",
  "function resolve(uint256 id)", "function settle(uint256 id)", "function abandon(uint256 id)", "function claim(uint256 id) returns (uint256)", "function claimable(uint256 id, address user) view returns (uint256)",
  "function open(bytes body, uint64 closeAt, uint64 resolveAfter) returns (uint256)",
  "function stake(uint256 id, bool yes, uint128 amount)",
  "event Opened(uint256 indexed id, address indexed creator, uint64 closeAt, uint64 resolveAfter, bytes body)",
]);
// Daily "up or down" rounds, like HIP-4's daily markets: target = the Coinbase spot price when the round
// opens, settled by the swarm on that day's close. The house seeds both sides so every round is live.
// One round a day keeps the swarm fee at 0.5 IMD/day; DAILY_PAIRS=ETH-USD,BTC-USD adds BTC back.
const DAILY = (process.env.DAILY_PAIRS ?? "ETH-USD").split(",").map((s) => s.trim()).filter(Boolean);
// Precheck codes that do not mean "bad question": the future (asked after the close) and IMD's own
// infra being briefly down (the onchain request is recorded and answered when it recovers).
const SOFT = new Set(["not_answerable", "chain_unavailable"]);
// Just enough on each side that the round shows odds and isn't one-sided (which refunds everyone).
const SEED = parseEther(process.env.DAILY_SEED_IMD ?? "0.01");
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
// IMD's intake refuses Coinbase-price wording as "not answerable from public sources" even for past
// days (both 19 Oct rounds voided that way); it accepts a CoinMarketCap historical close named with
// asset and ticker, e.g. "Bitcoin (BTC)" (plain "Bitcoin" was refused). Tested on 20 Oct 2026.
const ASSET: Record<string, string> = { "ETH-USD": "Ethereum (ETH)", "BTC-USD": "Bitcoin (BTC)" };
const dayText = (day: Date) => `${day.getUTCDate()} ${MONTHS[day.getUTCMonth()]} ${day.getUTCFullYear()}`;
export const dailyQuestion = (pair: string, day: Date, target: number) =>
  `Was the closing price of ${ASSET[pair] ?? pair} on ${dayText(day)}, as listed on CoinMarketCap historical data, above ${Math.round(target).toLocaleString("en-US")} US dollars?`;
const dailyPrefix = (pair: string, day: Date) => `Was the closing price of ${ASSET[pair] ?? pair} on ${dayText(day)},`;
const wagerAbi = parseAbi([
  "function count() view returns (uint256)",
  "function get(uint256 id) view returns ((address yes,address no,address creator,uint96 stake,uint96 fee,uint64 joinBy,uint64 resolveAfter,uint64 askedAt,uint8 state,bytes32 requestId,address winner) w, bytes body)",
  "function resolve(uint256 id)", "function settle(uint256 id)", "function cancel(uint256 id)", "function abandon(uint256 id)",
]);

type Act = { chainId?: number; contract: "market" | "wager"; id: number; fn: string; tx?: Hex; skipped?: string };

// Every chain with contracts gets resolved and settled; daily rounds open only on the active chain.
export async function runKeeper(): Promise<Act[]> {
  const out: Act[] = [];
  // The active chain first: a slow history-only chain must not eat the run's time before it.
  for (const c of chainList().filter((c) => c.market || c.wager).sort((a, b) => Number(b.id === ACTIVE.id) - Number(a.id === ACTIVE.id))) {
    try { out.push(...(await runChain(c)).map((a) => ({ chainId: c.id, ...a }))); }
    catch (e: any) { out.push({ chainId: c.id, contract: "market", id: 0, fn: "chain", skipped: String(e?.shortMessage ?? e?.message).slice(0, 80) }); }
  }
  return out;
}

async function runChain(c: ChainCfg): Promise<Act[]> {
  const transport = transportFor(c);
  const pub = createPublicClient({ chain: c.viem, transport });
  const account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex);
  const wallet = createWalletClient({ account, chain: c.viem, transport });
  const IMD_TOKEN = c.imd;
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

  const M = c.market;

  async function ensureDaily(M: Hex) {
    const d = new Date(), hour = d.getUTCHours();
    if (hour >= 18) return; // keep at least ~5h of betting per round
    const day = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
    const logs = await getLogsChunked(c, { address: M, event: marketAbi.find((x: any) => x.name === "Opened") as any }, c.id === 1 ? BigInt(process.env.MARKET_FROM_BLOCK ?? "26222300") : c.fromBlock);
    // Only the house's own rounds count: anyone can open a market with the same question shape.
    const mine = logs.filter((l: any) => String(l.args.creator).toLowerCase() === account.address.toLowerCase());
    const bodies = mine.map((l: any) => { try { return JSON.parse(hexToString(l.args.body)); } catch { return {}; } });
    const send = async (r: any) => { const h = await wallet.writeContract({ account, ...r }); await pub.waitForTransactionReceipt({ hash: h }); return h; };
    const imdOf = (a: Hex) => pub.readContract({ address: IMD_TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [a] });
    for (const pair of DAILY) {
      const k = bodies.findIndex((x: any) => typeof x.question === "string" && x.question.startsWith(dailyPrefix(pair, day)));
      if (k >= 0) {
        // Opened earlier but the seeding failed part way: finish it, so the round is live and announced.
        const id = BigInt(mine[k].args.id);
        const [m] = await pub.readContract({ address: M, abi: marketAbi, functionName: "get", args: [id] });
        if (SEED > 0n && m.phase === 1 && m.yesPool === 0n && m.noPool === 0n && BigInt(Math.floor(Date.now() / 1000)) < m.closeAt && (await imdOf(account.address)) >= 2n * SEED) {
          try {
            await send({ address: IMD_TOKEN, abi: erc20Abi, functionName: "approve", args: [M, 2n * SEED] });
            await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, true, SEED] });
            const h = await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, false, SEED] });
            acts.push({ contract: "market", id: Number(id), fn: `daily ${pair} seeded`, tx: h });
            await announceOpened(Number(id), bodies[k].question, Number(m.closeAt), true, c.id);
          } catch (e: any) { acts.push({ contract: "market", id: Number(id), fn: `daily ${pair} seed`, skipped: String(e?.shortMessage ?? e?.message).slice(0, 80) }); }
        }
        continue;
      }
      try {
        // The market escrows the registry's current price; open only when the house can also seed both sides.
        const fee = c.registries[0] ? await pub.readContract({ address: c.registries[0], abi: parseAbi(["function price() view returns (uint256)"]), functionName: "price" }) : 500000000000000000n;
        if ((await imdOf(account.address)) < fee + 2n * SEED) { acts.push({ contract: "market", id: 0, fn: `daily ${pair}`, skipped: "house IMD too low" }); continue; }
        const t = await (await fetch(`https://api.exchange.coinbase.com/products/${pair}/ticker`, { headers: { "user-agent": "askswarm" }, signal: AbortSignal.timeout(8000) })).json();
        const price = Number(t.price); if (!Number.isFinite(price)) continue;
        const question = dailyQuestion(pair, day, price);
        let chk: Awaited<ReturnType<typeof imd.check>>;
        try {
          chk = await Promise.race([
            imd.check(question, Number(process.env.IMD_PANEL_SIZE ?? 15), c.id),
            new Promise<never>((_, rej) => setTimeout(() => rej(new Error("precheck timeout")), 20_000)),
          ]);
        } catch {
          // IMD's precheck unreachable (not a rejection): reuse the last accepted body for this pair, which
          // differs from today's only in the question, so the day still gets its round.
          const prev = [...bodies].reverse().find((x: any) => typeof x.question === "string" && x.question.startsWith(`Was the closing price of ${ASSET[pair] ?? pair} on`));
          if (!prev) throw new Error("precheck unreachable, no template");
          chk = { request: { ...prev, question }, blockers: [] } as any;
        }
        if (!chk.request || chk.request.answerType !== "bool" || (chk.blockers ?? []).some((b) => !SOFT.has(b.code))) { acts.push({ contract: "market", id: 0, fn: `daily ${pair}`, skipped: "precheck" }); continue; }
        const closeAt = BigInt(day.getTime() / 1000 + 23 * 3600), after = BigInt(day.getTime() / 1000 + 26 * 3600); // 02:00 UTC next day: CoinMarketCap has the close by then
        await send({ address: IMD_TOKEN, abi: erc20Abi, functionName: "approve", args: [M, fee + 2n * SEED] });
        const h = await send({ address: M, abi: marketAbi, functionName: "open", args: [stringToHex(JSON.stringify(chk.request)), closeAt, after] });
        const rc = await pub.getTransactionReceipt({ hash: h });
        const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === M.toLowerCase())!.topics[1]!);
        if (SEED > 0n) { await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, true, SEED] }); await send({ address: M, abi: marketAbi, functionName: "stake", args: [id, false, SEED] }); }
        acts.push({ contract: "market", id: Number(id), fn: `daily ${pair} > ${Math.round(price)}`, tx: h });
        await announceOpened(Number(id), chk.request.question, Number(closeAt), true, c.id);
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
      else if (m.phase >= 3) { // Settled or void: collect the house's seed stakes and winnings, so they fund the next rounds
        const owed = await pub.readContract({ address: M, abi: marketAbi, functionName: "claimable", args: [i, account.address] }).catch(() => 0n);
        if (owed > 0n) await tryCall("market", M, marketAbi, "claim", i);
      }
      const done = acts[acts.length - 1];
      if (done && done.contract === "market" && done.id === Number(i) && done.tx && (done.fn === "settle" || done.fn === "abandon" || done.fn === "resolve")) {
        const [after, body] = await pub.readContract({ address: M, abi: marketAbi, functionName: "get", args: [i] });
        let q = ""; try { q = JSON.parse(hexToString(body)).question; } catch {}
        const yes = Number(after.yesPool) / 1e18, no = Number(after.noPool) / 1e18;
        if (after.phase === 3 || after.phase === 4) await announceSettled(Number(i), q, after.phase === 3 ? "yes" : "no", `Pool ${(yes + no).toFixed(2)} IMD.`, c.id);
        else if (after.phase === 5) await announceSettled(Number(i), q, "void", yes === 0 || no === 0 ? "only one side bet" : "the swarm did not reach a verdict", c.id);
      }
    }
  }
  const W = c.wager;
  if (W) {
    const n = await pub.readContract({ address: W, abi: wagerAbi, functionName: "count" });
    for (let i = 1n; i <= n; i++) {
      const [w] = await pub.readContract({ address: W, abi: wagerAbi, functionName: "get", args: [i] });
      if (w.state === 1 && now > w.joinBy) await tryCall("wager", W, wagerAbi, "cancel", i); // Open, nobody joined
      else if (w.state === 2 && now > w.resolveAfter + 3n * 86400n) await tryCall("wager", W, wagerAbi, "abandon", i); // Matched, never answered: refund both
      else if (w.state === 2 && now >= w.resolveAfter) await tryCall("wager", W, wagerAbi, "resolve", i); // Matched
      else if (w.state === 3) await tryCall("wager", W, wagerAbi, "settle", i); // Asked
    }
  }
  // Daily rounds last, isolated: a failed history scan or open must not hold up resolves and settles.
  if (M && DAILY.length && c.id === ACTIVE.id) {
    try { await ensureDaily(M); } catch (e: any) { acts.push({ contract: "market", id: 0, fn: "daily", skipped: String(e?.shortMessage ?? e?.message).slice(0, 80) }); }
  }
  return acts.filter((a) => a.tx || !/StillPending|TooEarly/.test(a.skipped ?? ""));
}

export async function GET(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) return new Response("unauthorized", { status: 401 });
  try {
    const acts = await runKeeper();
    const subs = subsEnabled ? (await subscribers().catch(() => null))?.length ?? null : "off"; // who market news reaches
    return new Response(JSON.stringify({ acts, subs }), { headers: { "content-type": "application/json" } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: String(e?.message ?? e) }), { status: 502, headers: { "content-type": "application/json" } });
  }
}
