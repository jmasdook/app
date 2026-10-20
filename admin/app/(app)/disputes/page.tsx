import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { formatMoney, parseMoneyToMinor } from "@/lib/money";
import { hasPermission } from "@/lib/permissions";
import { Flash, Page, StatusBadge, Table } from "@/components/ui";

export default async function Disputes({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const staff = await requirePermission("disputes.read");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const canManage = hasPermission(staff.perms, "disputes.manage"), canRefund = hasPermission(staff.perms, "refunds.approve");
  const [{ data: disputes }, { data: refunds }] = await Promise.all([
    sb.from("disputes").select("*, booking:bookings(ref)").in("status", ["open", "investigating"]).order("created_at"),
    canRefund ? sb.from("refunds").select("*, booking:bookings(ref)").eq("status", "requested").order("created_at") : Promise.resolve({ data: [] as any[] }),
  ]);
  async function resolve(f: FormData) { "use server";
    let amt: number | null = null; if (str(f, "amount")) { try { amt = parseMoneyToMinor(str(f, "amount")); } catch { amt = -1; } }
    await runRpc("resolve_dispute", { p_dispute_id: str(f, "id"), p_outcome: str(f, "outcome"), p_refund_amount_minor: amt, p_note: str(f, "note") || null }, "/disputes", "Dispute resolved"); }
  async function decide(f: FormData) { "use server"; await runRpc("decide_refund", { p_refund_id: str(f, "id"), p_approve: str(f, "approve") === "yes", p_note: str(f, "note") || null }, "/disputes", "Refund decision saved"); }
  return (
    <Page title="Disputes & refunds" sub="Investigate disputes, approve or decline refund requests">
      <Flash ok={ok} error={error} />
      <div className="card"><h2>Open disputes</h2><Table head={["Booking", "Raised by", "Reason", "Status", "Resolve"]} empty="No open disputes.">
        {(disputes ?? []).map((d: any) => <tr key={d.id}><td>{d.booking?.ref}</td><td>{d.raised_role}</td><td>{d.reason}</td><td><StatusBadge status={d.status} /></td>
          <td>{canManage && <form action={resolve} className="inline"><input type="hidden" name="id" value={d.id} />
            <select name="outcome" aria-label="Outcome"><option value="no_refund">No refund</option><option value="partial_refund">Partial refund</option><option value="full_refund">Full refund</option></select>
            <input name="amount" placeholder="Partial amount AED" aria-label="Partial amount" inputMode="decimal" /><input name="note" placeholder="Resolution note" aria-label="Note" /><button type="submit">Resolve</button></form>}</td></tr>)}</Table></div>
      {canRefund && <div className="card"><h2>Refund requests</h2><Table head={["Booking", "Amount", "Reason", "Decision"]} empty="No pending refund requests.">
        {(refunds ?? []).map((r: any) => <tr key={r.id}><td>{r.booking?.ref}</td><td>{formatMoney(r.amount_minor, r.currency)}</td><td>{r.reason}</td>
          <td><form action={decide} className="inline"><input type="hidden" name="id" value={r.id} /><select name="approve" aria-label="Decision"><option value="yes">Approve</option><option value="no">Decline</option></select>
            <input name="note" placeholder="Note" aria-label="Note" /><button type="submit">Save</button></form></td></tr>)}</Table></div>}
    </Page>
  );
}
