import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { formatMoney } from "@/lib/money";
import { hasPermission } from "@/lib/permissions";
import { Flash, Page, StatusBadge, Table } from "@/components/ui";

export default async function BookingDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const staff = await requirePermission("bookings.read");
  const { id } = await params; const { ok, error } = await searchParams;
  const sb = await createClient();
  const { data: b } = await sb.from("bookings").select("*, service:services(name)").eq("id", id).maybeSingle();
  if (!b) return <Page title="Booking not found">{null}</Page>;
  const { data: history } = await sb.from("booking_status_history").select("*").eq("booking_id", id).order("created_at");
  const { data: workers } = await sb.from("worker_profiles").select("id, profile:profiles(full_name)").eq("status", "approved");
  const canManage = hasPermission(staff.perms, "bookings.manage");
  const back = `/bookings/${id}`;

  async function assign(f: FormData) { "use server"; await runRpc("admin_assign_worker", { p_booking_id: id, p_worker_id: str(f, "worker"), p_reason: str(f, "reason") || null }, back, "Worker assigned"); }
  async function cancel(f: FormData) { "use server"; await runRpc("admin_cancel_booking", { p_booking_id: id, p_reason: str(f, "reason"), p_refund_bps: Number(f.get("refund_bps")) }, back, "Booking cancelled"); }

  return (
    <Page title={`Booking ${b.ref}`} sub={b.service?.name}>
      <Flash ok={ok} error={error} />
      <div className="card"><h2>Summary</h2>
        <p><StatusBadge status={b.status} /> &nbsp; {new Date(b.scheduled_start).toLocaleString()} ({b.timezone}), {b.duration_minutes} min (+{b.extra_minutes} extra)</p>
        <p>Total {formatMoney(b.total_minor, b.currency)} &middot; commission {formatMoney(b.commission_minor, b.currency)} ({b.commission_rate_bps / 100}%) &middot; worker earning {formatMoney(b.worker_earning_minor, b.currency)}</p>
        <p className="sub">Worker: {b.worker_id ?? "unassigned"} &middot; Customer: {b.customer_id}</p>
      </div>
      {canManage && (
        <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit,minmax(300px,1fr))" }}>
          <form action={assign} className="card"><h2>Assign / reassign worker</h2>
            <label htmlFor="worker">Worker</label>
            <select id="worker" name="worker" required>{(workers ?? []).map((w: any) => <option key={w.id} value={w.id}>{w.profile?.full_name} ({w.id.slice(0, 8)})</option>)}</select>
            <label htmlFor="reason">Reason</label><input id="reason" name="reason" />
            <p><button type="submit">Assign</button></p></form>
          <form action={cancel} className="card"><h2>Cancel booking</h2>
            <label htmlFor="reason2">Reason (required)</label><input id="reason2" name="reason" required minLength={3} />
            <label htmlFor="bps">Refund %</label>
            <select id="bps" name="refund_bps"><option value="10000">100%</option><option value="5000">50%</option><option value="0">0%</option></select>
            <p><button className="danger" type="submit">Cancel booking</button></p></form>
        </div>)}
      <div className="card"><h2>Status history</h2>
        <Table head={["When", "From", "To", "Actor", "Reason"]} empty="No history.">
          {(history ?? []).map((h: any) => (<tr key={h.id}><td>{new Date(h.created_at).toLocaleString()}</td><td>{h.from_status ?? "-"}</td>
            <td>{h.to_status}</td><td>{h.actor_role}</td><td>{h.reason}</td></tr>))}
        </Table></div>
    </Page>
  );
}
