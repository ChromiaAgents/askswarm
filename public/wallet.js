// One wallet entry point for every page: getWallet(C) returns { w, account, kind } ready for viem.
//
//  1. A browser wallet (extension or a wallet app's own browser): used directly.
//  2. AskSwarm wallet: a key made on first use and kept in Telegram's SecureStorage (Keychain /
//     Keystore) inside the Mini App, else Telegram CloudStorage, else this browser. One-tap bets, no
//     app switching. The house sends a little gas (and a small starter while it lasts) through
//     /api/wallet, which only answers Telegram-signed requests. For small amounts: it is a hot key.
//  3. WalletConnect, the same modal and wallets as Chromia Pay's checkout: QR on desktop, the wallet
//     app on a phone. Inside Telegram, https wallet links go through Telegram.WebApp.openLink, since
//     the webview drops window.open. Chain is set on the session, not asked of the wallet
//     (MetaMask Mobile ignores wallet_switchEthereumChain over WalletConnect).
import { createWalletClient, createPublicClient, custom, http, erc20Abi, formatEther, parseEther, isAddress } from "https://esm.sh/viem@2.57.7";
import { privateKeyToAccount, generatePrivateKey } from "https://esm.sh/viem@2.57.7/accounts";
import { viemChain, switchTo, addr as addrLink } from "/chain.js";

// Chromia's Reown project (shared with Chromia Pay). Not a secret; swap for AskSwarm's own when registered.
const WC_PROJECT_ID = "70e9c33528a1e905ab36488c8281098f";
const KEY = "askswarm_wallet_v1", CHOICE = "askswarm_wallet_choice";
const tg = window.Telegram && Telegram.WebApp && Telegram.WebApp.initData ? Telegram.WebApp : null;
// Only the storage this Telegram version supports; otherwise the SDK throws "not supported".
const secure = tg?.isVersionAtLeast?.("9.0") ? tg.SecureStorage : null, cloud = tg?.isVersionAtLeast?.("6.9") ? tg.CloudStorage : null;
export const inTelegram = !!tg;

