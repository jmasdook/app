// Provider webhook receiver. Public endpoint: deploy with --no-verify-jwt. Authenticity comes ONLY from
// the provider signature over the raw body. Duplicate deliveries are absorbed by process_payment_event().
import { adminClient } from "../_shared/http.ts";
import { getProvider } from "../_shared/providers/index.ts";
import { WebhookSignatureError } from "../_shared/providers/types.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const raw = await req.text();                       // raw body: required for signature verification
  if (raw.length > 262_144) return new Response("too large", { status: 413 });
  try {
    const event = await getProvider().parseWebhook(raw, req.headers);
    if (!event) return new Response(JSON.stringify({ result: "ignored" }), { status: 200 });
    const { data, error } = await adminClient().rpc("process_payment_event", {
      p_provider: event.provider, p_event_id: event.eventId, p_event_type: event.type,
      p_provider_ref: event.providerRef, p_amount_minor: event.amountMinor, p_currency: event.currency,
      p_livemode: event.livemode, p_payload: event.payload, p_refund_ref: event.refundRef ?? null });
    if (error) { console.error("process_payment_event failed", error.message); return new Response("retry", { status: 500 }); }
    return new Response(JSON.stringify(data), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    if (e instanceof WebhookSignatureError) return new Response("invalid signature", { status: 400 });
    console.error("webhook error", (e as Error).message);
    return new Response("error", { status: 500 });
  }
});
