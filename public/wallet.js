// One wallet entry point for every page: getWallet(C) returns { w, account, kind } ready for viem.
//
//  1. A browser wallet (extension or a wallet app's own browser): used directly.
//  2. AskSwarm wallet: a key made on first use and kept in Telegram's SecureStorage (Keychain /
//     Keystore) inside the Mini App, else Telegram CloudStorage, else this browser. One-tap bets, no
//     app switching. The house sends a little gas (and a small starter while it lasts) through
//     /api/wallet, which only answers Telegram-signed requests. For small amounts: it is a hot key.
//  3. WalletConnect: QR on desktop, the wallet app on a phone. Inside Telegram the wallet is opened
//     with Telegram.WebApp.openLink and an https universal link, since Telegram blocks the custom
//     schemes WalletConnect's own picker uses. Chain is set on the session, not asked of the wallet
//     (MetaMask Mobile ignores wallet_switchEthereumChain over WalletConnect).
import { createWalletClient, createPublicClient, custom, http, erc20Abi, formatEther, parseEther, isAddress } from "https://esm.sh/viem@2.57.7";
import { privateKeyToAccount, generatePrivateKey } from "https://esm.sh/viem@2.57.7/accounts";
import { viemChain, switchTo, addr as addrLink } from "/chain.js";

// Chromia's Reown project (shared with Chromia Pay). Not a secret; swap for AskSwarm's own when registered.
const WC_PROJECT_ID = "70e9c33528a1e905ab36488c8281098f";
const KEY = "askswarm_wallet_v1", CHOICE = "askswarm_wallet_choice";
const tg = window.Telegram && Telegram.WebApp && Telegram.WebApp.initData ? Telegram.WebApp : null;
export const inTelegram = !!tg;

const css = `.sw-sheet{position:fixed;inset:auto 0 0 0;z-index:80;background:var(--card,#2a2430);color:var(--ink,#F5EEEE);border-top:2px solid var(--ink,#1F1A23);border-radius:22px 22px 0 0;padding:18px 16px calc(18px + env(safe-area-inset-bottom));box-shadow:0 -10px 40px rgba(0,0,0,.35);max-height:85vh;overflow:auto}
.sw-sheet h3{margin:0 0 4px;font-size:19px}.sw-sheet p{margin:4px 0 12px;font-size:14px;opacity:.8;line-height:1.45}
.sw-sheet .opt{display:block;width:100%;text-align:left;margin:0 0 10px;padding:13px 14px;border:2px solid var(--ink,#1F1A23);border-radius:16px;background:var(--bg,#1F1A23);color:inherit;font:inherit;cursor:pointer}
.sw-sheet .opt b{display:block;font-size:16px}.sw-sheet .opt span{font-size:13px;opacity:.75}
.sw-sheet .opt.rec{background:#CCFF00;color:#1F1A23}.sw-sheet .row{display:flex;gap:8px;flex-wrap:wrap}
.sw-sheet .row button,.sw-sheet .x{padding:10px 14px;border-radius:999px;border:2px solid var(--ink,#1F1A23);background:#CC91F0;color:#1F1A23;font:700 14px inherit;cursor:pointer}
.sw-sheet .x{background:transparent;color:inherit;margin-top:6px}.sw-sheet code{word-break:break-all;font-size:13px}
.sw-sheet input{width:100%;box-sizing:border-box;padding:11px 12px;border-radius:12px;border:2px solid var(--ink,#1F1A23);font:inherit;margin:6px 0 10px;background:var(--bg,#fff);color:inherit}
.sw-bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:13px;margin:0 0 12px;padding:9px 12px;border:2px dashed color-mix(in srgb,currentColor 30%,transparent);border-radius:14px}
.sw-bar b{font-size:14px}.sw-bar button{padding:5px 11px;border-radius:999px;border:2px solid currentColor;background:transparent;color:inherit;font:700 12px inherit;cursor:pointer}`;
{ const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st); }

const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const remember = (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} };
const recall = (k) => { try { return localStorage.getItem(k); } catch { return null; } };

