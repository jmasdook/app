# Architecture

```
Flutter app (customer + professional)  ─┐
Next.js admin portal (staff)           ─┼─►  Supabase Auth ─► PostgREST (RLS) ─► PostgreSQL
                                         │                                       ▲  ▲
                                         └─►  Edge Functions (Deno) ──────────────┘  │
                                              create-payment • payments-webhook      │
                                              process-refunds • maintenance • push   │
Payment provider (Stripe test mode / sandbox) ──signed webhooks──► payments-webhook ─┘
```

**Principle: the database is the product.** Pricing, availability, the booking state machine, the ledger and
authorisation live in PostgreSQL functions, constraints and RLS. Clients are thin and untrusted; Edge Functions only
add things the database cannot do (talk to the payment provider, push, cron triggers).

## Components
| Path | What |
|---|---|
| `supabase/migrations` | Versioned schema, RLS, business functions (applied in order) |
| `supabase/seed.sql` | Fictional development data |
| `supabase/functions` | Edge Functions + provider abstraction (`_shared/providers`) |
| `supabase/tests` | SQL tests (pricing, availability, booking, payments, extra time, RLS, payouts, concurrency) |
| `admin/` | Next.js 16 admin portal; acts as the signed-in staff user (no service key) |
| `mobile/` | Flutter app: feature folders, Riverpod, go_router, repositories behind interfaces |

## Booking flow
1. `available_slots()` computes slots from worker windows, time off, holidays, existing bookings (+travel buffer), live holds, lead time.
2. `reserve_slot()` locks the worker row, re-checks, inserts a hold. An `EXCLUDE USING gist` constraint on
   `(worker_id, blocked_during)` is the final guard, so two customers can never hold or book the same worker/time.
3. `create_booking()` revalidates, calls `calculate_pricing()`, snapshots price/commission/policy, converts the hold.
4. `create-payment` (Edge) calls `prepare_payment()` as the user (amount read from DB) then the provider.
5. Provider webhook → signature verified → `process_payment_event()` (idempotent) → ledger entries, earning, commission, `pending_payment → assigned`.
6. Worker: accept → en route → arrived → in progress → awaiting confirmation; customer confirms (or auto-complete after 24 h).
7. Earnings become payout-eligible after a hold (default 24 h) with no open dispute/refund; admins create payout batches.

## State machine
`booking_status_transitions` lists every legal `(from, to, actors)`. `private.transition_booking()` is the only code
path that changes `bookings.status` (a trigger rejects any other writer) and writes `booking_status_history`
(actor, role, reason, time). See `supabase/migrations/20260101000003_bookings.sql`.

## Pricing & commission
Integer minor units everywhere. `round_div` = half-up on non-negative values.
* base: fixed → price; hourly → `rate × minutes / 60` (rounded once); base_plus_extra → base price (extra hours are billed through the extra-time workflow).
* surcharges (`service_pricing_rules`), then promo discount (capped, never > subtotal), then optional fixed customer fee.
* **Tax** (VAT, default 5 %) = rate × (subtotal − discount + fee); prices are tax-exclusive.
* **Commission** = rate × (subtotal − discount). It excludes tax and the customer fee. Worker earning = net − commission (remainder arithmetic: no unit is lost).
* Commission rate: service policy > category policy > global; versioned (never edited), snapshotted on the booking.
* Refunds are decomposed exactly (tax / fee / commission / worker earning); the final refund takes the exact remainder.
* Tax treatment and who remits VAT is an accounting decision: confirm with a UAE tax adviser before launch.

## Extra time
`request_extra_time` (worker, price computed server-side, one open request per booking, max extension, no overlap with next job)
→ `decide_extra_time` (customer only) → approval opens a **payment step**; only a verified provider event finalises
the charge. Unresponsive customer: request expires (default 15 min), nothing is charged; worker may escalate to a
support ticket. Admins can investigate but cannot authorise charges on the customer's behalf.

## Ledger
Append-only double-entry (`ledger_transactions/entries`, immutable triggers, deferred balance check). Accounts:
PROVIDER_CLEARING, WORKER_PAYABLE (per worker), COMMISSION_REVENUE, FEE_REVENUE, TAX_PAYABLE, CUSTOMER_UNAPPLIED.
Corrections are compensating transactions. `reconcile_finance()` checks balance, worker payable vs earnings, payout batches vs items.
No stored-value wallet exists: "payable" is an accounting liability, money moves only via the provider/payout channel.
