// getLogs in block chunks: public RPCs cap the range per call (publicnode refuses ~10k+ blocks).
// ponytail: sequential 5k-block chunks; parallelize or index into KV if the range grows past ~100k.
import type { PublicClient } from "viem";

export async function getLogsChunked(pub: PublicClient, args: any, fromBlock: bigint, step = 5000n) {
  const toBlock = await pub.getBlockNumber();
  const out: any[] = [];
  for (let a = fromBlock; a <= toBlock; a += step) {
    const b = a + step - 1n > toBlock ? toBlock : a + step - 1n;
    out.push(...(await pub.getLogs({ ...args, fromBlock: a, toBlock: b })));
  }
  return out;
}
