import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Chromia Pay SDK. Zero dependencies — global fetch plus node:crypto — so adding CHR payments to a
 * project cannot drag in a dependency tree.
 *
 *   const cpay = new ChromiaPay(process.env.CPAY_SECRET_KEY!)
 *   const payment = await cpay.payments.create({ amount: "12.5", successUrl })
 *   // redirect the customer to payment.checkout_url
 *
 *   const event = cpay.webhooks.constructEvent(rawBody, req.headers["chromia-pay-signature"], secret)
 *   if (event.type === "payment.confirmed") fulfil(event.data.payment.metadata.order_id)
 */

export type PaymentStatus =
  | "created"
  | "pending"
  | "confirmed"
  | "overpaid"
  | "underpaid"
  | "expired"
  | "canceled";

export type EventType =
  | "payment.pending"
  | "payment.confirmed"
  | "payment.overpaid"
  | "payment.underpaid"
  | "payment.expired"
  | "payment.canceled";

export interface Deposit {
  chain: string;
  tx_id: string;
  event_index: number;
  amount: string;
  payer: string;
  status: "seen" | "confirmed" | "orphaned" | "simulated";
  memo?: string | null;
}

export interface Payment {
  id: string;
  object: "payment";
  status: PaymentStatus;
  livemode: boolean;
  currency: "CHR";
  /** Decimal string with 6 decimals, e.g. "12.500000". */
  amount: string;
  /**
   * Set when the payment was priced in fiat: the original price, its currency, and the rate the CHR
   * figure was quoted at. The rate is held for the payment's lifetime, so this is what the customer
   * agreed to and what belongs on the receipt.
   */
  price: string | null;
  price_currency: string | null;
  rate: string | null;
  rate_source: string | null;
  /** What the payer is asked to send: amount plus attribution dust on the EVM rails. */
  amount_expected: string;
  amount_paid: string;
  amount_pending: string;
  reference: string;
  chain: string | null;
  description: string | null;
  metadata: Record<string, unknown>;
  deposits: Deposit[];
  checkout_url: string;
  expires_at: number;
  created_at: number;
  confirmed_at: number | null;
}

export interface WebhookEvent {
  id: string;
  object: "event";
  type: EventType;
  created: number;
  livemode: boolean;
  data: { payment: Payment };
}

export interface CreatePaymentParams {
  /** Decimal string, up to 6 decimals. Strings only — floats lose money. */
  amount: string;
  /**
   * What `amount` is denominated in. Default "chr".
   *
   * "usd" prices the order in dollars and quotes CHR once, at creation; that rate is then held for the
   * payment's lifetime, so the figure the customer agreed to is the figure they pay. If no rate can be
   * obtained the request fails with 503 rather than inventing one.
   */
  currency?: "chr" | "usd";
  successUrl: string;
  cancelUrl?: string;
  description?: string;
  metadata?: Record<string, unknown>;
  /** Seconds until the payment link expires. Default 1800, max 86400. */
  expiresIn?: number;
  /** Safe retries: the same key returns the original payment instead of creating a second one. */
  idempotencyKey?: string;
}

export class ChromiaPayError extends Error {
  constructor(
    message: string,
    readonly type: string,
    readonly status: number,
    readonly param?: string,
  ) {
    super(message);
    this.name = "ChromiaPayError";
  }
}

export class WebhookVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WebhookVerificationError";
  }
}

/** Fulfil an order on these, and only these. */
export function isPaid(payment: Payment): boolean {
  return payment.status === "confirmed" || payment.status === "overpaid";
}

export interface ChromiaPayOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetch?: typeof globalThis.fetch;
}

export interface WebhookEndpoint {
  id: string;
  object: "webhook_endpoint";
  url: string;
  livemode: boolean;
  active: boolean;
  disabled_reason: string | null;
  /** Null means every event type, including ones added after this endpoint was created. */
  enabled_events: EventType[] | null;
  created_at: number;
  /** Returned on creation only, and never again. */
  secret?: string;
}

