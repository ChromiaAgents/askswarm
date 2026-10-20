// Open a SwarmMarket from the house wallet: bun scripts/open-market.ts "<q>" <closeAtISO> <resolveAfterISO> [seedNoIMD]
// The optional seed stakes the house on NO, so a YES winner is paid more than their stake back.
import { createPublicClient, createWalletClient, http, parseAbi, erc20Abi, stringToHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE } from "../lib/chains";
const mainnet = ACTIVE.viem; // ACTIVE_CHAIN_ID picks the chain (4663 Robinhood, 1 Ethereum)
import * as imd from "../packages/imd/src/index";
const [q, closeIso, afterIso, seedNo] = process.argv.slice(2);
const seed = seedNo ? BigInt(Math.round(Number(seedNo) * 1e18)) : 0n;
const M = ACTIVE.market as Hex, IMD = ACTIVE.imd;
const t = http(ACTIVE.rpc), pub = createPublicClient({ chain: mainnet, transport: t });
const w = createWalletClient({ account: privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex), chain: mainnet, transport: t });
const chk = await imd.check(q, 15, ACTIVE.id as any);
if (!chk.request || chk.request.answerType !== "bool" || (chk.blockers ?? []).some((b) => b.code !== "not_answerable")) throw new Error("not a usable yes/no question: " + JSON.stringify(chk.blockers));
const send = async (r: any) => { const h = await w.writeContract(r); await pub.waitForTransactionReceipt({ hash: h, timeout: 600_000 }); return h; };
await send({ address: IMD, abi: erc20Abi, functionName: "approve", args: [M, 500000000000000000n + seed] });
const h = await send({ address: M, abi: parseAbi(["function open(bytes body, uint64 closeAt, uint64 resolveAfter) returns (uint256)"]), functionName: "open", args: [stringToHex(JSON.stringify(chk.request)), BigInt(Date.parse(closeIso) / 1000), BigInt(Date.parse(afterIso) / 1000)] });
const rc = await pub.getTransactionReceipt({ hash: h });
const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === M.toLowerCase())!.topics[1]!);
console.log(`opened #${id} ${h}\nhttps://askswarm.evalengine.ai/market?id=${id}&c=${ACTIVE.id}`);
if (seed) console.log("seeded NO", await send({ address: M, abi: parseAbi(["function stake(uint256 id, bool yes, uint128 amount)"]), functionName: "stake", args: [id, false, seed] }));
process.exit(0);
