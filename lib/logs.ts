// Historical event scans. publicnode now refuses blocks older than ~a day without a paid token, and
// most free RPCs cap getLogs ranges, so history goes through RPCs that serve archive logs for free,
// with fallback, in 5k-block chunks, one address per call.
// ponytail: sequential chunks; parallelize or index into KV if the range grows past ~100k blocks.
import { createPublicClient, fallback, http, type PublicClient } from "viem";
import { mainnet } from "viem/chains";

const URLS = (process.env.LOGS_RPC_URLS ?? "https://gateway.tenderly.co/public/mainnet,https://rpc.flashbots.net,https://rpc.mevblocker.io")
  .split(",").map((s) => s.trim()).filter(Boolean);
const logsClient = createPublicClient({ chain: mainnet, transport: fallback(URLS.map((u) => http(u, { timeout: 15_000 }))) });

export async function getLogsChunked(_pub: PublicClient | any, args: any, fromBlock: bigint, step = 5000n) {
  const toBlock = await logsClient.getBlockNumber();
  const addrs: any[] = Array.isArray(args.address) ? args.address : [args.address];
  const out: any[] = [];
  for (const address of addrs) {
    for (let a = fromBlock; a <= toBlock; a += step) {
      const b = a + step - 1n > toBlock ? toBlock : a + step - 1n;
      out.push(...(await logsClient.getLogs({ ...args, address, fromBlock: a, toBlock: b })));
    }
  }
  // Callers fold events in order; merge per-address results back into chain order.
  return out.sort((x, y) => (x.blockNumber === y.blockNumber ? (x.logIndex ?? 0) - (y.logIndex ?? 0) : x.blockNumber < y.blockNumber ? -1 : 1));
}

/** Block timestamps for charts, through the same archive-capable RPCs. */
export const getBlockTs = async (blockNumber: bigint) => Number((await logsClient.getBlock({ blockNumber })).timestamp);
