import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { formatMoney } from "@/lib/money";
import { hasPermission } from "@/lib/permissions";
import { Flash, Kpi, Page, StatusBadge, Table } from "@/components/ui";
import Link from "next/link";

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const staff = await requirePermission("bookings.read");
  const { error } = await searchParams;
  const sb = await createClient();
  const { data: d } = await sb.rpc("admin_dashboard");
  const today = new Date().toISOString().slice(0, 10);
  const { data: todays } = await sb.from("bookings").select("id, ref, status, scheduled_start, worker_id")
    .gte("scheduled_start", today).lt("scheduled_start", today + "T23:59:59Z").neq("status", "pending_payment").order("scheduled_start").limit(10);
  const trend: { day: string; count: number }[] = d?.booking_trend ?? [];
  const max = Math.max(1, ...trend.map((t) => t.count));
  const fin = hasPermission(staff.perms, "finance.read");
  return (
    <Page title="Overview" sub="Live operational snapshot">
      <Flash error={error === "forbidden" ? "You do not have access to that page." : undefined} />
      <div className="grid">
        <Kpi label="Bookings today" value={d?.bookings_today ?? 0} />
        <Kpi label="Active workers" value={d?.active_workers ?? 0} />
        <Kpi label="Pending worker verifications" value={d?.pending_worker_reviews ?? 0} />
        <Kpi label="Open disputes" value={d?.open_disputes ?? 0} />
        <Kpi label="Open support tickets" value={d?.open_tickets ?? 0} />
        {fin && <>
          <Kpi label="Collected (applied)" value={formatMoney(d?.revenue_minor)} />
          <Kpi label="Commission earned" value={formatMoney(d?.commission_minor)} />
          <Kpi label="Refunds issued" value={formatMoney(d?.refunds_minor)} />
          <Kpi label="Payment exceptions" value={d?.payment_exceptions ?? 0} hint="payments needing review" />
        </>}
      </div>
      <div className="card"><h2>Bookings, last 14 days</h2>
        <div className="bars" role="img" aria-label="Bookings per day for the last 14 days">
          {trend.map((t) => <div key={t.day} title={`${t.day}: ${t.count}`} style={{ height: `${(t.count / max) * 100}%` }} />)}
        </div>
      </div>
      <div className="card"><h2>Today&apos;s appointments</h2>
        <Table head={["Ref", "Status", "Start"]} empty="No appointments today.">
          {(todays ?? []).map((b) => (
            <tr key={b.id}><td><Link href={`/bookings/${b.id}`}>{b.ref}</Link></td><td><StatusBadge status={b.status} /></td>
              <td>{new Date(b.scheduled_start).toLocaleString()}</td></tr>))}
        </Table>
      </div>
    </Page>
  );
}
