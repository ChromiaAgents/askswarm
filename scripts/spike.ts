// DAY-1 GATE. bun scripts/spike.ts "Did Argentina win the 2022 FIFA World Cup?"
// Exit 0 only when a verified attestation comes back. Costs 0.5 IMD per run.
import { privateKeyToAccount } from "viem/accounts";
import * as imd from "../packages/imd/src/index";

const question = process.argv.slice(2).join(" ").trim();
if (!question) { console.error("usage: bun scripts/spike.ts <question>"); process.exit(2); }

const token = must("IMD_PAID_TOKEN");
const signer = privateKeyToAccount(must("EVM_PRIVATE_KEY") as `0x${string}`);
const panelSize = Number(process.env.IMD_PANEL_SIZE ?? 15);
const t0 = Date.now();
const step = (s: string, v?: unknown) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s] ${s}`, v === undefined ? "" : JSON.stringify(v, null, 1).slice(0, 1200));

step("payer", signer.address);

// 1. free precheck, take drafted request verbatim
const chk = await imd.check(question, panelSize);
if (chk.blockers?.length) { step("BLOCKED", chk.blockers); process.exit(1); }
if (!chk.request) { step("no drafted request", chk); process.exit(1); }
step("check ok", chk.request);

// 2. quote
const requestKey = crypto.randomUUID();
const order = await imd.quote(token, requestKey, chk.request);
step("quoted", { orderId: order.id, expiresAt: order.quote.expiresAt, amount: order.quote.payment.amount });

// 3+4. 402 -> sign x2 -> submit
const sub = await imd.paySubmit(token, order.id, signer);
step(`submit ${sub.status}`, sub.body);

// 5. admission
const admitted = await imd.pollUntil(
  () => imd.getOrder(token, order.id),
  (o) => ["admitted", "payment_failed", "expired"].includes(o.status) || o.admission?.result?.kind === "refused",
);
step("order", { status: admitted.status, admission: admitted.admission });
const requestId = admitted.admission?.result?.requestId;
if (admitted.status !== "admitted" || !requestId) { console.error("NOT ADMITTED"); process.exit(1); }

// 6. oracle outcome
const terminal = new Set(["attested", "disagreed", "blocked", "mismatch", "refused", "failed"]);
const outcome = await imd.pollUntil(() => imd.oracleStatus(requestId), (s) => terminal.has(s.status), { every: 10_000 });
step("oracle", { status: outcome.status, agreed: outcome.agreement?.agreed, jobUrl: outcome.jobUrl, failure: outcome.failure });
if (outcome.status !== "attested") { console.error("NO ATTESTATION:", outcome.status); process.exit(1); }

const att = await imd.pollUntil(() => imd.attestation(requestId), (a) => a !== null, { every: 5000, timeoutMs: 5 * 60_000 });
const valid = await imd.verifyAttestation(att!);
step("attestation", { valid, signer: att!.signer, answer: att!.message.answer, figure: att!.message.figure, agreed: att!.message.agreed, quorum: att!.message.quorum, panelSize: att!.message.panelSize });
console.log(`explorer: https://explorer.imd.fun/jobs/${admitted.admission?.result?.jobId}`);
console.log(`attestation: ${imd.IMD_API}/oracle/requests/${requestId}/attestation`);
process.exit(valid ? 0 : 1);

function must(k: string): string {
  const v = process.env[k];
  if (!v) { console.error(`missing env ${k}`); process.exit(2); }
  return v;
}
