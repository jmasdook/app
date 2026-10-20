import { requirePermission } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { runRpc, str } from "@/lib/actions";
import { Flash, Page, Table } from "@/components/ui";

export default async function Roles({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requirePermission("roles.manage");
  const { ok, error } = await searchParams;
  const sb = await createClient();
  const [{ data: staff }, { data: perms }] = await Promise.all([
    sb.from("user_roles").select("user_id, role, granted_at, profile:profiles(full_name)").in("role", ["support", "admin", "super_admin"]),
    sb.from("role_permissions").select("*").order("role"),
  ]);
  async function change(f: FormData) { "use server"; await runRpc("admin_set_role", { p_user_id: str(f, "user"), p_role: str(f, "role"), p_grant: str(f, "grant") === "yes" }, "/roles", "Role updated"); }
  return (<Page title="Roles & staff" sub="Staff accounts are created in Supabase Auth, then granted a role here (super administrators only).">
    <Flash ok={ok} error={error} />
    <form action={change} className="card"><h2>Grant or revoke</h2><div className="row">
      <div><label htmlFor="user">User ID (UUID)</label><input id="user" name="user" required pattern="[0-9a-fA-F-]{36}" /></div>
      <div><label htmlFor="role">Role</label><select id="role" name="role"><option>support</option><option>admin</option><option>super_admin</option></select></div>
      <div><label htmlFor="grant">Action</label><select id="grant" name="grant"><option value="yes">Grant</option><option value="no">Revoke</option></select></div></div>
      <p><button type="submit">Apply</button></p></form>
    <div className="card"><h2>Staff</h2><Table head={["Name", "User", "Role", "Since"]} empty="No staff.">
      {(staff ?? []).map((s: any) => <tr key={s.user_id + s.role}><td>{s.profile?.full_name}</td><td><code>{s.user_id}</code></td><td>{s.role}</td><td>{new Date(s.granted_at).toLocaleDateString()}</td></tr>)}</Table></div>
    <div className="card"><h2>Permission matrix</h2><Table head={["Role", "Permission"]} empty="-">{(perms ?? []).map((p: any) => <tr key={p.role + p.permission}><td>{p.role}</td><td>{p.permission}</td></tr>)}</Table></div></Page>);
}
