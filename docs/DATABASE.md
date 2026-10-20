# Database & migrations

Migrations are plain SQL in `supabase/migrations`, applied in filename order (`supabase db push` / CI).

| Migration | Contents |
|---|---|
| 01 foundation | enums, profiles, roles/permissions, settings, areas, categories, services, pricing rules, commission policies, promotions |
| 02 workers | addresses, worker profiles/documents/skills/areas/availability/time off, bookability |
| 03 bookings | reservations, bookings (+exclusion constraint), state transitions, history, assignments, attachments, messages, extra-time |
| 04 finance | payments, events, refunds, commissions, ledger, earnings, payouts, reconciliation |
| 05 support_misc | reviews, notifications/templates/device tokens, tickets, disputes, audit log, idempotency keys |
| 06 pricing_availability | `calculate_pricing`, `available_slots`, `reserve_slot`, notifications, `create_booking` |
| 07 booking_lifecycle | state machine, worker/customer RPCs, reschedule, messaging, extra time, reviews |
| 08 payments_finance | `prepare_payment`, `process_payment_event`, refunds, ledger posting, payouts, reconciliation |
| 09 admin_ops | worker verification, admin booking ops, disputes, roles, bootstrap, deletion, maintenance, dashboard, views, templates |
| 10 rls_grants | RLS on every table, explicit grants, RPC allow-list, storage buckets/policies, audit triggers |
| 11 rate_limits | rate-limit table + function for Edge Functions |
| 12 search_services | catalogue search RPC |

Key relationships: `bookings → profiles(customer) / worker_profiles / services / service_areas`; `payments → bookings
(+extra_time_requests)`; `refunds → payments`; `ledger_transactions → bookings/payments/refunds/payout_items`;
`worker_earnings → bookings/refunds/payout_items`. Deletion policy: financial and booking rows are `ON DELETE RESTRICT`;
account deletion anonymises (`process_account_deletion`) instead of deleting rows.

Rules for new migrations: enable RLS, add explicit grants (the baseline revokes defaults from `anon`/`authenticated`),
add the function to the RPC allow-list if clients may call it, and extend `supabase/tests/60_rls.test.sql`.
Never edit an applied migration; add a new one. Never run tests or migrations destructively against production.
