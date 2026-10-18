// Keeper: Vercel cron every 10 minutes (vercel.json). SwarmMarket only accepts `resolve` within
// RESOLVE_WINDOW (1 hour) of a market's deadline, so somebody has to call it on time; this does,
// from the house wallet (gas only; the swarm fee comes from each market's own escrow). It also
// settles anything the swarm has answered and unwinds what can no longer resolve. Every call it
// makes is permissionless: anyone can run the same loop.
// ponytail: scans all ids each run; fine below a few hundred markets, index by events beyond that.
import { createPublicClient, createWalletClient, http, parseAbi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

export const maxDuration = 60;
const marketAbi = parseAbi([
  "function count() view returns (uint256)",
  "function RESOLVE_WINDOW() view returns (uint64)",
  "function get(uint256 id) view returns ((address creator,uint64 closeAt,uint64 resolveAfter,uint64 askedAt,uint8 phase,uint96 feeEscrow,uint128 yesPool,uint128 noPool,uint128 winnersShare,bytes32 requestId) m, bytes body)",
  "function resolve(uint256 id)", "function settle(uint256 id)", "function abandon(uint256 id)",
]);
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
  if (M) {
    const n = await pub.readContract({ address: M, abi: marketAbi, functionName: "count" });
    const win = await pub.readContract({ address: M, abi: marketAbi, functionName: "RESOLVE_WINDOW" });
    for (let i = 1n; i <= n; i++) {
      const [m] = await pub.readContract({ address: M, abi: marketAbi, functionName: "get", args: [i] });
      if (m.phase === 1) { // Open
        if (now >= m.resolveAfter && now <= m.resolveAfter + win) await tryCall("market", M, marketAbi, "resolve", i);
        else if (now > m.resolveAfter + win) await tryCall("market", M, marketAbi, "abandon", i);
      } else if (m.phase === 2) await tryCall("market", M, marketAbi, "settle", i); // Asked
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
