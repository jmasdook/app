-- Pricing engine, availability, slot reservations, booking creation. All server-side.
-- Rounding: every percentage/proration uses round_div (half-up, integer arithmetic on minor units).
-- Splits use "remainder" arithmetic (earning = net - commission) so no minor unit is ever lost.

create function private.err(p_code text, p_detail text default null) returns void
language plpgsql as $$
begin
  raise exception '%', p_code using errcode = 'P0001', detail = coalesce(p_detail, '');
end $$;

-- ---------------------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------------------
create function public.calculate_pricing(
  p_service_id uuid, p_start timestamptz, p_duration_minutes int default null,
  p_promo_code text default null, p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, private as $$
declare
  s public.services%rowtype;
  v_dur int; v_base bigint; v_surcharge bigint := 0; v_sub bigint; v_disc bigint := 0;
  v_fee bigint; v_tax_rate int; v_tax bigint; v_net bigint; v_rate int; v_comm bigint;
  v_lines jsonb := '[]'::jsonb; v_local timestamp; v_dow int; v_min int; r record;
  pr public.promotions%rowtype; v_promo jsonb := null; v_cust uuid := coalesce(p_customer_id, auth.uid());
  v_amt bigint;
begin
  select * into s from public.services where id = p_service_id and active;
  if not found then perform private.err('service_not_found'); end if;

  v_dur := coalesce(p_duration_minutes, s.included_minutes);
  if s.pricing_model = 'hourly' then
    if v_dur < s.included_minutes or v_dur > s.max_duration_minutes or v_dur % 30 <> 0 then
      perform private.err('invalid_duration');
    end if;
    v_base := public.round_div(s.base_price_minor::numeric * v_dur, 60);
  else
    if v_dur <> s.included_minutes then perform private.err('invalid_duration'); end if;
    v_base := s.base_price_minor;
  end if;
  v_lines := v_lines || jsonb_build_object('type', 'base', 'label', s.name, 'amount_minor', v_base);

  v_local := p_start at time zone s.timezone;
  v_dow := extract(dow from v_local)::int;
  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  for r in select * from public.service_pricing_rules
           where service_id = s.id and active and v_dow = any (applies_dow)
             and v_min >= start_minute and v_min < end_minute order by created_at, id loop
    v_amt := case r.kind when 'surcharge_bps' then public.round_div(v_base::numeric * r.value, 10000) else r.value end;
    v_surcharge := v_surcharge + v_amt;
    v_lines := v_lines || jsonb_build_object('type', 'surcharge', 'label', r.name, 'amount_minor', v_amt);
  end loop;
  v_sub := v_base + v_surcharge;

  if p_promo_code is not null and p_promo_code <> '' then
    select * into pr from public.promotions
     where code = upper(p_promo_code) and active and starts_at <= now() and (ends_at is null or ends_at > now());
    if not found
       or (pr.service_id is not null and pr.service_id <> s.id)
       or (pr.category_id is not null and pr.category_id <> s.category_id)
       or v_sub < pr.min_subtotal_minor
       or (pr.max_redemptions is not null and
           (select count(*) from public.promotion_redemptions where promotion_id = pr.id and released_at is null) >= pr.max_redemptions)
       or (v_cust is not null and
           (select count(*) from public.promotion_redemptions
             where promotion_id = pr.id and customer_id = v_cust and released_at is null) >= pr.per_customer_limit)
    then perform private.err('promo_not_applicable'); end if;
    v_disc := case pr.kind when 'percent_bps' then public.round_div(v_sub::numeric * pr.value, 10000) else pr.value end;
    if pr.max_discount_minor is not null then v_disc := least(v_disc, pr.max_discount_minor); end if;
    v_disc := least(v_disc, v_sub);
    v_promo := jsonb_build_object('id', pr.id, 'code', pr.code);
    v_lines := v_lines || jsonb_build_object('type', 'discount', 'label', pr.code, 'amount_minor', -v_disc);
  end if;

  v_fee := public.app_setting_int('fees.platform_fee_minor', 0);
  if v_fee > 0 then
    v_lines := v_lines || jsonb_build_object('type', 'fee', 'label', 'Service fee', 'amount_minor', v_fee);
  end if;

  -- Tax applies to (service amount after discount + customer fee); prices are tax-exclusive.
  v_tax_rate := coalesce(s.tax_rate_bps, public.app_setting_int('tax.default_rate_bps', 0));
  v_tax := public.round_div((v_sub - v_disc + v_fee)::numeric * v_tax_rate, 10000);
  if v_tax > 0 then
    v_lines := v_lines || jsonb_build_object('type', 'tax', 'label', 'VAT', 'amount_minor', v_tax);
  end if;

  -- Commission is charged on the service amount after discount; excludes tax and the customer fee.
  v_net := v_sub - v_disc;
  v_rate := coalesce(public.resolve_commission_rate_bps(s.id, now()), 0);
  v_comm := public.round_div(v_net::numeric * v_rate, 10000);

  return jsonb_build_object(
    'service_id', s.id, 'currency', s.currency, 'pricing_model', s.pricing_model,
    'duration_minutes', v_dur, 'base_minor', v_base, 'surcharge_minor', v_surcharge,
    'subtotal_minor', v_sub, 'discount_minor', v_disc, 'fee_minor', v_fee,
    'tax_rate_bps', v_tax_rate, 'tax_minor', v_tax,
    'total_minor', v_sub - v_disc + v_fee + v_tax,
    'service_net_minor', v_net, 'commission_rate_bps', v_rate,
    'commission_minor', v_comm, 'worker_earning_minor', v_net - v_comm,
    'promotion', v_promo, 'lines', v_lines);
end $$;

-- Cancellation refund percentage for a given moment, from the booking's own snapshot.
create function public.refund_bps_for_cancellation(p_policy jsonb, p_start timestamptz, p_at timestamptz default now())
returns int language sql immutable as $$
  select coalesce((
    select (t ->> 'refund_bps')::int
    from jsonb_array_elements(p_policy) t
    where extract(epoch from (p_start - p_at)) / 3600.0 >= (t ->> 'hours_before')::numeric
    order by (t ->> 'hours_before')::numeric desc limit 1), 0)
$$;

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------
create function public.available_slots(
  p_service_id uuid, p_area_id uuid, p_date date,
  p_duration_minutes int default null, p_worker_id uuid default null)
returns table (worker_id uuid, slot_start timestamptz, slot_end timestamptz)
language sql stable security definer set search_path = public, private as $$
  with svc as (
    select s.*, coalesce(p_duration_minutes, s.included_minutes) as dur
    from public.services s
    where s.id = p_service_id and s.active
      and not exists (select 1 from public.public_holidays h
                      join public.service_areas a on a.id = p_area_id and a.country_code = h.country_code
                      where h.holiday_date = p_date and h.blocks_booking)
  ),
  workers as (
    select wp.id
    from public.worker_profiles wp
    join public.worker_skills sk on sk.worker_id = wp.id and sk.service_id = p_service_id and sk.approved
    join public.worker_service_areas wa on wa.worker_id = wp.id and wa.area_id = p_area_id
    where wp.is_available and public.is_worker_bookable(wp.id) and (p_worker_id is null or wp.id = p_worker_id)
  ),
  windows as (
    select w.id as wid, svc.dur, svc.slot_minutes, svc.travel_buffer_minutes as buf, svc.lead_time_minutes as lead,
           (p_date + make_interval(mins => av.start_minute)) at time zone svc.timezone as ws,
           (p_date + make_interval(mins => av.end_minute)) at time zone svc.timezone as we
    from workers w
    join public.worker_availability av on av.worker_id = w.id and av.dow = extract(dow from p_date)::int
    cross join svc
  ),
  cand as (
    select win.wid, gs as s_start, gs + make_interval(mins => win.dur) as s_end, win.buf, win.lead
    from windows win,
         lateral generate_series(win.ws, win.we - make_interval(mins => win.dur), make_interval(mins => win.slot_minutes)) gs
  )
  select c.wid, c.s_start, c.s_end
  from cand c
  where c.s_start >= now() + make_interval(mins => c.lead)
    and not exists (select 1 from public.worker_time_off t
                    where t.worker_id = c.wid and t.during && tstzrange(c.s_start, c.s_end, '[)'))
    and not exists (select 1 from public.bookings b
                    where b.worker_id = c.wid
                      and b.status in ('pending_payment','assigned','accepted','en_route','arrived','in_progress','awaiting_confirmation')
                      and b.blocked_during && tstzrange(c.s_start, c.s_end + make_interval(mins => c.buf), '[)'))
    and not exists (select 1 from public.booking_slot_reservations r
                    where r.worker_id = c.wid and r.status = 'active' and r.expires_at > now()
                      and r.blocked_during && tstzrange(c.s_start, c.s_end + make_interval(mins => c.buf), '[)'))
  order by c.s_start, c.wid
$$;

-- Marks overdue active reservations as expired. Cheap and idempotent; safe to call often.
create function public.release_expired_reservations() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.booking_slot_reservations set status = 'expired'
   where status = 'active' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

create function public.reserve_slot(
  p_service_id uuid, p_area_id uuid, p_start timestamptz,
  p_duration_minutes int default null, p_worker_id uuid default null)
returns public.booking_slot_reservations
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := auth.uid();
  s public.services%rowtype;
  v_dur int; v_ttl int; c record; v_res public.booking_slot_reservations;
  v_local_date date;
begin
  if v_uid is null then perform private.err('not_authenticated'); end if;
  select * into s from public.services where id = p_service_id and active;
  if not found then perform private.err('service_not_found'); end if;
  v_dur := coalesce(p_duration_minutes, s.included_minutes);
  v_ttl := public.app_setting_int('booking.reservation_ttl_minutes', 10);
  v_local_date := (p_start at time zone s.timezone)::date;

  perform public.release_expired_reservations();
  if (select count(*) from public.booking_slot_reservations
       where customer_id = v_uid and status = 'active') >= public.app_setting_int('booking.max_active_reservations', 3) then
    perform private.err('too_many_reservations');
  end if;

  for c in select a.worker_id from public.available_slots(p_service_id, p_area_id, v_local_date, v_dur, p_worker_id) a
           join public.worker_profiles wp on wp.id = a.worker_id
           where a.slot_start = p_start and a.worker_id <> v_uid
           order by wp.rating_avg desc, random() loop
    -- Serialise competing requests for the same worker, then re-check under the lock.
    perform 1 from public.worker_profiles where id = c.worker_id for update;
    perform public.release_expired_reservations();
    if not exists (select 1 from public.available_slots(p_service_id, p_area_id, v_local_date, v_dur, c.worker_id) a2
                   where a2.slot_start = p_start) then
      continue;
    end if;
    begin
      insert into public.booking_slot_reservations
        (customer_id, worker_id, service_id, area_id, start_at, end_at, duration_minutes, blocked_during, expires_at)
      values (v_uid, c.worker_id, p_service_id, p_area_id, p_start, p_start + make_interval(mins => v_dur), v_dur,
              tstzrange(p_start, p_start + make_interval(mins => v_dur + s.travel_buffer_minutes), '[)'),
              now() + make_interval(mins => v_ttl))
      returning * into v_res;
      return v_res;
    exception when exclusion_violation then
      continue;   -- lost the race; try the next eligible worker
    end;
  end loop;
  perform private.err('slot_unavailable');
  return null;
end $$;

create function public.release_reservation(p_reservation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.booking_slot_reservations set status = 'released'
   where id = p_reservation_id and customer_id = auth.uid() and status = 'active';
end $$;

-- ---------------------------------------------------------------------------
-- Notifications (in-app records; push delivery is performed by an Edge Function)
-- ---------------------------------------------------------------------------
create function private.notify(p_user uuid, p_key text, p_vars jsonb default '{}'::jsonb, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare t public.notification_templates%rowtype; v_title text; v_body text; kv record; v_locale text;
begin
  if p_user is null then return; end if;
  select locale into v_locale from public.profiles where id = p_user;
  select * into t from public.notification_templates where key = p_key and locale = coalesce(v_locale, 'en');
  if not found then select * into t from public.notification_templates where key = p_key and locale = 'en'; end if;
  if not found then return; end if;
  v_title := t.title; v_body := t.body;
  for kv in select key, value from jsonb_each_text(p_vars) loop
    v_title := replace(v_title, '{{' || kv.key || '}}', kv.value);
    v_body := replace(v_body, '{{' || kv.key || '}}', kv.value);
  end loop;
  insert into public.notifications (user_id, type, title, body, data)
  values (p_user, p_key, v_title, v_body, p_data);
end $$;

create function private.notify_staff(p_permission text, p_key text, p_vars jsonb default '{}'::jsonb, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  for u in select distinct ur.user_id from public.user_roles ur
           join public.role_permissions rp on rp.role = ur.role and rp.permission in (p_permission, '*') loop
    perform private.notify(u, p_key, p_vars, p_data);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Booking creation
-- ---------------------------------------------------------------------------
create function public.create_booking(
  p_reservation_id uuid, p_address_id uuid, p_description text default '',
  p_promo_code text default null, p_idempotency_key text default null,
  p_attachment_paths text[] default '{}')
returns public.bookings
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := auth.uid();
  v_res public.booking_slot_reservations%rowtype;
  v_addr public.customer_addresses%rowtype;
  s public.services%rowtype;
  v_q jsonb; v_b public.bookings; v_path text; v_eff_extra bigint;
begin
  if v_uid is null then perform private.err('not_authenticated'); end if;
  if p_idempotency_key is not null then
    select * into v_b from public.bookings where customer_id = v_uid and idempotency_key = p_idempotency_key;
    if found then return v_b; end if;
  end if;

  select * into v_res from public.booking_slot_reservations where id = p_reservation_id for update;
  if not found or v_res.customer_id <> v_uid then perform private.err('reservation_not_found'); end if;
  if v_res.status <> 'active' or v_res.expires_at <= now() then perform private.err('reservation_expired'); end if;

  select * into v_addr from public.customer_addresses where id = p_address_id and user_id = v_uid;
  if not found then perform private.err('address_not_found'); end if;
  if v_addr.area_id <> v_res.area_id then perform private.err('address_outside_reserved_area'); end if;

  -- Revalidate the worker at confirmation time (may have been suspended or gone on leave).
  if not public.is_worker_bookable(v_res.worker_id)
     or exists (select 1 from public.worker_time_off t where t.worker_id = v_res.worker_id
                and t.during && tstzrange(v_res.start_at, v_res.end_at, '[)')) then
    update public.booking_slot_reservations set status = 'released' where id = v_res.id;
    perform private.err('slot_unavailable');
  end if;

  select * into s from public.services where id = v_res.service_id;
  v_q := public.calculate_pricing(v_res.service_id, v_res.start_at, v_res.duration_minutes, p_promo_code, v_uid);
  if (v_q ->> 'total_minor')::bigint <= 0 then perform private.err('zero_total_not_supported'); end if;

  v_eff_extra := case when s.pricing_model = 'hourly' and s.extra_hour_rate_minor = 0
                      then s.base_price_minor else s.extra_hour_rate_minor end;

  update public.booking_slot_reservations set status = 'converted' where id = v_res.id;

  insert into public.bookings (
    customer_id, worker_id, service_id, area_id, address_id, address_snapshot, description,
    scheduled_start, scheduled_end, duration_minutes, travel_buffer_minutes, timezone,
    currency, pricing_model, included_minutes, base_rate_minor, extra_hour_rate_minor,
    commission_rate_bps, cancellation_policy, pricing_snapshot,
    subtotal_minor, discount_minor, fee_minor, tax_rate_bps, tax_minor, total_minor,
    commission_minor, worker_earning_minor, promotion_id, payment_due_at, idempotency_key)
  values (
    v_uid, v_res.worker_id, s.id, v_res.area_id, v_addr.id,
    to_jsonb(v_addr) - 'user_id' - 'created_at' - 'updated_at',
    left(coalesce(p_description, ''), 2000),
    v_res.start_at, v_res.end_at, v_res.duration_minutes, s.travel_buffer_minutes, s.timezone,
    s.currency, s.pricing_model, s.included_minutes, s.base_price_minor, v_eff_extra,
    (v_q ->> 'commission_rate_bps')::int, s.cancellation_policy, v_q,
    (v_q ->> 'subtotal_minor')::bigint, (v_q ->> 'discount_minor')::bigint, (v_q ->> 'fee_minor')::bigint,
    (v_q ->> 'tax_rate_bps')::int, (v_q ->> 'tax_minor')::bigint, (v_q ->> 'total_minor')::bigint,
    (v_q ->> 'commission_minor')::bigint, (v_q ->> 'worker_earning_minor')::bigint,
    nullif(v_q -> 'promotion' ->> 'id', '')::uuid,
    now() + make_interval(mins => public.app_setting_int('booking.payment_window_minutes', 15)),
    p_idempotency_key)
  returning * into v_b;

  if v_b.promotion_id is not null then
    insert into public.promotion_redemptions (promotion_id, customer_id, booking_id, discount_minor)
    values (v_b.promotion_id, v_uid, v_b.id, v_b.discount_minor);
  end if;

  foreach v_path in array coalesce(p_attachment_paths, '{}') loop
    if split_part(v_path, '/', 1) <> v_uid::text then perform private.err('invalid_attachment_path'); end if;
    insert into public.booking_attachments (booking_id, uploaded_by, storage_path, kind)
    values (v_b.id, v_uid, v_path, 'issue_photo');
  end loop;

  insert into public.booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, reason)
  values (v_b.id, null, 'pending_payment', v_uid, 'customer', 'booking created');
  return v_b;
end $$;
