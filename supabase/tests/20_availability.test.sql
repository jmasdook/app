begin;
do $$
declare v_start timestamptz := tests.slot(3, 10); n bigint; r public.booking_slot_reservations; v_date date := current_date + 3;
begin
  perform tests.login(tests.id('c1'));
  n := (select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date));
  perform tests.eq(n, 42::bigint, '2 workers x 21 slots (08:00-18:00 starts, 120min job in 08:00-20:00 window)');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area3'), v_date)), 0::bigint, 'no workers serve Al Reem Island');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), current_date) where slot_start < now() + interval '120 minutes'), 0::bigint, 'lead time hides imminent slots');

  r := public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), v_start);
  perform tests.eq(r.status, 'active', 'reservation active');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where slot_start = v_start), 1::bigint, 'one worker left for that slot');
  perform public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), v_start);
  perform tests.throws($t$select public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), tests.slot(3, 10))$t$, 'slot_unavailable', 'third attempt for the same slot fails (both workers held)');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where slot_start = v_start), 0::bigint, 'slot hidden once held');
  -- overlapping slot (11:00 overlaps 10:00-12:00 job) also blocked for both workers, 12:30 ok (30m buffer)
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where slot_start = tests.slot(3, 11)), 0::bigint, 'overlapping slot blocked');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where slot_start = tests.slot(3, 12)), 0::bigint, 'travel buffer blocks 12:00 start');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where slot_start = tests.slot(3, 12.5)), 2::bigint, '12:30 start is free after buffer');
  perform tests.throws($t$select public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), tests.slot(3, 14)); select public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), tests.slot(3, 16)); select public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), tests.slot(3, 18))$t$,
                       'too_many_reservations', 'customers cannot hoard more than 3 holds');
  perform tests.logout();
end $$;

-- expiry releases the hold
do $$
declare v_start timestamptz := tests.slot(4, 10);
begin
  perform tests.login(tests.id('c3'));
  perform public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), v_start, null, tests.id('w1'));
  perform tests.throws($t$select public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), tests.slot(4, 10), null, tests.id('w1'))$t$, 'slot_unavailable', 'held slot unavailable for worker w1');
  perform tests.logout();
  update public.booking_slot_reservations set expires_at = now() - interval '1 minute' where worker_id = tests.id('w1') and start_at = v_start;
  perform tests.eq(public.release_expired_reservations() >= 1, true, 'expired reservations released');
  perform tests.login(tests.id('c2'));
  perform public.reserve_slot(tests.id('svc_elec'), tests.id('area1'), v_start, null, tests.id('w1'));
  perform tests.ok(true, 'slot can be reserved again after expiry');
  perform tests.logout();
end $$;

-- time off, holidays, suspension, credentials
do $$
declare v_date date := current_date + 5; v_start timestamptz := tests.slot(5, 10);
begin
  insert into public.worker_time_off (worker_id, during) values (tests.id('w1'), tstzrange(tests.slot(5, 0), tests.slot(6, 0)));
  perform tests.login(tests.id('c1'));
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where worker_id = tests.id('w1')), 0::bigint, 'time off removes worker slots');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date) where worker_id = tests.id('w2')), 21::bigint, 'other worker unaffected');
  perform tests.logout();
  insert into public.public_holidays (holiday_date, name) values (v_date, 'test holiday');
  perform tests.login(tests.id('c1'));
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), v_date)), 0::bigint, 'public holiday blocks all slots');
  perform tests.logout();
  delete from public.public_holidays where holiday_date = v_date;

  update public.worker_profiles set status = 'suspended' where id = tests.id('w2');
  perform tests.login(tests.id('c1'));
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), current_date + 6) where worker_id = tests.id('w2')), 0::bigint, 'suspended worker not bookable');
  perform tests.logout();
  update public.worker_profiles set status = 'approved' where id = tests.id('w2');
  update public.worker_documents set expires_on = current_date - 1 where worker_id = tests.id('w2') and doc_type = 'identity';
  perform tests.login(tests.id('c1'));
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), current_date + 6) where worker_id = tests.id('w2')), 0::bigint, 'expired credential removes bookability');
  perform tests.logout();
  update public.worker_documents set status = 'pending' where worker_id = tests.id('w2') and doc_type = 'qualification';
  perform tests.eq(public.is_worker_bookable(tests.id('w2')), false, 'unapproved document => not bookable');
  perform tests.eq((select count(*) from public.available_slots(tests.id('svc_elec'), tests.id('area1'), current_date + 6) where worker_id = tests.id('w3')), 0::bigint, 'bookable worker without approved skills/areas gets no slots');
end $$;
rollback;
