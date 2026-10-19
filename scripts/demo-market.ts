// Open a live SwarmMarket and take both sides from two wallets; the keeper cron resolves and settles.
//   bun scripts/demo-market.ts "<yes/no question>" <closeInSeconds> <houseYesIMD> <demoNoIMD>
import { createPublicClient, createWalletClient, http, parseAbi, erc20Abi, parseEther, stringToHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTIVE } from "../lib/chains";
const mainnet = ACTIVE.viem; // ACTIVE_CHAIN_ID picks the chain (4663 Robinhood, 1 Ethereum)
import * as imd from "../packages/imd/src/index";

const M = ACTIVE.market as Hex, IMD = ACTIVE.imd;
const [q = "Did Argentina win the 2022 FIFA World Cup?", closeIn = "300", yesAmt = "1", noAmt = "0.1"] = process.argv.slice(2);
const t = http(ACTIVE.rpc);
const pub = createPublicClient({ chain: mainnet, transport: t });
const A = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex), B = privateKeyToAccount(process.env.DEMO_PK as Hex);
const wa = createWalletClient({ account: A, chain: mainnet, transport: t }), wb = createWalletClient({ account: B, chain: mainnet, transport: t });
const abi = parseAbi(["function open(bytes body, uint64 closeAt, uint64 resolveAfter) returns (uint256)", "function stake(uint256 id, bool yes, uint128 amount)"]);
const send = async (w: any, r: any) => { const h = await w.writeContract(r); await pub.waitForTransactionReceipt({ hash: h }); return h; };

const chk = await imd.check(q, 15);
if (!chk.request || chk.request.answerType !== "bool") throw new Error("not a yes/no question");
const yes = parseEther(yesAmt), no = parseEther(noAmt), fee = 500000000000000000n;
await send(wa, { address: IMD, abi: erc20Abi, functionName: "approve", args: [M, yes + fee] });
await send(wb, { address: IMD, abi: erc20Abi, functionName: "approve", args: [M, no] });
const closeAt = BigInt(Math.floor(Date.now() / 1000) + Number(closeIn));
const h = await send(wa, { address: M, abi, functionName: "open", args: [stringToHex(JSON.stringify(chk.request)), closeAt, closeAt] });
const rc = await pub.getTransactionReceipt({ hash: h });
const id = BigInt(rc.logs.find((l) => l.address.toLowerCase() === M.toLowerCase())!.topics[1]!);
console.log("opened", id, h);
console.log("yes", await send(wa, { address: M, abi, functionName: "stake", args: [id, true, yes] }));
console.log("no", await send(wb, { address: M, abi, functionName: "stake", args: [id, false, no] }));
console.log(`https://askswarm-nine.vercel.app/market?id=${id}  closes ${new Date(Number(closeAt) * 1000).toISOString()}`);
process.exit(0);
