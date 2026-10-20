/** Minor units (integer) -> display string. Never uses floating point for the arithmetic. */
export function formatMoney(minor: number | bigint | null | undefined, currency = "AED"): string {
  if (minor === null || minor === undefined) return "-";
  const n = BigInt(minor);
  const neg = n < 0n;
  const abs = neg ? -n : n;
  const whole = (abs / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = (abs % 100n).toString().padStart(2, "0");
  return `${currency} ${neg ? "-" : ""}${whole}.${frac}`;
}

/** "12.50" -> 1250. Rejects anything that is not a plain decimal with at most two places. */
export function parseMoneyToMinor(input: string): number {
  const m = /^(\d{1,9})(?:\.(\d{1,2}))?$/.exec(input.trim());
  if (!m) throw new Error("invalid_amount");
  return Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0") || "0");
}
