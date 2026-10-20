-- SkillConnect foundation: types, identity, roles/permissions, settings, catalog.
-- All money is stored as bigint minor units (AED fils) + ISO currency code. Never floats.

create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;
create schema if not exists private;  -- internal functions; never exposed through the API
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('customer', 'worker', 'support', 'admin', 'super_admin');
create type public.worker_status as enum
  ('draft', 'submitted', 'under_review', 'approved', 'rejected', 'suspended', 'expired_credentials');
create type public.document_status as enum ('pending', 'approved', 'rejected');
create type public.pricing_model as enum ('fixed', 'hourly', 'base_plus_extra');
create type public.booking_status as enum
  ('pending_payment', 'assigned', 'accepted', 'en_route', 'arrived', 'in_progress',
   'awaiting_confirmation', 'completed', 'cancelled', 'disputed', 'unassigned');

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------
create function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- Half-up integer division on non-negative numerators (money rounding rule).
create function public.round_div(numer numeric, denom numeric) returns bigint
language sql immutable parallel safe as $$
  select floor((2 * numer + denom) / (2 * denom))::bigint
$$;

-- ---------------------------------------------------------------------------
-- Profiles & roles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 120),
  phone text check (phone is null or phone ~ '^\+?[0-9]{7,15}$'),
  avatar_path text,
  locale text not null default 'en' check (locale in ('en', 'ar')),
  country_code char(2) not null default 'AE',
  marketing_opt_in boolean not null default false,
  deletion_requested_at timestamptz,
  anonymized_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.user_roles (
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.app_role not null,
  granted_by uuid references public.profiles (id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);
create index user_roles_role_idx on public.user_roles (role);

create table public.role_permissions (
  role public.app_role not null,
  permission text not null,
  primary key (role, permission)
);

-- New auth user => profile + customer role. The client can never choose its role.
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120));
  insert into public.user_roles (user_id, role) values (new.id, 'customer');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- True when the call comes from trusted server-side code (service role / direct DB
-- connection) rather than an end user. Anonymous and authenticated JWTs are never system.
create function public.is_system() returns boolean language sql stable as $$
  select auth.uid() is null
     and coalesce(auth.role(), 'service_role') = 'service_role'
$$;

create function public.has_role(p_role public.app_role) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = p_role)
$$;

create function public.has_permission(p_permission text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.role_permissions rp on rp.role = ur.role
    where ur.user_id = auth.uid() and rp.permission in (p_permission, '*')
  )
$$;

create function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles
                 where user_id = auth.uid() and role in ('support', 'admin', 'super_admin'))
$$;

insert into public.role_permissions (role, permission) values
  ('super_admin', '*'),
  ('support', 'customers.read'), ('support', 'bookings.read'), ('support', 'workers.read'),
  ('support', 'support.manage'), ('support', 'disputes.read'), ('support', 'reviews.moderate'),
  ('admin', 'customers.read'), ('admin', 'bookings.read'), ('admin', 'bookings.manage'),
  ('admin', 'workers.read'), ('admin', 'workers.review'), ('admin', 'workers.documents.read'),
  ('admin', 'workers.manage'), ('admin', 'catalog.manage'), ('admin', 'pricing.manage'),
  ('admin', 'payments.read'), ('admin', 'finance.read'), ('admin', 'refunds.approve'),
  ('admin', 'payouts.manage'), ('admin', 'disputes.read'), ('admin', 'disputes.manage'),
  ('admin', 'support.manage'), ('admin', 'reviews.moderate'), ('admin', 'promotions.manage'),
  ('admin', 'notifications.manage'), ('admin', 'audit.read'), ('admin', 'reports.export'),
  ('admin', 'settings.manage'), ('admin', 'users.suspend');

