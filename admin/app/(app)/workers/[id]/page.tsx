import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { hasPermission } from "@/lib/permissions";
import { Flash, Page, StatusBadge, Table } from "@/components/ui";

export default async function WorkerDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const staff = await requirePermission("workers.read");
  const { id } = await params; const { ok, error } = await searchParams;
  const sb = await createClient();
  const { data: w } = await sb.from("worker_profiles").select("*, profile:profiles(full_name, phone)").eq("id", id).maybeSingle();
  if (!w) return <Page title="Worker not found">{null}</Page>;
  const canReview = hasPermission(staff.perms, "workers.review");
  const canDocs = hasPermission(staff.perms, "workers.documents.read");
  const { data: docs } = canDocs ? await sb.from("worker_documents").select("*").eq("worker_id", id).order("created_at") : { data: [] as any[] };
  // Short-lived (5 min) signed URLs; storage RLS re-checks permission on every request.
  const urls: Record<string, string> = {};
  for (const d of docs ?? []) {
    const { data } = await sb.storage.from("worker-documents").createSignedUrl(d.storage_path, 300);
    if (data) urls[d.id] = data.signedUrl;
  }
  const { data: skills } = await sb.from("worker_skills").select("service_id, approved, service:services(name)").eq("worker_id", id);
  const back = `/workers/${id}`;
  async function decide(f: FormData) { "use server"; await runRpc("review_worker", { p_worker_id: id, p_decision: str(f, "decision"), p_reason: str(f, "reason") || null }, back, "Decision recorded"); }
  async function doc(f: FormData) { "use server"; await runRpc("review_document", { p_document_id: str(f, "doc"), p_approve: str(f, "approve") === "yes", p_note: str(f, "note") || null }, back, "Document reviewed"); }
  async function skill(f: FormData) {
    "use server";
    const s = await createClient();
    const { error: e } = await s.from("worker_skills").update({ approved: str(f, "approve") === "yes" }).eq("worker_id", id).eq("service_id", str(f, "service"));
    const { redirect } = await import("next/navigation");
    redirect(`${back}?${e ? "error=" + encodeURIComponent(e.message) : "ok=Skill+updated"}`);
  }
  return (
    <Page title={w.profile?.full_name || "Worker"} sub={`ID ${id}`}>
      <Flash ok={ok} error={error} />
      <div className="card"><h2>Status</h2><p><StatusBadge status={w.status} /> {w.status_reason && <span className="sub">{w.status_reason}</span>}</p>
        {canReview && (<form action={decide} className="inline">
          <select name="decision" aria-label="Decision"><option value="start_review">Start review</option><option value="approve">Approve</option><option value="reject">Reject</option>
            {hasPermission(staff.perms, "users.suspend") && <><option value="suspend">Suspend</option><option value="reinstate">Reinstate</option></>}</select>
          <input name="reason" placeholder="Reason (required for reject/suspend)" aria-label="Reason" /><button type="submit">Apply</button></form>)}</div>
      {canDocs && (<div className="card"><h2>Documents (private storage)</h2>
        <Table head={["Type", "Status", "Expires", "File", "Review"]} empty="No documents uploaded.">
          {(docs ?? []).map((d: any) => (<tr key={d.id}><td>{d.doc_type}</td><td><StatusBadge status={d.status} /></td><td>{d.expires_on ?? "-"}</td>
            <td>{urls[d.id] ? <a href={urls[d.id]} target="_blank" rel="noopener noreferrer">Open (5 min link)</a> : "-"}</td>
            <td>{canReview && <form action={doc} className="inline"><input type="hidden" name="doc" value={d.id} />
              <select name="approve" aria-label="Decision"><option value="yes">Approve</option><option value="no">Reject</option></select>
              <input name="note" placeholder="Note" aria-label="Note" /><button type="submit">Save</button></form>}</td></tr>))}
        </Table></div>)}
      <div className="card"><h2>Skills</h2><Table head={["Service", "Approved", ""]} empty="No skills declared.">
        {(skills ?? []).map((s: any) => (<tr key={s.service_id}><td>{s.service?.name}</td><td>{s.approved ? "yes" : "no"}</td>
          <td>{hasPermission(staff.perms, "workers.manage") && <form action={skill} className="inline"><input type="hidden" name="service" value={s.service_id} />
            <select name="approve" aria-label="Approve skill"><option value="yes">Approve</option><option value="no">Revoke</option></select><button type="submit">Save</button></form>}</td></tr>))}
      </Table></div>
    </Page>
  );
}
