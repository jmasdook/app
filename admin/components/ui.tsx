import type { ReactNode } from "react";

export function Flash({ ok, error }: { ok?: string; error?: string }) {
  if (error) return <div className="flash err" role="alert">{error}</div>;
  if (ok) return <div className="flash ok" role="status">{ok}</div>;
  return null;
}

export function Kpi({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div className="card kpi" style={{ marginBottom: 0 }}>
      <div className="v">{value}</div><div className="l">{label}</div>{hint && <div className="l">{hint}</div>}
    </div>
  );
}

const TONE: Record<string, string> = {
  completed: "ok", approved: "ok", succeeded: "ok", paid: "ok", resolved: "ok", published: "ok", assigned: "",
  cancelled: "bad", rejected: "bad", failed: "bad", suspended: "bad", disputed: "bad", hidden: "bad", expired_credentials: "bad",
  pending_payment: "warn", unassigned: "warn", pending: "warn", requested: "warn", submitted: "warn", under_review: "warn", open: "warn",
};
export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge ${TONE[status] ?? ""}`}>{status.replace(/_/g, " ")}</span>;
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }

export function Table({ head, children, empty }: { head: string[]; children: ReactNode[]; empty: string }) {
  return (
    <div className="table-wrap">
      <table>
        <thead><tr>{head.map((h) => <th key={h} scope="col">{h}</th>)}</tr></thead>
        <tbody>{children.length ? children : <tr><td colSpan={head.length}><Empty>{empty}</Empty></td></tr>}</tbody>
      </table>
    </div>
  );
}

export function Page({ title, sub, children }: { title: string; sub?: string; children: ReactNode }) {
  return (<><h1>{title}</h1>{sub && <p className="sub">{sub}</p>}{children}</>);
}
