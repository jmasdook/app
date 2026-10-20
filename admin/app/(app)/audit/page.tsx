import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Page, Table } from "@/components/ui";

export default async function Audit() {
  await requirePermission("audit.read");
  const sb = await createClient();
  const { data } = await sb.from("admin_audit_logs").select("*").order("id", { ascending: false }).limit(200);
  return (<Page title="Audit log" sub="Append-only record of privileged actions">
    <div className="card"><Table head={["When", "Actor", "Action", "Entity", "Details"]} empty="No entries.">
      {(data ?? []).map((a: any) => <tr key={a.id}><td>{new Date(a.created_at).toLocaleString()}</td><td>{a.actor_id?.slice(0, 8) ?? "system"} <span className="sub">{a.actor_role}</span></td><td>{a.action}</td>
        <td>{a.entity_type} {a.entity_id?.slice(0, 8)}</td><td><code style={{ fontSize: ".8rem" }}>{JSON.stringify(a.details).slice(0, 140)}</code></td></tr>)}</Table></div></Page>);
}
