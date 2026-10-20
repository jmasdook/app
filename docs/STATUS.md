# Implementation status

Legend: ✅ implemented and tested here · 🟡 implemented, not verifiable in this environment · ⛔ not done

## Verified in this environment
| Area | Result |
|---|---|
| SQL migrations + 11 SQL test files + concurrency (PostgreSQL 16) | ✅ all pass (see docs/TESTING.md) |
| Edge Function unit tests + `deno check` | ✅ 6 tests pass, all functions type-check |
| Admin portal | ✅ 11 vitest tests, `tsc`, `next build`, route guard smoke-tested (unauthenticated → /login) |
| Flutter | ✅ `flutter analyze` clean, 14 unit/widget tests, `flutter build web --release` compiles the whole app |
| Android debug APK | ⛔ blocked: no Android SDK (`dl.google.com` unreachable from this sandbox). CI builds it. |
| Real Supabase project / Stripe test account / FCM | ⛔ no credentials: functions are type-checked and unit-tested, not run against the real services |

## Feature checklist
**Backend** ✅ auth roles & permissions, RLS everywhere, catalogue/pricing/commission (versioned), slot engine + holds + exclusion constraints, state machine, extra-time workflow, payments (abstraction, sandbox, Stripe test adapter 🟡), refunds, ledger, earnings, payout batches, reconciliation, disputes, reviews, tickets, notifications + templates, audit log, maintenance job, account deletion/anonymisation, promotions, CSV report.
**Admin** ✅ login, dashboard, bookings (assign/cancel/history), workers (documents via signed URLs, approve/reject/suspend, skills), customers, services/categories/areas, pricing & commission & settings, promotions, payments & payouts & reconciliation, disputes & refunds, support tickets, reviews, templates, reports CSV, audit, roles. ⛔ editing existing service fields beyond enable/disable, review of credential-expiry list (workers filter `expired_credentials` shows them), charts beyond a simple trend.
**Mobile** ✅ auth (secure session storage), browse/search/filter, service detail, 4-step booking wizard with server-held slot + server price + payment, booking list/detail/timeline, cancel, dispute, review, chat, extra-time approval, notifications, support, addresses, deletion request; worker onboarding (documents, skills, areas, availability, submit), home, jobs, job lifecycle, extra-time request, earnings.
🟡 Live card payment sheet (needs `flutter_stripe` + device test), push registration (needs Firebase config), reschedule UI (RPC `reschedule_booking` exists and is granted; no screen yet), worker-side evidence uploads (RPC exists), refund-request UI (RPC exists), Arabic/RTL (locale column + templates exist; app strings are English only).

## Known limitations / decisions to confirm
* Provider eligibility (Stripe UAE Connect) and the legal fund-flow/VAT treatment must be confirmed before any live money. Worker payouts are recorded and reconciled but not transferred automatically.
* Booking price is not re-quoted on reschedule (surcharge windows are not re-evaluated).
* Only AED/2-decimal currencies are supported by the formatting helpers.
