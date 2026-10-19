// Onchain-door gate. bun scripts/spike-sepolia.ts "Did Argentina win the 2022 FIFA World Cup?"
// Sepolia by default (free, mints IMDtest). SPIKE_CHAIN=1 runs the same path on mainnet: costs 0.5 IMD + gas.
// Exit 0 = verified attestation.
import { formatEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import * as imd from "../packages/imd/src/index";
import * as intake from "../packages/imd/src/intake";

const question = process.argv.slice(2).join(" ").trim() || "Did Argentina win the 2022 FIFA World Cup?";
const account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as `0x${string}`);
const CHAIN = Number(process.env.SPIKE_CHAIN ?? 11155111) as intake.IntakeChainId;
const t0 = Date.now();
const step = (s: string, v?: unknown) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s] ${s}`, v === undefined ? "" : JSON.stringify(v).slice(0, 1000));

const { pub, cfg } = intake.clients(CHAIN, account);
const eth = await pub.getBalance({ address: account.address });
step("wallet", { chain: CHAIN, address: account.address, eth: formatEther(eth) });
if (eth === 0n) { console.error("fund Sepolia ETH first: https://cloud.google.com/application/web3/faucet/ethereum/sepolia"); process.exit(2); }

const chk = await imd.check(question, Number(process.env.IMD_PANEL_SIZE ?? 15));
if (chk.blockers?.length || !chk.request) { step("BLOCKED", chk); process.exit(1); }
step("check ok", chk.request);

const bal = await pub.readContract({ address: cfg.imd, abi: (await import("viem")).erc20Abi, functionName: "balanceOf", args: [account.address] });
if (bal < intake.PRICE) { if (!intake.CHAINS[CHAIN].free) { console.error("need 0.5 IMD"); process.exit(2); } step("minted IMDtest", await intake.mintTest(CHAIN, account)); }
const ap = await intake.ensureAllowance(CHAIN, account);
step("allowance", ap ?? "already ok");

const tx = await intake.ask(CHAIN, account, chk.request);
step("asked tx", tx);
const rcpt = await pub.waitForTransactionReceipt({ hash: tx });
step("receipt", { status: rcpt.status, block: Number(rcpt.blockNumber) });
if (rcpt.status !== "success") process.exit(1);

const requestId = await imd.pollUntil(
  async () => { const r = await intake.readIntake(CHAIN, tx); if (r) step("intake", r.entries?.[0]); return intake.oracleRequestIdFrom(r); },
  (id) => id !== null, { every: 10_000, timeoutMs: 15 * 60_000 },
);
step("oracle requestId", requestId);

const terminal = new Set(["attested", "disagreed", "blocked", "mismatch", "refused", "failed"]);
const outcome = await imd.pollUntil(() => imd.oracleStatus(requestId!), (s) => terminal.has(s.status), { every: 10_000 });
step("oracle", { status: outcome.status, agreed: outcome.agreement?.agreed, jobUrl: outcome.jobUrl, failure: outcome.failure });
if (outcome.status !== "attested") process.exit(1);

const att = await imd.pollUntil(() => imd.attestation(requestId!), (a) => a !== null, { every: 5000, timeoutMs: 5 * 60_000 });
const valid = await imd.verifyAttestation(att!);
step("attestation", { valid, signer: att!.signer, answer: att!.message.answer, figure: att!.message.figure, agreed: att!.message.agreed, quorum: att!.message.quorum });
console.log(`tx: ${CHAIN === 4663 ? "https://robinhoodchain.blockscout.com" : `https://${CHAIN === 1 ? "" : "sepolia."}etherscan.io`}/tx/${tx}\nattestation: ${imd.IMD_API}/oracle/requests/${requestId}/attestation`);
process.exit(valid ? 0 : 1);
