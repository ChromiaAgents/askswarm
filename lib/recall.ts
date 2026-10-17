// Free tier 1: the swarm already attested ~7.5k questions (Eval Engine dataset). Exact or near-exact
// match returns that signed answer at no cost. Near-exact = token Jaccard ≥ 0.9, strict on purpose:
// a wrong recall costs trust, a missed one costs nothing.
import answers from "./answers.json";

export type Prior = { q: string; t: string; a: string; agreed: number; panel: number; id: string; at: string };
const norm = (q: string) => q.toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
const toks = (q: string) => new Set(norm(q).split(" ").filter(Boolean));
const exact = new Map<string, Prior>((answers as Prior[]).map((p) => [norm(p.q), p]));

export function recall(question: string): Prior | null {
  const hit = exact.get(norm(question));
  if (hit) return hit;
  const a = toks(question); let best: Prior | null = null, bestJ = 0;
  for (const p of answers as Prior[]) {
    const b = toks(p.q); let inter = 0; for (const t of a) if (b.has(t)) inter++;
    const j = inter / (a.size + b.size - inter);
    if (j > bestJ) { bestJ = j; best = p; }
  }
  return bestJ >= 0.9 ? best : null;
}
