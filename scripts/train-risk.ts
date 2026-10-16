// bun run scripts/train-risk.ts <dir>   dir holds train.jsonl validation.jsonl test.jsonl from
// huggingface.co/datasets/evalengine/imd-oracle-outcomes. Use the snapshots/2026-10-13 split. Writes lib/risk-model.json.
import { readFileSync, writeFileSync } from "node:fs";
import { features, BUCKETS } from "../lib/risk";

const dir = process.argv[2] ?? ".";
const load = (s: string) => readFileSync(`${dir}/${s}.jsonl`, "utf8").trim().split("\n").map((l) => {
  const r = JSON.parse(l); const i = JSON.parse(r.input_json);
  return { x: features({ question: i.question, answerType: i.answerType, panelSize: i.panelSize ?? 0, quorum: i.quorum ?? 0, evidence: i.evidence, validForSeconds: i.validForSeconds, window: i.window }), y: r.label as 0 | 1 };
});
const train = load("train"), val = load("validation"), test = load("test");

const w = new Float64Array(BUCKETS);
const posW = 3, L2 = 1e-3, EPOCHS = 25; // grid-picked on the 2026-10-13 validation split
let seed = 7; const rnd = () => (seed = (seed * 48271) % 2147483647) / 2147483647;
for (let e = 0; e < EPOCHS; e++) {
  const lr = 0.1 / (1 + e * 0.2);
  for (let i = train.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [train[i], train[j]] = [train[j], train[i]]; }
  for (const { x, y } of train) {
    let z = 0; for (const i of x) z += w[i];
    const p = 1 / (1 + Math.exp(-z)), g = (p - y) * (y ? posW : 1);
    for (const i of x) w[i] -= lr * (g + L2 * w[i]);
  }
}

const score = (x: number[]) => { let z = 0; for (const i of x) z += w[i]; return 1 / (1 + Math.exp(-z)); };
const auc = (rows: typeof val) => {
  const s = rows.map((r) => ({ p: score(r.x), y: r.y })).sort((a, b) => a.p - b.p);
  let rank = 0, sumPos = 0, np = 0;
  for (let i = 0; i < s.length; i++) { rank = i + 1; if (s[i].y) { sumPos += rank; np++; } }
  const nn = s.length - np; return (sumPos - (np * (np + 1)) / 2) / (np * nn);
};
const report = (name: string, rows: typeof val, thr: number) => {
  let tp = 0, fp = 0, fn = 0;
  for (const r of rows) { const h = score(r.x) >= thr; if (h && r.y) tp++; else if (h) fp++; else if (r.y) fn++; }
  console.log(`${name}: n=${rows.length} pos=${tp + fn} auc=${auc(rows).toFixed(3)} @${thr}: precision=${(tp / Math.max(tp + fp, 1)).toFixed(2)} recall=${(tp / Math.max(tp + fn, 1)).toFixed(2)} flagged=${tp + fp}`);
};
for (const thr of [0.2, 0.3, 0.5]) { report("val", val, thr); report("test", test, thr); }

writeFileSync("lib/risk-model.json", JSON.stringify({ w: Array.from(w, (v) => +v.toFixed(4)), buckets: BUCKETS, trained: new Date().toISOString().slice(0, 10), n: train.length }));
console.log("wrote lib/risk-model.json");
