// Who gets market news: every private chat that talked to the bot and every group it was added to,
// minus anyone who sent /stop, kept in Upstash Redis over its REST API (Vercel's Upstash integration
// sets KV_REST_API_URL / KV_REST_API_TOKEN). Without those env vars this is a no-op and news goes only
// to BROADCAST_CHATS, as before.
const URL_ = process.env.KV_REST_API_URL ?? process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN ?? process.env.UPSTASH_REDIS_REST_TOKEN;
const CHATS = "askswarm:chats", MUTED = "askswarm:muted";
export const subsEnabled = !!(URL_ && TOKEN);

async function redis(...cmds: (string | number)[][]): Promise<any[]> {
  if (!subsEnabled) return [];
  const r = await fetch(`${URL_}/pipeline`, {
    method: "POST", headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify(cmds.map((c) => c.map(String))), signal: AbortSignal.timeout(5000),
  });
  if (!r.ok) throw new Error(`redis ${r.status}`);
  return (await r.json()).map((x: any) => x.result);
}

// ponytail: per-instance memo so a chatty group costs one Redis call per cold start, not per message.
const seen = new Set<string>();

/** First contact from a chat: subscribe it unless it sent /stop before. */
export async function track(chatId: number | string) {
  const id = String(chatId);
  if (!subsEnabled || seen.has(id)) return;
  const [muted] = await redis(["SISMEMBER", MUTED, id]);
  if (!muted) await redis(["SADD", CHATS, id]);
  seen.add(id); // only after the write landed, so a failed one is retried on the next message
}
export async function subscribe(chatId: number | string) { const id = String(chatId); seen.add(id); await redis(["SREM", MUTED, id], ["SADD", CHATS, id]); }
export async function unsubscribe(chatId: number | string, mute = true) { const id = String(chatId); seen.add(id); await redis(["SREM", CHATS, id], ...(mute ? [["SADD", MUTED, id]] : [])); }
export async function subscribers(): Promise<string[]> { const [all] = await redis(["SMEMBERS", CHATS]); return all ?? []; }

// Usage counters for /stats: per-day command counts plus unique users (HyperLogLog, ~1% error, 12KB each).
const day = (t = Date.now()) => new Date(t).toISOString().slice(0, 10);
export async function hit(cmd: string, uid?: number) {
  const d = day();
  await redis(["HINCRBY", `askswarm:hits:${d}`, cmd, 1], ...(uid ? [["PFADD", "askswarm:users", uid], ["PFADD", `askswarm:dau:${d}`, uid]] : []));
}
export async function botStats(days = 14) {
  if (!subsEnabled) return null;
  const ds = Array.from({ length: days }, (_, i) => day(Date.now() - i * 86400_000)).reverse();
  const res = await redis(["SMEMBERS", CHATS], ["SCARD", MUTED], ["PFCOUNT", "askswarm:users"], ...ds.flatMap((d) => [["HGETALL", `askswarm:hits:${d}`], ["PFCOUNT", `askswarm:dau:${d}`]]));
  const [chats, muted, users] = res;
  const pairs = (a: string[] = []) => Object.fromEntries(a.flatMap((_, i) => (i % 2 ? [] : [[a[i], Number(a[i + 1])]])));
  return {
    users, muted, privateChats: (chats ?? []).filter((c: string) => !c.startsWith("-")).length, groups: (chats ?? []).filter((c: string) => c.startsWith("-")).length,
    daily: ds.map((d, i) => ({ day: d, users: res[4 + i * 2], hits: pairs(res[3 + i * 2]) })),
  };
}
