import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Page, Table } from "@/components/ui";

export default async function Customers({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  await requirePermission("customers.read");
  const { q } = await searchParams;
  const sb = await createClient();
  let query = sb.from("profiles").select("id, full_name, phone, created_at, deletion_requested_at").order("created_at", { ascending: false }).limit(100);
  if (q && /^[\p{L}\p{N} .'-]{2,60}$/u.test(q)) query = query.ilike("full_name", `%${q}%`);
  const { data } = await query;
  return (<Page title="Customers" sub="Profiles visible to your role">
    <form className="card inline" method="get"><input name="q" placeholder="Search by name" defaultValue={q} aria-label="Name" /><button type="submit">Search</button></form>
    <div className="card"><Table head={["Name", "Phone", "Joined", "Deletion requested"]} empty="No customers match.">
      {(data ?? []).map((c: any) => <tr key={c.id}><td>{c.full_name || "-"}</td><td>{c.phone ?? "-"}</td><td>{new Date(c.created_at).toLocaleDateString()}</td><td>{c.deletion_requested_at ? "yes" : ""}</td></tr>)}</Table></div></Page>);
}
