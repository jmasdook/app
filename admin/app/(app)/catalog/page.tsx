import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { parseMoneyToMinor, formatMoney } from "@/lib/money";
import { friendly, str } from "@/lib/actions";
import { Flash, Page, Table } from "@/components/ui";

export default async function Catalog({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requirePermission("catalog.manage");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const [{ data: cats }, { data: services }, { data: areas }] = await Promise.all([
    sb.from("service_categories").select("*").order("sort_order"),
    sb.from("services").select("*, category:service_categories(name)").order("sort_order"),
    sb.from("service_areas").select("*").order("city"),
  ]);
  const done = (e: { message: string } | null, msg: string) => redirect(`/catalog?${e ? "error=" + encodeURIComponent(friendly(e.message)) : "ok=" + encodeURIComponent(msg)}`);

  async function addCategory(f: FormData) { "use server"; const s = await createClient();
    const { error: e } = await s.from("service_categories").insert({ slug: str(f, "slug"), name: str(f, "name"), description: str(f, "description"), image_url: str(f, "image_url") || null });
    redirect(`/catalog?${e ? "error=" + encodeURIComponent(friendly(e.message)) : "ok=Category+created"}`); }
  async function addService(f: FormData) { "use server"; const s = await createClient();
    let price: number, extra: number;
    try { price = parseMoneyToMinor(str(f, "price")); extra = parseMoneyToMinor(str(f, "extra") || "0"); } catch { redirect("/catalog?error=Invalid+price"); }
    const lines = (k: string) => str(f, k).split("\n").map((x) => x.trim()).filter(Boolean);
    const { error: e } = await s.from("services").insert({ category_id: str(f, "category"), slug: str(f, "slug"), name: str(f, "name"), description: str(f, "description"),
      pricing_model: str(f, "model"), base_price_minor: price, extra_hour_rate_minor: extra, included_minutes: Number(f.get("minutes")),
      included: lines("included"), excluded: lines("excluded"), max_extension_minutes: Number(f.get("max_ext") || 120), image_url: str(f, "image_url") || null });
    redirect(`/catalog?${e ? "error=" + encodeURIComponent(friendly(e.message)) : "ok=Service+created"}`); }
  async function toggleService(f: FormData) { "use server"; const s = await createClient();
    const { error: e } = await s.from("services").update({ active: str(f, "active") === "true" }).eq("id", str(f, "id")); done(e, "Service updated"); }
  async function addArea(f: FormData) { "use server"; const s = await createClient();
    const { error: e } = await s.from("service_areas").insert({ city: str(f, "city"), name: str(f, "name") }); done(e, "Area added"); }

  return (
    <Page title="Services & areas" sub="Configure what customers can book. No code changes needed.">
      <Flash ok={ok} error={error} />
      <div className="card"><h2>Services</h2>
        <Table head={["Name", "Category", "Model", "Price", "Duration", "Active", ""]} empty="No services yet.">
          {(services ?? []).map((s: any) => (<tr key={s.id}><td>{s.name}</td><td>{s.category?.name}</td><td>{s.pricing_model.replace(/_/g, " ")}</td>
            <td>{formatMoney(s.base_price_minor, s.currency)}{s.pricing_model === "hourly" ? "/h" : ""}</td><td>{s.included_minutes} min</td><td>{s.active ? "yes" : "no"}</td>
            <td><form action={toggleService}><input type="hidden" name="id" value={s.id} /><input type="hidden" name="active" value={String(!s.active)} />
              <button className="secondary" type="submit">{s.active ? "Disable" : "Enable"}</button></form></td></tr>))}
        </Table></div>
      <form action={addService} className="card"><h2>New service</h2><div className="row">
        <div><label htmlFor="s-name">Name</label><input id="s-name" name="name" required /></div>
        <div><label htmlFor="s-slug">Slug</label><input id="s-slug" name="slug" required pattern="[a-z0-9-]+" /></div>
        <div><label htmlFor="s-cat">Category</label><select id="s-cat" name="category" required>{(cats ?? []).map((c: any) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>
        <div><label htmlFor="s-model">Pricing model</label><select id="s-model" name="model"><option value="fixed">Fixed price</option><option value="hourly">Hourly</option><option value="base_plus_extra">Base + extra hours</option></select></div>
        <div><label htmlFor="s-price">Price / hourly rate (AED)</label><input id="s-price" name="price" inputMode="decimal" required /></div>
        <div><label htmlFor="s-extra">Extra-hour rate (AED)</label><input id="s-extra" name="extra" inputMode="decimal" /></div>
        <div><label htmlFor="s-min">Included minutes</label><input id="s-min" name="minutes" type="number" min={15} max={1440} step={15} defaultValue={60} required /></div>
        <div><label htmlFor="s-max">Max extension (min)</label><input id="s-max" name="max_ext" type="number" min={0} defaultValue={120} /></div></div>
        <label htmlFor="s-desc">Description</label><textarea id="s-desc" name="description" rows={2} />
        <div className="row"><div><label htmlFor="s-inc">Included (one per line)</label><textarea id="s-inc" name="included" rows={3} /></div>
          <div><label htmlFor="s-exc">Excluded (one per line)</label><textarea id="s-exc" name="excluded" rows={3} /></div></div>
        <label htmlFor="s-img">Image URL</label><input id="s-img" name="image_url" type="url" />
        <p><button type="submit">Create service</button></p></form>
      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit,minmax(320px,1fr))" }}>
        <form action={addCategory} className="card"><h2>New category</h2>
          <label htmlFor="c-name">Name</label><input id="c-name" name="name" required /><label htmlFor="c-slug">Slug</label><input id="c-slug" name="slug" required pattern="[a-z0-9-]+" />
          <label htmlFor="c-desc">Description</label><input id="c-desc" name="description" /><label htmlFor="c-img">Image URL</label><input id="c-img" name="image_url" type="url" />
          <p><button type="submit">Create category</button></p></form>
        <div className="card"><h2>Service areas</h2>
          <Table head={["City", "Area", "Active"]} empty="No areas.">{(areas ?? []).map((a: any) => <tr key={a.id}><td>{a.city}</td><td>{a.name}</td><td>{a.active ? "yes" : "no"}</td></tr>)}</Table>
          <form action={addArea} className="inline" style={{ marginTop: 12 }}><input name="city" placeholder="City" aria-label="City" required /><input name="name" placeholder="Area" aria-label="Area" required /><button type="submit">Add</button></form></div>
      </div>
    </Page>
  );
}
