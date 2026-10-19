// Live two-party wager on mainnet: house wallet (EVM_PRIVATE_KEY) creates YES, demo wallet (DEMO_PK)
// joins NO, then resolve → swarm → settle. bun scripts/demo-wager.ts "<yes/no question>" [stakeIMD]
import { createPublicClient, createWalletClient, http, parseAbi, erc20Abi, parseEther, stringToHex, formatEther, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE } from "../lib/chains";
const mainnet = ACTIVE.viem; // ACTIVE_CHAIN_ID picks the chain (4663 Robinhood, 1 Ethereum)
import * as imd from "../packages/imd/src/index";

const WAGER = ACTIVE.wager as Hex, IMD = ACTIVE.imd;
const q = process.argv[2] ?? "Did Argentina win the 2022 FIFA World Cup?";
const stake = parseEther(process.argv[3] ?? "1");
const t = http(ACTIVE.rpc);
const pub = createPublicClient({ chain: mainnet, transport: t });
const A = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex), B = privateKeyToAccount(process.env.DEMO_PK as Hex);
const wa = createWalletClient({ account: A, chain: mainnet, transport: t }), wb = createWalletClient({ account: B, chain: mainnet, transport: t });
const abi = parseAbi([
  "function create(bytes body, bool creatorSaysYes, uint96 stake, uint64 joinBy, uint64 resolveAfter) returns (uint256)",
  "function join(uint256 id)", "function resolve(uint256 id)", "function settle(uint256 id)",
  "function get(uint256 id) view returns ((address yes,address no,address creator,uint96 stake,uint96 fee,uint64 joinBy,uint64 resolveAfter,uint64 askedAt,uint8 state,bytes32 requestId,address winner) w, bytes body)",
  "error StillPending()",
]);
const log = (s: string, v?: unknown) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${s}`, v ?? "");
const send = async (w: any, req: any) => { const h = await w.writeContract(req); await pub.waitForTransactionReceipt({ hash: h }); return h; };

const chk = await imd.check(q, 15);
if (!chk.request || chk.request.answerType !== "bool") throw new Error("not a yes/no question the swarm takes");
const fee = 500000000000000000n;
await send(wa, { address: IMD, abi: erc20Abi, functionName: "approve", args: [WAGER, stake + fee] });
await send(wb, { address: IMD, abi: erc20Abi, functionName: "approve", args: [WAGER, stake] });
const now = BigInt(Math.floor(Date.now() / 1000)), joinBy = now + 240n;
const hc = await send(wa, { address: WAGER, abi, functionName: "create", args: [stringToHex(JSON.stringify(chk.request)), true, stake, joinBy, joinBy] });
const rc = await pub.getTransactionReceipt({ hash: hc });
const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === WAGER.toLowerCase())!.topics[1]!);
log(`created #${id}`, hc);
log("joined", await send(wb, { address: WAGER, abi, functionName: "join", args: [id] }));
while (BigInt(Math.floor(Date.now() / 1000)) < joinBy + 15n) await new Promise((r) => setTimeout(r, 10_000));
log("resolve", await send(wa, { address: WAGER, abi, functionName: "resolve", args: [id] }));
for (let i = 0; i < 60; i++) {
  await new Promise((r) => setTimeout(r, 20_000));
  try { const h = await send(wa, { address: WAGER, abi, functionName: "settle", args: [id] }); log("settled", h); break; } catch (e: any) { if (!String(e?.message).includes("StillPending")) { log("settle error", e?.shortMessage ?? e?.message); } }
}
const [w] = await pub.readContract({ address: WAGER, abi, functionName: "get", args: [id] });
log("final", { state: ["none", "open", "matched", "asked", "paid", "refunded"][w.state], winner: w.winner, requestId: w.requestId });
console.log(`https://askswarm-nine.vercel.app/wager?id=${id}`);
process.exit(0);
