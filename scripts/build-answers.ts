// bun scripts/build-answers.ts <raw/oracle-requests.jsonl>   (gunzip the HF file first)
// Writes lib/answers.json: one row per distinct attested question, latest wins. Used by lib/recall.ts
// to show a prior signed swarm answer for free before anyone pays.
import { readFileSync, writeFileSync } from "node:fs";
import { hexToString } from "viem";

const rows = readFileSync(process.argv[2], "utf8").trim().split("\n").map((l) => JSON.parse(l).body);
const text = (t: string, att: any): string => {
  const f = att.figure;
  // The signed answer bytes decide; `figure` is 0 for bool attestations, which once read as "No" for all.
  if (t === "bool") { try { if (att.answer && att.answer !== "0x") return BigInt(att.answer) !== 0n ? "Yes" : "No"; } catch {} return f === "1" || f === 1 || f === true || f === "true" ? "Yes" : "No"; }
  if (t === "bytes32") { try { const s = hexToString(att.answer).replace(/\0+$/, ""); if (s && /^[\x20-\x7e]+$/.test(s)) return s; } catch {} }
  return f != null ? String(f) : String(att.answer);
};
const norm = (q: string) => q.toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
const byQ = new Map<string, any>();
for (const b of rows) {
  if (b.status !== "attested" || !b.attestation) continue;
  const k = norm(b.question), prev = byQ.get(k);
  if (prev && prev.at >= b.attestedAt) continue;
  byQ.set(k, { q: b.question, t: b.answerType, a: text(b.answerType, b.attestation), agreed: b.agreement?.agreed ?? b.attestation.agreed, panel: b.panelSize, id: b.id, at: b.attestedAt });
}
const out = [...byQ.values()];
writeFileSync("lib/answers.json", JSON.stringify(out));
console.log(`wrote lib/answers.json: ${out.length} questions, ${(JSON.stringify(out).length / 1024).toFixed(0)} KB`);
