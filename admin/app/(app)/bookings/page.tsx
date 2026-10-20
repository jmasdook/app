import Link from "next/link";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { formatMoney } from "@/lib/money";
import { Page, StatusBadge, Table } from "@/components/ui";

const STATUSES = ["pending_payment", "assigned", "accepted", "en_route", "arrived", "in_progress", "awaiting_confirmation", "completed", "cancelled", "disputed", "unassigned"];

export default async function Bookings({ searchParams }: { searchParams: Promise<{ q?: string; status?: string }> }) {
  await requirePermission("bookings.read");
  const { q, status } = await searchParams;
  const sb = await createClient();
  let query = sb.from("bookings").select("id, ref, status, scheduled_start, total_minor, currency, service:services(name)")
    .order("scheduled_start", { ascending: false }).limit(100);
  if (status && STATUSES.includes(status)) query = query.eq("status", status);
  if (q && /^[A-Za-z0-9-]{2,20}$/.test(q)) query = query.ilike("ref", `%${q}%`);
  const { data } = await query;
  return (
    <Page title="Bookings" sub="Search and manage the booking lifecycle">
      <form className="card inline" method="get">
        <input name="q" placeholder="Reference e.g. SC-000123" defaultValue={q} aria-label="Reference" />
        <select name="status" defaultValue={status ?? ""} aria-label="Status"><option value="">All statuses</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s.replace(/_/g, " ")}</option>)}</select>
        <button type="submit">Filter</button>
      </form>
      <div className="card">
        <Table head={["Ref", "Service", "Status", "Start", "Total"]} empty="No bookings match.">
          {(data ?? []).map((b: any) => (
            <tr key={b.id}><td><Link href={`/bookings/${b.id}`}>{b.ref}</Link></td><td>{b.service?.name}</td>
              <td><StatusBadge status={b.status} /></td><td>{new Date(b.scheduled_start).toLocaleString()}</td>
              <td>{formatMoney(b.total_minor, b.currency)}</td></tr>))}
        </Table>
      </div>
    </Page>
  );
}
