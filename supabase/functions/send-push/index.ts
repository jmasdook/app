// Drains pending in-app notifications to push. In-app records are the source of truth; push is best-effort.
// Without FCM_SERVICE_ACCOUNT_JSON the rows are marked 'skipped' (development-safe fallback).
import { adminClient, fail, hasCronSecret, json } from "../_shared/http.ts";
import { buildMessage, fcmAccessToken } from "../_shared/fcm.ts";

Deno.serve(async (req) => {
  if (!hasCronSecret(req)) return json(req, { error: "forbidden" }, 403);
  try {
    const admin = adminClient();
    const { data: rows, error } = await admin.from("notifications").select("id, user_id, title, body, data")
      .eq("push_status", "pending").order("created_at").limit(100);
    if (error) throw new Error(error.message);
    const saJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
    if (!saJson) {
      if (rows?.length) await admin.from("notifications").update({ push_status: "skipped", push_error: "FCM not configured" }).in("id", rows.map((r) => r.id));
      return json(req, { skipped: rows?.length ?? 0 });
    }
    const sa = JSON.parse(saJson);
    const token = await fcmAccessToken(sa);
    let sent = 0, failed = 0;
    for (const n of rows ?? []) {
      const { data: devices } = await admin.from("device_tokens").select("token").eq("user_id", n.user_id);
      if (!devices?.length) { await admin.from("notifications").update({ push_status: "skipped", push_error: "no device" }).eq("id", n.id); continue; }
      let ok = false;
      for (const d of devices) {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
          method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify(buildMessage(d.token, n)) });
        if (res.ok) ok = true;
        else if (res.status === 404) await admin.from("device_tokens").delete().eq("token", d.token);   // stale token
      }
      await admin.from("notifications").update({ push_status: ok ? "sent" : "failed", push_attempts: 1 }).eq("id", n.id);
      ok ? sent++ : failed++;
    }
    return json(req, { sent, failed });
  } catch (e) { return fail(req, e); }
});
