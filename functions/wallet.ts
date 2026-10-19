// POST /api/wallet {initData, address}: starts a player's AskSwarm wallet on the active chain.
// Telegram signs initData with our bot token, so only a real Telegram user of this bot gets here.
// The house wallet sends a little gas (bets cost ~$0.01 on Robinhood Chain) and, while its IMD stays
// above a reserve, a small starter stake for a brand-new wallet so a first bet works with no deposit.
// ponytail: dedupe is per instance plus "brand-new address" onchain; a determined farmer with many
// Telegram accounts is bounded by STARTER_RESERVE_IMD, not stopped. Add a store if that matters.
import { createHmac, timingSafeEqual } from "node:crypto";
import { createPublicClient, createWalletClient, http, erc20Abi, parseEther, formatEther, isAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE } from "../lib/chains";

export const maxDuration = 60;
const GAS = parseEther(process.env.GAS_DRIP_ETH ?? "0.00005");
const GAS_MIN = parseEther("0.00002");
const STARTER = parseEther(process.env.STARTER_IMD ?? "0.1");
const RESERVE = parseEther(process.env.STARTER_RESERVE_IMD ?? "3");
const seen = new Map<string, number>();
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

/** Telegram Mini App initData check (core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app). */
export function verifyInitData(initData: string, botToken: string, maxAgeSec = 86400): { id: number } | null {
  const p = new URLSearchParams(initData);
  const hash = p.get("hash");
  if (!hash) return null;
  p.delete("hash");
  const check = [...p.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}=${v}`).join("\n");
  const secret = createHmac("sha256", "WebAppData").update(botToken).digest("hex");
  const want = createHmac("sha256", Buffer.from(secret, "hex") as unknown as string).update(check).digest("hex");
  if (hash.length !== want.length || !timingSafeEqual(new TextEncoder().encode(hash), new TextEncoder().encode(want))) return null;
  if (Date.now() / 1000 - Number(p.get("auth_date") ?? 0) > maxAgeSec) return null;
  try { const u = JSON.parse(p.get("user") ?? "null"); return typeof u?.id === "number" ? { id: u.id } : null; } catch { return null; }
}

export async function POST(req: Request) {
  let b: any; try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const user = verifyInitData(String(b.initData ?? ""), process.env.TELEGRAM_BOT_TOKEN ?? "");
  if (!user) return json({ error: "not_telegram" }, 403);
  const address = String(b.address ?? "") as Hex;
  if (!isAddress(address)) return json({ error: "bad_address" }, 400);
  const k = `${user.id}`;
  if (Date.now() - (seen.get(k) ?? 0) < 30_000) return json({ error: "slow_down" }, 429);
  seen.set(k, Date.now());

  const c = ACTIVE, transport = http(c.rpc);
  const pub = createPublicClient({ chain: c.viem, transport });
  const house = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex);
  const w = createWalletClient({ account: house, chain: c.viem, transport });
  const [eth, nonce, imd, houseImd] = await Promise.all([
    pub.getBalance({ address }), pub.getTransactionCount({ address }),
    pub.readContract({ address: c.imd, abi: erc20Abi, functionName: "balanceOf", args: [address] }),
    pub.readContract({ address: c.imd, abi: erc20Abi, functionName: "balanceOf", args: [house.address] }),
  ]);
  const out: { chainId: number; gasTx?: Hex; starterTx?: Hex; starter?: string; note?: string } = { chainId: c.id };
  // Starter first, then gas, back to back from the house wallet: number them explicitly, since the
  // node may not count the first before the second is built.
  let n = await pub.getTransactionCount({ address: house.address, blockTag: "pending" });
  if (STARTER > 0n && nonce === 0 && imd === 0n && houseImd - STARTER >= RESERVE) {
    out.starterTx = await w.writeContract({ address: c.imd, abi: erc20Abi, functionName: "transfer", args: [address, STARTER], nonce: n++ });
    out.starter = formatEther(STARTER);
  } else if (STARTER > 0n && nonce === 0 && imd === 0n) out.note = "starter IMD paused, deposit IMD to play";
  if (eth < GAS_MIN) out.gasTx = await w.sendTransaction({ to: address, value: GAS, nonce: n++ });
  await Promise.all([out.starterTx, out.gasTx].filter(Boolean).map((hash) => pub.waitForTransactionReceipt({ hash: hash as Hex })));
  return json(out);
}