const css = `.sw-sheet{position:fixed;inset:auto 0 0 0;z-index:80;background:var(--card,#2a2430);color:var(--ink,#F5EEEE);border-top:2px solid var(--ink,#1F1A23);border-radius:22px 22px 0 0;padding:18px 16px calc(18px + env(safe-area-inset-bottom));box-shadow:0 -10px 40px rgba(0,0,0,.35);max-height:85vh;overflow:auto}
.sw-sheet h3{margin:0 0 4px;font-size:19px}.sw-sheet p{margin:4px 0 12px;font-size:14px;opacity:.8;line-height:1.45}
.sw-sheet .opt{display:block;width:100%;text-align:left;margin:0 0 10px;padding:13px 14px;border:2px solid var(--ink,#1F1A23);border-radius:16px;background:var(--bg,#1F1A23);color:inherit;font:inherit;cursor:pointer}
.sw-sheet .opt b{display:block;font-size:16px}.sw-sheet .opt span{font-size:13px;opacity:.75}
.sw-sheet .opt.rec{background:#CCFF00;color:#1F1A23}.sw-sheet .opt img.lg{float:right;width:34px;height:34px;border-radius:10px;margin-left:10px}
.sw-sheet .logos{display:flex;align-items:center;gap:6px;margin-top:9px;min-height:28px}.sw-sheet .logos img{width:28px;height:28px;border-radius:8px}.sw-sheet .logos em{font-size:12px;opacity:.7;font-style:normal}.sw-sheet .row{display:flex;gap:8px;flex-wrap:wrap}
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
// null only when storage says "empty" (or UNSUPPORTED: this client, e.g. Telegram Web, keeps nothing
// there); undefined = unknown (no answer in time, or any other error).
// SecureStorage's third argument says the key exists but must be restored (new device): ask for it.
const tgGet = (api, k) => within(new Promise((res) => { try { api.getItem(k, (err, v, canRestore) => res(err ? (/UNSUPPORTED/.test(String(err)) ? null : undefined) : v || (canRestore ? "restore" : null))); } catch { res(undefined); } }), 2500, undefined);
const tgRestore = (k) => within(new Promise((res) => { try { secure.restoreItem(k, (err, v) => res(err ? undefined : v || undefined)); } catch { res(undefined); } }), 120_000, undefined);
const tgSet = (api, k, v) => within(new Promise((res) => { try { api.setItem(k, v, (err, ok) => res(!err && ok !== false)); } catch { res(false); } }), 2500, false);
async function loadKey() {
  let silent = false;
  if (secure) {
    let v = await tgGet(secure, KEY);
    if (v === "restore") { v = await tgRestore(KEY); if (!v) throw new Error("Your AskSwarm wallet is saved in Telegram but needs restoring. Allow the restore, or reopen the app."); }
    if (v) return { pk: v, where: "Telegram secure storage on this phone" }; silent ||= v === undefined;
  }
  if (cloud) { const v = await tgGet(cloud, KEY); if (v) return { pk: v, where: "Telegram cloud storage" }; silent ||= v === undefined; }
  const v = recall(KEY); if (v) return { pk: v, where: "this browser" };
  // Never mint a new key while Telegram has not said "empty": that could overwrite a funded one.
  if (silent) throw new Error("Telegram storage did not answer. Close and reopen the app, then try again.");
  return null;
}
async function saveKey(pk) {
  if (secure && (await tgSet(secure, KEY, pk)) && (await tgGet(secure, KEY)) === pk) return "Telegram secure storage on this phone";
  if (cloud && (await tgSet(cloud, KEY, pk)) && (await tgGet(cloud, KEY)) === pk) return "Telegram cloud storage";
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
  const r = await fetch("/api/wallet", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ initData: tg.initData, address: account, chainId: C.id }) }).then((x) => x.json()).catch(() => ({ error: "network" }));
  const send = "Send a little ETH on " + C.name + " to " + account + " for gas.";
  if (r.error === "slow_down") throw new Error("Wait a few seconds and try again.");
  if (r.error === "limit" || r.error === "wrong_chain" || r.error === "faucet_empty" || (!r.error && r.chainId !== C.id)) throw new Error("Free gas is used up. " + send);
  if (r.error) throw new Error("Could not fund gas (" + r.error + "). " + send);
  if (r.starter) log(`Welcome: ${r.starter} IMD starter added to your wallet.`, "ok");
  return r;
}

// The same five wallets Chromia Pay's checkout recommends (WalletConnect explorer ids). They lead the
// official WalletConnect modal, which shows their icons, a QR code on desktop and the wallet app on a phone.
const WC_IDS = [
  "c57ca95b47569778a828d19178114f4db188b89b763c899ba0be274e97267d96", // MetaMask
  "4622a2b2d6af1c9844944291e5e7351a6aa24cd7b23099efac1b2fd875da31a0", // Trust Wallet
  "1ae92b26df02f0abca6304df07debccd18262fdf5fe82daa81593582dac9a369", // Rainbow
  "d0ca99ff52b99abc48743dad0f7fc891e041be73574f7fac4afe5d4bb83845c8", // Coinbase Wallet
  "971e689d0a5be527bac79629b4ee9b925e82208e5168b733496a09c0faed0709", // OKX Wallet
];
let logos = null;
const walletLogos = () => (logos ||= fetch(`https://explorer-api.walletconnect.com/v3/wallets?projectId=${WC_PROJECT_ID}&ids=${WC_IDS.join(",")}`, { signal: AbortSignal.timeout(4000) })
  .then((r) => r.json()).then((d) => WC_IDS.map((id) => d.listings?.[id]).filter(Boolean).map((l) => ({ name: l.name, img: l.image_url?.sm }))).catch(() => []));

