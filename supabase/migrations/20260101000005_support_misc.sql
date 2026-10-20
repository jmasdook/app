-- Reviews, notifications, support, disputes, audit log, idempotency.

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings (id) on delete cascade,
  customer_id uuid not null references public.profiles (id) on delete cascade,
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 1000),
  status text not null default 'published' check (status in ('published', 'hidden')),
  moderated_by uuid references public.profiles (id) on delete set null,
  moderation_note text,
  created_at timestamptz not null default now()
);
create index reviews_worker_idx on public.reviews (worker_id) where status = 'published';

create table public.notification_templates (
  key text not null,
  locale text not null default 'en' check (locale in ('en', 'ar')),
  title text not null,
  body text not null,
  updated_at timestamptz not null default now(),
  primary key (key, locale)
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  push_status text not null default 'pending' check (push_status in ('pending', 'sent', 'failed', 'skipped')),
  push_attempts smallint not null default 0,
  push_error text,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_push_idx on public.notifications (created_at) where push_status = 'pending';

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null unique,
  platform text not null default 'android' check (platform in ('android', 'ios', 'web')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  booking_id uuid references public.bookings (id) on delete set null,
  category text not null default 'general' check (category in ('general', 'booking', 'payment', 'complaint', 'account', 'worker_conduct')),
  subject text not null check (char_length(subject) between 3 and 200),
  status text not null default 'open' check (status in ('open', 'pending', 'resolved', 'closed')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  assigned_to uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index support_tickets_user_idx on public.support_tickets (user_id);
create index support_tickets_status_idx on public.support_tickets (status, created_at);
create trigger support_tickets_updated before update on public.support_tickets
  for each row execute function public.set_updated_at();

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  is_internal boolean not null default false,        -- staff-only note
  created_at timestamptz not null default now()
);
create index support_messages_ticket_idx on public.support_messages (ticket_id, created_at);

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete restrict,
  raised_by uuid not null references public.profiles (id) on delete restrict,
  raised_role text not null check (raised_role in ('customer', 'worker', 'admin')),
  extra_time_request_id uuid references public.extra_time_requests (id) on delete set null,
  reason text not null check (char_length(reason) between 10 and 2000),
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'rejected')),
  outcome text check (outcome in ('full_refund', 'partial_refund', 'no_refund', 'worker_adjustment')),
  resolution_note text,
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  prior_status public.booking_status not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index disputes_booking_idx on public.disputes (booking_id);
create unique index disputes_one_open on public.disputes (booking_id) where status in ('open', 'investigating');
create trigger disputes_updated before update on public.disputes
  for each row execute function public.set_updated_at();

create table public.admin_audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid,
  actor_role text,
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index admin_audit_logs_entity_idx on public.admin_audit_logs (entity_type, entity_id);
create index admin_audit_logs_actor_idx on public.admin_audit_logs (actor_id, created_at desc);

create function private.audit_log_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit log is append-only' using errcode = '42501'; end $$;
create trigger admin_audit_logs_immutable before update or delete on public.admin_audit_logs
  for each row execute function private.audit_log_immutable();

create table public.idempotency_keys (
  scope text not null,
  key text not null,
  actor_id uuid,
  response jsonb,
  created_at timestamptz not null default now(),
  primary key (scope, key)
);
