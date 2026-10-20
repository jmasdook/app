import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";

/** Run an RPC as the signed-in staff user (RLS/permissions enforced by the database) and flash the result. */
export async function runRpc(fn: string, args: Record<string, unknown>, back: string, okMessage: string) {
  const sb = await createClient();
  const { error } = await sb.rpc(fn, args);
  const sep = back.includes("?") ? "&" : "?";
  redirect(`${back}${sep}${error ? "error=" + encodeURIComponent(friendly(error.message)) : "ok=" + encodeURIComponent(okMessage)}`);
}

export function friendly(message: string): string {
  if (/42501|forbidden|permission denied|row-level security/i.test(message)) return "You do not have permission for this action.";
  return message.replace(/_/g, " ").slice(0, 160);
}

export const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();
export const num = (f: FormData, k: string) => Number(f.get(k) ?? 0);
