// Bridge ETH from the house wallet on Ethereum to the same address on Robinhood Chain, through the
// canonical Arbitrum bridge (Delayed Inbox.depositEth). Arrives in ~10 minutes.
//   bun scripts/bridge-eth.ts [amountEth=0.005]
// Inbox from docs.robinhood.com/chain/protocol-contracts, checked onchain: inbox.bridge() = Bridge,
// bridge.allowedDelayedInboxes(inbox) = true, rollup.chainId() = 4663.
import { createPublicClient, createWalletClient, http, parseAbi, parseEther, formatEther, type Hex } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const INBOX = "0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D" as const;
const amount = parseEther(process.argv[2] ?? "0.005");
const t = http(process.env.ETH_RPC_URL), account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex);
const c = createPublicClient({ chain: mainnet, transport: t }), w = createWalletClient({ account, chain: mainnet, transport: t });
const rollupChain = await c.readContract({ address: "0x23A19d23e89166adedbDcB432518AB01e4272D94", abi: parseAbi(["function chainId() view returns (uint256)"]), functionName: "chainId" });
if (rollupChain !== 4663n) throw new Error(`rollup chainId ${rollupChain}, expected 4663`);
console.log(`Bridging ${formatEther(amount)} ETH from ${account.address} (balance ${formatEther(await c.getBalance({ address: account.address }))} ETH) to Robinhood Chain`);
const { request } = await c.simulateContract({ account, address: INBOX, abi: parseAbi(["function depositEth() payable returns (uint256)"]), functionName: "depositEth", value: amount });
const h = await w.writeContract(request);
console.log("tx", `https://etherscan.io/tx/${h}`);
const r = await c.waitForTransactionReceipt({ hash: h });
console.log("status", r.status, "· funds show on Robinhood Chain in ~10 min: bun scripts/balance.ts");
