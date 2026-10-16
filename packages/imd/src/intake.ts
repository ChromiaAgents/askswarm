// Onchain intake path (imd.fun/docs#intake). One tx buys an oracle question; no token, no x402.
// Sepolia sells oracle.request only, and its IMD is a free mintable test token. Used for the demo.
import {
  createPublicClient, createWalletClient, erc20Abi, http, parseAbi, stringToHex,
  type Hex, type PrivateKeyAccount,
} from "viem";
import { mainnet, sepolia } from "viem/chains";
import { IMD_API, ImdError, type OracleRequestBody } from "./index";

export const INTAKE = "0xa43e6f75ee006411f79ac1c84120606c2330de82" as const; // Intakev2, same on every chain
export const PRICE = 500000000000000000n; // 0.5 IMD
export const CHAINS = {
  11155111: { chain: sepolia, imd: "0x44a1cd38474fb1748400e7deb5f8d786cce3f89a" as Hex, rpcEnv: "SEPOLIA_RPC_URL", free: true },
  1: { chain: mainnet, imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Hex, rpcEnv: "ETH_RPC_URL", free: false },
} as const;
export type IntakeChainId = keyof typeof CHAINS;

const intakeAbi = parseAbi([
  "function request(bytes32 action, bytes body, (address target, bytes4 selector) callback, address asset, uint256 amount) returns (bytes32 requestId)",
]);
const mintAbi = parseAbi(["function mint(address to, uint256 amount)"]);
const ACTION_ID = stringToHex("oracle.request@oracle-1", { size: 32 });

export function clients(chainId: IntakeChainId, account: PrivateKeyAccount) {
  const c = CHAINS[chainId];
  const transport = http(process.env[c.rpcEnv]);
  return {
    cfg: c,
    pub: createPublicClient({ chain: c.chain, transport }),
    wallet: createWalletClient({ account, chain: c.chain, transport }),
  };
}

/** Sepolia only: mint free IMDtest to self. */
export async function mintTest(chainId: IntakeChainId, account: PrivateKeyAccount, amount = PRICE * 20n) {
  const { cfg, pub, wallet } = clients(chainId, account);
  if (!cfg.free) throw new Error("mint only on testnet");
  const hash = await wallet.writeContract({ address: cfg.imd, abi: mintAbi, functionName: "mint", args: [account.address, amount] });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

/** Approve intake to pull IMD. Idempotent: skips when allowance already covers `cap`. */
export async function ensureAllowance(chainId: IntakeChainId, account: PrivateKeyAccount, cap = PRICE * 20n) {
  const { cfg, pub, wallet } = clients(chainId, account);
  const allowance = await pub.readContract({ address: cfg.imd, abi: erc20Abi, functionName: "allowance", args: [account.address, INTAKE] });
  if (allowance >= cap) return null;
  const hash = await wallet.writeContract({ address: cfg.imd, abi: erc20Abi, functionName: "approve", args: [INTAKE, cap] });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

/** Pays 0.5 IMD and asks. Returns tx hash; the plane indexes it at GET /intake/:chainId/:tx. */
export async function ask(chainId: IntakeChainId, account: PrivateKeyAccount, body: OracleRequestBody): Promise<Hex> {
  const { cfg, wallet } = clients(chainId, account);
  // ponytail: no nonce manager; one hot wallet, low volume. Add viem nonceManager if webhooks ever overlap.
  return wallet.writeContract({
    address: INTAKE, abi: intakeAbi, functionName: "request",
    args: [ACTION_ID, stringToHex(JSON.stringify(body)), { target: "0x0000000000000000000000000000000000000000", selector: "0x00000000" }, cfg.imd, PRICE],
  });
}

export interface IntakeEntry {
  logIndex: number; kind: string; state: string; reason?: string; detail?: unknown;
  requestId?: string; action?: string;
  order?: { id?: string; status?: string };
  admission?: { result?: { kind: string; requestId?: string; jobId?: string; attestationUrl?: string; problems?: unknown } };
  completion?: unknown;
}

/** 404 unknown_transaction until the plane has seen the tx (needs `confirmations`, 2 on mainnet). */
export async function readIntake(chainId: IntakeChainId, tx: Hex): Promise<{ entries: IntakeEntry[] } | null> {
  const res = await fetch(`${IMD_API}/intake/${chainId}/${tx}`);
  if (res.status === 404) return null;
  const text = await res.text();
  let body: any = text; try { body = JSON.parse(text); } catch {}
  if (!res.ok) throw new ImdError(res.status, body);
  return body;
}

/** Oracle request UUID once admitted, else null. Throws on refusal. */
export function oracleRequestIdFrom(r: { entries: IntakeEntry[] } | null): string | null {
  const e = r?.entries?.[0];
  if (!e) return null;
  if (e.state === "refused" || e.admission?.result?.kind === "refused") throw new Error(`intake refused: ${e.reason ?? JSON.stringify(e.admission?.result?.problems ?? e.detail)}`);
  return e.admission?.result?.requestId ?? null;
}