function sheet(html) {
  document.querySelector(".sw-sheet")?.remove();
  const el = document.createElement("div"); el.className = "sw-sheet"; el.innerHTML = html;
  document.body.appendChild(el);
  return el;
}
const closeSheet = () => document.querySelector(".sw-sheet")?.remove();

// ---- key storage: Telegram SecureStorage → CloudStorage → this browser ----
// Older Telegram clients (and plain browsers that load telegram-web-app.js) never call back: time out.
const within = (p, ms, fallback) => Promise.race([p, new Promise((r) => setTimeout(() => r(fallback), ms))]);
// null = empty (or unsupported, which throws at once); undefined = no answer in time.
const tgGet = (api, k) => within(new Promise((res) => { try { api.getItem(k, (err, v) => res(err ? null : v || null)); } catch { res(null); } }), 2500, undefined);
const tgSet = (api, k, v) => within(new Promise((res) => { try { api.setItem(k, v, (err, ok) => res(!err && ok !== false)); } catch { res(false); } }), 2500, false);
async function loadKey() {
  let silent = false;
  if (tg?.SecureStorage) { const v = await tgGet(tg.SecureStorage, KEY); if (v) return { pk: v, where: "Telegram secure storage on this phone" }; silent ||= v === undefined; }
  if (tg?.CloudStorage) { const v = await tgGet(tg.CloudStorage, KEY); if (v) return { pk: v, where: "Telegram cloud storage" }; silent ||= v === undefined; }
  const v = recall(KEY); if (v) return { pk: v, where: "this browser" };
  // Never mint a new key while Telegram has not said "empty": that could overwrite a funded one.
  if (silent) throw new Error("Telegram storage did not answer. Close and reopen the app, then try again.");
  return null;
}
async function saveKey(pk) {
  if (tg?.SecureStorage && (await tgSet(tg.SecureStorage, KEY, pk)) && (await tgGet(tg.SecureStorage, KEY)) === pk) return "Telegram secure storage on this phone";
  if (tg?.CloudStorage && (await tgSet(tg.CloudStorage, KEY, pk)) && (await tgGet(tg.CloudStorage, KEY)) === pk) return "Telegram cloud storage";
  // ponytail: last resort is this webview's localStorage, which Telegram may clear; the UI says so.
  remember(KEY, pk); if (recall(KEY) !== pk) throw new Error("Could not store a wallet key on this device.");
  return "this browser";
}
export async function hasEmbedded() { try { return !!(await loadKey()); } catch { return false; } }

// ---- the three kinds ----
let session = null; // { kind, w, account, provider?, walletLink? }

async function injected(C) {
  const w = createWalletClient({ chain: viemChain(C), transport: custom(window.ethereum) });
  const [account] = await w.requestAddresses();
  await switchTo(w, C);
  return { kind: "browser", w, account };
}

async function embedded(C, { create = true } = {}) {
  let k = await loadKey();
  if (!k) { if (!create) return null; const pk = generatePrivateKey(); k = { pk, where: await saveKey(pk) }; }
  const acct = privateKeyToAccount(k.pk);
  const w = createWalletClient({ account: acct, chain: viemChain(C), transport: http(C.rpc) });
  return { kind: "askswarm", w, account: acct.address, where: k.where };
}

// Gas (and a starter while the house has spare IMD) for an AskSwarm wallet, from inside Telegram.
export async function ensureGas(C, account, log = () => {}) {
  const pub = createPublicClient({ chain: viemChain(C), transport: http(C.rpc) });
  if ((await pub.getBalance({ address: account })) >= parseEther("0.00002")) return null;
  if (!tg) throw new Error("This wallet needs a little ETH on " + C.name + " for gas. Send some to " + account + ".");
  log("Getting gas for your wallet…");
  const r = await fetch("/api/wallet", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ initData: tg.initData, address: account }) }).then((x) => x.json()).catch(() => ({ error: "network" }));
  if (r.error) throw new Error(r.error === "slow_down" ? "Wait a few seconds and try again." : "Could not fund gas (" + r.error + ").");
  if (r.starter) log(`Welcome: ${r.starter} IMD starter added to your wallet.`, "ok");
  return r;
}

