import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { Flash, Page, Table } from "@/components/ui";

export default async function Pricing({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requirePermission("pricing.manage");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const [{ data: policies }, { data: cats }, { data: services }, { data: settings }] = await Promise.all([
    sb.from("commission_policies").select("*").order("effective_from", { ascending: false }).limit(50),
    sb.from("service_categories").select("id, name"), sb.from("services").select("id, name"),
    sb.from("application_settings").select("key, value, description").order("key"),
  ]);
  async function setRate(f: FormData) { "use server";
    const scope = str(f, "scope"); const target = str(f, "target") || null;
    await runRpc("set_commission_rate", { p_scope: scope, p_category_id: scope === "category" ? target : null, p_service_id: scope === "service" ? target : null,
      p_rate_bps: Math.round(Number(f.get("percent")) * 100), p_note: str(f, "note") || null }, "/pricing", "New commission version saved"); }
  async function setSetting(f: FormData) { "use server"; const s = await createClient();
    let value: unknown; try { value = JSON.parse(str(f, "value")); } catch { value = null; }
    const { redirect } = await import("next/navigation");
    if (value === null) redirect("/pricing?error=Value+must+be+valid+JSON");
    const { error: e } = await s.from("application_settings").update({ value }).eq("key", str(f, "key"));
    redirect(`/pricing?${e ? "error=Not+permitted+or+invalid" : "ok=Setting+saved"}`); }
  const nameOf = (p: any) => p.scope === "global" ? "All services" : p.scope === "category" ? (cats ?? []).find((c: any) => c.id === p.category_id)?.name : (services ?? []).find((c: any) => c.id === p.service_id)?.name;
  return (
    <Page title="Pricing & commission" sub="Rates are versioned: bookings keep the rate agreed at confirmation.">
      <Flash ok={ok} error={error} />
      <form action={setRate} className="card"><h2>Set commission</h2><div className="row">
        <div><label htmlFor="scope">Scope</label><select id="scope" name="scope"><option value="global">Global default</option><option value="category">Category</option><option value="service">Service</option></select></div>
        <div><label htmlFor="target">Category / service</label><select id="target" name="target"><option value="">(global)</option>
          <optgroup label="Categories">{(cats ?? []).map((c: any) => <option key={c.id} value={c.id}>{c.name}</option>)}</optgroup>
          <optgroup label="Services">{(services ?? []).map((c: any) => <option key={c.id} value={c.id}>{c.name}</option>)}</optgroup></select></div>
        <div><label htmlFor="percent">Rate %</label><input id="percent" name="percent" type="number" min={0} max={100} step={0.01} required /></div>
        <div><label htmlFor="note">Note</label><input id="note" name="note" /></div></div>
        <p className="sub">Target must match the scope (category scope needs a category, service scope a service).</p><button type="submit">Save new version</button></form>
      <div className="card"><h2>Commission history</h2><Table head={["Applies to", "Scope", "Rate", "From", "To"]} empty="No policies.">
        {(policies ?? []).map((p: any) => <tr key={p.id}><td>{nameOf(p)}</td><td>{p.scope}</td><td>{p.rate_bps / 100}%</td><td>{new Date(p.effective_from).toLocaleDateString()}</td><td>{p.effective_to ? new Date(p.effective_to).toLocaleDateString() : "current"}</td></tr>)}</Table></div>
      <div className="card"><h2>Platform settings</h2><Table head={["Key", "Value", "Description", ""]} empty="No settings.">
        {(settings ?? []).map((s: any) => <tr key={s.key}><td><code>{s.key}</code></td><td colSpan={1}>
          <form action={setSetting} className="inline"><input type="hidden" name="key" value={s.key} /><input name="value" defaultValue={JSON.stringify(s.value)} aria-label={s.key} /><button className="secondary" type="submit">Save</button></form></td>
          <td>{s.description}</td><td /></tr>)}</Table></div>
    </Page>
  );
}
