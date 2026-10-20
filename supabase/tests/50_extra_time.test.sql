begin;
create function pg_temp.in_progress(p_cust text, p_day int, p_hour numeric) returns uuid language plpgsql as $$
declare b uuid;
begin
  b := tests.new_booking(p_cust, 'svc_elec', tests.slot(p_day, p_hour), 'w1');
  perform tests.pay_booking(b);
  perform tests.login(tests.id('w1'));
  perform public.worker_update_job_status(b, 'accepted'); perform public.worker_update_job_status(b, 'en_route');
  perform public.worker_update_job_status(b, 'arrived'); perform public.worker_update_job_status(b, 'in_progress');
  perform tests.logout();
  return b;
end $$;

do $$
declare b uuid; r public.extra_time_requests; p public.payments; res jsonb;
begin
  b := pg_temp.in_progress('c1', 3, 10);
  perform tests.login(tests.id('w1'));
  r := public.request_extra_time(b, 60, 'Found a second faulty circuit');
  perform tests.eq(r.rate_minor, 6000::bigint, 'rate snapshot from booking');
  perform tests.eq(r.net_minor, 6000::bigint, 'net for one extra hour computed server-side');
  perform tests.eq(r.tax_minor, 300::bigint, 'tax on extra time');
  perform tests.eq(r.total_minor, 6300::bigint, 'total payable');
  perform tests.eq(r.commission_minor + r.worker_earning_minor, r.net_minor, 'commission + earning = net');
  perform tests.throws(format($t$select public.request_extra_time(%L, 30, 'another one please')$t$, b), 'extra_time_request_already_open', 'duplicate open request refused');
  perform tests.throws(format($t$select public.decide_extra_time(%L, true)$t$, r.id), 'request_not_found', 'worker cannot decide own request');
  perform tests.eq(tests.val(format('select extra_minutes from public.bookings where id = %L', b)), '0', 'nothing charged by merely requesting');
  perform tests.eq(tests.val(format('select count(*) from public.notifications where user_id = %L and type = %L', tests.id('c1'), 'extra_time.requested')), '1', 'customer notified');

  perform tests.login(tests.id('c2'));
  perform tests.throws(format($t$select public.decide_extra_time(%L, true)$t$, r.id), 'request_not_found', 'other customers cannot decide');
  perform tests.login(tests.id('c1'));
  perform tests.throws(format($t$select public.prepare_payment(%L, %L, 'extra-pay-early')$t$, b, r.id), 'request_not_payable', 'no payment before approval');
  r := public.decide_extra_time(r.id, true, 'ok');
  perform tests.eq(r.status, 'awaiting_payment', 'approval opens a payment step, nothing is charged yet');
  perform tests.eq(tests.val(format('select extra_minutes from public.bookings where id = %L', b)), '0', 'approval alone does not add charges');
  p := public.prepare_payment(b, r.id, 'extra-pay-1');
  perform tests.eq(p.amount_minor, 6300::bigint, 'extra payment amount from the request snapshot');
  perform tests.eq(p.purpose, 'extra_time', 'purpose extra_time');
  perform tests.logout();
  perform tests.service();
  perform public.attach_provider_ref(p.id, 'sandbox', 'sbx_x1', false);
  res := public.process_payment_event('sandbox', 'evt_x1', 'payment.succeeded', 'sbx_x1', 6300, 'AED', false);
  perform tests.logout();
  perform tests.eq((select status from public.extra_time_requests where id = r.id), 'approved', 'verified payment finalises extra time');
  perform tests.eq((select extra_minutes from public.bookings where id = b), 60, 'booking extra minutes updated');
  perform tests.eq((select amount_minor from public.worker_earnings where extra_time_request_id = r.id), r.worker_earning_minor, 'extra earning recorded');
  perform tests.eq((select amount_minor from public.commissions where extra_time_request_id = r.id), r.commission_minor, 'extra commission recorded');
  perform tests.eq((public.reconcile_finance() ->> 'mismatch_count')::int, 0, 'books reconcile after extra time');

  -- maximum extension (service allows 180 min; 60 already used)
  perform tests.login(tests.id('w1'));
  perform tests.throws(format($t$select public.request_extra_time(%L, 150, 'a very long extension')$t$, b), 'extension_limit_exceeded', 'configured maximum enforced');
  perform tests.throws(format($t$select public.request_extra_time(%L, 20, 'odd duration here')$t$, b), 'invalid_extension', 'must be a multiple of 15 minutes');
  r := public.request_extra_time(b, 30, 'Needs half an hour more');
  perform tests.login(tests.id('c1'));
  perform tests.eq((public.decide_extra_time(r.id, false, 'no thanks')).status, 'rejected', 'customer can reject');
  perform tests.eq(tests.val(format('select count(*) from public.notifications where user_id = %L and type = %L', tests.id('w1'), 'extra_time.rejected')), '1', 'worker told of rejection');
  perform tests.eq(tests.val(format('select extra_minutes from public.bookings where id = %L', b)), '60', 'rejection adds no charge');
  perform tests.login(tests.id('w1'));
  perform tests.eq(public.escalate_extra_time(r.id, 'customer refused, job unfinished') is not null, true, 'worker may escalate; support ticket opened');
  perform tests.eq((select count(*) from public.support_tickets where booking_id = b and user_id = tests.id('w1')), 1::bigint, 'escalation ticket exists');
  perform tests.logout();
