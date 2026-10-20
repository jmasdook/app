-- Payments, refunds, commissions, append-only ledger, worker earnings, payouts.
-- Keeps four things conceptually distinct:
--   (1) money collected by the provider (payments / PROVIDER_CLEARING)
--   (2) what we owe workers (WORKER_PAYABLE / worker_earnings)
--   (3) platform revenue (COMMISSION_REVENUE, FEE_REVENUE)
--   (4) actual bank settlement (reconciliation_runs; never inferred from client claims)

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete restrict,
  extra_time_request_id uuid references public.extra_time_requests (id) on delete restrict,
  purpose text not null check (purpose in ('booking', 'extra_time')),
  provider text not null,                              -- 'stripe', 'sandbox', ...
  provider_ref text,                                   -- session / intent id
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'pending' check (status in
    ('pending', 'requires_action', 'authorized', 'succeeded', 'failed', 'cancelled', 'partially_refunded', 'refunded')),
  is_sandbox boolean not null default true,
  livemode boolean not null default false,
  allocated boolean not null default false,            -- funds applied to a booking / extra request
  needs_review boolean not null default false,
  review_reason text,
  refunded_minor bigint not null default 0 check (refunded_minor >= 0),
  idempotency_key text not null unique,
  expires_at timestamptz,
  succeeded_at timestamptz,
  failure_code text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((purpose = 'extra_time') = (extra_time_request_id is not null)),
  check (refunded_minor <= amount_minor),
  unique (provider, provider_ref)
);
create index payments_booking_idx on public.payments (booking_id);
create unique index payments_one_allocated_booking on public.payments (booking_id)
  where purpose = 'booking' and allocated;
create unique index payments_one_allocated_extra on public.payments (extra_time_request_id)
  where purpose = 'extra_time' and allocated;
create trigger payments_updated before update on public.payments
  for each row execute function public.set_updated_at();

-- Raw provider notifications. Unique (provider, event id) makes redelivery idempotent.
create table public.payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  payment_id uuid references public.payments (id) on delete set null,
  livemode boolean not null default false,
  payload jsonb not null default '{}'::jsonb,         -- minimal, PII-free subset
  processing_status text not null default 'received'
    check (processing_status in ('received', 'processed', 'ignored', 'error')),
  processing_note text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, provider_event_id)
);
create index payment_events_payment_idx on public.payment_events (payment_id);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete restrict,
  booking_id uuid not null references public.bookings (id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  status text not null default 'requested' check (status in
    ('requested', 'approved', 'processing', 'succeeded', 'failed', 'rejected')),
  reason_code text not null check (reason_code in
    ('customer_cancellation', 'worker_cancellation', 'admin_cancellation', 'payment_timeout_late_capture',
     'duplicate_payment', 'dispute_resolution', 'service_issue', 'other')),
  reason text,
  refund_bps int check (refund_bps between 0 and 10000),
  -- Exact decomposition of the refund (sums to amount_minor).
  tax_part_minor bigint not null default 0,
  fee_part_minor bigint not null default 0,
  commission_part_minor bigint not null default 0,
  earning_part_minor bigint not null default 0,
  unapplied_part_minor bigint not null default 0,
  requested_by uuid references public.profiles (id) on delete set null,
  requested_role text not null,
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  provider_refund_ref text,
  idempotency_key text not null unique,
  succeeded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (tax_part_minor + fee_part_minor + commission_part_minor + earning_part_minor + unapplied_part_minor = amount_minor)
);
create index refunds_payment_idx on public.refunds (payment_id);
create index refunds_status_idx on public.refunds (status);
create trigger refunds_updated before update on public.refunds
  for each row execute function public.set_updated_at();

-- Append-only: earned commission rows (+) and reversal rows (-).
create table public.commissions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete restrict,
  extra_time_request_id uuid references public.extra_time_requests (id) on delete restrict,
  refund_id uuid references public.refunds (id) on delete restrict,
  kind text not null check (kind in ('earned', 'reversal')),
  rate_bps int not null,
  amount_minor bigint not null,
  currency char(3) not null,
  created_at timestamptz not null default now(),
  check ((kind = 'earned' and amount_minor >= 0) or (kind = 'reversal' and amount_minor <= 0))
);
create index commissions_booking_idx on public.commissions (booking_id);

-- ---------------------------------------------------------------------------
-- Double-entry ledger (append-only; corrections are compensating transactions)
-- ---------------------------------------------------------------------------
create table public.ledger_accounts (
  id smallint generated always as identity primary key,
  code text not null unique,
  name text not null,
  account_type text not null check (account_type in ('asset', 'liability', 'revenue', 'expense'))
);
insert into public.ledger_accounts (code, name, account_type) values
  ('PROVIDER_CLEARING',   'Funds held by payment provider (not yet settled to bank)', 'asset'),
  ('WORKER_PAYABLE',      'Owed to workers (sub-ledger by worker)',                   'liability'),
  ('COMMISSION_REVENUE',  'Platform commission revenue',                              'revenue'),
  ('FEE_REVENUE',         'Customer service-fee revenue',                             'revenue'),
  ('TAX_PAYABLE',         'Tax collected, owed to the tax authority',                 'liability'),
  ('CUSTOMER_UNAPPLIED',  'Customer funds received but not applied to a booking',     'liability');

