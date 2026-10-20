import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { str } from "@/lib/actions";
import { Page, StatusBadge, Table } from "@/components/ui";

export default async function Reviews() {
  await requirePermission("reviews.moderate");
  const sb = await createClient();
  const { data } = await sb.from("reviews").select("*").order("created_at", { ascending: false }).limit(100);
  async function moderate(f: FormData) { "use server"; const s = await createClient();
    await s.from("reviews").update({ status: str(f, "status"), moderation_note: str(f, "note") || null }).eq("id", str(f, "id")); redirect("/reviews"); }
  return (<Page title="Review moderation" sub="Hide abusive or fraudulent reviews. Hidden reviews are excluded from ratings.">
    <div className="card"><Table head={["Rating", "Comment", "Status", "Action"]} empty="No reviews yet.">
      {(data ?? []).map((r: any) => <tr key={r.id}><td>{"★".repeat(r.rating)}</td><td>{r.comment}</td><td><StatusBadge status={r.status} /></td>
        <td><form action={moderate} className="inline"><input type="hidden" name="id" value={r.id} /><input type="hidden" name="status" value={r.status === "published" ? "hidden" : "published"} />
          <input name="note" placeholder="Note" aria-label="Note" /><button className="secondary" type="submit">{r.status === "published" ? "Hide" : "Publish"}</button></form></td></tr>)}</Table></div></Page>);
}