-- ---------------------------------------------------------------------------
-- Application settings (configurable branding, market, money and timing rules)
-- ---------------------------------------------------------------------------
create table public.application_settings (
  key text primary key,
  value jsonb not null,
  description text not null default '',
  is_public boolean not null default false,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create function public.app_setting(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select value from public.application_settings where key = p_key
$$;

create function public.app_setting_int(p_key text, p_default int default 0) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from public.application_settings where key = p_key), p_default)
$$;

insert into public.application_settings (key, value, description, is_public) values
  ('platform.name', '"SkillConnect"', 'Brand name shown in apps and notifications', true),
  ('platform.country', '"AE"', 'Default market (ISO 3166-1 alpha-2)', true),
  ('platform.currency', '"AED"', 'Default currency (ISO 4217)', true),
  ('platform.timezone', '"Asia/Dubai"', 'Default service timezone', true),
  ('tax.default_rate_bps', '500', 'Default tax (UAE VAT 5%) in basis points; services may override', true),
  ('fees.platform_fee_minor', '0', 'Fixed customer service fee per booking (minor units)', true),
  ('booking.reservation_ttl_minutes', '10', 'How long a slot hold lasts before payment', false),
  ('booking.payment_window_minutes', '15', 'Time allowed to pay a pending booking', false),
  ('booking.max_active_reservations', '3', 'Max simultaneous holds per customer', false),
  ('booking.worker_accept_minutes', '60', 'Time a worker has to accept an assigned job', false),
  ('booking.auto_complete_hours', '24', 'Auto-complete after worker marks done and customer is silent', false),
  ('booking.dispute_window_hours', '72', 'Customer may dispute a completed job within this window', false),
  ('extra_time.response_minutes', '15', 'Time the customer has to answer an extra-time request', false),
  ('payouts.hold_hours', '24', 'Hold after completion before earnings become payout-eligible', false),
  ('worker.required_documents', '["identity","qualification"]', 'Document types needed before a worker can be bookable', false),
  ('payments.live_enabled', 'false', 'Must be true (set by an authorised admin after launch approval) to accept live-mode provider events', false);

-- ---------------------------------------------------------------------------
-- Service areas & catalog
-- ---------------------------------------------------------------------------
create table public.service_areas (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null default 'AE',
  city text not null,
  name text not null,
  timezone text not null default 'Asia/Dubai',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (country_code, city, name)
);
create trigger service_areas_updated before update on public.service_areas
  for each row execute function public.set_updated_at();

create table public.public_holidays (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null default 'AE',
  holiday_date date not null,
  name text not null,
  blocks_booking boolean not null default true,
  unique (country_code, holiday_date)
);

create table public.service_categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  description text not null default '',
  image_url text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger service_categories_updated before update on public.service_categories
  for each row execute function public.set_updated_at();

create table public.services (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.service_categories (id) on delete restrict,
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  description text not null default '',
  included text[] not null default '{}',
  excluded text[] not null default '{}',
  image_url text,
  pricing_model public.pricing_model not null,
  currency char(3) not null default 'AED' check (currency ~ '^[A-Z]{3}$'),
  -- fixed: the price. hourly: the hourly rate. base_plus_extra: price for included_minutes.
  base_price_minor bigint not null check (base_price_minor >= 0),
  included_minutes int not null check (included_minutes between 15 and 1440),
  -- Rate for additional hours (extra-time workflow). For hourly services 0 means "use base rate".
  extra_hour_rate_minor bigint not null default 0 check (extra_hour_rate_minor >= 0),
  max_extension_minutes int not null default 120 check (max_extension_minutes >= 0),
  max_duration_minutes int not null default 480 check (max_duration_minutes >= 15),
  slot_minutes int not null default 30 check (slot_minutes in (15, 30, 60)),
  travel_buffer_minutes int not null default 30 check (travel_buffer_minutes between 0 and 240),
  lead_time_minutes int not null default 120 check (lead_time_minutes >= 0),
  tax_rate_bps int check (tax_rate_bps is null or tax_rate_bps between 0 and 10000),
  -- Ordered tiers, most generous first: [{"hours_before":24,"refund_bps":10000}, ...]
  cancellation_policy jsonb not null default
    '[{"hours_before":24,"refund_bps":10000},{"hours_before":4,"refund_bps":5000},{"hours_before":0,"refund_bps":0}]',
  timezone text not null default 'Asia/Dubai',
  popular boolean not null default false,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(cancellation_policy) = 'array')
);
create index services_category_idx on public.services (category_id) where active;
create trigger services_updated before update on public.services
  for each row execute function public.set_updated_at();

