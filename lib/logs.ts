// Historical event scans per chain, in chunks the chain's RPCs accept (Ethereum: 5k blocks through
// archive-capable free RPCs; Robinhood Chain: 100k blocks on its own RPC), with fallback.
// ponytail: sequential chunks; index into KV if a chain's range grows past a few hundred calls.
import { createPublicClient, fallback, http, parseEventLogs, type PublicClient } from "viem";
import type { ChainCfg } from "./chains";

const clients = new Map<number, PublicClient>();
export const logsClient = (c: ChainCfg) => {
  if (!clients.has(c.id)) clients.set(c.id, createPublicClient({ chain: c.viem, transport: fallback(c.logsRpcs.map((u) => http(u, { timeout: 20_000 }))) }) as PublicClient);
  return clients.get(c.id)!;
};

export async function getLogsChunked(c: ChainCfg, args: any, fromBlock = c.fromBlock) {
  const pub = logsClient(c);
  const toBlock = await pub.getBlockNumber();
  const addrs: any[] = Array.isArray(args.address) ? args.address : [args.address];
  const abi = args.events ?? (args.event ? [args.event] : null);
  const local = !!(c.addrStep && abi); // address-only fetch, events decoded here (same shape as viem's)
  const step = local ? c.addrStep! : c.logStep;
  const out: any[] = [];
  for (const address of addrs) {
    for (let a = fromBlock; a <= toBlock; a += step) {
      const b = a + step - 1n > toBlock ? toBlock : a + step - 1n;
      out.push(...(local
        ? parseEventLogs({ abi, logs: await pub.getLogs({ address, fromBlock: a, toBlock: b }), strict: false })
        : await pub.getLogs({ ...args, address, fromBlock: a, toBlock: b })));
    }
  }
  return out.sort((x, y) => (x.blockNumber === y.blockNumber ? (x.logIndex ?? 0) - (y.logIndex ?? 0) : x.blockNumber < y.blockNumber ? -1 : 1));
}

export const getBlockTs = async (c: ChainCfg, blockNumber: bigint) => Number((await logsClient(c).getBlock({ blockNumber })).timestamp);
