begin;
do $$
declare b uuid; p uuid; v public.bookings; n bigint; v_debit bigint; v_credit bigint;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(3, 10), 'w1');
  select * into v from public.bookings where id = b;
  perform tests.eq(v.status::text, 'pending_payment', 'new booking waits for payment');
  perform tests.eq(v.total_minor, 15750::bigint, 'server-computed total stored');
  perform tests.eq(v.commission_rate_bps, 1500, 'commission rate snapshot stored');
  perform tests.eq(v.cancellation_policy -> 0 ->> 'hours_before', '24', 'cancellation policy snapshot stored');
  perform tests.eq(v.worker_id, tests.id('w1'), 'worker auto-assigned at reservation');

  -- clients cannot mark anything paid or change state directly
  perform tests.login(tests.id('c1'));
  perform tests.throws(format($t$update public.bookings set status = 'assigned' where id = %L$t$, b), '42501', 'customer cannot update bookings directly');
  perform tests.throws(format($t$select public.process_payment_event('sandbox','e1','payment.succeeded','x',15750,'AED',false)$t$), 'permission denied', 'customer cannot post payment events (not even executable)');
  perform tests.throws(format($t$select public.worker_update_job_status(%L, 'accepted')$t$, b), 'booking_not_found', 'customer cannot act as worker');
  perform tests.throws(format($t$select public.prepare_payment(%L, null, 'short')$t$, b), 'idempotency_key_required', 'payment prep needs an idempotency key');
  perform tests.logout();
  perform tests.throws(format($t$update public.bookings set status = 'completed' where id = %L$t$, b), 'state machine', 'status guard blocks even privileged direct updates');

  p := tests.pay_booking(b);
  select * into v from public.bookings where id = b;
  perform tests.eq(v.status::text, 'assigned', 'verified payment moves booking to assigned');
  perform tests.eq((select allocated from public.payments where id = p), true, 'payment allocated');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b and kind = 'job' and amount_minor = 12750), 1::bigint, 'worker earning created');
  perform tests.eq((select sum(amount_minor)::bigint from public.commissions where booking_id = b), 2250::bigint, 'commission recorded');
  select coalesce(sum(amount_minor) filter (where direction='debit'),0), coalesce(sum(amount_minor) filter (where direction='credit'),0)
    into v_debit, v_credit from public.ledger_entries e join public.ledger_transactions t on t.id = e.transaction_id where t.booking_id = b;
  perform tests.eq(v_debit, v_credit, 'ledger balanced for booking');
  perform tests.eq(v_debit, 15750::bigint, 'ledger debit equals customer payment');
  perform tests.eq((select count(*) from public.notifications where user_id = tests.id('w1') and type = 'booking.assigned'), 1::bigint, 'worker notified of assignment');
  perform tests.eq((select count(*) from public.notifications where user_id = tests.id('c1') and type = 'booking.confirmed'), 1::bigint, 'customer notified of confirmation');

  -- unauthorised and invalid transitions
  perform tests.login(tests.id('w2'));
  perform tests.throws(format($t$select public.worker_update_job_status(%L, 'accepted')$t$, b), 'booking_not_found', 'other worker cannot touch the job');
  perform tests.login(tests.id('w1'));
  perform tests.throws(format($t$select public.worker_update_job_status(%L, 'en_route')$t$, b), 'invalid_transition', 'cannot skip acceptance');
  perform tests.throws(format($t$select public.worker_update_job_status(%L, 'completed')$t$, b), 'invalid_transition', 'worker cannot mark completed');
  perform tests.eq((public.worker_update_job_status(b, 'accepted')).status::text, 'accepted', 'worker accepts');
  perform tests.eq((public.worker_update_job_status(b, 'en_route')).status::text, 'en_route', 'en route');
  perform tests.eq((select customer_phone from public.worker_jobs where id = b), '+971500000001', 'phone visible once en route');
  perform tests.eq((public.worker_update_job_status(b, 'arrived')).status::text, 'arrived', 'arrived');
  perform tests.eq((public.worker_update_job_status(b, 'in_progress')).status::text, 'in_progress', 'in progress');
  perform tests.eq((public.worker_update_job_status(b, 'awaiting_confirmation')).status::text, 'awaiting_confirmation', 'awaiting customer');
  perform tests.throws(format($t$select public.confirm_completion(%L)$t$, b), 'booking_not_found', 'worker cannot confirm own job');
  perform tests.login(tests.id('c2'));
  perform tests.throws(format($t$select public.confirm_completion(%L)$t$, b), 'booking_not_found', 'other customer cannot confirm');
  perform tests.login(tests.id('c1'));
  perform tests.throws(format($t$select public.cancel_booking(%L)$t$, b), 'invalid_transition', 'customer cannot cancel once work is done');
  perform tests.eq((public.confirm_completion(b)).status::text, 'completed', 'customer confirms completion');
  perform tests.logout();
end $$;
rollback;
