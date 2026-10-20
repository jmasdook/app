import Link from "next/link";
import { redirect } from "next/navigation";
import { getStaff } from "@/lib/auth";
import { visibleNav } from "@/lib/permissions";
import { createClient } from "@/lib/supabase/server";

async function signOut() {
  "use server";
  await (await createClient()).auth.signOut();
  redirect("/login");
}

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const staff = await getStaff();
  if (!staff) redirect("/login");
  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">Skill<span>Connect</span></div>
        <nav aria-label="Main">{visibleNav(staff.perms).map((n) => <Link key={n.href} href={n.href}>{n.label}</Link>)}</nav>
        <form action={signOut} style={{ marginTop: 24 }}>
          <div className="sub" style={{ fontSize: ".85rem", margin: "0 10px 8px" }}>{staff.email}<br />{staff.roles.join(", ")}</div>
          <button className="secondary" type="submit">Sign out</button>
        </form>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
