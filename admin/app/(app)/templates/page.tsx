import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { str } from "@/lib/actions";
import { Page, Table } from "@/components/ui";

export default async function Templates() {
  await requirePermission("notifications.manage");
  const sb = await createClient();
  const { data } = await sb.from("notification_templates").select("*").order("key");
  async function save(f: FormData) { "use server"; const s = await createClient();
    await s.from("notification_templates").update({ title: str(f, "title"), body: str(f, "body") }).eq("key", str(f, "key")).eq("locale", str(f, "locale")); redirect("/templates"); }
  return (<Page title="Notification templates" sub="Use {{placeholders}} such as {{ref}}, {{minutes}}, {{amount}}.">
    <div className="card"><Table head={["Key", "Locale", "Title / body"]} empty="No templates.">
      {(data ?? []).map((t: any) => <tr key={t.key + t.locale}><td><code>{t.key}</code></td><td>{t.locale}</td><td>
        <form action={save}><input type="hidden" name="key" value={t.key} /><input type="hidden" name="locale" value={t.locale} />
          <input name="title" defaultValue={t.title} aria-label={`${t.key} title`} /><textarea name="body" defaultValue={t.body} rows={2} aria-label={`${t.key} body`} /><button className="secondary" type="submit">Save</button></form></td></tr>)}</Table></div></Page>);
}
