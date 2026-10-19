// Open a SwarmMarket from the house wallet without staking: bun scripts/open-market.ts "<q>" <closeAtISO> <resolveAfterISO>
import { createPublicClient, createWalletClient, http, parseAbi, erc20Abi, stringToHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import * as imd from "../packages/imd/src/index";
const [q, closeIso, afterIso] = process.argv.slice(2);
const M = process.env.MARKET_ADDRESS as Hex, IMD = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Hex;
const t = http(process.env.ETH_RPC_URL), pub = createPublicClient({ chain: mainnet, transport: t });
const w = createWalletClient({ account: privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex), chain: mainnet, transport: t });
const chk = await imd.check(q, 15);
if (!chk.request || chk.request.answerType !== "bool" || (chk.blockers ?? []).some((b) => b.code !== "not_answerable")) throw new Error("not a usable yes/no question: " + JSON.stringify(chk.blockers));
const send = async (r: any) => { const h = await w.writeContract(r); await pub.waitForTransactionReceipt({ hash: h, timeout: 600_000 }); return h; };
await send({ address: IMD, abi: erc20Abi, functionName: "approve", args: [M, 500000000000000000n] });
const h = await send({ address: M, abi: parseAbi(["function open(bytes body, uint64 closeAt, uint64 resolveAfter) returns (uint256)"]), functionName: "open", args: [stringToHex(JSON.stringify(chk.request)), BigInt(Date.parse(closeIso) / 1000), BigInt(Date.parse(afterIso) / 1000)] });
const rc = await pub.getTransactionReceipt({ hash: h });
const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === M.toLowerCase())!.topics[1]!);
console.log(`opened #${id} ${h}\nhttps://askswarm-nine.vercel.app/market?id=${id}`);
process.exit(0);
