import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { Flash, Kpi, StatusBadge, Table } from "@/components/ui";

describe("ui components", () => {
  it("renders errors with an alert role and successes with a status role", () => {
    render(<Flash error="Nope" />);
    expect(screen.getByRole("alert").textContent).toBe("Nope");
  });
  it("renders a KPI card and status badge", () => {
    render(<><Kpi label="Open disputes" value={3} /><StatusBadge status="pending_payment" /></>);
    expect(screen.getByText("Open disputes")).toBeTruthy();
    expect(screen.getByText("pending payment").className).toContain("warn");
  });
  it("shows a helpful empty state", () => {
    render(<Table head={["A"]} empty="Nothing here yet">{[]}</Table>);
    expect(screen.getByText("Nothing here yet")).toBeTruthy();
  });
});
