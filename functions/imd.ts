// Pay-with-IMD endpoint behind public/imd.html.
//   GET  /api/imd?c&m&q&s        → drafted request + Intakev2.request args for the user's wallet
//   POST /api/imd {c,m,q,s,tx}   → verify the tx on chain, then mark the card as asked
// `s` is an HMAC the bot minted over (chat, message, question); nobody else can point a card at a tx.
import { createPublicClient, http, decodeFunctionData, hexToString, type Hex } from "viem";
import { CHAINS, transportFor } from "../lib/chains";
import * as imd from "../packages/imd/src/index";
import * as intake from "../packages/imd/src/intake";
import { verifySig, markAsked, ASK_CHAIN } from "../lib/bot";

export const maxDuration = 300;
const PANEL = Number(process.env.IMD_PANEL_SIZE ?? 15);
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

function auth(p: { c?: string; m?: string; q?: string; s?: string }) {
  const c = String(p.c ?? ""), m = Number(p.m), q = String(p.q ?? ""), s = String(p.s ?? "");
  if (!c || !Number.isInteger(m) || !q || !verifySig(c, m, q, s)) return null;
  return { c, m, q };
}

export async function GET(req: Request) {
  const u = new URL(req.url);
  const a = auth(Object.fromEntries(u.searchParams));
  if (!a) return json({ error: "bad_signature" }, 403);
  const chainId = ASK_CHAIN === 11155111 ? 1 : ASK_CHAIN;
  const chk = await imd.check(a.q, PANEL, chainId);
  if (!chk.request || chk.blockers?.some((b) => b.code !== "chain_unavailable")) return json({ error: "blocked", blockers: chk.blockers }, 409);
  const [action, body, callback, asset, amount] = intake.requestArgs(chainId, intake.registryBody(chainId, chk.request));
  // With a registry the wallet calls registry.ask(body) and approves the registry; without, Intake directly.
  const c = CHAINS[chainId];
  return json({ request: chk.request, chainId, chain: { id: c.id, name: c.name, rpc: c.rpcPublic, explorer: c.explorer }, intake: intake.INTAKE, registry: intake.registryFor(chainId), asset, amount: amount.toString(), args: { action, body, callback } });
}

export async function POST(req: Request) {
  let p: any; try { p = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const a = auth(p);
  if (!a) return json({ error: "bad_signature" }, 403);
  const tx = String(p.tx ?? "") as Hex;
  if (!/^0x[0-9a-fA-F]{64}$/.test(tx)) return json({ error: "bad_tx" }, 400);

  const chainId = Number(p.chainId ?? (ASK_CHAIN === 11155111 ? 1 : ASK_CHAIN));
  const c = CHAINS[chainId]; if (!c) return json({ error: "bad_chain" }, 400);
  const pub = createPublicClient({ chain: c.viem, transport: transportFor(c) });
  const REG = intake.registryFor(chainId);
  const [t, r] = await Promise.all([pub.getTransaction({ hash: tx }), pub.getTransactionReceipt({ hash: tx })]);
  const to = t.to?.toLowerCase();
  let bodyHex: Hex;
  if (REG && to === REG.toLowerCase()) {
    const d = decodeFunctionData({ abi: intake.registryAbi, data: t.input });
    if (d.functionName !== "ask") return json({ error: "not_oracle_request" }, 422);
    bodyHex = d.args[0] as Hex;
  } else if (to === intake.INTAKE) {
    const d = decodeFunctionData({ abi: intake.intakeAbi, data: t.input });
    if (d.functionName !== "request" || d.args[0] !== intake.ACTION_ID) return json({ error: "not_oracle_request" }, 422);
    bodyHex = d.args[1] as Hex;
  } else return json({ error: "not_an_intake_tx" }, 422);
  if (r.status !== "success") return json({ error: "tx_failed" }, 422);
  let body: any; try { body = JSON.parse(hexToString(bodyHex)); } catch { return json({ error: "bad_body" }, 422); }
  if (body.question !== a.q) return json({ error: "question_mismatch" }, 422);

  await markAsked(a.c, a.m, a.q, chainId as any, tx, Number(body.panelSize) || PANEL, ` from ${t.from.slice(0, 6)}…${t.from.slice(-4)}`);
  return json({ ok: true, tx });
}
