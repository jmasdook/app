import Link from "next/link";
import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Page, StatusBadge, Table } from "@/components/ui";

export default async function Support() {
  await requirePermission("support.manage");
  const sb = await createClient();
  const { data } = await sb.from("support_tickets").select("*").in("status", ["open", "pending"]).order("created_at").limit(100);
  return (<Page title="Support tickets" sub="Open and pending conversations">
    <div className="card"><Table head={["Subject", "Category", "Priority", "Status", "Opened"]} empty="Inbox zero. No open tickets.">
      {(data ?? []).map((t: any) => <tr key={t.id}><td><Link href={`/support/${t.id}`}>{t.subject}</Link></td><td>{t.category}</td><td>{t.priority}</td><td><StatusBadge status={t.status} /></td><td>{new Date(t.created_at).toLocaleString()}</td></tr>)}</Table></div></Page>);
}