/** `chr_usd`, `usdc_usd`, `usdt_usd`. USD is the quote currency; only the base asset varies. */
export type RatePair = "chr_usd" | "usdc_usd" | "usdt_usd";

/** What an asset is worth in dollars, read on its own rather than off a payment. */
export interface AssetRate {
  object: "rate";
  pair: string;
  /** The base asset: `chr`, `usdc` or `usdt`. */
  base: string;
  /** USD per 1 unit of the base asset, decimal string — same format as `payment.rate`. */
  rate: string;
  /** Integer micro-USD per unit, for doing the arithmetic yourself. */
  rate_micro_usd: number;
  /** The venue that answered, or `peg:<asset>` for a stablecoin held at 1:1 by assumption. */
  source: string;
  /** Unix seconds the rate was read from its source. */
  as_of: number;
  age_ms: number;
  /** Older than this and a USD-priced create is refused rather than quoted. */
  max_age_ms: number;
  /** The conversion, when one was asked for. Null otherwise. */
  quote: { usd: string; base: string } | null;
}

/** One recorded point. A gap in the series is a feed that was unreachable; nothing is interpolated. */
export interface RatePoint {
  /** Unix seconds. */
  at: number;
  rate: string;
  rate_micro_usd: number;
  source: string;
}

export interface RateHistory {
  object: "list";
  pair: string;
  base: string;
  /** The window actually served, in unix seconds. */
  from: number;
  to: number;
  /** Newest first. */
  data: RatePoint[];
}

export class ChromiaPay {
  readonly payments: PaymentsResource;
  readonly webhookEndpoints: WebhookEndpointsResource;
  readonly events: EventsResource;
  readonly rates: RatesResource;
  readonly testMode: TestModeResource;
  readonly webhooks: WebhooksResource;

  constructor(
    private readonly secretKey: string,
    private readonly options: ChromiaPayOptions = {},
  ) {
    if (!secretKey?.startsWith("cpay_sk_")) {
      throw new Error("a Chromia Pay secret key looks like cpay_sk_live_… or cpay_sk_test_…");
    }
    this.payments = new PaymentsResource(this.request.bind(this));
    this.webhookEndpoints = new WebhookEndpointsResource(this.request.bind(this));
    this.events = new EventsResource(this.request.bind(this));
    this.rates = new RatesResource(this.request.bind(this));
    this.testMode = new TestModeResource(this.request.bind(this));
    this.webhooks = new WebhooksResource();
  }

  /** True for `cpay_sk_test_…`. Useful for refusing to run a destructive script against live. */
  get testKey(): boolean {
    return this.secretKey.startsWith("cpay_sk_test_");
  }

  private async request<T>(
    method: "GET" | "POST" | "DELETE",
    path: string,
    body?: unknown,
    headers: Record<string, string> = {},
  ): Promise<T> {
    const base = (this.options.baseUrl ?? "https://pay-api.chromia.com").replace(/\/$/, "");
    const doFetch = this.options.fetch ?? globalThis.fetch;

    const response = await doFetch(`${base}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.secretKey}`,
        "content-type": "application/json",
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 20_000),
    });

    const text = await response.text();
    const parsed = text ? safeJson(text) : null;

    if (!response.ok) {
      const err = (parsed as { error?: { message?: string; type?: string; param?: string } } | null)?.error;
      throw new ChromiaPayError(
        err?.message ?? `request failed with ${response.status}`,
        err?.type ?? "api_error",
        response.status,
        err?.param,
      );
    }
    return parsed as T;
  }
}

/** Query string from defined values only, so an omitted option is absent rather than "undefined". */
function query(params: Record<string, string | number | undefined>): string {
  const search = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) search.set(k, String(v));
  return search.size > 0 ? `?${search}` : "";
}

type Request = <T>(
  method: "GET" | "POST" | "DELETE",
  path: string,
  body?: unknown,
  headers?: Record<string, string>,
) => Promise<T>;

