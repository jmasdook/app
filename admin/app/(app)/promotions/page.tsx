import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendly, str } from "@/lib/actions";
import { Flash, Page, Table } from "@/components/ui";

export default async function Promotions({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requirePermission("promotions.manage");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const { data } = await sb.from("promotions").select("*").order("created_at", { ascending: false });
  async function create(f: FormData) { "use server"; const s = await createClient();
    const kind = str(f, "kind"); const raw = Number(f.get("value"));
    const { error: e } = await s.from("promotions").insert({ code: str(f, "code").toUpperCase(), kind, value: kind === "percent_bps" ? Math.round(raw * 100) : Math.round(raw * 100),
      max_discount_minor: f.get("max") ? Math.round(Number(f.get("max")) * 100) : null, max_redemptions: f.get("limit") ? Number(f.get("limit")) : null });
    redirect(`/promotions?${e ? "error=" + encodeURIComponent(friendly(e.message)) : "ok=Promotion+created"}`); }
  async function toggle(f: FormData) { "use server"; const s = await createClient();
    await s.from("promotions").update({ active: str(f, "active") === "true" }).eq("id", str(f, "id")); redirect("/promotions?ok=Updated"); }
  return (
    <Page title="Promotions" sub="Discount codes are validated and applied by the server-side pricing engine.">
      <Flash ok={ok} error={error} />
      <form action={create} className="card"><h2>New code</h2><div className="row">
        <div><label htmlFor="code">Code</label><input id="code" name="code" required pattern="[A-Za-z0-9_-]{3,32}" /></div>
        <div><label htmlFor="kind">Type</label><select id="kind" name="kind"><option value="percent_bps">Percent</option><option value="fixed">Fixed amount (AED)</option></select></div>
        <div><label htmlFor="value">Value (% or AED)</label><input id="value" name="value" type="number" step="0.01" min="0.01" required /></div>
        <div><label htmlFor="max">Max discount (AED)</label><input id="max" name="max" type="number" step="0.01" min="0" /></div>
        <div><label htmlFor="limit">Total redemptions</label><input id="limit" name="limit" type="number" min="1" /></div></div>
        <p><button type="submit">Create</button></p></form>
      <div className="card"><Table head={["Code", "Type", "Value", "Active", ""]} empty="No promotions.">
        {(data ?? []).map((p: any) => <tr key={p.id}><td><code>{p.code}</code></td><td>{p.kind}</td><td>{p.kind === "percent_bps" ? p.value / 100 + "%" : "AED " + p.value / 100}</td><td>{p.active ? "yes" : "no"}</td>
          <td><form action={toggle}><input type="hidden" name="id" value={p.id} /><input type="hidden" name="active" value={String(!p.active)} /><button className="secondary" type="submit">{p.active ? "Disable" : "Enable"}</button></form></td></tr>)}</Table></div>
    </Page>
  );
}
