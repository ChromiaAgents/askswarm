// Disagreement risk: P(swarm fails to reach consensus) for a drafted oracle request, trained on
// evalengine/imd-oracle-outcomes (7.8k IMD requests, label 1 = disagreed). Hashed logistic regression over request shape:
// no runtime deps, weights ship as JSON. Retrain with `bun run train:risk <dir with train/validation/test.jsonl>`.
import model from "./risk-model.json";

export const BUCKETS = 8192;
export type Draft = { question: string; answerType: string; panelSize: number; quorum: number; evidence?: string; validForSeconds?: number; window?: unknown };

const fnv = (s: string) => {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return (h >>> 0) % BUCKETS;
};

const REALTIME = /\b(right now|currently|last (hour|\d+ hours?|day|week)|previous \d+ hours?|previous hour|as of now|today|at the moment|latest|live)\b/i;
const FUTURE = /\b(20(2[7-9]|[3-9]\d))\b|\bwill\b|\bwould\b/i;
const UNKNOWABLE = /\b(how many (grains|people were born|stars)|population of springfield|estimate|roughly|approximately)\b/i;
const CONSTRAINT = /\b(only|exactly|in wei|four-digit|three-letter|surname|ticker|iso \d+|as an integer|answer with)\b/i;

export function features(d: Draft): number[] {
  // Structural only. Word n-grams overfit (test AUC 0.55 vs 0.75 without them); the panel splits on
  // request shape, not topic: tiny panels, unanimous quorum, moving targets, missing answer format.
  const q = d.question;
  const f = ["bias", `type=${d.answerType}`, `len=${Math.min(7, Math.floor(q.length / 100))}`,
    `qr=${Math.round((d.quorum / Math.max(d.panelSize, 1)) * 10)}`, `panel=${d.panelSize <= 10 ? "s" : d.panelSize <= 50 ? "m" : "l"}`,
    `ev=${d.evidence ?? "panel"}`, `vf=${Math.round(Math.log10((d.validForSeconds ?? 1) + 1))}`, `win=${d.window ? "y" : "n"}`];
  if (REALTIME.test(q)) f.push("realtime");
  if (FUTURE.test(q)) f.push("future");
  if (UNKNOWABLE.test(q)) f.push("unknowable");
  if (!CONSTRAINT.test(q)) f.push("noconstraint");
  if (/\?.*\?/s.test(q)) f.push("multiq");
  if (/https?:\/\//.test(q)) f.push("url");
  return f.map(fnv);
}

export function predict(d: Draft, w: ArrayLike<number> = model.w): number {
  let z = 0;
  for (const i of features(d)) z += w[i];
  return 1 / (1 + Math.exp(-z));
}

// Plain-language reasons the swarm may split. Doubles as the rephrase hint.
export function hints(d: Draft): string[] {
  const h: string[] = [];
  if (REALTIME.test(d.question)) h.push("asks about a moving target, pin a date or block");
  if (FUTURE.test(d.question)) h.push("asks about the future, the swarm only attests to things that already happened");
  if (UNKNOWABLE.test(d.question)) h.push("no single verifiable answer exists");
  if (!CONSTRAINT.test(d.question)) h.push("no answer format given, add e.g. “Answer with the year only”");
  if (/\?.*\?/s.test(d.question)) h.push("asks two things at once, split it");
  if (d.question.length > 450) h.push("very long, long questions split panels more often");
  return h;
}

export const riskLabel = (p: number) => (p < 0.05 ? "low" : p < 0.2 ? "medium" : "high");