end $$;

-- Unreachable customer: request expires; cannot be approved; late payment is refunded
do $$
declare b uuid; r public.extra_time_requests; p public.payments; res jsonb;
begin
  b := pg_temp.in_progress('c2', 4, 10);
  perform tests.login(tests.id('w1'));
  r := public.request_extra_time(b, 30, 'Need more time for repair');
  perform tests.logout();
  update public.extra_time_requests set expires_at = now() - interval '1 minute' where id = r.id;
  perform tests.login(tests.id('c2'));
  perform tests.eq((public.decide_extra_time(r.id, true)).status, 'expired', 'expired request cannot be approved');
  perform tests.logout();
  perform tests.eq((select status from public.extra_time_requests where id = r.id), 'expired', 'request marked expired');

  perform tests.login(tests.id('w1'));
  r := public.request_extra_time(b, 30, 'Trying once more later');
  perform tests.login(tests.id('c2'));
  r := public.decide_extra_time(r.id, true);
  p := public.prepare_payment(b, r.id, 'extra-pay-late');
  perform tests.logout();
  perform tests.service();
  perform public.attach_provider_ref(p.id, 'sandbox', 'sbx_x2', false);
  update public.extra_time_requests set payment_expires_at = now() - interval '1 minute' where id = r.id;
  perform public.run_maintenance();
  res := public.process_payment_event('sandbox', 'evt_x2', 'payment.succeeded', 'sbx_x2', p.amount_minor, 'AED', false);
  perform tests.eq(res ->> 'note', 'unallocated:extra_time_not_payable', 'payment after the request expired is not applied');
  perform tests.eq((select extra_minutes from public.bookings where id = b), 0, 'no extra minutes without a valid authorisation');
  perform tests.eq((select count(*) from public.refunds where payment_id = p.id and status = 'approved'), 1::bigint, 'late extra payment refunded');
  perform tests.logout();
end $$;

-- Preconditions
do $$
declare b uuid; b2 uuid;
begin
  b := tests.new_booking('c3', 'svc_elec', tests.slot(5, 10), 'w1');
  perform tests.pay_booking(b);
  perform tests.login(tests.id('w1'));
  perform tests.throws(format($t$select public.request_extra_time(%L, 60, 'job not started yet')$t$, b), 'job_not_in_progress', 'only for jobs in progress');
  perform tests.logout();
  b2 := pg_temp.in_progress('c1', 6, 10);
  perform tests.pay_booking(tests.new_booking('c2', 'svc_elec', tests.slot(6, 12.5), 'w1'));
  perform tests.login(tests.id('w1'));
  perform tests.throws(format($t$select public.request_extra_time(%L, 60, 'needs another hour')$t$, b2), 'extension_conflicts_with_next_booking', 'cannot overrun into the next booking');
  perform tests.logout();
end $$;
rollback;