class PaymentsResource {
  constructor(private readonly request: Request) {}

  create(params: CreatePaymentParams): Promise<Payment> {
    return this.request<Payment>(
      "POST",
      "/v1/payments",
      {
        amount: params.amount,
        currency: params.currency ?? "chr",
        description: params.description,
        metadata: params.metadata,
        success_url: params.successUrl,
        cancel_url: params.cancelUrl,
        expires_in: params.expiresIn,
      },
      params.idempotencyKey ? { "idempotency-key": params.idempotencyKey } : {},
    );
  }

  get(id: string): Promise<Payment> {
    return this.request<Payment>("GET", `/v1/payments/${encodeURIComponent(id)}`);
  }

  cancel(id: string): Promise<Payment> {
    return this.request<Payment>("POST", `/v1/payments/${encodeURIComponent(id)}/cancel`);
  }
}

/**
 * Prices in your own UI before anything is created.
 *
 * Reading a rate does not reserve it. The quote a payment settles at is the one taken when the payment
 * is created, so show this figure as approximate and let the create be the source of truth.
 */
class RatesResource {
  constructor(private readonly request: Request) {}

  /**
   * Pass `usd` to convert a dollar price to the CHR a payer would send — the same arithmetic, and the
   * same rounding, that creating the payment does. Pass `chr` for the other direction. Neither, and
   * you get the rate alone. Amounts are decimal strings, as everywhere else in this SDK.
   */
  /**
   * The rate now. Pass `usd` to convert a dollar price into the amount a payer would send — the same
   * arithmetic and the same rounding the create does — or `base` for the other direction. Amounts are
   * decimal strings, as everywhere else in this SDK.
   */
  retrieve(pair: RatePair = "chr_usd", params: { usd?: string; base?: string } = {}): Promise<AssetRate> {
    return this.request<AssetRate>("GET", `/v1/rates/${pair}${query(params)}`);
  }

  /** Which pairs this gateway quotes, and which of them are the peg rather than a feed. */
  list(): Promise<{ object: "list"; data: Array<{ pair: string; base: string; pegged: boolean }> }> {
    return this.request("GET", "/v1/rates");
  }

  /**
   * Recorded points for a chart, newest first. `from` and `to` are unix seconds and default to the
   * last 24 hours; `limit` is clamped to 1000. Only `chr_usd` has history — a peg is not observed.
   */
  history(
    pair: RatePair = "chr_usd",
    params: { from?: number; to?: number; limit?: number } = {},
  ): Promise<RateHistory> {
    return this.request<RateHistory>("GET", `/v1/rates/${pair}/history${query(params)}`);
  }
}

class EventsResource {
  constructor(private readonly request: Request) {}

  /**
   * The canonical event, from us.
   *
   * Worth using when something has gone wrong: it settles arguments about what was actually sent,
   * rather than what a log or a retried request body claims was sent.
   */
  retrieve(id: string): Promise<WebhookEvent> {
    return this.request<WebhookEvent>("GET", `/v1/events/${encodeURIComponent(id)}`);
  }
}

/**
 * Forcing an outcome, with a test key.
 *
 * The point is the awkward paths. Any consumer handles `confirmed`; the ones that break in production
 * break on `underpaid` and on a redelivery, and this reaches both without a faucet or a testnet.
 */
class TestModeResource {
  constructor(private readonly request: Request) {}

  simulatePayment(
    id: string,
    params: {
      outcome?: "confirmed" | "overpaid" | "underpaid" | "expired";
      chain?: "chromia" | "bsc" | "base";
    } = {},
  ): Promise<Payment> {
    return this.request<Payment>("POST", `/v1/test/payments/${encodeURIComponent(id)}/simulate_payment`, {
      outcome: params.outcome ?? "confirmed",
      chain: params.chain ?? "chromia",
    });
  }
}

/**
 * Managing where events go, so the whole integration can be scripted rather than clicked.
 *
 * Worth knowing before you call `create`: the signing secret comes back once, here, and is never
 * retrievable again. Store it before you do anything else with the response.
 */
