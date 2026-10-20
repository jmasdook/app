import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { formatMoney } from "@/lib/money";
import { hasPermission } from "@/lib/permissions";
import { Flash, Kpi, Page, StatusBadge, Table } from "@/components/ui";

export default async function Finance({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const staff = await requirePermission("payments.read");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const canFin = hasPermission(staff.perms, "finance.read"), canPay = hasPermission(staff.perms, "payouts.manage");
  const [{ data: payments }, { data: batches }, { data: items }, { data: runs }] = await Promise.all([
    sb.from("payments").select("id, purpose, provider, amount_minor, currency, status, is_sandbox, needs_review, review_reason, created_at, booking:bookings(ref)").order("created_at", { ascending: false }).limit(50),
    canFin ? sb.from("payout_batches").select("*").order("created_at", { ascending: false }).limit(10) : Promise.resolve({ data: [] as any[] }),
    canFin ? sb.from("payout_items").select("*").in("status", ["pending", "processing"]).limit(50) : Promise.resolve({ data: [] as any[] }),
    canFin ? sb.from("reconciliation_runs").select("*").order("created_at", { ascending: false }).limit(5) : Promise.resolve({ data: [] as any[] }),
  ]);
  async function newBatch() { "use server"; await runRpc("create_payout_batch", { p_idempotency_key: crypto.randomUUID() }, "/finance", "Payout batch created"); }
  async function mark(f: FormData) { "use server"; await runRpc("mark_payout_item", { p_item_id: str(f, "id"), p_status: str(f, "status"), p_ref: str(f, "ref") || null, p_reason: str(f, "reason") || null }, "/finance", "Payout item updated"); }
  async function reconcile() { "use server"; await runRpc("reconcile_finance", {}, "/finance", "Reconciliation run recorded"); }
  return (
    <Page title="Payments & payouts" sub="Provider payments, worker payables and reconciliation">
      <Flash ok={ok} error={error} />
      {(payments ?? []).some((p: any) => p.is_sandbox) && <div className="flash" style={{ background: "#fff1d6" }}>Sandbox payments are present. They are simulated and never represent real settlement.</div>}
      <div className="grid"><Kpi label="Payments needing review" value={(payments ?? []).filter((p: any) => p.needs_review).length} /></div>
      <div className="card"><h2>Recent payments</h2><Table head={["Booking", "Purpose", "Provider", "Amount", "Status", "Flag"]} empty="No payments yet.">
        {(payments ?? []).map((p: any) => <tr key={p.id}><td>{p.booking?.ref}</td><td>{p.purpose}</td><td>{p.provider}{p.is_sandbox ? " (sandbox)" : ""}</td><td>{formatMoney(p.amount_minor, p.currency)}</td>
          <td><StatusBadge status={p.status} /></td><td>{p.needs_review ? <span className="badge bad">{p.review_reason}</span> : ""}</td></tr>)}</Table></div>
      {canFin && (<>
        <div className="card"><h2>Payouts</h2>
          {canPay && <div className="inline"><form action={newBatch}><button type="submit">Create payout batch from eligible earnings</button></form>
            <form action={reconcile}><button className="secondary" type="submit">Run reconciliation</button></form></div>}
          <h2 style={{ marginTop: 18 }}>Open payout items</h2>
          <Table head={["Worker", "Amount", "Status", "Confirm"]} empty="No open payout items.">
            {(items ?? []).map((i: any) => <tr key={i.id}><td>{i.worker_id.slice(0, 8)}</td><td>{formatMoney(i.amount_minor, i.currency)}</td><td><StatusBadge status={i.status} /></td>
              <td>{canPay && <form action={mark} className="inline"><input type="hidden" name="id" value={i.id} /><select name="status" aria-label="Outcome"><option value="paid">Paid</option><option value="failed">Failed</option></select>
                <input name="ref" placeholder="Bank / provider ref" aria-label="Reference" /><input name="reason" placeholder="Failure reason" aria-label="Failure reason" /><button type="submit">Save</button></form>}</td></tr>)}</Table>
          <p className="sub">Only mark an item paid after the money has actually left via your payout channel. The system never infers this.</p></div>
        <div className="card"><h2>Batches</h2><Table head={["Created", "Status", "Items", "Total"]} empty="No batches.">
          {(batches ?? []).map((b: any) => <tr key={b.id}><td>{new Date(b.created_at).toLocaleString()}</td><td><StatusBadge status={b.status} /></td><td>{b.item_count}</td><td>{formatMoney(b.total_minor, b.currency)}</td></tr>)}</Table></div>
        <div className="card"><h2>Reconciliation runs</h2><Table head={["When", "Mismatches"]} empty="No runs yet.">
          {(runs ?? []).map((r: any) => <tr key={r.id}><td>{new Date(r.created_at).toLocaleString()}</td><td>{r.mismatches === 0 ? <span className="badge ok">balanced</span> : <span className="badge bad">{r.mismatches}</span>}</td></tr>)}</Table></div>
      </>)}
    </Page>
  );
}