create table public.ledger_transactions (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in
    ('payment_captured', 'payment_unallocated', 'refund', 'payout', 'payout_reversal', 'adjustment')),
  description text not null default '',
  booking_id uuid references public.bookings (id) on delete restrict,
  payment_id uuid references public.payments (id) on delete restrict,
  refund_id uuid references public.refunds (id) on delete restrict,
  payout_item_id uuid,
  reverses_id uuid references public.ledger_transactions (id) on delete restrict,
  currency char(3) not null,
  idempotency_key text not null unique,
  created_by uuid references public.profiles (id) on delete set null,
  posted_at timestamptz not null default now()
);
create index ledger_transactions_booking_idx on public.ledger_transactions (booking_id);

create table public.ledger_entries (
  id bigint generated always as identity primary key,
  transaction_id uuid not null references public.ledger_transactions (id) on delete restrict,
  account_id smallint not null references public.ledger_accounts (id),
  direction text not null check (direction in ('debit', 'credit')),
  amount_minor bigint not null check (amount_minor > 0),
  worker_id uuid references public.worker_profiles (id) on delete restrict
);
create index ledger_entries_tx_idx on public.ledger_entries (transaction_id);
create index ledger_entries_account_idx on public.ledger_entries (account_id, worker_id);

create function private.ledger_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'ledger records are append-only; post a compensating transaction' using errcode = '42501';
end $$;
create trigger ledger_transactions_immutable before update or delete on public.ledger_transactions
  for each row execute function private.ledger_immutable();
create trigger ledger_entries_immutable before update or delete on public.ledger_entries
  for each row execute function private.ledger_immutable();

-- Every transaction must balance (checked at commit so entries can be inserted one by one).
create function private.ledger_check_balanced() returns trigger language plpgsql as $$
declare v_debits bigint; v_credits bigint;
begin
  select coalesce(sum(amount_minor) filter (where direction = 'debit'), 0),
         coalesce(sum(amount_minor) filter (where direction = 'credit'), 0)
    into v_debits, v_credits
  from public.ledger_entries where transaction_id = new.transaction_id;
  if v_debits <> v_credits then
    raise exception 'unbalanced ledger transaction % (debits %, credits %)', new.transaction_id, v_debits, v_credits;
  end if;
  return null;
end $$;
create constraint trigger ledger_entries_balanced after insert on public.ledger_entries
  deferrable initially deferred for each row execute function private.ledger_check_balanced();

-- ---------------------------------------------------------------------------
-- Worker earnings & payouts
-- ---------------------------------------------------------------------------
create table public.payout_batches (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'draft' check (status in ('draft', 'processing', 'completed', 'failed', 'cancelled')),
  currency char(3) not null,
  total_minor bigint not null default 0 check (total_minor >= 0),
  item_count int not null default 0,
  idempotency_key text not null unique,
  provider_batch_ref text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.payout_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.payout_batches (id) on delete restrict,
  worker_id uuid not null references public.worker_profiles (id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'failed')),
  provider_payout_ref text,
  failure_reason text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (batch_id, worker_id)
);
create index payout_items_worker_idx on public.payout_items (worker_id);

create table public.worker_earnings (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.worker_profiles (id) on delete restrict,
  booking_id uuid references public.bookings (id) on delete restrict,
  extra_time_request_id uuid references public.extra_time_requests (id) on delete restrict,
  refund_id uuid references public.refunds (id) on delete restrict,
  kind text not null check (kind in ('job', 'extra_time', 'refund_adjustment', 'manual_adjustment')),
  amount_minor bigint not null,                          -- signed; adjustments may be negative
  currency char(3) not null,
  status text not null default 'pending'
    check (status in ('pending', 'eligible', 'held', 'in_payout', 'paid', 'netted', 'void')),
  eligible_at timestamptz,
  payout_item_id uuid references public.payout_items (id) on delete restrict,
  note text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind in ('job', 'extra_time') and amount_minor >= 0) or kind not in ('job', 'extra_time')),
  check (status not in ('in_payout', 'paid') or payout_item_id is not null)
);
create index worker_earnings_worker_idx on public.worker_earnings (worker_id, status);
create index worker_earnings_booking_idx on public.worker_earnings (booking_id);
create unique index worker_earnings_job_once on public.worker_earnings (booking_id) where kind = 'job' and status <> 'void';
create unique index worker_earnings_extra_once on public.worker_earnings (extra_time_request_id) where kind = 'extra_time';
create unique index worker_earnings_refund_once on public.worker_earnings (refund_id) where kind = 'refund_adjustment';
create trigger worker_earnings_updated before update on public.worker_earnings
  for each row execute function public.set_updated_at();

create table public.reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('provider_payments', 'payouts', 'ledger')),
  run_by uuid references public.profiles (id) on delete set null,
  mismatches int not null default 0,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Link extra-time requests to their payment now that payments exist.
alter table public.extra_time_requests
  add column payment_id uuid references public.payments (id) on delete set null;
