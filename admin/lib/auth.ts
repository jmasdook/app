import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";
import { hasPermission } from "./permissions";

export interface Staff { id: string; email: string; roles: string[]; perms: string[] }

export async function loadPermissions(sb: Awaited<ReturnType<typeof createClient>>, userId: string) {
  const { data: roleRows } = await sb.from("user_roles").select("role").eq("user_id", userId);
  const roles = (roleRows ?? []).map((r) => r.role as string).filter((r) => ["support", "admin", "super_admin"].includes(r));
  if (roles.length === 0) return { roles, perms: [] as string[] };
  const { data: permRows } = await sb.from("role_permissions").select("permission").in("role", roles);
  return { roles, perms: [...new Set((permRows ?? []).map((p) => p.permission as string))] };
}

/** Authenticated staff member for the current request (validated against Supabase Auth, not the cookie alone). */
export const getStaff = cache(async (): Promise<Staff | null> => {
  const sb = await createClient();
  const { data } = await sb.auth.getUser();
  if (!data.user) return null;
  const { roles, perms } = await loadPermissions(sb, data.user.id);
  if (perms.length === 0) return null;
  return { id: data.user.id, email: data.user.email ?? "", roles, perms };
});

export async function requirePermission(permission: string): Promise<Staff> {
  const staff = await getStaff();
  if (!staff) redirect("/login");
  if (!hasPermission(staff.perms, permission)) redirect("/dashboard?error=forbidden");
  return staff;
}
