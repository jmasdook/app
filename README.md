# SkillConnect

Secure, Android-first marketplace for booking verified skilled professionals (electrical, plumbing, cleaning, AC, handyman…) in the UAE.
Brand, currency, country, VAT, fees and timing rules are configuration (`application_settings`, `--dart-define`), not code.

| Part | Tech | Folder |
|---|---|---|
| Customer + professional app | Flutter 3.47 / Dart, Riverpod, go_router, supabase_flutter, secure storage | `mobile/` |
| Admin & support portal | Next.js 16, TypeScript | `admin/` |
| Backend | Supabase (Auth, Postgres + RLS, Storage, Edge Functions) | `supabase/` |

Start with **[docs/STATUS.md](docs/STATUS.md)** (what is verified vs. not), then [ARCHITECTURE](docs/ARCHITECTURE.md),
[DATABASE](docs/DATABASE.md), [PAYMENTS](docs/PAYMENTS.md), [SECURITY](docs/SECURITY.md), [DEPLOYMENT](docs/DEPLOYMENT.md), [TESTING](docs/TESTING.md).

## Run everything locally
Prerequisites: Node 22, Flutter 3.47, Deno 2, PostgreSQL 16 (tests) and the [Supabase CLI](https://supabase.com/docs/guides/cli) + Docker (full local stack).

```bash
# 1. Backend tests on a throw-away local Postgres (no Supabase needed)
PGUSER=postgres supabase/tests/run.sh

# 2. Full local stack
supabase start && supabase db reset          # applies migrations + fictional seed
supabase functions serve --env-file .env.local   # copy .env.example -> .env.local (sandbox values)

# 3. Admin portal
cd admin && cp .env.example .env.local        # fill URL + anon key printed by `supabase start`
npm ci && npm run dev                          # http://localhost:3000
#   create a user in Supabase Studio, then promote it once:
#   psql "$DB_URL" -v email="'you@example.com'" -f scripts/bootstrap-admin.sql

# 4. Mobile (Android emulator, 10.0.2.2 reaches the host)
cd mobile && flutter pub get
flutter run --dart-define=SUPABASE_URL=http://10.0.2.2:54321 --dart-define=SUPABASE_ANON_KEY=<anon>
flutter build apk --debug --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
#   -> mobile/build/app/outputs/flutter-apk/app-debug.apk   (needs the Android SDK; CI also builds it)
```
Sandbox payments: set `PAYMENT_PROVIDER=sandbox` and `SANDBOX_SIMULATION_ENABLED=true` (dev only) so the app can simulate paying.
Real money is **off by default** and needs the launch approval described in [DEPLOYMENT](docs/DEPLOYMENT.md).

## Secrets
Only public values (Supabase URL + anon key) go into the apps. Service-role key, payment secrets, FCM credentials and
signing keystores live in Supabase secrets / GitHub encrypted secrets. `.env*`, keystores and `key.properties` are git-ignored; CI runs gitleaks.

## CI
`.github/workflows/ci.yml`: SQL tests (Postgres service), Deno tests, admin typecheck/test/build/audit, Flutter analyze/test/web build/debug APK, secret scan.
`release-android.yml`: manual, confirmation + production-environment gated, requires signing secrets, uploads artifacts only (no store publishing, no deploys).