create function private.validate_service() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'invalid timezone %', new.timezone using errcode = '22023';
  end if;
  return new;
end $$;
create trigger services_validate before insert or update on public.services
  for each row execute function private.validate_service();

-- Extra pricing rules: fixed fees or percentage surcharges on selected weekdays/hours.
create table public.service_pricing_rules (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services (id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('surcharge_bps', 'fee_fixed')),
  value bigint not null check (value >= 0),
  applies_dow smallint[] not null default '{0,1,2,3,4,5,6}',
  start_minute smallint not null default 0 check (start_minute between 0 and 1439),
  end_minute smallint not null default 1440 check (end_minute between 1 and 1440),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (end_minute > start_minute)
);
create index service_pricing_rules_service_idx on public.service_pricing_rules (service_id) where active;

-- Commission policies are versioned: a rate is never edited, only superseded.
create table public.commission_policies (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('global', 'category', 'service')),
  category_id uuid references public.service_categories (id) on delete restrict,
  service_id uuid references public.services (id) on delete restrict,
  rate_bps int not null check (rate_bps between 0 and 10000),
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  note text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((scope = 'global' and category_id is null and service_id is null)
      or (scope = 'category' and category_id is not null and service_id is null)
      or (scope = 'service' and service_id is not null and category_id is null)),
  check (effective_to is null or effective_to > effective_from)
);
create index commission_policies_lookup_idx on public.commission_policies (scope, category_id, service_id, effective_from desc);

create function private.commission_policy_immutable() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'commission policies cannot be deleted'; end if;
  if new.rate_bps <> old.rate_bps or new.scope <> old.scope
     or new.effective_from <> old.effective_from
     or new.category_id is distinct from old.category_id
     or new.service_id is distinct from old.service_id then
    raise exception 'commission policy terms are immutable; create a new version';
  end if;
  return new;
end $$;
create trigger commission_policies_immutable before update or delete on public.commission_policies
  for each row execute function private.commission_policy_immutable();

create function public.resolve_commission_rate_bps(p_service_id uuid, p_at timestamptz default now())
returns int language sql stable security definer set search_path = public as $$
  select p.rate_bps
  from public.commission_policies p
  join public.services s on s.id = p_service_id
  where p.effective_from <= p_at and (p.effective_to is null or p.effective_to > p_at)
    and (   (p.scope = 'service' and p.service_id = s.id)
         or (p.scope = 'category' and p.category_id = s.category_id)
         or  p.scope = 'global')
  order by case p.scope when 'service' then 1 when 'category' then 2 else 3 end, p.effective_from desc
  limit 1
$$;

-- Promotions
create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code = upper(code) and code ~ '^[A-Z0-9_-]{3,32}$'),
  kind text not null check (kind in ('percent_bps', 'fixed')),
  value bigint not null check (value > 0),
  max_discount_minor bigint check (max_discount_minor is null or max_discount_minor >= 0),
  min_subtotal_minor bigint not null default 0,
  service_id uuid references public.services (id) on delete cascade,
  category_id uuid references public.service_categories (id) on delete cascade,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  max_redemptions int check (max_redemptions is null or max_redemptions > 0),
  per_customer_limit int not null default 1 check (per_customer_limit > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (kind <> 'percent_bps' or value <= 10000)
);
