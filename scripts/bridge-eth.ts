// Bridge ETH from the house wallet on Ethereum to the same address on Robinhood Chain, through the
// canonical Arbitrum bridge (Delayed Inbox.depositEth). Arrives in ~10 minutes.
//   bun scripts/bridge-eth.ts 0.005           bridge an exact amount
//   bun scripts/bridge-eth.ts all             bridge everything except gas + a keeper reserve
//   bun scripts/bridge-eth.ts all --keep 0    bridge everything except gas
//   add --dry to print the numbers without sending
// The reserve (default 0.0005 ETH) pays the keeper's resolve/settle calls for markets still open on
// Ethereum. Inbox from docs.robinhood.com/chain/protocol-contracts, checked onchain:
// inbox.bridge() = Bridge, bridge.allowedDelayedInboxes(inbox) = true, rollup.chainId() = 4663.
// IMD is not bridged: the canonical gateway would mint a different token than the IMD that IMD's
// contracts use on Robinhood Chain (0x5f7b…).
import { createPublicClient, createWalletClient, http, parseAbi, parseEther, formatEther, encodeFunctionData, type Hex } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const INBOX = "0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D" as const;
const ROLLUP = "0x23A19d23e89166adedbDcB432518AB01e4272D94" as const;
const abi = parseAbi(["function depositEth() payable returns (uint256)"]);
const args = process.argv.slice(2);
const ki = args.indexOf("--keep");
const keep = parseEther(ki >= 0 ? args[ki + 1] : "0.0005");
const arg = args.find((a, i) => !a.startsWith("--") && (ki < 0 || i !== ki + 1)) ?? "0.005";

const t = http(process.env.ETH_RPC_URL), account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as Hex);
const c = createPublicClient({ chain: mainnet, transport: t }), w = createWalletClient({ account, chain: mainnet, transport: t });

const rollupChain = await c.readContract({ address: ROLLUP, abi: parseAbi(["function chainId() view returns (uint256)"]), functionName: "chainId" } as any);
if (rollupChain !== 4663n) throw new Error(`rollup chainId ${rollupChain}, expected 4663`);
const pending = await c.getTransactionCount({ address: account.address, blockTag: "pending" });
const latest = await c.getTransactionCount({ address: account.address, blockTag: "latest" });
if (pending !== latest) throw new Error(`${pending - latest} tx still pending from this wallet; wait for it to confirm first`);

const bal = await c.getBalance({ address: account.address });
const fees = await c.estimateFeesPerGas();
const maxFee = fees.maxFeePerGas! * 2n; // headroom so a base-fee bump does not strand the tx
const gas = (await c.estimateGas({ account: account.address, to: INBOX, data: encodeFunctionData({ abi, functionName: "depositEth" }), value: 1n })) * 13n / 10n;
const gasCost = gas * maxFee;
const amount = arg === "all" ? bal - gasCost - keep : parseEther(arg);
if (amount <= 0n || amount + gasCost > bal) throw new Error(`not enough ETH: balance ${formatEther(bal)}, gas ≤${formatEther(gasCost)}, keep ${formatEther(keep)}`);

console.log(`Bridging ${formatEther(amount)} ETH from ${account.address} to Robinhood Chain`);
console.log(`  balance ${formatEther(bal)} · gas ≤${formatEther(gasCost)} · left on Ethereum ≈${formatEther(bal - amount - gasCost)}+ (keep ${formatEther(keep)})`);
if (args.includes("--dry")) process.exit(0);
const { request } = await c.simulateContract({ account, address: INBOX, abi, functionName: "depositEth", value: amount, gas, maxFeePerGas: maxFee, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
const h = await w.writeContract(request);
console.log("tx", `https://etherscan.io/tx/${h}`);
const r = await c.waitForTransactionReceipt({ hash: h });
console.log("status", r.status, "· shows on Robinhood Chain in ~10 min: bun scripts/balance.ts");
