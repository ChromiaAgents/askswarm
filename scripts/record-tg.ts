// Hands-on demo inside real Telegram (web.telegram.org), driving a logged-in Chrome over DevTools:
// /markets → open a market in the Mini App → bet (a real tx on the active chain, signed by the demo
// wallet DEMO_PK, which the Mini App sees as a browser wallet like MetaMask's extension) → /ask.
// Writes docs/demo/tg.webm and docs/demo/tg-marks.json.
//   1. Chrome with --remote-debugging-port=9333 and a Telegram Web session (scan the QR once)
//   2. bun scripts/record-tg.ts [marketId] ["question for /ask"]
import puppeteer, { type Frame, type Page } from "puppeteer-core";
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mkdirSync, writeFileSync } from "node:fs";
import { ACTIVE } from "../lib/chains";

const MARKET = process.argv[2] ?? "1";
// A question the swarm already attested, so the bot answers it free and instantly with the signed verdict.
const QUESTION = process.argv[3] ?? "Bitcoin's total supply is capped at 21 million coins. Answer true or false.";
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
mkdirSync("docs/demo", { recursive: true });

const b = await puppeteer.connect({ browserURL: "http://127.0.0.1:9333", defaultViewport: null, protocolTimeout: 60_000 });
const p = (await b.pages()).find((x) => x.url().includes("web.telegram.org")) as Page;
await p.bringToFront();
await p.goto("https://web.telegram.org/k/#@askswarm_bot", { waitUntil: "networkidle2" });
await wait(5000);
// Wallet bridge: the Mini App (askswarm origin only) asks, node signs with the demo key.
const account = privateKeyToAccount(process.env.DEMO_PK as Hex);
const transport = http(ACTIVE.rpc);
const pub = createPublicClient({ chain: ACTIVE.viem, transport });
const wallet = createWalletClient({ account, chain: ACTIVE.viem, transport });
// The Mini App is a cross-origin iframe (its own process), where init scripts and bindings do not
// reach, so the provider is installed after load and requests are passed by polling.
async function handle(method: string, params?: any[]) {
  if (method === "eth_requestAccounts" || method === "eth_accounts") return [account.address];
  if (method === "eth_chainId") return "0x" + ACTIVE.id.toString(16);
  if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
  if (method === "eth_sendTransaction") { const tx = params![0]; return wallet.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ? BigInt(tx.value) : 0n }); }
  return pub.request({ method: method as any, params: params as any });
}
let bridged: Frame | null = null;
async function bridge(f: Frame) {
  bridged = f;
  await f.evaluate(() => {
    const w = window as any; w.__ethQ = []; w.__ethP = {}; let n = 0;
    w.ethereum = { isMetaMask: true, on() {}, removeListener() {}, request: (a: any) => new Promise((res, rej) => { const id = ++n; w.__ethP[id] = { res, rej }; w.__ethQ.push({ id, method: a.method, params: a.params }); }) };
  });
  (async () => {
    while (bridged === f) {
      const q: any[] = await f.evaluate(() => (window as any).__ethQ?.splice(0) ?? []).catch(() => []);
      for (const r of q) {
        const out = await handle(r.method, r.params).then((v) => ({ v: JSON.parse(JSON.stringify(v ?? null, (_, x) => (typeof x === "bigint" ? "0x" + x.toString(16) : x))) }), (e) => ({ e: String(e?.shortMessage ?? e?.message ?? e) }));
        await f.evaluate((id, out) => { const p = (window as any).__ethP[id]; delete (window as any).__ethP[id]; "e" in out ? p.rej(new Error(out.e)) : p.res(out.v); }, r.id, out as any).catch(() => {});
      }
      await wait(150);
    }
  })();
}
// Keep the frame on this chat: hide the unread counter on the back arrow.
await p.addStyleTag({ content: ".sidebar-close-button .badge, .btn-icon .badge { display: none !important; }" });

const t0 = Date.now(), marks: Record<string, number> = {};
const mark = (k: string) => { marks[k] = (Date.now() - t0) / 1000; console.log(k, marks[k].toFixed(1)); };

