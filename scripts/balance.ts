// ETH and IMD balances of the house wallet (and the demo wallet if DEMO_PK is set) on every chain.
import { createPublicClient, http, formatEther, erc20Abi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chainList } from "../lib/chains";
const who: Record<string, Hex> = { house: "0x571E17B13D8F6492Bbc372A160520B20BfdA320c" };
if (process.env.DEMO_PK) who.demo = privateKeyToAccount(process.env.DEMO_PK as Hex).address;
for (const ch of chainList()) {
  const c = createPublicClient({ chain: ch.viem, transport: http(ch.rpc) });
  for (const [k, a] of Object.entries(who)) {
    const [eth, imd] = await Promise.all([c.getBalance({ address: a }), c.readContract({ address: ch.imd, abi: erc20Abi, functionName: "balanceOf", args: [a] })]);
    console.log(`${ch.name.padEnd(16)} ${k.padEnd(6)} ${a}  ${Number(formatEther(eth)).toFixed(5)} ETH  ${Number(formatEther(imd)).toFixed(3)} IMD`);
  }
}
