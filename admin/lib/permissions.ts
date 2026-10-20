export type Permission = string;

export interface NavItem { href: string; label: string; permission: Permission }

/** Every admin route and the permission needed to see it (mirrors role_permissions in the database). */
export const NAV: NavItem[] = [
  { href: "/dashboard", label: "Overview", permission: "bookings.read" },
  { href: "/bookings", label: "Bookings", permission: "bookings.read" },
  { href: "/workers", label: "Workers", permission: "workers.read" },
  { href: "/customers", label: "Customers", permission: "customers.read" },
  { href: "/catalog", label: "Services & areas", permission: "catalog.manage" },
  { href: "/pricing", label: "Pricing & commission", permission: "pricing.manage" },
  { href: "/promotions", label: "Promotions", permission: "promotions.manage" },
  { href: "/finance", label: "Payments & payouts", permission: "payments.read" },
  { href: "/disputes", label: "Disputes & refunds", permission: "disputes.read" },
  { href: "/support", label: "Support", permission: "support.manage" },
  { href: "/reviews", label: "Reviews", permission: "reviews.moderate" },
  { href: "/templates", label: "Notification templates", permission: "notifications.manage" },
  { href: "/reports", label: "Reports", permission: "reports.export" },
  { href: "/audit", label: "Audit log", permission: "audit.read" },
  { href: "/roles", label: "Roles & staff", permission: "roles.manage" },
];

export function hasPermission(perms: readonly string[], needed: Permission): boolean {
  return perms.includes("*") || perms.includes(needed);
}

export function visibleNav(perms: readonly string[]): NavItem[] {
  return NAV.filter((n) => hasPermission(perms, n.permission));
}

export function permissionForPath(pathname: string): Permission | null {
  const hit = NAV.find((n) => pathname === n.href || pathname.startsWith(n.href + "/"));
  return hit?.permission ?? null;
}