// DOM clicks: ElementHandle.click waits on an IntersectionObserver, which stalls in a window that is not in front.
const tap = (h: any) => h.evaluate((e: HTMLElement) => e.click());
async function send(text: string) {
  const inp = await p.waitForSelector(".input-message-input[contenteditable=true]", { visible: true });
  await inp!.evaluate((e) => (e as HTMLElement).focus()); await wait(300);
  for (const ch of text) { await p.keyboard.sendCharacter(ch); await wait(55); }
  await wait(500); await p.keyboard.press("Enter");
}
async function lastButton(re: RegExp) {
  let hit = null;
  for (const x of await p.$$(".reply-markup-button")) if (re.test(await x.evaluate((e) => e.textContent ?? ""))) hit = x;
  return hit;
}
// The Mini App's own Close (top of its window). Escape would leave the bot chat for the chat list.
async function closeApp() {
  for (let i = 0; i < 3; i++) {
    const shut = await p.$('[class*="_Browser"] [aria-label="Close"]');
    if (!shut) return;
    await tap(shut); await wait(1000);
    for (const c of await p.$$(".popup-button")) if (/close/i.test(await c.evaluate((e) => e.textContent ?? ""))) { await tap(c); break; }
    await wait(1200);
  }
}
async function appFrame(): Promise<Frame> {
  for (let i = 0; i < 60; i++) { const f = p.frames().find((x) => x.url().includes("askswarm-nine.vercel.app")); if (f) return f; await wait(500); }
  throw new Error("Mini App did not open");
}

await closeApp(); // a Mini App left open would otherwise be restored over the chat
// Telegram's narrow layout can leave the page slid sideways onto the chat list; keep it on the chat.
await p.evaluate(() => setInterval(() => { for (const e of [document.body, document.documentElement]) if (e.scrollLeft) e.scrollLeft = 0; }, 100));
await wait(1500);
const rec = await p.screencast({ path: "docs/demo/tg.webm" as `${string}.webm` });
try {
  mark("chat"); await wait(1500);

  mark("markets");
  await send("/markets");
  for (let i = 0; i < 40 && !(await lastButton(new RegExp(`#${MARKET}\\D`))); i++) await wait(500);
  await wait(3500);

  mark("open");
  await tap(await lastButton(new RegExp(`#${MARKET}\\D`))); await wait(1500);
  for (const c of await p.$$(".popup-button")) if (/launch|open/i.test(await c.evaluate((e) => e.textContent ?? ""))) { await tap(c); break; }
  const f = await appFrame();
  await f.waitForSelector(".sides", { visible: true, timeout: 30_000 });
  // Telegram restores a minimised Mini App instead of reloading it: start clean, with no leftover
  // WalletConnect pairing or remembered wallet, so the browser wallet is what connects.
  await f.evaluate(() => { for (const k of Object.keys(localStorage)) if (/^(wc@2|@appkit|@w3m|WALLETCONNECT|askswarm_wallet_choice)/.test(k)) localStorage.removeItem(k); location.reload(); });
  await wait(1500);
  await f.waitForSelector(".sides", { visible: true, timeout: 30_000 });
  await bridge(f);
  await wait(3500);

  mark("pick");
  await tap(await f.$(".side.y")); await wait(1200);
  await tap(await f.$('.chips button[data-v="0.1"]')); await wait(1800);

  mark("bet");
  // Telegram draws the Mini App's MainButton itself, below the iframe.
  await f.evaluate(() => { const v = document.querySelector("#vlog"); if (v) v.innerHTML = ""; });
  await p.waitForSelector(".web-app-button.is-visible", { visible: true, timeout: 10_000 });
  await p.evaluate(() => (document.querySelector(".web-app-button.is-visible") as HTMLElement).click());
  await f.waitForFunction(() => /Done\./.test(document.querySelector("#vlog")?.textContent ?? "") || !!document.querySelector("#vlog .err"), { timeout: 240_000, polling: 500 });
  mark("confirmed");
  console.log("log:", await f.evaluate(() => document.querySelector("#vlog")?.textContent?.slice(-400)));
  bridged = null;
  await wait(6000); // page reloads with the new odds

  mark("close");
  await closeApp();
  await wait(1500);

  mark("ask");
  await send(`/ask ${QUESTION}`);
  await p.waitForFunction((q) => [...document.querySelectorAll(".bubble.is-in")].some((e) => (e.textContent ?? "").includes("panel") && (e.textContent ?? "").includes(q.slice(4, 30))), { timeout: 60_000, polling: 500 }, QUESTION).catch(() => {});
  mark("answer");
  await wait(8000);
  mark("end");
} finally {
  await rec.stop();
  writeFileSync("docs/demo/tg-marks.json", JSON.stringify(marks, null, 1));
  b.disconnect();
}
process.exit(0);
