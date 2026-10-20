import { NextResponse, type NextRequest } from "next/server";
import { getStaff } from "@/lib/auth";
import { hasPermission } from "@/lib/permissions";
import { createClient } from "@/lib/supabase/server";
import { toCsv } from "@/lib/csv";

export async function GET(req: NextRequest) {
  const staff = await getStaff();
  if (!staff || !hasPermission(staff.perms, "reports.export")) return new NextResponse("Forbidden", { status: 403 });
  const from = req.nextUrl.searchParams.get("from") ?? "", to = req.nextUrl.searchParams.get("to") ?? "";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) return new NextResponse("Bad dates", { status: 400 });
  const sb = await createClient();
  const { data, error } = await sb.rpc("report_bookings", { p_from: from, p_to: to });   // permission re-checked + audited in SQL
  if (error) return new NextResponse("Not permitted", { status: 403 });
  const cols = ["ref", "status", "scheduled_start", "service", "customer_id", "worker_id", "currency", "total_minor", "commission_minor", "worker_earning_minor"];
  return new NextResponse(toCsv(data ?? [], cols), { headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="bookings_${from}_${to}.csv"`, "Cache-Control": "no-store" } });
}
