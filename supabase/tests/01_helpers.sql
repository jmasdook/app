-- Test helpers and synthetic fixtures (committed once per test database).
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claim.role', 'authenticated', false);
  execute 'reset role'; execute 'set role authenticated';
end $$;
create function tests.anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'anon', false);
  execute 'reset role'; execute 'set role anon';
end $$;
create function tests.service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'service_role', false);
  execute 'reset role'; execute 'set role service_role';
end $$;
create function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', '', false);
  execute 'reset role';
end $$;

create function tests.eq(actual anyelement, expected anyelement, msg text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL: % (expected %, got %)', msg, expected, actual;
  end if;
  raise notice 'ok - %', msg;
end $$;
create function tests.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;
-- Runs sql and requires it to fail with a message/sqlstate containing p_expect.
create function tests.throws(p_sql text, p_expect text, msg text) returns void language plpgsql as $$
declare v_msg text; v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    if position(p_expect in v_msg) = 0 and v_state <> p_expect then
      raise exception 'FAIL: % (expected error containing %, got % [%])', msg, p_expect, v_msg, v_state;
    end if;
    raise notice 'ok - % (%)', msg, v_msg;
    return;
  end;
  raise exception 'FAIL: % (expected an error containing %, but statement succeeded)', msg, p_expect;
end $$;
-- Count rows visible with the current role.
create function tests.count(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute 'select count(*) from (' || p_sql || ') q' into n; return n; end $$;

-- local timestamp helper: N days ahead at H:M in Dubai
create function tests.slot(p_days int, p_hour numeric default 10) returns timestamptz language sql stable as $$
  select ((current_date + p_days) + make_interval(mins => (p_hour * 60)::int)) at time zone 'Asia/Dubai'
$$;
grant execute on all functions in schema tests to anon, authenticated, service_role;

-- ids
create function tests.id(p_name text) returns uuid language sql immutable as $$
  select case p_name
    when 'c1' then '11111111-0000-0000-0000-000000000001'
    when 'c2' then '11111111-0000-0000-0000-000000000002'
    when 'c3' then '11111111-0000-0000-0000-000000000003'
    when 'w1' then '22222222-0000-0000-0000-000000000001'
    when 'w2' then '22222222-0000-0000-0000-000000000002'
    when 'w3' then '22222222-0000-0000-0000-000000000003'
    when 'root' then '33333333-0000-0000-0000-000000000001'
    when 'admin' then '33333333-0000-0000-0000-000000000002'
    when 'support' then '44444444-0000-0000-0000-000000000001'
    when 'a1' then 'b0000000-0000-0000-0000-000000000001'
    when 'a2' then 'b0000000-0000-0000-0000-000000000002'
    when 'a3' then 'b0000000-0000-0000-0000-000000000003'
    when 'svc_elec' then 'd0000000-0000-0000-0000-000000000001'
    when 'svc_plumb' then 'd0000000-0000-0000-0000-000000000002'
    when 'svc_clean' then 'd0000000-0000-0000-0000-000000000003'
    when 'svc_ac' then 'd0000000-0000-0000-0000-000000000004'
    when 'area1' then 'a0000000-0000-0000-0000-000000000001'
    when 'area3' then 'a0000000-0000-0000-0000-000000000003'
  end::uuid $$;

-- fixtures
insert into auth.users (id, email, raw_user_meta_data)
select tests.id(n), n || '@example.test', jsonb_build_object('full_name', initcap(n) || ' Testperson')
from unnest(array['c1','c2','c3','w1','w2','w3','root','admin','support']) n;
update public.profiles set phone = '+971500000001' where id = tests.id('c1');
insert into public.user_roles (user_id, role) values (tests.id('root'), 'super_admin'), (tests.id('admin'), 'admin'),
  (tests.id('support'), 'support');

insert into public.worker_profiles (id, status) select tests.id(n), 'approved' from unnest(array['w1','w2','w3']) n;
insert into public.user_roles (user_id, role) select tests.id(n), 'worker' from unnest(array['w1','w2','w3']) n;
insert into public.worker_documents (worker_id, doc_type, storage_path, status, expires_on)
select tests.id(n), t, tests.id(n)::text || '/' || t || '.pdf', 'approved', current_date + 365
from unnest(array['w1','w2','w3']) n, unnest(array['identity','qualification']) t;
insert into public.worker_skills (worker_id, service_id, approved)
select tests.id(n), s.id, true from unnest(array['w1','w2']) n, public.services s;
insert into public.worker_service_areas (worker_id, area_id)
select tests.id(n), a.id from unnest(array['w1','w2']) n, public.service_areas a where a.name <> 'Al Reem Island';
insert into public.worker_availability (worker_id, dow, start_minute, end_minute)
select tests.id(n), d, 480, 1200 from unnest(array['w1','w2']) n, generate_series(0, 6) d;
insert into public.customer_addresses (id, user_id, line1, city, area_id, is_default)
values (tests.id('a1'), tests.id('c1'), 'Fictional Tower 1, Apt 101', 'Dubai', tests.id('area1'), true),
       (tests.id('a2'), tests.id('c2'), 'Fictional Tower 2, Apt 202', 'Dubai', tests.id('area1'), true),
       (tests.id('a3'), tests.id('c3'), 'Fictional Tower 3, Apt 303', 'Dubai', tests.id('area1'), true);

-- shared scenario helper: reserve + book + start payment as customer, returns booking id & payment id
create function tests.new_booking(p_customer text, p_service text, p_start timestamptz, p_worker text default null,
                                  p_promo text default null, p_dur int default null)
returns uuid language plpgsql as $$
declare r public.booking_slot_reservations; b public.bookings; v_addr uuid;
begin
  perform tests.login(tests.id(p_customer));
  r := public.reserve_slot(tests.id(p_service), tests.id('area1'), p_start, p_dur,
                           case when p_worker is null then null else tests.id(p_worker) end);
  select id into v_addr from public.customer_addresses where user_id = tests.id(p_customer) limit 1;
  b := public.create_booking(r.id, v_addr, 'Fictional issue', p_promo, 'idem-' || gen_random_uuid());
  perform tests.logout();
  return b.id;
end $$;

-- pay a booking through the sandbox event path (what the webhook would do)
create function tests.pay_booking(p_booking uuid) returns uuid language plpgsql as $$
declare b public.bookings; p public.payments; v_cust uuid; res jsonb;
begin
  select * into b from public.bookings where id = p_booking;
  perform tests.login(b.customer_id);
  p := public.prepare_payment(p_booking, null, 'pay-' || gen_random_uuid());
  perform tests.service();
  perform public.attach_provider_ref(p.id, 'sandbox', 'sbx_' || p.id, false);
  res := public.process_payment_event('sandbox', 'evt_' || gen_random_uuid(), 'payment.succeeded', 'sbx_' || p.id,
                                      p.amount_minor, p.currency, false);
  perform tests.logout();
  return p.id;
end $$;

-- Superuser-evaluated scalar lookup for assertions made while impersonating another role.
create function tests.val(p_sql text) returns text language plpgsql security definer as $$
declare v text; begin execute p_sql into v; return v; end $$;
grant execute on function tests.val(text) to anon, authenticated, service_role;
