// Provider-agnostic payment boundary. The booking engine only ever sees these types;
// swapping Stripe for another UAE provider means adding one adapter, not touching the database.

export interface CheckoutInput {
  paymentId: string;
  bookingRef: string;
  amountMinor: number;
  currency: string;
  customerEmail?: string;
  idempotencyKey: string;
}

export interface CheckoutResult {
  providerRef: string;          // payment intent / session id (stored in payments.provider_ref)
  clientSecret?: string;        // for mobile PaymentSheet / web Elements
  redirectUrl?: string;         // for hosted pages
  livemode: boolean;
}

export interface RefundInput {
  providerRef: string;
  amountMinor: number;
  currency: string;
  idempotencyKey: string;
}

export type NormalizedEventType =
  | "payment.succeeded" | "payment.failed" | "payment.cancelled"
  | "payment.requires_action" | "payment.authorized"
  | "refund.succeeded" | "refund.failed";

export interface NormalizedEvent {
  provider: string;
  eventId: string;
  type: NormalizedEventType;
  providerRef: string;          // payment reference the event refers to
  refundRef?: string;
  amountMinor: number;
  currency: string;
  livemode: boolean;
  payload: Record<string, unknown>;   // minimal, PII-free subset
}

export interface PaymentProvider {
  readonly name: string;
  readonly isSandbox: boolean;
  createCheckout(input: CheckoutInput): Promise<CheckoutResult>;
  createRefund(input: RefundInput): Promise<{ refundRef: string }>;
  /** Verifies the signature over the RAW body and returns a normalised event, or null for ignorable events. */
  parseWebhook(rawBody: string, headers: Headers): Promise<NormalizedEvent | null>;
}

export class WebhookSignatureError extends Error {}
