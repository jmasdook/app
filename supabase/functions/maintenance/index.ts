// Runs the database maintenance job (expire holds/unpaid bookings, reminders, credential expiry, eligibility).
// Schedule every minute (pg_cron + pg_net, or an external scheduler) with the x-cron-secret header.
import { adminClient, fail, hasCronSecret, json } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (!hasCronSecret(req)) return json(req, { error: "forbidden" }, 403);
  try {
    const { data, error } = await adminClient().rpc("run_maintenance");
    if (error) throw new Error(error.message);
    return json(req, data);
  } catch (e) { return fail(req, e); }
});
