# Security

## Model
* Authorisation is enforced by PostgreSQL: RLS on every table, column-level grants, an explicit RPC allow-list, role/permission tables (`has_permission`). Clients never choose roles; new users are always `customer`. Workers get a draft profile via `become_worker()`; only an admin can approve.
* Only SECURITY DEFINER RPCs write business data; sensitive ones are `service_role`-only (`process_payment_event`, `attach_provider_ref`, `run_maintenance`, `bootstrap_first_admin`, refund processing). Tests assert `anon`/`authenticated` cannot execute them.
* Private storage buckets (`worker-documents`, `booking-media`); path prefix = owner uid; staff access needs `workers.documents.read`; admin portal issues 5-minute signed URLs.
* Audit: `admin_audit_logs` (append-only) written by privileged RPCs and triggers on config tables.
* Ledger and audit tables are immutable (triggers) even for the table owner.
* Admin portal: no sign-up page, deny-by-default route guard, CSP/HSTS/frame headers, no service key, generic login errors, CSV formula-injection guard. Edge Functions: CORS allow-list (never `*`), generic errors, DB-backed rate limiting (`check_rate_limit`), cron secret for ops endpoints.
* Account recovery uses Supabase Auth reset emails (same response regardless of account existence).

## Checklist before launch
- [ ] Supabase Auth: email confirmation on, password policy ≥ 8 (prefer 12), CAPTCHA/rate limits on sign-in/up, MFA for staff, redirect URLs restricted.
- [ ] `SANDBOX_SIMULATION_ENABLED` unset/false; `PAYMENT_PROVIDER=stripe` with provider-approved marketplace set-up; webhook endpoint secret configured.
- [ ] `ADMIN_ALLOWED_ORIGINS` set to the real admin origin; admin hosted on HTTPS only.
- [ ] First super admin created via `scripts/bootstrap-admin.sql`; no shared accounts.
- [ ] Service-role key only in Supabase function secrets / CI secrets; run `gitleaks` (CI) clean; rotate if ever exposed.
- [ ] Storage buckets verified private (`worker-documents`, `booking-media`).
- [ ] RLS test suite green on the deployed migration set; `SELECT * FROM pg_tables WHERE schemaname='public' AND NOT rowsecurity` returns nothing.
- [ ] Backups + PITR enabled, restore drill done (docs/DEPLOYMENT.md).
- [ ] Privacy policy, terms, retention schedule approved by counsel (UAE PDPL / VAT record keeping).
- [ ] Dependency audit (`npm audit`, `flutter pub outdated`, Dependabot) reviewed.
- [ ] Penetration test or independent review of RLS + payment flow.

## Data retention & deletion
`request_account_deletion()` records the request; staff run `process_account_deletion()` which anonymises the profile,
removes addresses, tokens, notifications, worker documents and redacts booking addresses while retaining financial
records. It refuses while bookings, earnings or refunds are open. Then delete the Auth user with the admin API.
Retention periods for financial/tax records (commonly 5 years in the UAE) must be confirmed by counsel.
