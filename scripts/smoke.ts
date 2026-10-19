// End-to-end smoke test of everything live. Read-only except where noted.
//   bun scripts/smoke.ts            pages, APIs, auth guards, contracts, bot webhook, dataset
import { createPublicClient, http, parseAbi, erc20Abi, formatEther, type Hex } from "viem";
import { mainnet } from "viem/chains";

const BASE = process.env.PUBLIC_URL ?? "https://askswarm-nine.vercel.app";
const IMD = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Hex;
const HOUSE = "0x571E17B13D8F6492Bbc372A160520B20BfdA320c" as Hex;
const results: { name: string; ok: boolean; detail: string }[] = [];
const check = async (name: string, fn: () => Promise<string | true>) => {
  try { const r = await fn(); results.push({ name, ok: true, detail: r === true ? "" : r }); }
  catch (e: any) { results.push({ name, ok: false, detail: String(e?.message ?? e).slice(0, 160) }); }
};
const must = (c: any, msg: string) => { if (!c) throw new Error(msg); };
const get = async (path: string, init?: RequestInit) => fetch(BASE + path, { ...init, signal: AbortSignal.timeout(30_000) });

// ---- pages
for (const p of ["/", "/answers", "/market", "/market?id=1", "/market?id=3", "/wager", "/wager?id=1", "/skill.md", "/llms.txt", "/pay?cs=x", "/imd", "/nav.js", "/logo.svg", "/og.png"])
  await check(`page ${p}`, async () => { const r = await get(p); must(r.ok, `HTTP ${r.status}`); return `${r.status}`; });

// ---- APIs
await check("api/answers", async () => { const j = await (await get("/api/answers")).json(); must(j.count >= 12 && j.verified >= 10, `count ${j.count} verified ${j.verified}`); return `${j.count} answers, ${j.verified} verified, ${j.registries.length} registries`; });
await check("api/markets", async () => { const j = await (await get("/api/markets")).json(); must(j.rows.length >= 4, `rows ${j.rows.length}`); must(j.rows.every((r: any) => Array.isArray(r.history) && Array.isArray(r.trades)), "missing history/trades"); return `${j.stats.markets} markets, ${j.stats.traders} traders, ${formatEther(BigInt(j.stats.volume))} IMD volume, ${formatEther(BigInt(j.stats.fees))} IMD fees`; });
await check("api/wagers", async () => { const j = await (await get("/api/wagers")).json(); must(j.rows.length >= 1 && j.rows.some((r: any) => r.state === "paid"), "no paid wager"); return `${j.rows.length} wagers`; });
await check("api/wagers draft yes/no", async () => { const r = await get("/api/wagers?draft=" + encodeURIComponent("Did Argentina win the 2022 FIFA World Cup?")); const j = await r.json(); must(r.ok && j.request?.answerType === "bool", JSON.stringify(j).slice(0, 120)); return "bool body"; });
await check("api/wagers draft rejects non yes/no", async () => { const r = await get("/api/wagers?draft=" + encodeURIComponent("In what year was Airbnb founded? Answer with the four-digit year only.")); must(r.status === 409, `HTTP ${r.status}`); return "409"; });
await check("api/price ETH", async () => { const j = await (await get(`/api/price?pair=ETH-USD&from=${Math.floor(Date.now() / 1000) - 86400}`)).json(); must(j.current > 0 && j.points.length > 50, "no candles"); return `ETH ${j.current}, ${j.points.length} points`; });
await check("api/price rejects bad pair", async () => { const r = await get("/api/price?pair=../x"); must(r.status === 400, `HTTP ${r.status}`); return "400"; });