// Telegram's webview drops window.open for wallet links; while the modal is up, send https links
// through Telegram.WebApp.openLink, which opens them in the wallet app.
async function viaTelegram(fn) {
  if (!tg) return fn();
  const open = window.open;
  window.open = (url, target, features) => { const u = String(url ?? ""); if (u.startsWith("https://")) { tg.openLink(u); return null; } return open.call(window, url, target, features); };
  try { return await fn(); } finally { window.open = open; }
}

async function walletConnect(C) {
  const { EthereumProvider } = await import("https://esm.sh/@walletconnect/ethereum-provider@2.23.10");
  const provider = await EthereumProvider.init({
    projectId: WC_PROJECT_ID, optionalChains: [C.id, ...(C.id === 1 ? [] : [1])], showQrModal: true,
    qrModalOptions: { explorerRecommendedWalletIds: WC_IDS },
    rpcMap: { [C.id]: C.rpc, 1: "https://ethereum-rpc.publicnode.com" },
    metadata: { name: "AskSwarm", description: "Bet IMD on yes/no questions the IMD swarm settles", url: location.origin, icons: [location.origin + "/logo.svg"] },
  });
  if (!provider.session) await viaTelegram(() => provider.connect()); // restored sessions skip pairing
  const approved = (provider.session?.namespaces?.eip155?.chains || []).map((c) => Number(c.split(":")[1]));
  if (!approved.includes(C.id)) { await provider.disconnect().catch(() => {}); throw new Error(`Your wallet did not approve ${C.name}. Use the AskSwarm wallet, or a wallet with ${C.name} support.`); }
  provider.chainId = C.id;
  const account = provider.accounts[0];
  // The modal records the wallet app picked on a phone; reuse it for the way back to sign.
  let walletLink = null; try { walletLink = JSON.parse(localStorage.getItem("WALLETCONNECT_DEEPLINK_CHOICE") || "null")?.href || null; } catch {}
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

/** Ask which wallet to use. Resolves "askswarm" | "walletconnect". */
function pick(C) {
  const icons = walletLogos();
  return new Promise((res, rej) => {
    const el = sheet(`<h3>Choose a wallet</h3><p>Bets are in IMD on ${esc(C.name)}.</p>
      <button class="opt rec" data-k="askswarm"><img class="lg" src="/logo.svg" alt=""><b>AskSwarm wallet${tg ? " · recommended" : ""}</b><span>${tg ? "Kept in Telegram on this device. Bet in one tap; deposit IMD to play. We cover gas." : "Kept in this browser. Bet in one tap; deposit IMD and a little ETH to play."}</span></button>
      <button class="opt" data-k="walletconnect"><b>Connect your wallet</b><span>WalletConnect: scan the QR code, or open your wallet app.</span><div class="logos"></div></button>
      <button class="x">Cancel</button>`);
    icons.then((ls) => { const d = el.querySelector(".logos"); if (d && ls.length) d.innerHTML = ls.map((l) => `<img src="${esc(l.img)}" alt="${esc(l.name)}" title="${esc(l.name)}">`).join("") + `<em>+ more</em>`; });
    el.querySelectorAll("[data-k]").forEach((b) => (b.onclick = () => { closeSheet(); res(b.dataset.k); }));
    el.querySelector(".x").onclick = () => { closeSheet(); rej(new Error("No wallet chosen.")); };
  });
}

/** The wallet for this page's chain C. Prompts once, then remembers the choice. */
let pending = null;
export function getWallet(C, opts) {
  if (session && session.chainId === C.id) return Promise.resolve(session);
  // One connect at a time: a second tap waits for the first instead of opening another prompt.
  return (pending ||= openWallet(C, opts).finally(() => (pending = null)));
}
async function openWallet(C, { log = () => {} } = {}) {
  let s;
  if (window.ethereum) s = await injected(C);
  else {
    let choice = recall(CHOICE);
    if (!choice) choice = (await hasEmbedded()) ? "askswarm" : "pick";
    if (choice === "pick") choice = await pick(C);
    s = choice === "walletconnect" ? await walletConnect(C) : await embedded(C);
    remember(CHOICE, s.kind);
  }
  if (s.kind === "askswarm") await ensureGas(C, s.account, log);
  session = { ...s, chainId: C.id };
  window.dispatchEvent(new CustomEvent("askswarm:wallet", { detail: session }));
  return session;
}

/** Ask again next time (and drop a WalletConnect session); the AskSwarm wallet key stays. */
export async function switchWallet() { remember(CHOICE, "pick"); await session?.provider?.disconnect?.().catch(() => {}); session = null; }

// ---- AskSwarm wallet bar: balance, deposit, withdraw, export ----
export async function walletBar(el, C) {
  if (!el || window.ethereum) return;
  if (recall(CHOICE) === "walletconnect") {
    el.className = "sw-bar";
    el.innerHTML = `<span>Connected wallet${session?.kind === "walletconnect" ? ` <a href="${addrLink(C, session.account)}" target="_blank" rel="noopener">${short(session.account)}</a>` : ""}</span><button data-a="switch">Switch wallet</button>`;
    el.querySelector('[data-a="switch"]').onclick = async () => { await switchWallet(); el.innerHTML = ""; };
    return;
  }
  let s;
  try { s = session?.kind === "askswarm" ? session : await embedded(C, { create: false }); }
  catch (e) { el.className = "sw-bar"; el.textContent = e.message; return; }
  if (!s) { el.innerHTML = ""; return; }
  const pub = createPublicClient({ chain: viemChain(C), transport: http(C.rpc) });
  const [eth, imd] = await Promise.all([pub.getBalance({ address: s.account }), pub.readContract({ address: C.imd, abi: erc20Abi, functionName: "balanceOf", args: [s.account] })]).catch(() => [0n, 0n]);
  const n = (v, d) => Number(formatEther(v)).toLocaleString(undefined, { maximumFractionDigits: d });
  el.className = "sw-bar";
  el.innerHTML = `<span>AskSwarm wallet <a href="${addrLink(C, s.account)}" target="_blank" rel="noopener">${short(s.account)}</a></span><b>${n(imd, 3)} IMD</b><span style="opacity:.7">${n(eth, 5)} ETH gas</span>
    <button data-a="deposit">Deposit</button><button data-a="withdraw">Withdraw</button><button data-a="more">⋯</button>`;
  el.querySelector('[data-a="deposit"]').onclick = () => deposit(C, s.account);
  el.querySelector('[data-a="withdraw"]').onclick = () => withdraw(C, el);
  el.querySelector('[data-a="more"]').onclick = () => more(C, el, s.where);
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

function more(C, bar, where = "this browser") {
  const fragile = tg && where === "this browser"; // Telegram may clear its webview storage
  const el = sheet(`<h3>AskSwarm wallet</h3><p>Your key is kept in ${esc(where)}. Nobody else holds it, so if you lose this device without a backup, the funds are gone. Keep small amounts here.</p>${fragile ? `<p><b>Back up your key now:</b> this Telegram version can only keep it in the app's browser storage, which can be cleared.</p>` : ""}
    <div class="row"><button data-x>Show private key</button><button data-s>Use another wallet</button></div><div id="sw-k" style="margin-top:10px"></div><button class="x">Close</button>`);
  el.querySelector(".x").onclick = closeSheet;
  el.querySelector("[data-x]").onclick = async () => { const k = await loadKey(); el.querySelector("#sw-k").innerHTML = k ? `<p>Anyone with this key controls the wallet. Import it into MetaMask or Rabby to move funds anywhere.</p><code>${k.pk}</code><div class="row" style="margin-top:8px"><button data-c>Copy key</button></div>` : "No key yet."; el.querySelector("[data-c]")?.addEventListener("click", (e) => { navigator.clipboard?.writeText(k.pk); e.target.textContent = "Copied"; }); };
  el.querySelector("[data-s]").onclick = async () => { await switchWallet(); closeSheet(); if (bar) bar.innerHTML = ""; };
}
