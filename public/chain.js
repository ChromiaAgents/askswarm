// Chain helpers shared by the pages. AskSwarm runs on Robinhood Chain (new activity) and Ethereum
// (earlier markets, wagers and answers stay readable). Chain data comes from the APIs' `chains` field.
import { defineChain, createPublicClient, http } from "https://esm.sh/viem@2.57.7";

export const FALLBACK = [
  { id: 4663, name: "Robinhood Chain", short: "RH", rpc: "https://rpc.mainnet.chain.robinhood.com", explorer: "https://robinhoodchain.blockscout.com", imd: "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127" },
  { id: 1, name: "Ethereum", short: "ETH", rpc: "https://ethereum-rpc.publicnode.com", explorer: "https://etherscan.io", imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", registry: "0x53e1e2f33f05086086adf618ca92c3cb0ab111cd" },
];
export const chainMap = (list) => Object.fromEntries([...FALLBACK, ...(list || [])].map((c) => [c.id, { ...FALLBACK.find((f) => f.id === c.id), ...c }]));

export const viemChain = (c) => defineChain({
  id: c.id, name: c.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [c.rpc] } }, blockExplorers: { default: { name: c.id === 1 ? "Etherscan" : "Blockscout", url: c.explorer } },
});
export const pubFor = (c) => createPublicClient({ chain: viemChain(c), transport: http(c.rpc) });

/** Switch the wallet to chain c, adding it first if the wallet has never seen it (Robinhood Chain). */
export async function switchTo(w, c) {
  if ((await w.getChainId()) === c.id) return;
  try { await w.switchChain({ id: c.id }); }
  catch (e) {
    if (e?.code === 4902 || /unrecognized|not added|unknown chain|4902/i.test(String(e?.message) + String(e?.details))) { await w.addChain({ chain: viemChain(c) }); await w.switchChain({ id: c.id }); }
    else throw e;
  }
}

export const tx = (c, h) => `${c.explorer}/tx/${h}`;
export const addr = (c, a) => `${c.explorer}/address/${a}`;
/** Small pill naming the chain; green for Robinhood Chain, grey for Ethereum. */
export const badge = (c, long = false) => `<span class="chainb ${c.id === 4663 ? "rh" : "eth"}">${long ? c.name : c.id === 4663 ? "Robinhood" : "Ethereum"}</span>`;
export const BADGE_CSS = `.chainb{display:inline-block;border-radius:999px;padding:1px 8px;font-size:11px;font-weight:700;vertical-align:middle;letter-spacing:.2px}
.chainb.rh{background:#CCFF00;color:#1F1A23;border:1.5px solid #1F1A23}.chainb.eth{background:#E6E3F0;color:#3B3550;border:1.5px solid #8C86A6}`;
const st = document.createElement("style"); st.textContent = BADGE_CSS; document.head.appendChild(st);
