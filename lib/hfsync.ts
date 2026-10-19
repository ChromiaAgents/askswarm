// Dataset flywheel: every answer the registry recorded goes back into the open dataset the split-risk
// model trains on (huggingface.co/datasets/evalengine/imd-oracle-outcomes), as
// contrib/askswarm/answers.jsonl, and every SwarmMarket bet market as contrib/askswarm/markets.jsonl
// (crowd odds at close next to the swarm's verdict). One commit per run, whole files replaced; idempotent.
// Needs HF_TOKEN with write access to the evalengine org. Off (returns null) without it.
import { formatEther } from "viem";
import { rows } from "../functions/answers";
import { marketRows } from "../functions/markets";

const REPO = process.env.HF_DATASET ?? "evalengine/imd-oracle-outcomes";
const PATH = "contrib/askswarm/answers.jsonl", MARKETS_PATH = "contrib/askswarm/markets.jsonl";

export async function syncToHuggingFace(): Promise<{ rows: number; markets: number; commit?: string } | null> {
  const token = process.env.HF_TOKEN;
  if (!token) return null;
  const all = await rows();
  const terminal = all.filter((r) => r.status !== "pending");
  const lines = terminal.map((r) => JSON.stringify({
    source: "askswarm-registry",
    chainId: r.chainId ?? 1,
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
  // Bets: what the crowd staked versus what the swarm then said. Open markets are included and
  // update on every run; outcome is null until settled.
  const markets = (await marketRows()).sort((x, y) => x.chainId - y.chainId || Number(x.id) - Number(y.id));
  const imd = (v: bigint) => Number(formatEther(v));
  const mLines = markets.map((r) => {
    const atClose = [...r.history].reverse().find((h: any) => h.t <= r.closeAt) ?? r.history[0];
    return JSON.stringify({
      source: "askswarm-market",
      chainId: r.chainId,
      market: r.market,
      marketId: Number(r.id),
      question: r.question,
      input_json: JSON.stringify(r.body),
      closeAt: r.closeAt,
      resolveAfter: r.resolveAfter,
      phase: r.phase,
      outcome: r.phase === "yes" ? true : r.phase === "no" ? false : null,
      void: r.phase === "void",
      yes_pool_imd: imd(r.yesPool),
      no_pool_imd: imd(r.noPool),
      crowd_yes_prob_at_close: atClose ? atClose.yesBps / 10000 : null,
      stakers: r.stakers.size,
      bets: r.trades.length,
      creator: r.creator,
      fee_imd: imd(r.fee),
      intakeRequestId: r.requestId ?? null,
      open_tx: r.openTx,
      resolve_tx: r.resolveTx ?? null,
      settle_tx: r.settleTx ?? null,
    });
  });
  // HF commit API: NDJSON, a header line then one file op with base64 content.
  const body = [
    JSON.stringify({ key: "header", value: { summary: `askswarm: ${terminal.length} registry answers, ${markets.length} bet markets`, description: "Appended by AskSwarm (github.com/ChromiaAgents/askswarm). answers.jsonl: one oracle.request paid through AskSwarmRegistry (Ethereum, Robinhood Chain) per row, with the onchain verification result. markets.jsonl: one SwarmMarket bet market per row, crowd odds at close next to the swarm's settled outcome." } }),
    JSON.stringify({ key: "file", value: { path: PATH, content: Buffer.from(content).toString("base64"), encoding: "base64" } }),
    JSON.stringify({ key: "file", value: { path: MARKETS_PATH, content: Buffer.from(mLines.join("\n") + "\n").toString("base64"), encoding: "base64" } }),
  ].join("\n");
  const res = await fetch(`https://huggingface.co/api/datasets/${REPO}/commit/main`, {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/x-ndjson" }, body,
  });
  if (!res.ok) throw new Error(`hf commit ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const j: any = await res.json();
  return { rows: terminal.length, markets: markets.length, commit: j.commitOid ?? j.commitUrl };
}
