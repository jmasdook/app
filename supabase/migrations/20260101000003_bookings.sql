-- Booking engine tables: reservations, bookings, state history, assignments,
-- attachments, messages, extra-time requests, promotion redemptions.

create table public.booking_slot_reservations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete cascade,
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  area_id uuid not null references public.service_areas (id) on delete cascade,
  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_minutes int not null,
  blocked_during tstzrange not null,                 -- [start, end + travel buffer)
  status text not null default 'active' check (status in ('active', 'converted', 'released', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (end_at > start_at),
  -- The database itself refuses two live holds on the same worker/time.
  exclude using gist (worker_id with =, blocked_during with &&) where (status = 'active')
);
create index reservations_customer_idx on public.booking_slot_reservations (customer_id) where status = 'active';
create index reservations_expiry_idx on public.booking_slot_reservations (expires_at) where status = 'active';

create sequence public.booking_ref_seq;

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default ('SC-' || lpad(nextval('public.booking_ref_seq')::text, 6, '0')),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  worker_id uuid references public.worker_profiles (id) on delete restrict,
  service_id uuid not null references public.services (id) on delete restrict,
  area_id uuid not null references public.service_areas (id) on delete restrict,
  address_id uuid references public.customer_addresses (id) on delete set null,
  address_snapshot jsonb not null,
  description text not null default '' check (char_length(description) <= 2000),
  status public.booking_status not null default 'pending_payment',
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  duration_minutes int not null check (duration_minutes > 0),
  travel_buffer_minutes int not null default 0,
  blocked_during tstzrange not null,
  timezone text not null,

  -- Snapshot of the terms agreed at confirmation time.
  currency char(3) not null,
  pricing_model public.pricing_model not null,
  included_minutes int not null,
  base_rate_minor bigint not null,
  extra_hour_rate_minor bigint not null,
  commission_rate_bps int not null check (commission_rate_bps between 0 and 10000),
  cancellation_policy jsonb not null,
  pricing_snapshot jsonb not null,

  -- Money (minor units). subtotal = base + surcharges; total = subtotal - discount + fee + tax.
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  discount_minor bigint not null default 0 check (discount_minor >= 0),
  fee_minor bigint not null default 0 check (fee_minor >= 0),
  tax_rate_bps int not null default 0,
  tax_minor bigint not null default 0 check (tax_minor >= 0),
  total_minor bigint not null check (total_minor >= 0),
  commission_minor bigint not null check (commission_minor >= 0),
  worker_earning_minor bigint not null check (worker_earning_minor >= 0),
  promotion_id uuid references public.promotions (id) on delete set null,
  -- Approved & paid extra time (accumulated, each with its own request/payment record).
  extra_minutes int not null default 0 check (extra_minutes >= 0),

  payment_due_at timestamptz,
  accept_by timestamptz,
  accepted_at timestamptz,
  en_route_at timestamptz,
  arrived_at timestamptz,
  started_at timestamptz,
  work_done_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancelled_role text,
  cancellation_reason text,
  reschedule_count int not null default 0,
  reminder_24h_sent_at timestamptz,
  reminder_1h_sent_at timestamptz,
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (scheduled_end > scheduled_start),
  check (total_minor = subtotal_minor - discount_minor + fee_minor + tax_minor),
  check (commission_minor + worker_earning_minor = subtotal_minor - discount_minor),
  unique (customer_id, idempotency_key),
  -- Double-booking guard: a worker cannot have two live bookings that overlap
  -- (including the travel buffer). This is enforced by PostgreSQL, not by clients.
  constraint bookings_no_worker_overlap exclude using gist (worker_id with =, blocked_during with &&)
    where (worker_id is not null and status in
      ('pending_payment', 'assigned', 'accepted', 'en_route', 'arrived', 'in_progress', 'awaiting_confirmation'))
);
create index bookings_customer_idx on public.bookings (customer_id, scheduled_start desc);
create index bookings_worker_idx on public.bookings (worker_id, scheduled_start desc);
create index bookings_status_idx on public.bookings (status, scheduled_start);
create index bookings_payment_due_idx on public.bookings (payment_due_at) where status = 'pending_payment';
create trigger bookings_updated before update on public.bookings
  for each row execute function public.set_updated_at();

-- Keep blocked_during in sync (timestamptz + interval is only STABLE, so no generated column).
create function private.bookings_set_range() returns trigger language plpgsql as $$
begin
  new.blocked_during := tstzrange(new.scheduled_start,
                                  new.scheduled_end + make_interval(mins => new.travel_buffer_minutes), '[)');
  return new;
end $$;
create trigger bookings_range before insert or update of scheduled_start, scheduled_end, travel_buffer_minutes
  on public.bookings for each row execute function private.bookings_set_range();

-- Status may only change through private._transition_booking (sets the GUC).
create function private.bookings_status_guard() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status
     and coalesce(current_setting('app.booking_transition', true), '') <> 'on' then
    raise exception 'booking status can only change through the state machine' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger bookings_status_guard before update on public.bookings
  for each row execute function private.bookings_status_guard();

