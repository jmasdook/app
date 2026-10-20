# Testing

| Suite | Command | Needs |
|---|---|---|
| SQL (schema, RLS, pricing, booking engine, payments, concurrency) | `PGUSER=postgres supabase/tests/run.sh` | local PostgreSQL 15+ (never remote; the script refuses non-local hosts) |
| Edge Functions | `cd supabase/functions && deno test --allow-env` and `deno check */index.ts` | Deno 2 |
| Admin portal | `cd admin && npm test && npm run typecheck && npm run build` | Node 22 |
| Flutter | `cd mobile && flutter analyze && flutter test` | Flutter 3.47 |
| Flutter builds | `flutter build web` (compile check) / `flutter build apk --debug` | Android SDK for APK |

`run.sh` creates a throw-away DB, applies `00_supabase_shim.sql` (emulates `auth`, `storage`, roles — never apply it to Supabase),
all migrations, `seed.sql`, then every `*.test.sql` and `concurrency.sh` (parallel sessions race for one slot and one webhook).
