# Payments

## Provider decision
Researched: Stripe Connect is available for UAE platforms with **UAE-based Express connected accounts**, using
destination charges or separate charges & transfers; UAE connected accounts cannot be self-served and onboarding
must be arranged with Stripe ([Stripe: Connect availability in the UAE](https://support.stripe.com/questions/connect-availability-in-the-uae)).
Stripe's docs and support page differ on `on_behalf_of` support for UAE platforms, so confirm with Stripe before design lock.

Decision: ship the **provider abstraction** (`supabase/functions/_shared/providers`) with a **Stripe test-mode adapter**
(PaymentIntents, official `stripe` SDK, signature-verified webhooks, idempotent refunds) and a clearly labelled
**sandbox adapter**. Alternatives to evaluate with the same interface if Stripe eligibility fails: Checkout.com, Network
International (N-Genius), Telr, PayTabs, Tap. Evaluation criteria: marketplace/split settlement licence, onboarding
of individual workers (UAE ID/trade licence), payout rails, refunds API, webhook signing, fees.

**Not automated (needs provider onboarding + legal review):** Connect account onboarding, transfers/payouts to workers,
settlement reporting. Today payouts are batches recorded in the database; an admin marks items paid *only after* money
leaves via the payout channel. Do not hold customer funds in a standard merchant account for later distribution
without the provider's approved marketplace arrangement. No stored-value wallet is implemented.

## Flow & safety
* `create-payment` (user JWT) → `prepare_payment()` reads the amount from the DB snapshot; one open payment per booking/extra request; idempotency key required.
* `payments-webhook` verifies the provider signature over the raw body (Stripe SDK `constructEventAsync`; sandbox HMAC with timestamp tolerance) then calls `process_payment_event()` (service role only).
* `process_payment_event` is idempotent (`UNIQUE(provider, event_id)`), checks amount/currency/livemode, ignores out-of-order events, and flags mismatches (`needs_review`).
* Live events are rejected unless `application_settings.payments.live_enabled = true`, which only a **super admin** can set; live Stripe keys are refused unless `ALLOW_LIVE_PAYMENTS=true`.
* Late/duplicate captures are booked as `CUSTOMER_UNAPPLIED` and refunded automatically.
* Refunds: policy refunds are auto-approved; discretionary ones need `refunds.approve`; `process-refunds` submits them with idempotency keys; completion comes from the provider webhook.
* `sandbox-pay` simulates a customer payment for development. It only works when `PAYMENT_PROVIDER=sandbox` **and** `SANDBOX_SIMULATION_ENABLED=true`. Sandbox payments are stored with `is_sandbox=true` and are shown as simulated in the admin portal; they are never real settlement.
* Mobile app: live card entry requires the provider's SDK (e.g. `flutter_stripe` PaymentSheet) using the `client_secret` returned by `create-payment`; `SupabaseBookingRepository.pay` throws `UnsupportedError` for non-sandbox providers until that is added and tested on a device.

## Webhook setup (Stripe test mode)
1. `supabase functions deploy payments-webhook --no-verify-jwt`
2. Stripe Dashboard (test) → Developers → Webhooks → endpoint `https://<ref>.functions.supabase.co/payments-webhook`; events: `payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`, `payment_intent.requires_action`, `refund.updated`, `refund.failed`.
3. `supabase secrets set PAYMENT_PROVIDER=stripe STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_...`
4. Reconciliation: compare provider balance transactions with `payments`/`refunds` (`reconcile_finance()` covers internal consistency; provider-side export comparison is an operational step).
