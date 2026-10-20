begin;
update public.application_settings set value = '0' where key = 'payouts.hold_hours';
create function pg_temp.complete(p_cust text, p_day int, p_hour numeric, p_worker text default 'w1') returns uuid language plpgsql as $$
declare b uuid;
begin
  b := tests.new_booking(p_cust, 'svc_elec', tests.slot(p_day, p_hour), p_worker);
  perform tests.pay_booking(b);
  perform tests.login(tests.id(p_worker));
  perform public.worker_update_job_status(b, 'accepted'); perform public.worker_update_job_status(b, 'en_route');
  perform public.worker_update_job_status(b, 'arrived'); perform public.worker_update_job_status(b, 'in_progress');
  perform public.worker_update_job_status(b, 'awaiting_confirmation');
  perform tests.login(tests.id(p_cust));
  perform public.confirm_completion(b);
  perform tests.logout();
  return b;
end $$;

do $$
declare b1 uuid; b2 uuid; batch public.payout_batches; batch2 public.payout_batches; item public.payout_items; rec jsonb; adj public.worker_earnings;
begin
  b1 := pg_temp.complete('c1', 3, 10);
  b2 := pg_temp.complete('c2', 4, 10);
  perform tests.eq(coalesce((select count(*) from public.worker_earnings where status = 'eligible'), 0), 0::bigint, 'nothing eligible before maintenance');
  perform tests.service();
  perform public.run_maintenance();
  perform tests.logout();
  perform tests.eq((select count(*) from public.worker_earnings where status = 'eligible'), 2::bigint, 'completed jobs become eligible after hold');

  perform tests.login(tests.id('support'));
  perform tests.throws($t$select public.create_payout_batch('b-support')$t$, '42501', 'support cannot run payouts');
  perform tests.login(tests.id('w1'));
  perform tests.throws($t$select public.create_payout_batch('b-w')$t$, '42501', 'worker cannot run payouts');
  perform tests.login(tests.id('admin'));
  batch := public.create_payout_batch('batch-1');
  perform tests.eq(batch.total_minor, 25500::bigint, 'batch totals both jobs');
  perform tests.eq(batch.item_count, 1, 'grouped per worker');
  perform tests.eq((public.create_payout_batch('batch-1')).id, batch.id, 'same key returns same batch');
  batch2 := public.create_payout_batch('batch-2');
  perform tests.eq(batch2.total_minor, 0::bigint, 'earnings already in a batch cannot be paid twice');
  perform tests.logout();
  perform tests.eq((public.reconcile_finance() ->> 'mismatch_count')::int, 0, 'reconciles with batch in flight');

  select * into item from public.payout_items where batch_id = batch.id;
  perform tests.login(tests.id('admin'));
  perform public.mark_payout_item(item.id, 'failed', null, 'bank rejected');
  perform tests.eq((select count(*) from public.worker_earnings where status = 'eligible'), 2::bigint, 'failed payout returns earnings to eligible');
  adj := public.add_earning_adjustment(tests.id('w1'), -2500, 'Damage deduction agreed with customer');
  batch := public.create_payout_batch('batch-3');
  perform tests.eq(batch.total_minor, 23000::bigint, 'negative adjustment netted into payout');
  select * into item from public.payout_items where batch_id = batch.id;
  perform public.mark_payout_item(item.id, 'paid', 'bank-ref-1');
  perform tests.eq((public.mark_payout_item(item.id, 'paid', 'bank-ref-1')).status, 'paid', 'marking paid twice is idempotent');
  perform tests.throws(format($t$select public.mark_payout_item(%L, 'failed')$t$, item.id), 'payout_item_final', 'paid item cannot be failed');
  perform tests.eq((select count(*) from public.worker_earnings where status = 'paid'), 3::bigint, 'earnings marked paid');
  perform tests.logout();
  rec := (select public.reconcile_finance() from (select tests.login(tests.id('admin'))) x);
  perform tests.logout();
  perform tests.eq((rec ->> 'mismatch_count')::int, 0, 'ledger, earnings and payouts reconcile after payout');

  -- negative balance carries forward
  perform tests.login(tests.id('admin'));
  perform public.add_earning_adjustment(tests.id('w1'), -500, 'Correction of earlier overpayment');
  perform tests.eq((public.create_payout_batch('batch-4')).item_count, 0, 'negative-only balance produces no payout');
  perform tests.eq((select count(*) from public.worker_earnings where status = 'eligible'), 1::bigint, 'negative balance stays for next payout');
  perform tests.logout();