// ---- auth guards (must refuse without secrets)
await check("guard api/telegram", async () => { const r = await get("/api/telegram", { method: "POST", body: "{}" }); must(r.status === 401, `HTTP ${r.status}`); return "401"; });
await check("guard api/keeper", async () => { const r = await get("/api/keeper"); must(r.status === 401, `HTTP ${r.status}`); return "401"; });
await check("guard api/hf-sync", async () => { const r = await get("/api/hf-sync"); must(r.status === 401, `HTTP ${r.status}`); return "401"; });
await check("guard api/imd bad signature", async () => { const r = await get("/api/imd?c=1&m=1&q=x&s=bad"); must(r.status === 403, `HTTP ${r.status}`); return "403"; });
await check("guard api/cpay-webhook unsigned", async () => { const r = await get("/api/cpay-webhook", { method: "POST", body: "{}", headers: { "content-type": "application/json" } }); must(r.status >= 400 && r.status < 500, `HTTP ${r.status}`); return `${r.status}`; });

// ---- keeper with secret (no-op or real work)
await check("keeper run", async () => { const r = await get("/api/keeper", { headers: { authorization: `Bearer ${process.env.CRON_SECRET}` } }); const j = await r.json(); must(r.ok && Array.isArray(j.acts), JSON.stringify(j).slice(0, 120)); return `${j.acts.length} actions`; });

// ---- contracts
const pub = createPublicClient({ chain: mainnet, transport: http(process.env.ETH_RPC_URL) });
await check("registry price + recent answer", async () => {
  const reg = process.env.REGISTRY_ADDRESS as Hex;
  const p = await pub.readContract({ address: reg, abi: parseAbi(["function price() view returns (uint256)"]), functionName: "price" });
  must(p === 500000000000000000n, `price ${p}`); return "0.5 IMD";
});
await check("market + wager counts", async () => {
  const c = parseAbi(["function count() view returns (uint256)"]);
  const m = await pub.readContract({ address: process.env.MARKET_ADDRESS as Hex, abi: c, functionName: "count" });
  const w = await pub.readContract({ address: process.env.WAGER_ADDRESS as Hex, abi: c, functionName: "count" });
  return `${m} markets, ${w} wagers`;
});
await check("house wallet runway", async () => {
  const [i, e] = await Promise.all([pub.readContract({ address: IMD, abi: erc20Abi, functionName: "balanceOf", args: [HOUSE] }), pub.getBalance({ address: HOUSE })]);
  must(i >= 2n * 10n ** 18n && e >= 3n * 10n ** 15n, `low: ${formatEther(i)} IMD ${formatEther(e)} ETH`);
  return `${Number(formatEther(i)).toFixed(2)} IMD, ${Number(formatEther(e)).toFixed(4)} ETH`;
});

// ---- bot
const TG = `https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}`;
await check("bot webhook", async () => {
  const w = (await (await fetch(`${TG}/getWebhookInfo`)).json()).result;
  must(w.url === `${BASE}/api/telegram`, `url ${w.url}`); must(!w.last_error_date || Date.now() / 1000 - w.last_error_date > 3600, `recent error: ${w.last_error_message}`);
  return `pending ${w.pending_update_count}${w.last_error_message ? `, last error ${w.last_error_message}` : ""}`;
});
await check("bot commands", async () => { const c = (await (await fetch(`${TG}/getMyCommands`)).json()).result.map((x: any) => x.command); must(["markets", "bet", "ask"].every((k) => c.includes(k)), c.join(",")); return c.join(", "); });

// ---- dataset write-back
await check("HF dataset contrib file", async () => { const t = await (await fetch("https://huggingface.co/datasets/evalengine/imd-oracle-outcomes/raw/main/contrib/askswarm/answers.jsonl")).text(); const n = t.trim().split("\n").length; must(n >= 11, `rows ${n}`); return `${n} rows`; });

// ---- report
const bad = results.filter((r) => !r.ok);
for (const r of results) console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.name}${r.detail ? "  · " + r.detail : ""}`);
console.log(`\n${results.length - bad.length}/${results.length} passed`);
process.exit(bad.length ? 1 : 0);
