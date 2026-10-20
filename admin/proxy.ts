import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { decideAccess } from "./lib/guard";

// Next.js 16 request proxy (formerly middleware): refreshes the session and enforces route permissions.
// Pages and server actions re-check permissions themselves; the database RLS is the final authority.
export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });
  const sb = createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });
  const { data } = await sb.auth.getUser();
  let perms: string[] = [];
  if (data.user) {
    const { data: roles } = await sb.from("user_roles").select("role").eq("user_id", data.user.id);
    const staffRoles = (roles ?? []).map((r) => r.role as string).filter((r) => ["support", "admin", "super_admin"].includes(r));
    if (staffRoles.length) {
      const { data: p } = await sb.from("role_permissions").select("permission").in("role", staffRoles);
      perms = (p ?? []).map((x) => x.permission as string);
    }
  }
  const decision = decideAccess({ pathname: request.nextUrl.pathname, signedIn: !!data.user, perms });
  if (decision.action === "redirect") {
    const url = new URL(decision.to, request.url);
    const redirect = NextResponse.redirect(url);
    response.cookies.getAll().forEach((c) => redirect.cookies.set(c));
    return redirect;
  }
  return response;
}

export const config = { matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"] };
