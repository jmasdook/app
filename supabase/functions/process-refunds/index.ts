// Executes approved refunds against the provider. Trigger from cron (x-cron-secret) or after admin approval.
import { adminClient, fail, hasCronSecret, json } from "../_shared/http.ts";
import { getProvider } from "../_shared/providers/index.ts";

Deno.serve(async (req) => {
  if (!hasCronSecret(req)) return json(req, { error: "forbidden" }, 403);
  try {
    const admin = adminClient(), provider = getProvider();
    const { data: refunds, error } = await admin.from("refunds")
      .select("id, amount_minor, currency, idempotency_key, payment:payments(provider, provider_ref, is_sandbox)")
      .eq("status", "approved").order("created_at").limit(20);
    if (error) throw new Error(error.message);
    const results: Record<string, string> = {};
    for (const r of refunds ?? []) {
      // deno-lint-ignore no-explicit-any
      const pay = r.payment as any;
      if (pay.provider !== provider.name || !pay.provider_ref) { results[r.id] = "skipped_provider_mismatch"; continue; }
      const { error: claimErr } = await admin.rpc("begin_refund_processing", { p_refund_id: r.id });
      if (claimErr) { results[r.id] = "not_claimed"; continue; }
      try {
        const { refundRef } = await provider.createRefund({
          providerRef: pay.provider_ref, amountMinor: Number(r.amount_minor), currency: r.currency, idempotencyKey: r.idempotency_key });
        await admin.rpc("set_refund_provider_ref", { p_refund_id: r.id, p_ref: refundRef });
        if (provider.isSandbox && pay.is_sandbox) {
          // Sandbox has no network: complete the refund explicitly, clearly labelled as simulated.
          await admin.rpc("process_payment_event", { p_provider: "sandbox", p_event_id: `sbx_evt_${r.id}`,
            p_event_type: "refund.succeeded", p_provider_ref: pay.provider_ref, p_amount_minor: Number(r.amount_minor),
            p_currency: r.currency, p_livemode: false, p_payload: { sandbox: true }, p_refund_ref: refundRef });
        }
        results[r.id] = "submitted";
      } catch (e) {
        console.error("refund submit failed", r.id, (e as Error).message);
        results[r.id] = "submit_failed";   // stays 'processing'; ops reconcile via the provider dashboard
      }
    }
    return json(req, { results });
  } catch (e) { return fail(req, e); }
});
