import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { loadPermissions } from "@/lib/auth";
import { Flash } from "@/components/ui";

async function signIn(formData: FormData) {
  "use server";
  const sb = await createClient();
  const { data, error } = await sb.auth.signInWithPassword({
    email: String(formData.get("email") ?? ""), password: String(formData.get("password") ?? ""),
  });
  // Same generic message for bad credentials and non-staff accounts: no account enumeration.
  if (error || !data.user) redirect("/login?error=invalid");
  const { perms } = await loadPermissions(sb, data.user.id);
  if (perms.length === 0) { await sb.auth.signOut(); redirect("/login?error=invalid"); }
  redirect("/dashboard");
}

export default async function Login({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main className="login">
      <div className="brand">Skill<span>Connect</span> Admin</div>
      <form action={signIn} className="card">
        <h1>Staff sign in</h1>
        <Flash error={error ? "Invalid credentials or this account is not authorised for the admin portal." : undefined} />
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" autoComplete="username" required />
        <label htmlFor="password">Password</label>
        <input id="password" name="password" type="password" autoComplete="current-password" required />
        <p><button type="submit">Sign in</button></p>
        <p className="sub">Accounts are created by a super administrator. There is no public sign-up.</p>
      </form>
    </main>
  );
}