end $$;

-- maintenance behaviours
do $$
declare b uuid; v jsonb;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(6, 10), 'w1');
  perform tests.pay_booking(b);
  update public.bookings set accept_by = now() - interval '1 minute' where id = b;
  perform tests.service(); v := public.run_maintenance(); perform tests.logout();
  perform tests.eq((v ->> 'timed_out_assignments')::int, 1, 'unaccepted job times out');
  perform tests.eq((select status::text from public.bookings where id = b), 'unassigned', 'booking becomes unassigned');
  perform tests.eq((select worker_id from public.bookings where id = b), null::uuid, 'slot released from worker');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b and status = 'held'), 1::bigint, 'earning held while unassigned');

  perform tests.login(tests.id('admin'));
  perform tests.throws(format($t$select public.admin_assign_worker(%L, %L)$t$, b, tests.id('w3')), 'worker_not_eligible', 'unqualified worker cannot be assigned');
  perform public.admin_assign_worker(b, tests.id('w2'), 'reassigned after timeout');
  perform tests.eq((public.reconcile_finance() ->> 'mismatch_count')::int, 0, 'ledger payable moved with the reassignment');
  perform tests.logout();
  perform tests.eq((select worker_id from public.bookings where id = b), tests.id('w2'), 'new worker assigned');
  perform tests.eq((select status::text from public.bookings where id = b), 'assigned', 'back to assigned');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b and worker_id = tests.id('w2') and status = 'pending'), 1::bigint, 'earning moved to new worker');

  -- auto-complete
  perform tests.login(tests.id('w2'));
  perform public.worker_update_job_status(b, 'accepted'); perform public.worker_update_job_status(b, 'en_route');
  perform public.worker_update_job_status(b, 'arrived'); perform public.worker_update_job_status(b, 'in_progress');
  perform public.worker_update_job_status(b, 'awaiting_confirmation');
  perform tests.logout();
  update public.bookings set work_done_at = now() - interval '25 hours' where id = b;
  perform public.run_maintenance();
  perform tests.eq((select status::text from public.bookings where id = b), 'completed', 'silent customer: auto-completed');
  perform tests.eq((select actor_role from public.booking_status_history where booking_id = b and to_status = 'completed'), 'system', 'history records system actor');

  -- reminders sent once
  b := tests.new_booking('c2', 'svc_plumb', tests.slot(7, 10), 'w1');
  perform tests.pay_booking(b);
  update public.bookings set scheduled_start = now() + interval '20 hours', scheduled_end = now() + interval '21 hours' where id = b;
  perform public.run_maintenance(); perform public.run_maintenance();
  perform tests.eq((select count(*) from public.notifications where type = 'reminder.24h' and user_id = tests.id('c2')), 1::bigint, 'reminder sent exactly once');

  -- credential expiry
  update public.worker_documents set expires_on = current_date - 1 where worker_id = tests.id('w2') and doc_type = 'identity';
  perform public.run_maintenance();
  perform tests.eq((select status::text from public.worker_profiles where id = tests.id('w2')), 'expired_credentials', 'lapsed credential removes approval');
  insert into public.worker_documents (worker_id, doc_type, storage_path, status, expires_on) values (tests.id('w2'), 'identity', tests.id('w2') || '/new-id.pdf', 'pending', current_date + 300);
  perform tests.login(tests.id('admin'));
  perform public.review_document((select id from public.worker_documents where storage_path like '%new-id.pdf'), true);
  perform tests.logout();
  perform tests.eq((select status::text from public.worker_profiles where id = tests.id('w2')), 'approved', 'renewed credential restores worker');
end $$;
rollback;
