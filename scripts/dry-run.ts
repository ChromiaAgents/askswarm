// unpaid dry run: check -> quote -> 402 challenge -> build both signatures locally (no submit)
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import * as imd from "../packages/imd/src/index.ts";
const token = Array.from(crypto.getRandomValues(new Uint8Array(32))).map(b=>b.toString(16).padStart(2,"0")).join("");
const signer = privateKeyToAccount(generatePrivateKey());
const chk = await imd.check("Did Argentina win the 2022 FIFA World Cup?", 15);
const order = await imd.quote(token, crypto.randomUUID(), chk.request!);
console.log("quoted", order.id, order.status, order.quote.quoteHash.slice(0,8));
const r = await fetch(`${imd.IMD_API}/requests/${order.id}/submit`, { method: "POST", headers: { Authorization: `Bearer ${token}` } });
console.log("challenge status", r.status, "has payment-required header", !!r.headers.get("payment-required"));
// now try the real paySubmit with an empty wallet: expect server-side payment_rejected / insufficient_funds, NOT a shape error
try { console.log(await imd.paySubmit(token, order.id, signer)); }
catch (e: any) { console.log("submit ->", e.status, e.message, JSON.stringify(e.body ?? null).slice(0, 600)); }
