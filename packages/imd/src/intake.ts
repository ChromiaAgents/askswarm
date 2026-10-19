// Onchain intake path (imd.fun/docs#intake). One tx buys an oracle question; no token, no x402.
// Sepolia sells oracle.request only, and its IMD is a free mintable test token. Used for the demo.
import {
  createPublicClient, createWalletClient, erc20Abi, http, parseAbi, stringToHex,
  type Hex, type PrivateKeyAccount,
} from "viem";
import { mainnet, sepolia } from "viem/chains";
import { IMD_API, ImdError, type OracleRequestBody } from "./index";
import { CHAINS as NET, robinhood, transportFor } from "../../../lib/chains";

export const INTAKE = "0xa43e6f75ee006411f79ac1c84120606c2330de82" as const; // Intakev2, same on every chain
export const PRICE = 500000000000000000n; // 0.5 IMD
export const CHAINS = {
  11155111: { chain: sepolia, imd: "0x44a1cd38474fb1748400e7deb5f8d786cce3f89a" as Hex, rpcEnv: "SEPOLIA_RPC_URL", free: true },
  1: { chain: mainnet, imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as Hex, rpcEnv: "ETH_RPC_URL", free: false },
  4663: { chain: robinhood, imd: "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127" as Hex, rpcEnv: "RH_RPC_URL", free: false },
} as const;
export type IntakeChainId = keyof typeof CHAINS;

export const intakeAbi = parseAbi([
  "function request(bytes32 action, bytes body, (address target, bytes4 selector) callback, address asset, uint256 amount) returns (bytes32 requestId)",
]);
const mintAbi = parseAbi(["function mint(address to, uint256 amount)"]);
export const ACTION_ID = stringToHex("oracle.request@oracle-1", { size: 32 });

// AskSwarmRegistry (src/AskSwarmRegistry.sol): pays Intake with itself as callback and keeps every
// verified answer onchain. When a chain has a registry configured (lib/chains), paid asks on that chain
// go through it instead of calling Intake directly, so each answer bought becomes public memory.
export const registryFor = (chainId: number) => (NET[chainId]?.registries[0] ?? null) as Hex | null;
export const registryAbi = parseAbi([
  "function ask(bytes body) returns (bytes32 requestId)",
  "function price() view returns (uint256)",
  "function latestFor(bytes32 questionHash) view returns (bytes32)",
  "function get(bytes32 requestId) view returns ((address asker, uint64 askedAt, uint8 status) k, (bytes32 questionHash, bytes answer, bytes32 answerHash, uint8 answerType, uint16 panelSize, uint16 quorum, uint16 agreed, uint64 issuedAt, uint64 expiresAt, bool verified) a)",
  "function answerOf(bytes32 questionHash) view returns (bytes32 requestId, (bytes32 questionHash, bytes answer, bytes32 answerHash, uint8 answerType, uint16 panelSize, uint16 quorum, uint16 agreed, uint64 issuedAt, uint64 expiresAt, bool verified) a)",
]);

const rpc = (chainId: IntakeChainId) => (NET[chainId] ? transportFor(NET[chainId]) : http(process.env[CHAINS[chainId].rpcEnv]));

export function clients(chainId: IntakeChainId, account: PrivateKeyAccount) {
  const c = CHAINS[chainId];
  const transport = rpc(chainId);
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

/** Approve the payee (Intake, or the registry when set) to pull IMD. Idempotent. */
export async function ensureAllowance(chainId: IntakeChainId, account: PrivateKeyAccount, cap = PRICE * 20n) {
  const { cfg, pub, wallet } = clients(chainId, account);
  const spender = registryFor(chainId) ?? INTAKE;
  const allowance = await pub.readContract({ address: cfg.imd, abi: erc20Abi, functionName: "allowance", args: [account.address, spender] });
  if (allowance >= cap) return null;
  const hash = await wallet.writeContract({ address: cfg.imd, abi: erc20Abi, functionName: "approve", args: [spender, cap] });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

/** Arguments for Intakev2.request, for a wallet other than the house (the Pay-with-IMD page). */
export const requestArgs = (chainId: IntakeChainId, body: OracleRequestBody) =>
  [ACTION_ID, stringToHex(JSON.stringify(body)), { target: "0x0000000000000000000000000000000000000000", selector: "0x00000000" }, CHAINS[chainId].imd, PRICE] as const;

/** Body for a registry ask: names the registry as the EIP-712 consumer explicitly. The docs say the
 *  callback contract is the domain anyway; every live attestation we sampled carried `consumer`, so
 *  we send it too. The contract's domain is address(this), so both roads lead to the same digest. */
export const registryBody = (chainId: IntakeChainId, body: OracleRequestBody) => {
  const reg = registryFor(chainId);
  return reg ? { ...body, consumer: { chainId, verifyingContract: reg.toLowerCase() } } : body;
};

/** Pays 0.5 IMD and asks. Returns tx hash; the plane indexes it at GET /intake/:chainId/:tx.
 *  Through the registry when REGISTRY_ADDRESS is set (same Requested event, callback = registry). */
export async function ask(chainId: IntakeChainId, account: PrivateKeyAccount, body: OracleRequestBody): Promise<Hex> {
  const { wallet } = clients(chainId, account);
  const reg = registryFor(chainId);
  if (reg) {
    return wallet.writeContract({ address: reg, abi: registryAbi, functionName: "ask", args: [stringToHex(JSON.stringify(registryBody(chainId, body)))] });
  }
  // ponytail: no nonce manager; one hot wallet, low volume. Add viem nonceManager if webhooks ever overlap.
  return wallet.writeContract({
    address: INTAKE, abi: intakeAbi, functionName: "request",
    args: requestArgs(chainId, body),
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

/** Onchain memory: the registry's latest verified answer for a question hash, or null. */
export async function registryAnswer(chainId: IntakeChainId, questionHash: Hex) {
  const reg = registryFor(chainId); if (!reg) return null;
  const c = CHAINS[chainId];
  const pub = createPublicClient({ chain: c.chain, transport: rpc(chainId) });
  const [requestId, a] = await pub.readContract({ address: reg, abi: registryAbi, functionName: "answerOf", args: [questionHash] });
  return a.verified ? { requestId, ...a } : null;
}

/** Onchain memory by Intake request id: what the registry recorded for this exact ask, or null. */
export async function registryRecord(chainId: IntakeChainId, intakeRequestId: Hex) {
  const reg = registryFor(chainId); if (!reg) return null;
  const c = CHAINS[chainId];
  const pub = createPublicClient({ chain: c.chain, transport: rpc(chainId) });
  const [k, a] = await pub.readContract({ address: reg, abi: registryAbi, functionName: "get", args: [intakeRequestId] });
  const status = (["none", "pending", "answered", "refused", "no result", "unverified"] as const)[k.status] ?? "?";
  return { status, verified: a.verified, agreed: a.agreed, panelSize: a.panelSize };
}
