import { requirePermission } from "@/lib/auth";
import { Page } from "@/components/ui";

export default async function Reports() {
  await requirePermission("reports.export");
  const today = new Date().toISOString().slice(0, 10);
  return (<Page title="Reports" sub="CSV exports are permission-gated and recorded in the audit log.">
    <form className="card" method="get" action="/reports/export"><h2>Bookings & commission</h2><div className="row">
      <div><label htmlFor="from">From</label><input id="from" name="from" type="date" defaultValue={today.slice(0, 8) + "01"} required /></div>
      <div><label htmlFor="to">To</label><input id="to" name="to" type="date" defaultValue={today} required /></div></div>
      <p><button type="submit">Download CSV</button></p></form></Page>);
}
