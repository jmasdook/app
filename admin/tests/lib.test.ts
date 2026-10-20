import { describe, expect, it } from "vitest";
import { decideAccess } from "@/lib/guard";
import { hasPermission, visibleNav } from "@/lib/permissions";
import { formatMoney, parseMoneyToMinor } from "@/lib/money";
import { csvCell, toCsv } from "@/lib/csv";

const support = ["customers.read", "bookings.read", "workers.read", "support.manage", "disputes.read", "reviews.moderate"];

describe("route protection", () => {
  it("sends anonymous users to login for every protected path", () => {
    for (const p of ["/", "/dashboard", "/finance", "/roles", "/anything"]) {
      expect(decideAccess({ pathname: p, signedIn: false, perms: [] })).toEqual({ action: "redirect", to: "/login" });
    }
  });
  it("rejects signed-in users who are not staff (e.g. customers or workers)", () => {
    expect(decideAccess({ pathname: "/dashboard", signedIn: true, perms: [] })).toEqual({ action: "redirect", to: "/login?error=not_staff" });
  });
  it("keeps support away from finance, roles and audit", () => {
    for (const p of ["/finance", "/roles", "/audit", "/pricing", "/catalog", "/reports"]) {
      expect(decideAccess({ pathname: p, signedIn: true, perms: support }).action).toBe("redirect");
    }
    expect(decideAccess({ pathname: "/support/123", signedIn: true, perms: support })).toEqual({ action: "allow" });
  });
  it("lets a super admin (wildcard) reach everything and denies unknown routes by default", () => {
    expect(decideAccess({ pathname: "/roles", signedIn: true, perms: ["*"] })).toEqual({ action: "allow" });
    expect(decideAccess({ pathname: "/secret-new-route", signedIn: true, perms: ["*"] }).action).toBe("redirect");
  });
  it("does not show nav entries the user cannot open", () => {
    const labels = visibleNav(support).map((n) => n.label);
    expect(labels).toContain("Support");
    expect(labels).not.toContain("Payments & payouts");
    expect(hasPermission(["*"], "anything")).toBe(true);
  });
});

describe("money", () => {
  it("formats minor units without floating point", () => {
    expect(formatMoney(15750)).toBe("AED 157.50");
    expect(formatMoney(5)).toBe("AED 0.05");
    expect(formatMoney(123456789012)).toBe("AED 1,234,567,890.12");
    expect(formatMoney(-250)).toBe("AED -2.50");
  });
  it("parses decimal input exactly and rejects junk", () => {
    expect(parseMoneyToMinor("150")).toBe(15000);
    expect(parseMoneyToMinor("0.1")).toBe(10);
    expect(parseMoneyToMinor("19.99")).toBe(1999);
    for (const bad of ["1e3", "-5", "1.234", "abc", ""]) expect(() => parseMoneyToMinor(bad)).toThrow();
  });
});

describe("csv export", () => {
  it("neutralises formula injection and escapes quotes", () => {
    expect(csvCell("=HYPERLINK(\"x\")")).toBe('"\'=HYPERLINK(""x"")"');
    expect(csvCell("+1")).toBe("'+1");
    expect(csvCell('a,"b"')).toBe('"a,""b"""');
    expect(toCsv([{ a: 1, b: "x" }], ["a", "b"])).toBe("a,b\r\n1,x\r\n");
  });
});