// Universal links that take a wc: URI at /wc?uri= (the format WalletConnect's own registry lists).
const WC_WALLETS = [["MetaMask", "https://metamask.app.link"], ["Trust Wallet", "https://link.trustwallet.com"], ["Rainbow", "https://rnbwapp.com"]];
async function walletConnect(C) {
  const { EthereumProvider } = await import("https://esm.sh/@walletconnect/ethereum-provider@2.23.10");
  const provider = await EthereumProvider.init({
    projectId: WC_PROJECT_ID, optionalChains: [C.id, ...(C.id === 1 ? [] : [1])], showQrModal: !tg,
    rpcMap: { [C.id]: C.rpc, 1: "https://ethereum-rpc.publicnode.com" },
    metadata: { name: "AskSwarm", description: "Bet IMD on yes/no questions the IMD swarm settles", url: location.origin, icons: [location.origin + "/logo.svg"] },
  });
  let walletLink = null;
  if (tg) {
    // Pairing URI first, then a tap opens the wallet through Telegram (a gesture is required).
    const connecting = provider.connect();
    const uri = await new Promise((res, rej) => { provider.on("display_uri", res); connecting.catch(rej); });
    const el = sheet(`<h3>Open your wallet</h3><p>Approve the connection in your wallet app, then come back to Telegram. Your wallet needs ${esc(C.name)} support.</p>
      <div class="row">${WC_WALLETS.map(([n], i) => `<button data-i="${i}">${n}</button>`).join("")}<button data-copy>Copy link</button></div><button class="x">Cancel</button>`);
    el.querySelectorAll("[data-i]").forEach((b) => (b.onclick = () => { walletLink = WC_WALLETS[b.dataset.i][1]; tg.openLink(walletLink + "/wc?uri=" + encodeURIComponent(uri)); }));
    el.querySelector("[data-copy]").onclick = (e) => { navigator.clipboard?.writeText(uri); e.target.textContent = "Copied"; };
    const cancelled = new Promise((_, rej) => { el.querySelector(".x").onclick = () => rej(new Error("Cancelled.")); });
    try { await Promise.race([connecting, cancelled]); } finally { closeSheet(); }
  } else {
    await provider.connect();
  }
  const approved = (provider.session?.namespaces?.eip155?.chains || []).map((c) => Number(c.split(":")[1]));
  if (approved.length && !approved.includes(C.id)) { await provider.disconnect().catch(() => {}); throw new Error(`Your wallet did not approve ${C.name}. Use the AskSwarm wallet, or a wallet with ${C.name} support.`); }
  provider.chainId = C.id;
  const account = provider.accounts[0];
  // In Telegram, every signing request needs the user to switch to the wallet app: offer the tap.
  const raw = provider.request.bind(provider);
  provider.request = async (args) => {
    const signing = /^(eth_sendTransaction|personal_sign|eth_signTypedData)/.test(args?.method || "");
    if (signing && tg && walletLink) { const el = sheet(`<h3>Confirm in your wallet</h3><p>The request is waiting in your wallet app.</p><div class="row"><button data-open>Open wallet</button></div>`); el.querySelector("[data-open]").onclick = () => tg.openLink(walletLink); }
    try { return await raw(args); } finally { if (signing && tg) closeSheet(); }
  };
  const w = createWalletClient({ account, chain: viemChain(C), transport: custom(provider) });
  return { kind: "walletconnect", w, account, provider, walletLink };
}

function deepLinks() {
  const here = location.href, host = location.host + location.pathname + location.search;
  return [["MetaMask", `https://metamask.app.link/dapp/${host}`], ["Trust Wallet", `https://link.trustwallet.com/open_url?coin_id=60&url=${encodeURIComponent(here)}`], ["Coinbase Wallet", `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(here)}`]];
}