class WebhookEndpointsResource {
  constructor(private readonly request: Request) {}

  /** Omit `enabledEvents` to receive everything, including event types added later. */
  create(params: { url: string; enabledEvents?: EventType[] }): Promise<WebhookEndpoint> {
    return this.request<WebhookEndpoint>("POST", "/v1/webhook_endpoints", {
      url: params.url,
      enabled_events: params.enabledEvents,
    });
  }

  list(): Promise<{ object: "list"; data: WebhookEndpoint[] }> {
    return this.request("GET", "/v1/webhook_endpoints");
  }

  /** Changes the subscription and nothing else — the signing secret survives. */
  update(id: string, params: { enabledEvents: EventType[] | null }): Promise<WebhookEndpoint> {
    return this.request<WebhookEndpoint>("POST", `/v1/webhook_endpoints/${encodeURIComponent(id)}`, {
      enabled_events: params.enabledEvents,
    });
  }

  del(id: string): Promise<{ id: string; deleted: boolean }> {
    return this.request("DELETE", `/v1/webhook_endpoints/${encodeURIComponent(id)}`);
  }
}

class WebhooksResource {
  /**
   * Verify a webhook and return the parsed event. Pass the *raw* request body — a re-serialized
   * object will not match the signature.
   *
   * Throws WebhookVerificationError on a bad signature or a timestamp outside the tolerance
   * window, which is what stops a captured delivery from being replayed later.
   */
  constructEvent(
    rawBody: string | Buffer,
    signatureHeader: string | string[] | undefined | null,
    secret: string,
    toleranceSeconds = 300,
  ): WebhookEvent {
    const raw = typeof rawBody === "string" ? rawBody : rawBody.toString("utf8");
    const header = Array.isArray(signatureHeader) ? signatureHeader[0] : signatureHeader;
    if (!header) throw new WebhookVerificationError("missing Chromia-Pay-Signature header");

    /*
     * A tolerance that is not a number is a configuration mistake, not a wider window.
     *
     * `age > toleranceSeconds` is false for every age when the tolerance is NaN, so the replay check
     * silently passed everything — and the natural way to reach that is the ordinary
     * `Number(process.env.CPAY_WEBHOOK_TOLERANCE_SECONDS)` with the variable unset. A security check
     * that disappears when its input is missing is worse than not having one, because the integrator
     * believes it is there. This is a consumer's own server, so refusing loudly is the right failure.
     */
    if (!Number.isFinite(toleranceSeconds) || toleranceSeconds < 0) {
      throw new WebhookVerificationError(
        `toleranceSeconds must be a non-negative number, received ${String(toleranceSeconds)}`,
      );
    }

    let timestamp = NaN;
    const signatures: string[] = [];
    for (const part of header.split(",")) {
      const idx = part.indexOf("=");
      if (idx === -1) continue;
      const key = part.slice(0, idx).trim();
      const value = part.slice(idx + 1).trim();
      if (key === "t") timestamp = Number(value);
      else if (key === "v1") signatures.push(value);
    }

    if (!Number.isFinite(timestamp)) throw new WebhookVerificationError("malformed signature header");
    if (signatures.length === 0) throw new WebhookVerificationError("no v1 signature in header");

    const age = Math.abs(Math.floor(Date.now() / 1000) - timestamp);
    if (age > toleranceSeconds) {
      throw new WebhookVerificationError(`timestamp is ${age}s old, outside the tolerance window`);
    }

    const expected = Buffer.from(
      createHmac("sha256", secret).update(`${timestamp}.${raw}`).digest("hex"),
      "utf8",
    );
    const matched = signatures.some((sig) => {
      const given = Buffer.from(sig, "utf8");
      return given.length === expected.length && timingSafeEqual(new Uint8Array(given), new Uint8Array(expected));
    });
    if (!matched) throw new WebhookVerificationError("signature mismatch");

    return JSON.parse(raw) as WebhookEvent;
  }
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
