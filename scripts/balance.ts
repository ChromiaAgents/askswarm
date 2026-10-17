import { createPublicClient, http, formatEther, formatUnits, erc20Abi } from "viem";
import { mainnet } from "viem/chains";
const c = createPublicClient({ chain: mainnet, transport: http(process.env.ETH_RPC_URL) });
const me = "0x571E17B13D8F6492Bbc372A160520B20BfdA320c", IMD = "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7";
const [eth, imd, dec] = await Promise.all([c.getBalance({ address: me }), c.readContract({ address: IMD, abi: erc20Abi, functionName: "balanceOf", args: [me] }), c.readContract({ address: IMD, abi: erc20Abi, functionName: "decimals" })]);
console.log({ eth: formatEther(eth), imd: formatUnits(imd, dec) });