create table public.booking_status_transitions (
  from_status public.booking_status not null,
  to_status public.booking_status not null,
  actors text[] not null,   -- subset of {customer,worker,admin,system}
  primary key (from_status, to_status)
);
insert into public.booking_status_transitions values
  ('pending_payment', 'assigned',              '{system}'),
  ('pending_payment', 'cancelled',             '{customer,admin,system}'),
  ('assigned',        'accepted',              '{worker}'),
  ('assigned',        'unassigned',            '{worker,admin,system}'),
  ('assigned',        'cancelled',             '{customer,admin}'),
  ('assigned',        'disputed',              '{admin}'),
  ('accepted',        'en_route',              '{worker}'),
  ('accepted',        'unassigned',            '{worker,admin}'),
  ('accepted',        'cancelled',             '{customer,admin}'),
  ('accepted',        'disputed',              '{admin}'),
  ('en_route',        'arrived',               '{worker}'),
  ('en_route',        'cancelled',             '{admin}'),
  ('en_route',        'disputed',              '{customer,admin}'),
  ('arrived',         'in_progress',           '{worker}'),
  ('arrived',         'cancelled',             '{admin}'),
  ('arrived',         'disputed',              '{customer,admin}'),
  ('in_progress',     'awaiting_confirmation', '{worker}'),
  ('in_progress',     'disputed',              '{customer,worker,admin}'),
  ('in_progress',     'cancelled',             '{admin}'),
  ('awaiting_confirmation', 'completed',       '{customer,admin,system}'),
  ('awaiting_confirmation', 'disputed',        '{customer,worker,admin}'),
  ('completed',       'disputed',              '{customer,admin}'),
  ('unassigned',      'assigned',              '{admin}'),
  ('unassigned',      'cancelled',             '{customer,admin}'),
  ('disputed',        'completed',             '{admin}'),
  ('disputed',        'cancelled',             '{admin}');

create table public.booking_status_history (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings (id) on delete cascade,
  from_status public.booking_status,
  to_status public.booking_status not null,
  actor_id uuid references public.profiles (id) on delete set null,
  actor_role text not null,
  reason text,
  created_at timestamptz not null default now()
);
create index booking_status_history_idx on public.booking_status_history (booking_id, created_at);

create table public.booking_assignments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  worker_id uuid not null references public.worker_profiles (id) on delete restrict,
  assigned_by uuid references public.profiles (id) on delete set null,
  assigned_via text not null check (assigned_via in ('auto', 'admin')),
  response text not null default 'pending' check (response in ('pending', 'accepted', 'rejected', 'withdrawn', 'reassigned', 'timed_out')),
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  note text
);
create index booking_assignments_booking_idx on public.booking_assignments (booking_id);
create unique index booking_assignments_one_open on public.booking_assignments (booking_id) where ended_at is null;

create table public.booking_attachments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  uploaded_by uuid not null references public.profiles (id) on delete cascade,
  storage_path text not null unique,
  kind text not null check (kind in ('issue_photo', 'completion_evidence', 'extra_time_evidence')),
  created_at timestamptz not null default now()
);
create index booking_attachments_booking_idx on public.booking_attachments (booking_id);

create table public.booking_messages (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index booking_messages_idx on public.booking_messages (booking_id, created_at);

create table public.promotion_redemptions (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions (id) on delete cascade,
  customer_id uuid not null references public.profiles (id) on delete cascade,
  booking_id uuid not null unique references public.bookings (id) on delete cascade,
  discount_minor bigint not null,
  released_at timestamptz,
  created_at timestamptz not null default now()
);
create index promotion_redemptions_idx on public.promotion_redemptions (promotion_id, customer_id) where released_at is null;

-- Extra-time: the worker asks, the customer decides, payment authorises the charge.
create table public.extra_time_requests (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  worker_id uuid not null references public.worker_profiles (id) on delete restrict,
  requested_minutes int not null check (requested_minutes > 0 and requested_minutes % 15 = 0),
  reason text not null check (char_length(reason) between 5 and 500),
  evidence_paths text[] not null default '{}',
  status text not null default 'pending'
    check (status in ('pending', 'awaiting_payment', 'approved', 'rejected', 'expired', 'cancelled', 'escalated')),
  currency char(3) not null,
  rate_minor bigint not null,                  -- hourly rate snapshot
  net_minor bigint not null check (net_minor >= 0),
  tax_rate_bps int not null,
  tax_minor bigint not null check (tax_minor >= 0),
  total_minor bigint not null check (total_minor = net_minor + tax_minor),
  commission_rate_bps int not null,
  commission_minor bigint not null,
  worker_earning_minor bigint not null,
  expires_at timestamptz not null,
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  payment_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (commission_minor + worker_earning_minor = net_minor)
);
create index extra_time_booking_idx on public.extra_time_requests (booking_id);
-- Duplicate-request / duplicate-charge protection: one open request per booking.
create unique index extra_time_one_open on public.extra_time_requests (booking_id)
  where status in ('pending', 'awaiting_payment');
create trigger extra_time_updated before update on public.extra_time_requests
  for each row execute function public.set_updated_at();
