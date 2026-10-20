import { hasPermission, permissionForPath } from "./permissions";

export type Access = { action: "allow" } | { action: "redirect"; to: string };

export interface AccessInput {
  pathname: string;
  signedIn: boolean;
  perms: readonly string[];   // permissions granted by the user's staff roles (empty for non-staff)
}

const PUBLIC_PATHS = ["/login"];

/** Pure routing decision used by the request proxy; deny by default. */
export function decideAccess({ pathname, signedIn, perms }: AccessInput): Access {
  if (PUBLIC_PATHS.includes(pathname)) {
    return signedIn && perms.length > 0 ? { action: "redirect", to: "/dashboard" } : { action: "allow" };
  }
  if (!signedIn) return { action: "redirect", to: "/login" };
  if (perms.length === 0) return { action: "redirect", to: "/login?error=not_staff" };
  if (pathname === "/") return { action: "redirect", to: "/dashboard" };
  const needed = permissionForPath(pathname);
  if (needed === null) return { action: "redirect", to: "/dashboard" };   // unknown route: deny by default
  return hasPermission(perms, needed) ? { action: "allow" } : { action: "redirect", to: "/dashboard?error=forbidden" };
}
