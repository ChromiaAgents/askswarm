// Hands-on demo recording of the live site on a phone-sized screen, with a real bet signed by the
// demo wallet (DEMO_PK) through an injected EIP-1193 provider, so the transactions are real
// transactions on the active chain (Robinhood Chain). Writes docs/demo/raw.webm and docs/demo/marks.json (phase timestamps for editing).
//   bun scripts/record-demo.ts [marketId]
import puppeteer from "puppeteer-core";
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE } from "../lib/chains";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE = "https://askswarm-nine.vercel.app";
const MARKET = process.argv[2] ?? "3";
const account = privateKeyToAccount(process.env.DEMO_PK as Hex);
const transport = http(ACTIVE.rpc);
const pub = createPublicClient({ chain: ACTIVE.viem, transport });
const wallet = createWalletClient({ account, chain: ACTIVE.viem, transport });
mkdirSync("docs/demo", { recursive: true });

const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  args: ["--hide-scrollbars", "--force-prefers-color-scheme=light", "--disable-blink-features=AutomationControlled"],
});
const page = await browser.newPage();
await page.setViewport({ width: 430, height: 860, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);

// Wallet bridge: page asks, node signs with the demo key.
await page.exposeFunction("__ethReq", async ({ method, params }: { method: string; params?: any[] }) => {
  if (method === "eth_requestAccounts" || method === "eth_accounts") return [account.address];
  if (method === "eth_chainId") return "0x" + ACTIVE.id.toString(16);
  if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
  if (method === "eth_sendTransaction") {
    const tx = params![0];
    return wallet.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ? BigInt(tx.value) : 0n });
  }
  return pub.request({ method: method as any, params: params as any });
});
await page.evaluateOnNewDocument(() => {
  (window as any).ethereum = { isMetaMask: true, request: (a: any) => (window as any).__ethReq(a), on() {}, removeListener() {} };
});

const t0 = Date.now(), marks: Record<string, number> = {};
const mark = (k: string) => { marks[k] = (Date.now() - t0) / 1000; console.log(k, marks[k].toFixed(1)); };
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const smoothScroll = (y: number, ms = 1200) => page.evaluate((y, ms) => new Promise<void>((res) => {
  const s = scrollY, d = y - s, t = performance.now();
  const f = (n: number) => { const p = Math.min(1, (n - t) / ms); scrollTo(0, s + d * (p < .5 ? 2 * p * p : 1 - (-2 * p + 2) ** 2 / 2)); p < 1 ? requestAnimationFrame(f) : res(); };
  requestAnimationFrame(f);
}), y, ms);
const tap = async (sel: string) => { const el = await page.waitForSelector(sel, { visible: true, timeout: 20_000 }); await el!.scrollIntoView(); await wait(400); await el!.tap(); };

const rec = await page.screencast({ path: "docs/demo/raw.webm" as `${string}.webm` });
try {
  mark("home");
  await page.goto(BASE + "/", { waitUntil: "networkidle2" });
  await wait(2500); await smoothScroll(700, 2000); await wait(1500);

  mark("markets");
  await tap('.sw-links a[href="/market"]');
  await page.waitForSelector(".cardlink", { visible: true, timeout: 30_000 });
  await wait(2500); await smoothScroll(520, 1800); await wait(2000);

  mark("market");
  await tap(`.cardlink[href="?id=${MARKET}&c=${ACTIVE.id}"]`);
  await page.waitForSelector(".sides", { visible: true, timeout: 30_000 });
  await wait(3000);

  mark("pick");
  await tap('.side.n'); await wait(1200);
  await tap('.chips button[data-v="0.5"]'); await wait(1500);
  await tap('.side.y'); await wait(1200);
  await tap('.chips button[data-v="0.1"]'); await wait(1800);

  mark("bet");
  await tap("#cta");
  await page.waitForFunction(() => /Done\.|err/.test(document.querySelector("#vlog")?.textContent ?? "") || !!document.querySelector("#vlog .err"), { timeout: 240_000 });
  mark("confirmed");
  await wait(2500);
  await page.waitForSelector(".sides", { visible: true, timeout: 60_000 }); // page reloads after Done
  await wait(2500);

  mark("chart");
  await smoothScroll(560, 1500); await wait(2500);
  await tap("details.more summary"); await wait(2000);
  await tap("details.more:nth-of-type(2) summary").catch(() => {}); await wait(2500);

  mark("answers");
  await page.goto(BASE + "/answers", { waitUntil: "networkidle2" });
  await page.waitForSelector(".card .a", { timeout: 30_000 });
  await wait(1500);
  await page.type("#q", "CHF", { delay: 160 }); await wait(2500);
  await page.evaluate(() => { (document.querySelector("#q") as HTMLInputElement).value = ""; document.querySelector("#q")!.dispatchEvent(new Event("input")); });
  await smoothScroll(900, 2500); await wait(1500);

  mark("end");
} finally {
  await rec.stop();
  writeFileSync("docs/demo/marks.json", JSON.stringify(marks, null, 1));
  await browser.close();
}
