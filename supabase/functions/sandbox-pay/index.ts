// DEVELOPMENT ONLY: simulates a customer completing a payment in the SANDBOX provider so the whole flow
// can be exercised without a payment network. It refuses to run unless PAYMENT_PROVIDER=sandbox AND
// SANDBOX_SIMULATION_ENABLED=true, only for payments stored with is_sandbox=true that belong to the caller,
// and it feeds the normal verified-event path. It never represents real money.
import { adminClient, corsHeaders, fail, json, userClient } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (Deno.env.get("PAYMENT_PROVIDER") !== "sandbox" || Deno.env.get("SANDBOX_SIMULATION_ENABLED") !== "true") {
    return json(req, { error: "sandbox_simulation_disabled" }, 403);
  }
  try {
    const user = userClient(req);
    const { data: auth } = await user.auth.getUser();
    if (!auth.user) return json(req, { error: "unauthenticated" }, 401);
    const { payment_id, outcome } = await req.json();
    const { data: p } = await user.from("payments").select("id, provider, provider_ref, amount_minor, currency, status, is_sandbox").eq("id", String(payment_id)).maybeSingle();
    if (!p || !p.is_sandbox || p.provider !== "sandbox" || !p.provider_ref || !["pending", "requires_action", "failed"].includes(p.status)) {
      return json(req, { error: "payment_not_simulatable" }, 400);
    }
    const type = outcome === "fail" ? "payment.failed" : "payment.succeeded";
    const { data, error } = await adminClient().rpc("process_payment_event", {
      p_provider: "sandbox", p_event_id: `sbx_evt_${p.id}_${crypto.randomUUID()}`, p_event_type: type, p_provider_ref: p.provider_ref,
      p_amount_minor: Number(p.amount_minor), p_currency: p.currency, p_livemode: false, p_payload: { sandbox: true, simulated: true }, p_refund_ref: null });
    if (error) throw new Error(error.message);
    return json(req, { simulated: true, result: data });
  } catch (e) { return fail(req, e); }
});
