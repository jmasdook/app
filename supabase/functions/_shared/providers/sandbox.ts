import { hmacSha256Hex, safeEqual } from "../crypto.ts";
import {
  CheckoutInput, CheckoutResult, NormalizedEvent, PaymentProvider, RefundInput, WebhookSignatureError,
} from "./types.ts";

/**
 * DEVELOPMENT-ONLY adapter. It never talks to a payment network, never moves money, and every
 * payment it creates is stored with is_sandbox = true / livemode = false. Events must still carry a valid
 * HMAC (SANDBOX_WEBHOOK_SECRET), so a client cannot fabricate a "successful payment".
 */
export class SandboxProvider implements PaymentProvider {
  readonly name = "sandbox";
  readonly isSandbox = true;
  constructor(private readonly webhookSecret: string, private readonly tolerance = 300) {}

  createCheckout(input: CheckoutInput): Promise<CheckoutResult> {
    return Promise.resolve({ providerRef: `sbx_${input.paymentId}`, livemode: false, clientSecret: `sandbox_secret_${input.paymentId}` });
  }

  createRefund(input: RefundInput): Promise<{ refundRef: string }> {
    return Promise.resolve({ refundRef: `sbx_re_${input.idempotencyKey}` });
  }

  /** Header format: `t=<unix>,v1=<hex hmac of "t.body">` (Stripe-style). */
  static async sign(secret: string, body: string, t = Math.floor(Date.now() / 1000)): Promise<string> {
    return `t=${t},v1=${await hmacSha256Hex(secret, `${t}.${body}`)}`;
  }

  async parseWebhook(rawBody: string, headers: Headers): Promise<NormalizedEvent | null> {
    const header = headers.get("x-sandbox-signature") ?? "";
    const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]));
    const t = Number(parts.t);
    if (!parts.v1 || !Number.isFinite(t)) throw new WebhookSignatureError("missing signature");
    if (Math.abs(Date.now() / 1000 - t) > this.tolerance) throw new WebhookSignatureError("timestamp outside tolerance");
    const expected = await hmacSha256Hex(this.webhookSecret, `${t}.${rawBody}`);
    if (!safeEqual(expected, parts.v1)) throw new WebhookSignatureError("bad signature");
    const e = JSON.parse(rawBody);
    return {
      provider: this.name, eventId: String(e.id), type: e.type, providerRef: String(e.providerRef),
      refundRef: e.refundRef, amountMinor: Number(e.amountMinor), currency: String(e.currency).toUpperCase(),
      livemode: false, payload: { sandbox: true },
    };
  }
}
