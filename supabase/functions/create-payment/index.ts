// Creates a provider payment for a booking or an approved extra-time request.
// The amount is read from the database snapshot by prepare_payment(); the client only sends ids.
import { adminClient, fail, json, corsHeaders, userClient } from "../_shared/http.ts";
import { getProvider } from "../_shared/providers/index.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);
  try {
    const user = userClient(req);
    const { data: auth, error: authErr } = await user.auth.getUser();
    if (authErr || !auth.user) return json(req, { error: "unauthenticated" }, 401);

    const body = await req.json();
    const bookingId = String(body.booking_id ?? "");
    const extraId = body.extra_request_id ? String(body.extra_request_id) : null;
    const key = String(req.headers.get("idempotency-key") ?? body.idempotency_key ?? "");
    if (!/^[0-9a-f-]{36}$/.test(bookingId) || key.length < 8 || key.length > 80) return json(req, { error: "invalid_request" }, 400);

    const admin = adminClient();
    const { data: allowed } = await admin.rpc("check_rate_limit", { p_bucket: `create-payment:${auth.user.id}`, p_max: 10, p_window_seconds: 60 });
    if (allowed !== true) return json(req, { error: "rate_limited" }, 429);

    // Authorisation + amount: runs as the user, so RLS-style ownership checks apply.
    const { data: payment, error } = await user.rpc("prepare_payment", {
      p_booking_id: bookingId, p_extra_request_id: extraId, p_idempotency_key: key });
    if (error) throw new Error(error.message);

    const provider = getProvider();
    const checkout = await provider.createCheckout({
      paymentId: payment.id, bookingRef: bookingId, amountMinor: Number(payment.amount_minor),
      currency: payment.currency, customerEmail: auth.user.email ?? undefined, idempotencyKey: payment.idempotency_key });

    if (!payment.provider_ref) {
      const { error: attachErr } = await admin.rpc("attach_provider_ref", {
        p_payment_id: payment.id, p_provider: provider.name, p_ref: checkout.providerRef, p_livemode: checkout.livemode });
      if (attachErr) throw new Error(attachErr.message);
    }
    return json(req, {
      payment_id: payment.id, amount_minor: Number(payment.amount_minor), currency: payment.currency,
      provider: provider.name, sandbox: provider.isSandbox, client_secret: checkout.clientSecret ?? null,
      redirect_url: checkout.redirectUrl ?? null,
    });
  } catch (e) {
    return fail(req, e);
  }
});
