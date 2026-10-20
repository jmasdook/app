import Stripe from "npm:stripe@17.7.0";
import {
  CheckoutInput, CheckoutResult, NormalizedEvent, NormalizedEventType, PaymentProvider, RefundInput,
  WebhookSignatureError,
} from "./types.ts";

/**
 * Stripe adapter (TEST MODE by default: use an sk_test_ key). Uses PaymentIntents so the mobile app can use
 * PaymentSheet and the card data never touches our servers. Marketplace payouts to workers
 * (Stripe Connect transfers) are intentionally NOT automated here - see docs/PAYMENTS.md for eligibility.
 */
export class StripeProvider implements PaymentProvider {
  readonly name = "stripe";
  readonly isSandbox = false;
  private readonly stripe: Stripe;
  constructor(secretKey: string, private readonly webhookSecret: string) {
    this.stripe = new Stripe(secretKey, { httpClient: Stripe.createFetchHttpClient() });
  }

  async createCheckout(i: CheckoutInput): Promise<CheckoutResult> {
    const pi = await this.stripe.paymentIntents.create({
      amount: i.amountMinor, currency: i.currency.toLowerCase(), receipt_email: i.customerEmail,
      automatic_payment_methods: { enabled: true },
      metadata: { payment_id: i.paymentId, booking_ref: i.bookingRef },
    }, { idempotencyKey: i.idempotencyKey });
    return { providerRef: pi.id, clientSecret: pi.client_secret ?? undefined, livemode: pi.livemode };
  }

  async createRefund(i: RefundInput): Promise<{ refundRef: string }> {
    const r = await this.stripe.refunds.create(
      { payment_intent: i.providerRef, amount: i.amountMinor }, { idempotencyKey: i.idempotencyKey });
    return { refundRef: r.id };
  }

  async parseWebhook(rawBody: string, headers: Headers): Promise<NormalizedEvent | null> {
    let event: Stripe.Event;
    try {
      event = await this.stripe.webhooks.constructEventAsync(
        rawBody, headers.get("stripe-signature") ?? "", this.webhookSecret);
    } catch (e) {
      throw new WebhookSignatureError((e as Error).message);
    }
    const map: Record<string, NormalizedEventType> = {
      "payment_intent.succeeded": "payment.succeeded",
      "payment_intent.payment_failed": "payment.failed",
      "payment_intent.canceled": "payment.cancelled",
      "payment_intent.requires_action": "payment.requires_action",
      "payment_intent.amount_capturable_updated": "payment.authorized",
      "refund.updated": "refund.succeeded",
      "refund.failed": "refund.failed",
    };
    const type = map[event.type];
    if (!type) return null;
    if (event.type === "refund.updated") {
      const r = event.data.object as Stripe.Refund;
      if (r.status !== "succeeded") return null;
      return { provider: this.name, eventId: event.id, type, providerRef: String(r.payment_intent), refundRef: r.id,
        amountMinor: r.amount, currency: r.currency.toUpperCase(), livemode: event.livemode, payload: {} };
    }
    if (event.type === "refund.failed") {
      const r = event.data.object as Stripe.Refund;
      return { provider: this.name, eventId: event.id, type, providerRef: String(r.payment_intent), refundRef: r.id,
        amountMinor: r.amount, currency: r.currency.toUpperCase(), livemode: event.livemode, payload: {} };
    }
    const pi = event.data.object as Stripe.PaymentIntent;
    return { provider: this.name, eventId: event.id, type, providerRef: pi.id,
      amountMinor: type === "payment.succeeded" ? pi.amount_received : pi.amount,
      currency: pi.currency.toUpperCase(), livemode: event.livemode,
      payload: { failure_code: pi.last_payment_error?.code ?? null } };
  }
}
