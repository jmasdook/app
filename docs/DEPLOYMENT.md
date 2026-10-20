# Deployment & operations

## Backend (Supabase)
```bash
supabase link --project-ref <ref>
supabase db push                                   # applies migrations (review the diff first)
supabase secrets set --env-file .env.production    # never commit this file
supabase functions deploy create-payment maintenance process-refunds send-push
supabase functions deploy payments-webhook --no-verify-jwt   # authenticated by provider signature
# dev only: supabase functions deploy sandbox-pay
```
Schedule `maintenance` every minute, `process-refunds` and `send-push` every minute (pg_cron + pg_net or an external
scheduler) with header `x-cron-secret: $CRON_SECRET`. Seed data (`supabase/seed.sql`) is **development only**.
First admin: create the user in Auth, then `psql "$SUPABASE_DB_URL" -v email="'you@co.com'" -f scripts/bootstrap-admin.sql`.
Storage buckets are created by migration 10 (private except `service-images`).

## Admin portal (Next.js)
`cd admin && cp .env.example .env.local && npm ci && npm run build && npm start`. Deploy to any Node host (e.g. Vercel);
set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` only. Add the origin to `ADMIN_ALLOWED_ORIGINS`.

## Android
```bash
cd mobile
flutter pub get && flutter analyze && flutter test
flutter build apk --debug   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```
Release (signed): create a keystore, store it as GitHub secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`), run the **Release Android** workflow manually, or locally write
`mobile/android/key.properties` (gitignored) and `flutter build appbundle --release --dart-define=...`.
Push notifications: add `firebase_messaging`, `google-services.json` (gitignored), register tokens into `device_tokens`; the `send-push` function already delivers via FCM v1 when `FCM_SERVICE_ACCOUNT_JSON` is set.

## Backup / restore
Enable Supabase daily backups + PITR. Logical backup: `pg_dump --format=custom --no-owner "$SUPABASE_DB_URL" > backup.dump`.
Restore drill (quarterly, into a **new** project/local DB, never over production): `createdb restore_test && pg_restore --no-owner -d restore_test backup.dump`
then run `select public.reconcile_finance();` and spot-check counts. Storage objects are backed up separately (Supabase Storage / S3 sync).

## Launch approval checklist (real money)
1. Provider marketplace onboarding complete; legal/tax review of fund flow, VAT and commission treatment.
2. Test-mode end-to-end run: pay, refund, partial refund, dispute, extra time, payout, reconciliation.
3. `docs/SECURITY.md` checklist complete.
4. A super admin deliberately sets `payments.live_enabled=true` and ops sets `ALLOW_LIVE_PAYMENTS=true` with live keys. Nothing here does it automatically.
5. Monitoring: alert on `payments.needs_review`, failed webhooks (5xx), `reconcile_finance().mismatch_count > 0`, cron failures.
