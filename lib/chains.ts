// One place for everything chain-specific. AskSwarm runs on Ethereum mainnet and Robinhood Chain;
// ACTIVE_CHAIN_ID picks where new activity goes (bot asks, daily rounds, new markets), and every read
// path covers both so history on either chain stays visible.
import { defineChain, type Chain, type Hex } from "viem";
import { mainnet } from "viem/chains";

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

export type ChainCfg = {
  id: 1 | 4663;
  name: string;
  short: string;
  viem: Chain;
  rpc: string;
  logsRpcs: string[];
  logStep: bigint;
  explorer: string;
  imd: Hex;
  registries: Hex[]; // first = current, rest = older deployments still read
  market?: Hex;
  wager?: Hex;
  fromBlock: bigint;
};

const list = (s?: string) => (s ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean) as Hex[];
const env = process.env;

export const CHAINS: Record<number, ChainCfg> = {
  1: {
    id: 1, name: "Ethereum", short: "ETH", viem: mainnet,
    rpc: env.ETH_RPC_URL ?? "https://ethereum-rpc.publicnode.com",
    logsRpcs: list(env.LOGS_RPC_URLS ?? "https://gateway.tenderly.co/public/mainnet,https://rpc.flashbots.net,https://rpc.mevblocker.io"),
    logStep: 5000n, explorer: "https://etherscan.io",
    imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
    registries: list(env.REGISTRY_ADDRESSES ?? env.REGISTRY_ADDRESS),
    market: (env.MARKET_ADDRESS?.toLowerCase() || undefined) as Hex | undefined,
    wager: (env.WAGER_ADDRESS?.toLowerCase() || undefined) as Hex | undefined,
    fromBlock: BigInt(env.ETH_FROM_BLOCK ?? "26213400"),
  },
  4663: {
    id: 4663, name: "Robinhood Chain", short: "RH", viem: robinhood,
    rpc: env.RH_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com",
    logsRpcs: list(env.RH_LOGS_RPC_URLS ?? env.RH_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com"),
    logStep: 2_000_000n, explorer: "https://robinhoodchain.blockscout.com",
    imd: "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127",
    registries: list(env.RH_REGISTRY_ADDRESSES ?? env.RH_REGISTRY_ADDRESS),
    market: (env.RH_MARKET_ADDRESS?.toLowerCase() || undefined) as Hex | undefined,
    wager: (env.RH_WAGER_ADDRESS?.toLowerCase() || undefined) as Hex | undefined,
    fromBlock: BigInt(env.RH_FROM_BLOCK ?? "92500000"),
  },
};

/** Where new activity goes. Falls back to Ethereum until the Robinhood registry is configured. */
const want = CHAINS[Number(env.ACTIVE_CHAIN_ID ?? 1)];
export const ACTIVE: ChainCfg = want?.registries.length ? want : CHAINS[1];
export const chainList = () => Object.values(CHAINS);
export const txUrl = (chainId: number, tx: string) => `${CHAINS[chainId]?.explorer ?? "https://etherscan.io"}/tx/${tx}`;
export const addrUrl = (chainId: number, a: string) => `${CHAINS[chainId]?.explorer ?? "https://etherscan.io"}/address/${a}`;
/** Public, browser-safe summary for pages: addresses, explorers, RPCs. */
export const publicChains = () => chainList().map((c) => ({ id: c.id, name: c.name, short: c.short, rpc: c.id === 1 ? "https://ethereum-rpc.publicnode.com" : c.rpc, explorer: c.explorer, imd: c.imd, registry: c.registries[0] ?? null, registries: c.registries, market: c.market ?? null, wager: c.wager ?? null }));
