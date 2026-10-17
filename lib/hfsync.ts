// Dataset flywheel: every answer the registry recorded goes back into the open dataset the split-risk
// model trains on (huggingface.co/datasets/evalengine/imd-oracle-outcomes), as
// contrib/askswarm/answers.jsonl. One commit per run, whole file replaced; idempotent.
// Needs HF_TOKEN with write access to the evalengine org. Off (returns null) without it.
import { rows } from "../functions/answers";

const REPO = process.env.HF_DATASET ?? "evalengine/imd-oracle-outcomes";
const PATH = "contrib/askswarm/answers.jsonl";

export async function syncToHuggingFace(): Promise<{ rows: number; commit?: string } | null> {
  const token = process.env.HF_TOKEN;
  if (!token) return null;
  const all = await rows();
  const terminal = all.filter((r) => r.status !== "pending");
  const lines = terminal.map((r) => JSON.stringify({
    source: "askswarm-registry",
    chainId: 1,
    registry: r.registry,
    intakeRequestId: r.requestId,
    question: r.question,
    input_json: JSON.stringify(r.body),
    answerType: r.answerType ?? r.body?.answerType ?? null,
    answer: r.answer ?? null,
    answer_raw: r.answerRaw ?? null,
    agreed: r.agreed ?? null,
    quorum: r.quorum ?? null,
    panelSize: r.panelSize ?? r.body?.panelSize ?? null,
    expiresAt: r.expiresAt ?? null,
    questionHash: r.questionHash ?? null,
    observed_status: r.status === "answered" ? "attested" : r.status === "no result" ? "disagreed" : r.status,
    label: r.status === "answered" ? 0 : r.status === "no result" ? 1 : null,
    verified_onchain: r.verified ?? false,
    ask_tx: r.askTx,
    result_tx: r.resultTx ?? null,
    block: r.block,
  }));
  const content = lines.join("\n") + "\n";
  // HF commit API: NDJSON, a header line then one file op with base64 content.
  const body = [
    JSON.stringify({ key: "header", value: { summary: `askswarm: ${terminal.length} registry answers`, description: "Appended by AskSwarm (github.com/ChromiaAgents/askswarm). Each row is one oracle.request paid through AskSwarmRegistry on Ethereum, with the onchain verification result." } }),
    JSON.stringify({ key: "file", value: { path: PATH, content: Buffer.from(content).toString("base64"), encoding: "base64" } }),
  ].join("\n");
  const res = await fetch(`https://huggingface.co/api/datasets/${REPO}/commit/main`, {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/x-ndjson" }, body,
  });
  if (!res.ok) throw new Error(`hf commit ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const j: any = await res.json();
  return { rows: terminal.length, commit: j.commitOid ?? j.commitUrl };
}
