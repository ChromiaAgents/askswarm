// POST /api/wallet {initData, address}: starts a player's AskSwarm wallet on the active chain.
// Telegram signs initData with our bot token, so only a real Telegram user of this bot gets here.
// The house wallet sends a little gas (bets cost ~$0.01 on Robinhood Chain) and, while its IMD stays
// above a reserve, a small starter stake for a brand-new wallet so a first bet works with no deposit.
// Limits, with no database: each Telegram user gets at most MAX_DRIPS top-ups ever (the starter only on
// the first), counted onchain (see marker). House IMD keeps STARTER_RESERVE_IMD and house ETH keeps
// GAS_RESERVE_ETH for the keeper and bot, so the faucet can never spend those. Robinhood Chain only.
import { createHmac, timingSafeEqual } from "node:crypto";
import { createPublicClient, createWalletClient, http, erc20Abi, parseEther, formatEther, isAddress, getAddress, keccak256, toHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE, transportFor } from "../lib/chains";

export const maxDuration = 60;
const GAS = parseEther(process.env.GAS_DRIP_ETH ?? "0.00005");
const GAS_MIN = parseEther("0.00002");
const STARTER = parseEther(process.env.STARTER_IMD ?? "0.1");
const RESERVE = parseEther(process.env.STARTER_RESERVE_IMD ?? "3");
const GAS_RESERVE = parseEther(process.env.GAS_RESERVE_ETH ?? "0.005");
const MAX_DRIPS = BigInt(process.env.MAX_DRIPS ?? "5");
// Durable per-user count with no store: every top-up also sends 1 wei to an address derived from the
// Telegram user id, so that address's balance is the number of top-ups this user has had.
// ponytail: two requests landing on different instances in the same second can both pass the count
// (shared house nonces make one of them fail most of the time); use a KV row if that gets abused.
export const marker = (uid: number) => getAddress(`0x${keccak256(toHex(`askswarm-drip:${uid}`)).slice(-40)}`);
const seen = new Map<string, number>();
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

/** Telegram Mini App initData check (core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app). */
export function verifyInitData(initData: string, botToken: string, maxAgeSec = 86400): { id: number } | null {
  const p = new URLSearchParams(initData);
  const hash = p.get("hash");
  if (!hash) return null;
  p.delete("hash");
  const check = [...p.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => `${k}=${v}`).join("\n");
  const secret = createHmac("sha256", "WebAppData").update(botToken).digest("hex");
  const want = createHmac("sha256", Buffer.from(secret, "hex") as unknown as string).update(check).digest("hex");
  if (hash.length !== want.length || !timingSafeEqual(new TextEncoder().encode(hash), new TextEncoder().encode(want))) return null;
  const age = Date.now() / 1000 - Number(p.get("auth_date"));
  if (!Number.isFinite(age) || age > maxAgeSec) return null;
  try { const u = JSON.parse(p.get("user") ?? "null"); return typeof u?.id === "number" ? { id: u.id } : null; } catch { return null; }
}

export async function POST(req: Request) {
  const tok = process.env.TELEGRAM_BOT_TOKEN, pk = process.env.EVM_PRIVATE_KEY as Hex | undefined;
  if (!tok || !pk) return json({ error: "not_configured" }, 503); // an empty token would accept forged initData
  let b: any; try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const user = verifyInitData(String(b.initData ?? ""), tok);
  if (!user) return json({ error: "not_telegram" }, 403);
  const address = String(b.address ?? "") as Hex;
  if (!isAddress(address)) return json({ error: "bad_address" }, 400);
  const c = ACTIVE;
  // Only on Robinhood Chain (cents of gas), and only for the chain the page is on.
  if (c.id !== 4663 || Number(b.chainId ?? c.id) !== c.id) return json({ error: "wrong_chain", chainId: c.id }, 409);
  const k = `${user.id}`;
  if (Date.now() - (seen.get(k) ?? 0) < 30_000) return json({ error: "slow_down" }, 429);
  if (seen.size > 10_000) seen.clear();
  seen.set(k, Date.now());

  try {
    const transport = transportFor(c);
    const pub = createPublicClient({ chain: c.viem, transport });
    const house = privateKeyToAccount(pk);
    const w = createWalletClient({ account: house, chain: c.viem, transport });
    const mark = marker(user.id);
    const [eth, nonce, imd, houseImd, houseEth, drips] = await Promise.all([
      pub.getBalance({ address }), pub.getTransactionCount({ address, blockTag: "pending" }),
      pub.readContract({ address: c.imd, abi: erc20Abi, functionName: "balanceOf", args: [address] }),
      pub.readContract({ address: c.imd, abi: erc20Abi, functionName: "balanceOf", args: [house.address] }),
      pub.getBalance({ address: house.address }), pub.getBalance({ address: mark }),
    ]);
    if (drips >= MAX_DRIPS) return json({ error: "limit", chainId: c.id }, 429);
    const out: { chainId: number; gasTx?: Hex; starterTx?: Hex; starter?: string; note?: string } = { chainId: c.id };
    const fresh = drips === 0n && nonce === 0 && imd === 0n;
    const giveStarter = STARTER > 0n && fresh && houseImd - STARTER >= RESERVE;
    const giveGas = eth < GAS_MIN && houseEth - GAS >= GAS_RESERVE;
    if (STARTER > 0n && fresh && !giveStarter) out.note = "starter IMD paused, deposit IMD to play";
    if (eth < GAS_MIN && !giveGas) return json({ error: "faucet_empty", chainId: c.id }, 503);
    if (!giveStarter && !giveGas) return json(out);
    // Count first, then send, back to back from the house wallet: number them explicitly, since the
    // node may not count one tx before the next is built.
    let n = await pub.getTransactionCount({ address: house.address, blockTag: "pending" });
    const hashes = [await w.sendTransaction({ to: mark, value: 1n, nonce: n++ })];
    if (giveStarter) { hashes.push(out.starterTx = await w.writeContract({ address: c.imd, abi: erc20Abi, functionName: "transfer", args: [address, STARTER], nonce: n++ })); out.starter = formatEther(STARTER); }
    if (giveGas) hashes.push(out.gasTx = await w.sendTransaction({ to: address, value: GAS, nonce: n++ }));
    await Promise.all(hashes.map((hash) => pub.waitForTransactionReceipt({ hash, timeout: 40_000 })));
    return json(out);
  } catch (e) {
    console.error("wallet faucet", (e as any)?.shortMessage ?? (e as Error)?.message);
    return json({ error: "send_failed" }, 502);
  }
}
