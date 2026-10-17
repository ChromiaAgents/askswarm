// IMD oracle client. Pure TS, no Telegram. Every path/field here was seen live in
// api.imd.fun docs (llms.txt "How paying works") or in a real 402 challenge on 2026-10-16.
import { x402Client } from "@x402/core/client";
import { encodePaymentSignatureHeader } from "@x402/core/http";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import {
  sha256,
  stringToBytes,
  verifyTypedData,
  type Hex,
  type PrivateKeyAccount,
} from "viem";

export const IMD_API = process.env.IMD_API ?? "https://api.imd.fun";
export const IMD_TOKEN = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7" as const;
export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as const;
/** Oracle attestation signer seen on every live attestation. Pin it. */
export const ORACLE_SIGNER = "0x5598aa91" as const; // prefix only; full address asserted at runtime via env ORACLE_SIGNER if set

export interface OracleRequestBody {
  v: 1;
  question: string;
  chainId: number;
  window: { hours: number };
  answerType: string;
  evidence: string;
  panelSize: number;
  quorum: number;
  validForSeconds: number;
}

export interface CheckResult {
  action: string;
  blockers: { code: string; detail: string }[];
  suggestions: unknown[];
  request?: OracleRequestBody;
  online?: unknown;
}

export interface Quote {
  v: 1;
  id: string;
  action: string;
  policyVersion: string;
  inputHash: string;
  issuedAt: number;
  expiresAt: number;
  payment: { network: string; asset: Hex; amount: string; payTo: Hex; decimals: number; scheme: string };
  terms: { purchase: string; resultGuaranteed: boolean };
  quoteHash: string;
}

export interface Order {
  id: string;
  status: string;
  quote: Quote;
  payment?: unknown;
  admission?: { result?: { kind: string; requestId?: string; jobId?: string; statusUrl?: string; attestationUrl?: string; problems?: unknown } };
}

export class ImdError extends Error {
  constructor(public status: number, public body: unknown, msg?: string) {
    super(msg ?? `IMD ${status}: ${JSON.stringify(body).slice(0, 400)}`);
  }
}

async function j<T>(res: Response): Promise<T> {
  const text = await res.text();
  let body: unknown = text;
  try { body = JSON.parse(text); } catch {}
  if (!res.ok) throw new ImdError(res.status, body);
  return body as T;
}

const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
const json = { "Content-Type": "application/json" };

