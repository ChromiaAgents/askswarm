// Hire the swarm to audit and deploy contracts/ through the IMD protocol (hackathon criterion 1).
//   bun scripts/launch.ts            dry run: free check only, prints blockers/plan
//   bun scripts/launch.ts --pay      quote + x402 pay 0.5 IMD + submit, then follow job → launch
// Body shape per imd.fun/docs "Launches": objective + repoUrl/baseCommit (public GitHub, Foundry),
// onchain evm_contracts, chainId 1, owner = our wallet (prize wallet; the factory is the literal deployer).
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import * as imd from "../packages/imd/src/index";

const PAY = process.argv.includes("--pay");
const token = process.env.IMD_PAID_TOKEN!;
const signer = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as `0x${string}`);
const OWNER = (process.env.PRIZE_WALLET ?? signer.address).toLowerCase();
const REG_DIR = process.env.REGISTRY_DIR ?? "../askswarm-registry";
const repoUrl = "https://github.com/ChromiaAgents/askswarm-registry";
const baseCommit = execSync(`git -C ${REG_DIR} rev-parse HEAD`).toString().trim();
const objective = readFileSync(`${REG_DIR}/LAUNCH.md`, "utf8").trim();

const input = {
  objective,
  repoUrl,
  baseCommit,
  onchain: "evm_contracts",
  chainId: Number(process.env.LAUNCH_CHAIN_ID ?? 1),
  owner: OWNER,
  github: true,
  contracts: ["src/AskSwarmRegistry.sol"],
  // From-your-repo launches start with an audit of the import, then adaptation; the planner adds its
  // own audit panel at the end (explorer.imd.fun/launch "Contracts" tab does the same).
  shape: "chain",
  references: ["solidity-security-review"],
  steps: [
    { skill: "audit-imported-code", references: ["pashov-skill", "pashov-xray", "tob-entry-point-analyzer"] },
    { skill: "adapt-contract-project" },
    { skill: "adversarial-review" },
  ],
};
const t0 = Date.now();
const step = (s: string, v?: unknown) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s] ${s}`, v === undefined ? "" : JSON.stringify(v, null, 1).slice(0, 2000));

const chk = await imd.checkAction("launch.open", input);
step("check", { blockers: chk.blockers, suggestions: chk.suggestions, kind: chk.kind, plan: chk.plan });
if (chk.blockers?.length) process.exit(1);
if (!PAY) { step("dry run ok; rerun with --pay to spend 0.5 IMD"); process.exit(0); }

const order = await imd.quote(token, crypto.randomUUID(), input, "launch.open");
step("quoted", { orderId: order.id, amount: order.quote.payment.amount });
const sub = await imd.paySubmit(token, order.id, signer);
step(`submit ${sub.status}`, sub.body);
const admitted = await imd.pollUntil(() => imd.getOrder(token, order.id), (o) => ["admitted", "payment_failed", "expired"].includes(o.status) || o.admission?.result?.kind === "refused");
step("order", { status: admitted.status, admission: admitted.admission });
const jobId = (admitted.admission as any)?.result?.jobId;
if (!jobId) process.exit(1);
console.log(`job: ${imd.IMD_API}/jobs/${jobId}\nexplorer: https://explorer.imd.fun/jobs/${jobId}`);

// Follow until the launch is live (observed 50 min to 2h20m).
const launch = await imd.pollUntil(async () => {
  const job: any = await (await fetch(`${imd.IMD_API}/jobs/${jobId}`)).json();
  const lid = job?.launch?.id;
  const l: any = lid ? await (await fetch(`${imd.IMD_API}/launches/${lid}`)).json() : null;
  step(`job ${job?.state} launch ${l?.status ?? "-"}`);
  return { job, l };
}, ({ job, l }) => ["live", "parked", "failed"].includes(l?.status) || ["failed", "cancelled", "blocked"].includes(job?.state), { every: 60_000, timeoutMs: 4 * 60 * 60_000 });
step("launch", launch.l);
process.exit(launch.l?.status === "live" ? 0 : 1);
