import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

export function corsHeaders(req: Request): Record<string, string> {
  const allowed = (Deno.env.get("ADMIN_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const origin = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, idempotency-key",
    "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin",
  };
  if (allowed.includes(origin)) h["Access-Control-Allow-Origin"] = origin;   // never "*"
  return h;
}

export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(req), "Content-Type": "application/json" } });
}

/** Never leaks internals: logs the cause, returns a generic message. */
export function fail(req: Request, e: unknown, fallback = "request_failed"): Response {
  const msg = e instanceof Error ? e.message : String(e);
  console.error("function error:", msg);
  const known = /^[a-z_]{3,60}$/.test(msg) ? msg : fallback;   // our RPC error codes are snake_case
  return json(req, { error: known }, known === "forbidden" ? 403 : 400);
}

export const adminClient = (): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

export const userClient = (req: Request): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false }, global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });

/** Cron/ops endpoints authenticate with a shared secret (never the service key itself). */
export function hasCronSecret(req: Request): boolean {
  const expected = Deno.env.get("CRON_SECRET");
  return !!expected && req.headers.get("x-cron-secret") === expected;
}
