import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendly, str } from "@/lib/actions";
import { Flash, Page, StatusBadge } from "@/components/ui";

export default async function Ticket({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string }> }) {
  const staff = await requirePermission("support.manage");
  const { id } = await params; const { error } = await searchParams;
  const sb = await createClient();
  const { data: t } = await sb.from("support_tickets").select("*").eq("id", id).maybeSingle();
  if (!t) return <Page title="Ticket not found">{null}</Page>;
  const { data: msgs } = await sb.from("support_messages").select("*").eq("ticket_id", id).order("created_at");
  async function reply(f: FormData) { "use server"; const s = await createClient();
    const { error: e } = await s.from("support_messages").insert({ ticket_id: id, sender_id: staff.id, body: str(f, "body"), is_internal: f.get("internal") === "on" });
    redirect(`/support/${id}${e ? "?error=" + encodeURIComponent(friendly(e.message)) : ""}`); }
  async function setStatus(f: FormData) { "use server"; const s = await createClient();
    await s.from("support_tickets").update({ status: str(f, "status"), assigned_to: staff.id }).eq("id", id); redirect(`/support/${id}`); }
  return (<Page title={t.subject} sub={`${t.category} · priority ${t.priority}`}>
    <Flash error={error} />
    <div className="card"><StatusBadge status={t.status} />
      <form action={setStatus} className="inline" style={{ marginLeft: 12 }}><select name="status" defaultValue={t.status} aria-label="Status">{["open", "pending", "resolved", "closed"].map((s) => <option key={s}>{s}</option>)}</select><button className="secondary" type="submit">Update</button></form></div>
    <div className="card">{(msgs ?? []).map((m: any) => <p key={m.id} style={{ borderLeft: `3px solid ${m.is_internal ? "var(--warn)" : "var(--accent)"}`, paddingLeft: 10 }}>
      <strong>{m.is_internal ? "Internal note" : m.sender_id === t.user_id ? "Customer/worker" : "Staff"}</strong> <span className="sub">{new Date(m.created_at).toLocaleString()}</span><br />{m.body}</p>)}</div>
    <form action={reply} className="card"><label htmlFor="body">Reply</label><textarea id="body" name="body" rows={3} required />
      <label className="inline" style={{ fontWeight: 400 }}><input type="checkbox" name="internal" style={{ width: "auto", minHeight: 0 }} /> Internal note (not visible to the user)</label><p><button type="submit">Send</button></p></form></Page>);
}
