-- Customers' addresses, worker profiles, credentials, skills, areas, availability.

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  label text not null default 'Home',
  line1 text not null check (char_length(line1) between 3 and 200),
  line2 text,
  city text not null,
  area_id uuid not null references public.service_areas (id) on delete restrict,
  latitude numeric(9, 6) check (latitude between -90 and 90),
  longitude numeric(9, 6) check (longitude between -180 and 180),
  access_notes text check (char_length(access_notes) <= 500),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customer_addresses_user_idx on public.customer_addresses (user_id);
create unique index customer_addresses_one_default on public.customer_addresses (user_id) where is_default;
create trigger customer_addresses_updated before update on public.customer_addresses
  for each row execute function public.set_updated_at();

create table public.worker_profiles (
  id uuid primary key references public.profiles (id) on delete restrict,
  status public.worker_status not null default 'draft',
  bio text not null default '' check (char_length(bio) <= 1000),
  years_experience smallint check (years_experience between 0 and 60),
  service_radius_km smallint not null default 15 check (service_radius_km between 1 and 200),
  base_latitude numeric(9, 6),
  base_longitude numeric(9, 6),
  is_available boolean not null default true,        -- worker-controlled online/offline switch
  rating_avg numeric(3, 2) not null default 0,
  rating_count int not null default 0,
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  status_reason text,                                -- rejection / suspension reason
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index worker_profiles_status_idx on public.worker_profiles (status);
create trigger worker_profiles_updated before update on public.worker_profiles
  for each row execute function public.set_updated_at();

create table public.worker_documents (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  doc_type text not null check (doc_type in ('identity', 'qualification', 'trade_license', 'police_clearance', 'other')),
  title text not null default '',
  storage_path text not null,                        -- path inside the private worker-documents bucket
  status public.document_status not null default 'pending',
  expires_on date,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  unique (storage_path)
);
create index worker_documents_worker_idx on public.worker_documents (worker_id);
create index worker_documents_expiry_idx on public.worker_documents (expires_on) where status = 'approved';

-- A worker can only create pending documents inside their own storage folder.
create function private.worker_document_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and not public.is_system() then
    new.status := 'pending'; new.reviewed_by := null; new.reviewed_at := null; new.review_note := null;
    if split_part(new.storage_path, '/', 1) <> new.worker_id::text then
      raise exception 'storage path must start with the worker id' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger worker_documents_guard before insert on public.worker_documents
  for each row execute function private.worker_document_guard();

create table public.worker_skills (
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  approved boolean not null default false,           -- only admins may set true
  years_experience smallint check (years_experience between 0 and 60),
  created_at timestamptz not null default now(),
  primary key (worker_id, service_id)
);

create table public.worker_service_areas (
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  area_id uuid not null references public.service_areas (id) on delete cascade,
  primary key (worker_id, area_id)
);

-- Working windows per weekday (0=Sunday..6=Saturday), in the service timezone.
-- A break is simply a gap between two windows on the same day.
create table public.worker_availability (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  dow smallint not null check (dow between 0 and 6),
  start_minute smallint not null check (start_minute between 0 and 1439),
  end_minute smallint not null check (end_minute between 1 and 1440),
  check (end_minute > start_minute),
  exclude using gist (worker_id with =, dow with =, int4range(start_minute, end_minute) with &&)
);

create table public.worker_time_off (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.worker_profiles (id) on delete cascade,
  during tstzrange not null,
  reason text,
  created_at timestamptz not null default now(),
  check (not isempty(during) and lower_inf(during) = false and upper_inf(during) = false)
);
create index worker_time_off_idx on public.worker_time_off using gist (worker_id, during);

-- Every required credential type is approved and unexpired.
create function public.worker_documents_valid(p_worker_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1
    from jsonb_array_elements_text(coalesce(public.app_setting('worker.required_documents'), '[]'::jsonb)) r (t)
    where not exists (
      select 1 from public.worker_documents d
      where d.worker_id = p_worker_id and d.doc_type = r.t and d.status = 'approved'
        and (d.expires_on is null or d.expires_on > current_date)))
$$;

-- Bookable = approved by an admin AND every required credential valid.
create function public.is_worker_bookable(p_worker_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.worker_profiles w where w.id = p_worker_id and w.status = 'approved')
     and public.worker_documents_valid(p_worker_id)
$$;

-- Only admins may approve skills; workers may only add unapproved skills.
create function private.worker_skill_guard() returns trigger language plpgsql as $$
begin
  if not public.is_system() and not public.has_permission('workers.manage') then
    if tg_op = 'INSERT' then new.approved := false;
    elsif new.approved is distinct from old.approved then
      raise exception 'only administrators can approve skills' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger worker_skills_guard before insert or update on public.worker_skills
  for each row execute function private.worker_skill_guard();

-- Workers may not change verification state, rating or review fields directly.
create function private.worker_profile_guard() returns trigger language plpgsql as $$
begin
  if public.is_system() or public.has_permission('workers.review')
     or coalesce(current_setting('app.internal_write', true), '') = 'on' then return new; end if;
  if new.status is distinct from old.status or new.rating_avg is distinct from old.rating_avg
     or new.rating_count is distinct from old.rating_count or new.reviewed_by is distinct from old.reviewed_by
     or new.reviewed_at is distinct from old.reviewed_at or new.status_reason is distinct from old.status_reason
     or new.submitted_at is distinct from old.submitted_at then
    raise exception 'protected worker fields cannot be changed directly' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger worker_profiles_guard before update on public.worker_profiles
  for each row execute function private.worker_profile_guard();
