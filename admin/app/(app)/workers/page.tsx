import Link from "next/link";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Page, StatusBadge, Table } from "@/components/ui";

export default async function Workers({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  await requirePermission("workers.read");
  const { status } = await searchParams;
  const sb = await createClient();
  let q = sb.from("worker_profiles").select("id, status, submitted_at, rating_avg, rating_count, profile:profiles(full_name, phone)").order("submitted_at", { ascending: true, nullsFirst: false }).limit(200);
  if (status) q = q.eq("status", status);
  const { data } = await q;
  return (
    <Page title="Workers" sub="Applications, verification and credential status">
      <form className="card inline" method="get"><select name="status" defaultValue={status ?? ""} aria-label="Status">
        <option value="">All</option>{["submitted", "under_review", "approved", "rejected", "suspended", "expired_credentials", "draft"].map((s) => <option key={s} value={s}>{s.replace(/_/g, " ")}</option>)}</select>
        <button type="submit">Filter</button></form>
      <div className="card"><Table head={["Name", "Status", "Submitted", "Rating"]} empty="No workers match.">
        {(data ?? []).map((w: any) => (<tr key={w.id}><td><Link href={`/workers/${w.id}`}>{w.profile?.full_name || w.id.slice(0, 8)}</Link></td>
          <td><StatusBadge status={w.status} /></td><td>{w.submitted_at ? new Date(w.submitted_at).toLocaleDateString() : "-"}</td>
          <td>{w.rating_count ? `${w.rating_avg} (${w.rating_count})` : "-"}</td></tr>))}
      </Table></div>
    </Page>
  );
}
