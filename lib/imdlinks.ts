// IMD explorer links for an onchain ask: the Intake plane indexes every request by (chain, tx) and
// names the oracle request and the swarm job behind it. api.imd.fun sends no CORS headers, so pages
// get these from our APIs instead of asking IMD themselves.
// ponytail: per-instance memory cache; settled lookups are kept, pending ones retried after a minute.
const API = process.env.IMD_API ?? "https://api.imd.fun";
export const IMD_EXPLORER = "https://explorer.imd.fun";

export type ImdLinks = { state: string; job?: string; attestation?: string; request?: string; completionTx?: string };
const cache = new Map<string, { at: number; v: ImdLinks | null }>();

export async function imdLinks(chainId: number, tx?: string | null): Promise<ImdLinks | null> {
  if (!tx) return null;
  const k = `${chainId}:${tx.toLowerCase()}`;
  const hit = cache.get(k);
  if (hit && (hit.v?.state === "completed" || Date.now() - hit.at < 60_000)) return hit.v;
  let v: ImdLinks | null = null;
  try {
    const r = await fetch(`${API}/intake/${chainId}/${tx}`, { signal: AbortSignal.timeout(5000) });
    if (r.ok) {
      const e = (await r.json())?.entries?.[0];
      const res = e?.admission?.result;
      if (e) v = {
        state: String(e.state ?? "indexed"),
        request: res?.requestId,
        job: res?.jobId ? `${IMD_EXPLORER}/jobs/${res.jobId}` : undefined,
        attestation: res?.attestationUrl ? `${API}${res.attestationUrl}` : undefined,
        completionTx: e.completion?.txHash,
      };
    }
  } catch {}
  cache.set(k, { at: Date.now(), v });
  return v;
}

/** Fill `imd` on every row that has a tx, in parallel, never throwing. */
export async function withImd<T extends Record<string, any>>(rows: T[], chainOf: (r: T) => number, txOf: (r: T) => string | undefined): Promise<T[]> {
  await Promise.all(rows.map(async (r) => { const l = await imdLinks(chainOf(r), txOf(r)); if (l) (r as any).imd = l; }));
  return rows;
}
