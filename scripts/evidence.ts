// Runs a batch of real asks through the registry on one chain and appends an evidence table to
// docs/EVIDENCE.md: question, tx, oracle request, outcome, onchain verified flag. 0.5 IMD each.
//   bun scripts/evidence.ts [n]                      Ethereum (default)
//   EVIDENCE_CHAIN=4663 bun scripts/evidence.ts 5    Robinhood Chain
import { execSync } from "node:child_process";
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { CHAINS } from "../lib/chains";

const CHAIN = Number(process.env.EVIDENCE_CHAIN ?? 1);
const C = CHAINS[CHAIN];
const REG = C?.registries[0];
if (!REG) { console.error(`no registry configured for chain ${CHAIN}`); process.exit(2); }
const QS = CHAIN === 1 ? [
  "What is the ISO 4217 currency code of the British pound? Answer with the three-letter code only.",
  "In what year did the Black Monday crash occur, when the Dow fell about 22.6% in a single day? Answer with the four-digit year only.",
  "Did Argentina win the 2022 FIFA World Cup?",
  "What is the NASDAQ ticker symbol of Apple Inc.? Answer with the ticker symbol only.",
  "In what year was Ethereum's genesis block mined? Answer with the four-digit year only.",
  "What is the ISO 3166-1 alpha-3 country code of Japan? Answer with the three-letter code only.",
  "How many players does each team field in a standard association football match? Answer with the whole number only.",
  "What is the atomic number of gold? Answer with the whole number only.",
  "Did Bitcoin's genesis block get mined in January 2009?",
] : [
  "What is the Nasdaq ticker symbol of Robinhood Markets, Inc.? Answer with the ticker symbol only.",
  "In what year did Robinhood Markets, Inc. list its shares on the Nasdaq? Answer with the four-digit year only.",
  "Did Ethereum switch from proof of work to proof of stake (the Merge) in 2022?",
  "How many satoshis make up one bitcoin? Answer with the whole number only.",
  "What is the ISO 4217 currency code of the Swiss franc? Answer with the three-letter code only.",
  "Was Sveriges Riksbank, Sweden's central bank, founded before the year 1700?",
  "What is the atomic number of silver? Answer with the whole number only.",
  "In what year was the Bitcoin whitepaper by Satoshi Nakamoto published? Answer with the four-digit year only.",
];
const n = Math.min(QS.length, Number(process.argv[2] ?? QS.length));
const f = "docs/EVIDENCE.md";
if (!existsSync(f)) writeFileSync(f, "# Evidence: real mainnet asks through AskSwarmRegistry\n");
appendFileSync(f, `\n## ${C.name}: ${new Date().toISOString().slice(0, 10)} batch\n\nRegistry [\`${REG}\`](${C.explorer}/address/${REG}), each row is one \`ask(body)\` paid in 0.5 IMD by the house wallet, answered by the swarm and verified onchain in \`onOracleResult\`.\n\n| # | question | ask tx | oracle request | outcome | onchain verified |\n|---|---|---|---|---|---|\n`);
for (let i = 0; i < n; i++) {
  const q = QS[i];
  let out = "";
  try { out = execSync(`SPIKE_CHAIN=${CHAIN} bun scripts/spike-sepolia.ts ${JSON.stringify(q)}`, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 15 * 60_000 }); }
  catch (e: any) { out = String(e.stdout ?? "") + String(e.stderr ?? ""); }
  const tx = out.match(/asked tx "(0x[0-9a-f]{64})"/)?.[1] ?? "";
  const rid = out.match(/oracle requestId "([0-9a-f-]{36})"/)?.[1] ?? "";
  const status = out.match(/oracle \{"status":"([a-z_]+)"/)?.[1] ?? "unknown";
  const answer = out.match(/"answer":"(0x[0-9a-f]+)"/)?.[1] ?? "";
  const intakeId = out.match(/"requestId":"(0x[0-9a-f]{64})"/)?.[1] ?? "";
  let verified = "-";
  if (intakeId) {
    try {
      const got = execSync(`cast call --rpc-url ${C.rpc} ${REG} "get(bytes32)((address,uint64,uint8),(bytes32,bytes,bytes32,uint8,uint16,uint16,uint16,uint64,uint64,bool))" ${intakeId}`, { encoding: "utf8" });
      // Ask status is the last field of the first tuple: 1 Pending, 2 Answered, 3 Refused, 4 NoResult, 5 Unverified.
      // The callback lands a few seconds after the attestation is published, so re-check later if Pending.
      const st = Number(got.trim().split("\n")[0].replace(/\)$/, "").split(",").pop());
      verified = st === 2 && got.trim().endsWith("true)") ? "verified" : ["-", "Pending", "Answered", "Refused", "NoResult", "Unverified"][st] ?? "?";
    } catch {}
  }
  const dec = answer ? Buffer.from(answer.slice(2), "hex").toString("utf8").replace(/\0+$/, "") : "";
  const row = `| ${i + 1} | ${q.replace(/\|/g, "/")} | ${tx ? `[${tx.slice(0, 10)}…](${C.explorer}/tx/${tx})` : "-"} | ${rid ? `[${rid.slice(0, 8)}](https://api.imd.fun/oracle/requests/${rid}/attestation)` : "-"} | ${status}${dec && /^[\x20-\x7e]+$/.test(dec) ? ` · ${dec}` : ""} | ${verified} |\n`;
  appendFileSync(f, row);
  console.log(row.trim());
}