/** Free. No token. Returns the drafted request the panel would see. */
/** Free precheck for any paid action body (launch.open, job.open...). */
export async function checkAction(action: string, input: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${IMD_API}/requests/check`, { method: "POST", headers: json, body: JSON.stringify({ action, input }) });
  return j<any>(res);
}

export async function check(question: string, panelSize: number): Promise<CheckResult> {
  // server rejects `quorum` here and derives it (15 -> 11). Limits seen live: panelSize 5..100.
  const res = await fetch(`${IMD_API}/requests/check`, {
    method: "POST", headers: json,
    body: JSON.stringify({ action: "oracle.request", input: { question, panelSize } }),
  });
  return j<CheckResult>(res);
}

export async function quote(token: string, requestKey: string, input: OracleRequestBody | Record<string, unknown>, action = "oracle.request"): Promise<Order> {
  const res = await fetch(`${IMD_API}/requests/quote`, {
    method: "POST", headers: { ...auth(token), ...json },
    body: JSON.stringify({ requestKey, action, input }),
  });
  const body = await j<{ created: boolean; order: Order }>(res);
  return body.order;
}

export async function getOrder(token: string, orderId: string): Promise<Order & { status: string }> {
  return j(await fetch(`${IMD_API}/requests/${orderId}`, { headers: auth(token) }));
}

// canonical JSON: sorted keys, no whitespace. Must match server byte-for-byte for paymentHash.
const canon = (v: any): string =>
  v === null ? "null"
  : Array.isArray(v) ? `[${v.map(canon).join(",")}]`
  : typeof v === "object" ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`
  : JSON.stringify(v);

/**
 * 402 challenge -> x402 Permit2 payload + EIP-712 QuoteApproval -> submit.
 * Wallet needs IMD balance + Permit2 allowance (see scripts/approve-permit2.ts). Server pays gas.
 * Retries reuse the order and never charge twice.
 */
export async function paySubmit(token: string, orderId: string, signer: PrivateKeyAccount): Promise<{ status: number; body: unknown }> {
  const url = `${IMD_API}/requests/${orderId}/submit`;
  const chRes = await fetch(url, { method: "POST", headers: auth(token) });
  if (chRes.status !== 402) throw new ImdError(chRes.status, await chRes.text(), "expected 402 challenge");
  const ch: any = await chRes.json();
  const req = ch.accepts[0];

  // spendControls off: IMD is not a default asset and the server pins the amount in the quote anyway.
  const client = x402Client.fromConfig({ schemes: [{ network: req.network, client: new ExactEvmScheme(signer) }], spendControls: false });
  const { extensions, ...generated } = await client.createPaymentPayload({ x402Version: 2, resource: ch.resource, accepts: [req] });
  // strict shape on server: drop undefined, echo accepted exactly
  const payment = JSON.parse(JSON.stringify({ ...generated, accepted: req }));

  const q: Quote = ch.quote;
  const quoteSignature = await signer.signTypedData({
    domain: { name: "IdentityMD Paid Action", version: "1", chainId: Number(q.payment.network.slice(7)) },
    primaryType: "QuoteApproval",
    types: { QuoteApproval: [
      { name: "resource", type: "string" },
      { name: "requesterScopeHash", type: "bytes32" },
      { name: "quoteId", type: "string" },
      { name: "quoteHash", type: "bytes32" },
      { name: "paymentHash", type: "bytes32" },
      { name: "action", type: "string" },
      { name: "asset", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "payTo", type: "address" },
      { name: "expiresAt", type: "uint256" },
    ] },
    message: {
      resource: ch.resourceUrl,
      requesterScopeHash: `0x${ch.requesterScopeHash}` as Hex,
      quoteId: q.id,
      quoteHash: `0x${q.quoteHash}` as Hex,
      paymentHash: sha256(stringToBytes(canon(payment))),
      action: q.action,
      asset: q.payment.asset,
      amount: BigInt(q.payment.amount),
      payTo: q.payment.payTo,
      expiresAt: BigInt(q.expiresAt),
    },
  });

  const res = await fetch(url, {
    method: "POST",
    headers: { ...auth(token), ...json, "PAYMENT-SIGNATURE": encodePaymentSignatureHeader(payment) },
    body: JSON.stringify({ quoteSignature }),
  });
  const text = await res.text();
  let body: unknown = text; try { body = JSON.parse(text); } catch {}
  if (res.status !== 200 && res.status !== 202) throw new ImdError(res.status, body, "submit rejected");
  return { status: res.status, body };
}

export interface OracleStatus {
  status: string; // assessing|reproducing|attested|disagreed|blocked|mismatch|refused|failed
  agreement?: { agreed?: number };
  failure?: unknown;
  jobUrl?: string;
  members?: unknown[];
}

/** Public read plane. 503 "busy" is normal, caller backs off. */
export async function oracleStatus(requestId: string): Promise<OracleStatus> {
  return j(await fetch(`${IMD_API}/oracle/requests/${requestId}`));
}

export interface Attestation {
  requestId: string;
  domain: any; types: any; primaryType: string;
  message: Record<string, any>;
  signature: Hex; signer: Hex; attestedAt?: string;
}

/** 404 not_attested until signed. */
export async function attestation(requestId: string): Promise<Attestation | null> {
  const res = await fetch(`${IMD_API}/oracle/requests/${requestId}/attestation`);
  if (res.status === 404) return null;
  return j(await Promise.resolve(res));
}

const ANSWER_TYPE_ENUM: Record<string, number> = { bool: 0, address: 1, bytes32: 2, uint256: 3, "address[]": 4, "bytes32[]": 5 };

/** Offline EIP-712 verification. Ported from the verified scratchpad verify.ts. */
export async function verifyAttestation(att: Attestation): Promise<boolean> {
  const m = att.message;
  const message = {
    ...m,
    chainId: BigInt(m.chainId), figure: BigInt(m.figure), fromBlock: BigInt(m.fromBlock), toBlock: BigInt(m.toBlock),
    issuedAt: BigInt(m.issuedAt), expiresAt: BigInt(m.expiresAt),
    answerType: ANSWER_TYPE_ENUM[m.answerType] ?? m.answerType,
  };
  const ok = await verifyTypedData({ domain: att.domain, types: att.types, primaryType: att.primaryType, message, signature: att.signature, address: att.signer });
  const pinned = process.env.ORACLE_SIGNER;
  if (pinned && att.signer.toLowerCase() !== pinned.toLowerCase()) return false;
  return ok && att.signer.toLowerCase().startsWith(ORACLE_SIGNER);
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Poll helper with 503 backoff. */
export async function pollUntil<T>(fn: () => Promise<T>, done: (v: T) => boolean, { every = 5000, timeoutMs = 20 * 60_000 } = {}): Promise<T> {
  const start = Date.now();
  let wait = every;
  for (;;) {
    try {
      const v = await fn();
      if (done(v)) return v;
      wait = every;
    } catch (e) {
      if (e instanceof ImdError && e.status === 503) wait = Math.min(wait * 2, 60_000);
      else throw e;
    }
    if (Date.now() - start > timeoutMs) throw new Error("poll timeout");
    await sleep(wait);
  }
}