/** Ask which wallet to use. Resolves "askswarm" | "walletconnect"; deep links leave the page. */
function pick(C) {
  return new Promise((res, rej) => {
    const el = sheet(`<h3>Choose a wallet</h3><p>Bets are in IMD on ${esc(C.name)}.</p>
      <button class="opt rec" data-k="askswarm"><b>AskSwarm wallet${tg ? " · recommended" : ""}</b><span>${tg ? "Kept in Telegram on this phone. Bet in one tap; deposit IMD to play. We cover gas." : "Kept in this browser. Bet in one tap; deposit IMD and a little ETH to play."}</span></button>
      <button class="opt" data-k="walletconnect"><b>Connect your wallet</b><span>MetaMask, Trust, Rainbow and more via WalletConnect${tg ? "" : ": QR code or wallet app"}.</span></button>
      <div class="row">${deepLinks().map(([n, u]) => `<button data-u="${esc(u)}">Open in ${n}</button>`).join("")}</div>
      <button class="x">Cancel</button>`);
    el.querySelectorAll("[data-k]").forEach((b) => (b.onclick = () => { closeSheet(); res(b.dataset.k); }));
    el.querySelectorAll("[data-u]").forEach((b) => (b.onclick = () => (tg ? tg.openLink(b.dataset.u) : (location.href = b.dataset.u))));
    el.querySelector(".x").onclick = () => { closeSheet(); rej(new Error("No wallet chosen.")); };
  });
}

/** The wallet for this page's chain C. Prompts once, then remembers the choice. */
export async function getWallet(C, { log = () => {} } = {}) {
  if (session && session.chainId === C.id) return session;
  let s;
  if (window.ethereum) s = await injected(C);
  else {
    let choice = recall(CHOICE);
    if (!choice) choice = (await hasEmbedded()) ? "askswarm" : await pick(C);
    s = choice === "walletconnect" ? await walletConnect(C) : await embedded(C);
    remember(CHOICE, s.kind);
  }
  if (s.kind === "askswarm") await ensureGas(C, s.account, log);
  session = { ...s, chainId: C.id };
  window.dispatchEvent(new CustomEvent("askswarm:wallet", { detail: session }));
  return session;
}

/** Forget the remembered choice (and a WalletConnect session); the AskSwarm wallet key stays. */
export async function switchWallet() { remember(CHOICE, null); await session?.provider?.disconnect?.().catch(() => {}); session = null; }

// ---- AskSwarm wallet bar: balance, deposit, withdraw, export ----
export async function walletBar(el, C) {
  if (!el || window.ethereum) return;
  const s = session?.kind === "askswarm" ? session : (recall(CHOICE) !== "walletconnect" ? await embedded(C, { create: false }) : null);
  if (!s) { el.innerHTML = ""; return; }
  const pub = createPublicClient({ chain: viemChain(C), transport: http(C.rpc) });
  const [eth, imd] = await Promise.all([pub.getBalance({ address: s.account }), pub.readContract({ address: C.imd, abi: erc20Abi, functionName: "balanceOf", args: [s.account] })]).catch(() => [0n, 0n]);
  const n = (v, d) => Number(formatEther(v)).toLocaleString(undefined, { maximumFractionDigits: d });
  el.className = "sw-bar";
  el.innerHTML = `<span>AskSwarm wallet <a href="${addrLink(C, s.account)}" target="_blank" rel="noopener">${short(s.account)}</a></span><b>${n(imd, 3)} IMD</b><span style="opacity:.7">${n(eth, 5)} ETH gas</span>
    <button data-a="deposit">Deposit</button><button data-a="withdraw">Withdraw</button><button data-a="more">⋯</button>`;
  el.querySelector('[data-a="deposit"]').onclick = () => deposit(C, s.account);
  el.querySelector('[data-a="withdraw"]').onclick = () => withdraw(C, el);
  el.querySelector('[data-a="more"]').onclick = () => more(C, el);
}

