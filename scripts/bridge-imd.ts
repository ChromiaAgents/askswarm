// Bridge IMD from Ethereum to the same address on Robinhood Chain. IMD is a LayerZero OFT on both
// chains (same owner; Ethereum IMD 0xd34a… and Robinhood IMD 0x5f7b… are each other's peer), so this
// is the token's own bridge: burn on Ethereum, mint on Robinhood Chain, ~2-5 minutes.
//   bun scripts/bridge-imd.ts all                     house wallet, all its IMD
//   bun scripts/bridge-imd.ts 5                       house wallet, 5 IMD
//   bun scripts/bridge-imd.ts all --gas-from demo     demo wallet first sends the house the ETH it needs
//   bun scripts/bridge-imd.ts all --from demo         bridge the demo wallet's own IMD
//   add --dry to print the numbers without sending
// Track it on https://layerzeroscan.com/tx/<tx>.
import { createPublicClient, createWalletClient, http, parseAbi, parseEther, formatEther, pad, type Hex } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const IMD = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as const;
const RH_IMD = "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127";
const RH_EID = 30416;
const abi = parseAbi([
  "function peers(uint32) view returns (bytes32)",
  "function balanceOf(address) view returns (uint256)",
  "struct SendParam { uint32 dstEid; bytes32 to; uint256 amountLD; uint256 minAmountLD; bytes extraOptions; bytes composeMsg; bytes oftCmd; }",
  "struct MessagingFee { uint256 nativeFee; uint256 lzTokenFee; }",
  "function quoteSend(SendParam _sendParam, bool _payInLzToken) view returns (MessagingFee)",
  "function send(SendParam _sendParam, MessagingFee _fee, address _refundAddress) payable returns ((bytes32 guid, uint64 nonce, MessagingFee fee), (uint256 amountSentLD, uint256 amountReceivedLD))",
]);
const args = process.argv.slice(2);
const flag = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const dry = args.includes("--dry");
const keyOf = (who?: string) => (who === "demo" ? process.env.DEMO_PK : process.env.EVM_PRIVATE_KEY) as Hex;
const from = privateKeyToAccount(keyOf(flag("--from")));
const arg = args.find((a, i) => !a.startsWith("--") && !["--from", "--gas-from"].includes(args[i - 1])) ?? "all";

const t = http(process.env.ETH_RPC_URL);
const c = createPublicClient({ chain: mainnet, transport: t });
const peer = await c.readContract({ address: IMD, abi, functionName: "peers", args: [RH_EID] });
if (peer.toLowerCase() !== pad(RH_IMD as Hex).toLowerCase()) throw new Error(`unexpected peer ${peer}`);

const bal = await c.readContract({ address: IMD, abi, functionName: "balanceOf", args: [from.address] });
let amount = arg === "all" ? bal : parseEther(arg);
amount -= amount % 10n ** 12n; // OFT shared decimals = 6; drop dust below 1e-6 IMD
if (amount <= 0n || amount > bal) throw new Error(`have ${formatEther(bal)} IMD, asked ${arg}`);
const p = { dstEid: RH_EID, to: pad(from.address), amountLD: amount, minAmountLD: amount, extraOptions: "0x" as Hex, composeMsg: "0x" as Hex, oftCmd: "0x" as Hex };
const fee = await c.readContract({ address: IMD, abi, functionName: "quoteSend", args: [p, false] });
const fees = await c.estimateFeesPerGas();
const maxFee = fees.maxFeePerGas! * 2n;
const gasBudget = 250_000n * maxFee;
const need = fee.nativeFee + gasBudget;
const eth = await c.getBalance({ address: from.address });
console.log(`Bridging ${formatEther(amount)} IMD from ${from.address} to Robinhood Chain`);
console.log(`  LayerZero fee ${formatEther(fee.nativeFee)} ETH · gas ≤${formatEther(gasBudget)} ETH · wallet has ${formatEther(eth)} ETH`);

if (eth < need) {
  const g = flag("--gas-from");
  if (!g) throw new Error(`needs ${formatEther(need)} ETH on Ethereum; rerun with --gas-from demo to top it up from the demo wallet`);
  const donor = privateKeyToAccount(keyOf(g));
  const top = need - eth + parseEther("0.00005");
  console.log(`  topping up ${formatEther(top)} ETH from ${g} ${donor.address}`);
  if (!dry) {
    const h = await createWalletClient({ account: donor, chain: mainnet, transport: t }).sendTransaction({ to: from.address, value: top, maxFeePerGas: maxFee, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
    await c.waitForTransactionReceipt({ hash: h }); console.log("  top-up tx", `https://etherscan.io/tx/${h}`);
  }
}
if (dry) process.exit(0);
const w = createWalletClient({ account: from, chain: mainnet, transport: t });
const { request } = await c.simulateContract({ account: from, address: IMD, abi, functionName: "send", args: [p, { nativeFee: fee.nativeFee, lzTokenFee: 0n }, from.address], value: fee.nativeFee, maxFeePerGas: maxFee, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
const h = await w.writeContract(request);
console.log("tx", `https://etherscan.io/tx/${h}`, "·", `https://layerzeroscan.com/tx/${h}`);
const r = await c.waitForTransactionReceipt({ hash: h });
console.log("status", r.status, "· arrives on Robinhood Chain in ~2-5 min: bun scripts/balance.ts");
