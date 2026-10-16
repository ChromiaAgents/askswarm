// One-time: approve Permit2 to spend a capped amount of IMD from the hot wallet. Needs dust ETH.
// bun scripts/approve-permit2.ts [capIMD=25]
import { createPublicClient, createWalletClient, erc20Abi, formatEther, http, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { IMD_TOKEN, PERMIT2 } from "../packages/imd/src/index";

const account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as `0x${string}`);
const transport = http(process.env.ETH_RPC_URL);
const pub = createPublicClient({ chain: mainnet, transport });
const wallet = createWalletClient({ account, chain: mainnet, transport });
const cap = parseEther(process.argv[2] ?? "25"); // IMD is 18 decimals

const [bal, eth, allowance] = await Promise.all([
  pub.readContract({ address: IMD_TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [account.address] }),
  pub.getBalance({ address: account.address }),
  pub.readContract({ address: IMD_TOKEN, abi: erc20Abi, functionName: "allowance", args: [account.address, PERMIT2] }),
]);
console.log({ wallet: account.address, imd: formatEther(bal), eth: formatEther(eth), permit2Allowance: formatEther(allowance) });
if (allowance >= cap) { console.log("allowance already sufficient"); process.exit(0); }

const hash = await wallet.writeContract({ address: IMD_TOKEN, abi: erc20Abi, functionName: "approve", args: [PERMIT2, cap] });
console.log("approve tx", hash);
const rcpt = await pub.waitForTransactionReceipt({ hash });
console.log("status", rcpt.status);