export function openDeposit(C, account) { deposit(C, account); }
function deposit(C, account) {
  const el = sheet(`<h3>Deposit IMD</h3><p>Send IMD on <b>${esc(C.name)}</b> to your AskSwarm wallet. Only ${esc(C.name)} IMD (<code>${short(C.imd)}</code>) works here; IMD on Ethereum must be bridged first.</p>
    <code>${account}</code><div id="sw-qr" style="margin:12px 0"></div><div class="row"><button data-copy>Copy address</button></div><button class="x">Done</button>`);
  el.querySelector("[data-copy]").onclick = (e) => { navigator.clipboard?.writeText(account); e.target.textContent = "Copied"; tg?.HapticFeedback?.notificationOccurred("success"); };
  el.querySelector(".x").onclick = closeSheet;
  import("https://esm.sh/qrcode@1.5.4").then((q) => q.default.toDataURL(account, { margin: 1, width: 180 })).then((u) => { const q = el.querySelector("#sw-qr"); if (q) q.innerHTML = `<img src="${u}" width="180" height="180" alt="QR code of your wallet address" style="border-radius:12px">`; }).catch(() => {});
}

async function withdraw(C, bar) {
  const el = sheet(`<h3>Withdraw</h3><p>Sends all IMD, then the leftover gas, to an address on ${esc(C.name)}.</p><input id="sw-to" placeholder="0x… address on ${esc(C.name)}" autocomplete="off"><div class="row"><button data-go>Withdraw all</button></div><div id="sw-log" class="log"></div><button class="x">Cancel</button>`);
  el.querySelector(".x").onclick = closeSheet;
  el.querySelector("[data-go]").onclick = async (e) => {
    const to = el.querySelector("#sw-to").value.trim(), lg = el.querySelector("#sw-log");
    if (!isAddress(to)) { lg.textContent = "Enter a valid 0x address."; return; }
    e.target.disabled = true;
    try {
      const s = await embedded(C, { create: false }), pub = createPublicClient({ chain: viemChain(C), transport: http(C.rpc) });
      const imd = await pub.readContract({ address: C.imd, abi: erc20Abi, functionName: "balanceOf", args: [s.account] });
      if (imd > 0n) { lg.textContent = "Sending IMD…"; await pub.waitForTransactionReceipt({ hash: await s.w.writeContract({ address: C.imd, abi: erc20Abi, functionName: "transfer", args: [to, imd] }) }); }
      const bal = await pub.getBalance({ address: s.account }), gp = await pub.getGasPrice(), fee = 21000n * gp * 3n;
      if (bal > fee) { lg.textContent = "Sending ETH…"; await pub.waitForTransactionReceipt({ hash: await s.w.sendTransaction({ to, value: bal - fee, gas: 21000n, gasPrice: gp * 3n }) }); }
      lg.textContent = "Done."; walletBar(bar, C);
    } catch (err) { lg.textContent = err?.shortMessage || err?.message || String(err); e.target.disabled = false; }
  };
}

function more(C, bar) {
  const el = sheet(`<h3>AskSwarm wallet</h3><p>Your key is kept in ${tg?.SecureStorage ? "Telegram secure storage on this phone" : tg ? "Telegram cloud storage" : "this browser"}. Nobody else holds it, so if you lose this device without a backup, the funds are gone. Keep small amounts here.</p>
    <div class="row"><button data-x>Show private key</button><button data-s>Use another wallet</button></div><div id="sw-k" style="margin-top:10px"></div><button class="x">Close</button>`);
  el.querySelector(".x").onclick = closeSheet;
  el.querySelector("[data-x]").onclick = async () => { const k = await loadKey(); el.querySelector("#sw-k").innerHTML = k ? `<p>Anyone with this key controls the wallet. Import it into MetaMask or Rabby to move funds anywhere.</p><code>${k.pk}</code><div class="row" style="margin-top:8px"><button data-c>Copy key</button></div>` : "No key yet."; el.querySelector("[data-c]")?.addEventListener("click", (e) => { navigator.clipboard?.writeText(k.pk); e.target.textContent = "Copied"; }); };
  el.querySelector("[data-s]").onclick = async () => { await switchWallet(); closeSheet(); if (bar) bar.innerHTML = ""; };
}
