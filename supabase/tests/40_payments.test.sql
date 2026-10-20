begin;
-- Webhook idempotency, verification and failure handling
do $$
declare b uuid; p public.payments; res jsonb; v_n bigint;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(3, 10), 'w1');
  perform tests.login(tests.id('c1'));
  p := public.prepare_payment(b, null, 'idem-key-booking-1');
  perform tests.eq((public.prepare_payment(b, null, 'idem-key-booking-1')).id, p.id, 'same idempotency key returns same payment');
  perform tests.eq((public.prepare_payment(b, null, 'idem-key-booking-2')).id, p.id, 'open payment is reused (no duplicate payment rows)');
  perform tests.eq(p.amount_minor, 15750::bigint, 'amount comes from the server snapshot');
  perform tests.logout();
  perform tests.service();
  perform public.attach_provider_ref(p.id, 'sandbox', 'sbx_1', false);
  perform tests.throws($t$select public.attach_provider_ref(null, 'stripe', 'x', true)$t$, 'live_payments_disabled', 'live mode refused until explicitly enabled');

  res := public.process_payment_event('sandbox', 'evt_amount', 'payment.succeeded', 'sbx_1', 100, 'AED', false);
  perform tests.eq(res ->> 'result', 'error', 'amount mismatch is rejected');
  perform tests.eq((select status from public.payments where id = p.id), 'pending', 'payment untouched by mismatching event');
  perform tests.eq((select needs_review from public.payments where id = p.id), true, 'mismatch flagged for review');
  res := public.process_payment_event('sandbox', 'evt_live', 'payment.succeeded', 'sbx_1', 15750, 'AED', true);
  perform tests.eq(res ->> 'result', 'ignored', 'live-mode events ignored while live disabled');
  res := public.process_payment_event('sandbox', 'evt_unknown', 'payment.succeeded', 'nope', 15750, 'AED', false);
  perform tests.eq(res ->> 'result', 'unknown_payment', 'unknown provider reference recorded, not applied');

  res := public.process_payment_event('sandbox', 'evt_fail', 'payment.failed', 'sbx_1', 15750, 'AED', false, '{"failure_code":"card_declined"}');
  perform tests.eq((select status from public.payments where id = p.id), 'failed', 'failed event recorded');
  perform tests.eq((select status::text from public.bookings where id = b), 'pending_payment', 'failed payment does not confirm booking');
  res := public.process_payment_event('sandbox', 'evt_ok', 'payment.succeeded', 'sbx_1', 15750, 'AED', false);
  perform tests.eq(res ->> 'result', 'processed', 'retry on same intent can succeed');
  perform tests.eq((select status::text from public.bookings where id = b), 'assigned', 'booking confirmed after success');
  res := public.process_payment_event('sandbox', 'evt_ok', 'payment.succeeded', 'sbx_1', 15750, 'AED', false);
  perform tests.eq(res ->> 'result', 'duplicate', 'duplicate delivery detected');
  res := public.process_payment_event('sandbox', 'evt_ok_2', 'payment.succeeded', 'sbx_1', 15750, 'AED', false);
  perform tests.eq(res ->> 'result', 'ignored', 'redelivery under a different event id is ignored');
  res := public.process_payment_event('sandbox', 'evt_late_fail', 'payment.failed', 'sbx_1', 15750, 'AED', false);
  perform tests.eq((select status from public.payments where id = p.id), 'succeeded', 'out-of-order failure cannot undo success');
  perform tests.eq((select count(*) from public.ledger_transactions where payment_id = p.id), 1::bigint, 'exactly one ledger transaction despite duplicates');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b), 1::bigint, 'exactly one earning despite duplicates');
  perform tests.logout();
end $$;

-- Late capture after the booking expired => unapplied funds + automatic refund
do $$
declare b uuid; p public.payments; res jsonb; r public.refunds; v_ref text;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(4, 10), 'w1');
  perform tests.login(tests.id('c1'));
  p := public.prepare_payment(b, null, 'idem-late-1');
  perform tests.service();
  perform public.attach_provider_ref(p.id, 'sandbox', 'sbx_late', false);
  update public.bookings set payment_due_at = now() - interval '1 minute' where id = b;
  perform tests.eq((public.run_maintenance() ->> 'unpaid_bookings_cancelled')::int >= 1, true, 'maintenance cancels unpaid booking');
  perform tests.eq((select status::text from public.bookings where id = b), 'cancelled', 'booking cancelled on payment timeout');
  res := public.process_payment_event('sandbox', 'evt_late', 'payment.succeeded', 'sbx_late', 15750, 'AED', false);
  perform tests.eq(res ->> 'note', 'unallocated:booking_not_payable', 'late success is not applied to the cancelled booking');
  select * into r from public.refunds where payment_id = p.id;
  perform tests.eq(r.amount_minor, 15750::bigint, 'automatic full refund created');
  perform tests.eq(r.unapplied_part_minor, 15750::bigint, 'refund drawn from unapplied funds');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b), 0::bigint, 'no earning for unapplied payment');
  perform public.begin_refund_processing(r.id);
  perform public.set_refund_provider_ref(r.id, 're_late');
  res := public.process_payment_event('sandbox', 'evt_re_late', 'refund.succeeded', 'sbx_late', 15750, 'AED', false, '{}', 're_late');
  perform tests.eq((select status from public.refunds where id = r.id), 'succeeded', 'refund completed from provider event');
  perform tests.eq((select status from public.payments where id = p.id), 'refunded', 'payment marked refunded');
  perform tests.eq((public.reconcile_finance() ->> 'mismatch_count')::int, 0, 'books reconcile after unapplied refund');
  perform tests.logout();
end $$;

-- Duplicate payment for the same booking
do $$
declare b uuid; p1 uuid; p2 public.payments; res jsonb;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(5, 10), 'w1');
  p1 := tests.pay_booking(b);
  perform tests.service();
  insert into public.payments (booking_id, purpose, provider, provider_ref, amount_minor, currency, idempotency_key)
  values (b, 'booking', 'sandbox', 'sbx_dup', 15750, 'AED', 'dup-key-12345') returning * into p2;
  res := public.process_payment_event('sandbox', 'evt_dup', 'payment.succeeded', 'sbx_dup', 15750, 'AED', false);
  perform tests.eq(res ->> 'note', 'unallocated:duplicate_payment', 'second payment becomes unapplied duplicate');
  perform tests.eq((select reason_code from public.refunds where payment_id = p2.id), 'duplicate_payment', 'duplicate auto-refunded');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b), 1::bigint, 'still exactly one earning');
  perform tests.logout();
end $$;

-- Cancellation refunds and exact decomposition
do $$
declare b uuid; p uuid; f public.refunds; res jsonb; r jsonb;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(6, 10), 'w1');
  p := tests.pay_booking(b);
  perform tests.login(tests.id('c1'));
  perform tests.eq((public.cancel_booking(b, 'changed my mind')).status::text, 'cancelled', 'customer cancels early');
  perform tests.logout();
  select * into f from public.refunds where booking_id = b;
  perform tests.eq(f.amount_minor, 15750::bigint, '>24h cancellation refunds 100%');
  perform tests.eq(f.status, 'approved', 'policy refund auto-approved');
  perform tests.eq(f.tax_part_minor + f.commission_part_minor + f.earning_part_minor, 15750::bigint, 'decomposition sums to refund');
  perform tests.service();
  perform public.begin_refund_processing(f.id);
  perform public.set_refund_provider_ref(f.id, 're_1');
  perform public.process_payment_event('sandbox', 'evt_re_1', 'refund.succeeded', 'sbx_' || p, 15750, 'AED', false, '{}', 're_1');
  perform public.process_payment_event('sandbox', 'evt_re_1', 'refund.succeeded', 'sbx_' || p, 15750, 'AED', false, '{}', 're_1');
  perform tests.eq((select count(*) from public.worker_earnings where booking_id = b and kind = 'refund_adjustment'), 1::bigint, 'refund event applied once');
  perform tests.eq((select sum(amount_minor)::bigint from public.worker_earnings where booking_id = b), 0::bigint, 'worker net earning zero after full refund');
  perform tests.eq((select sum(amount_minor)::bigint from public.commissions where booking_id = b), 0::bigint, 'commission fully reversed');
  perform tests.eq((public.reconcile_finance() ->> 'mismatch_count')::int, 0, 'books reconcile after full refund');
  perform tests.logout();

  -- late (<4h) cancellation => 0% refund; mid tier => 50%
  b := tests.new_booking('c2', 'svc_elec', tests.slot(7, 10), 'w1');
  p := tests.pay_booking(b);
  update public.bookings set scheduled_start = now() + interval '10 hours', scheduled_end = now() + interval '12 hours' where id = b;
  perform tests.login(tests.id('c2'));
  perform public.cancel_booking(b);
  perform tests.logout();
  select * into f from public.refunds where booking_id = b;
  perform tests.eq(f.amount_minor, 7875::bigint, '4-24h cancellation refunds 50%');
  perform tests.eq(f.tax_part_minor, 375::bigint, 'tax part proportional');
  perform tests.eq(f.commission_part_minor, 1125::bigint, 'commission reversal proportional');
  perform tests.eq(f.earning_part_minor, 6375::bigint, 'worker earning reduction proportional');

  b := tests.new_booking('c3', 'svc_elec', tests.slot(8, 10), 'w1');
  p := tests.pay_booking(b);
  update public.bookings set scheduled_start = now() + interval '2 hours', scheduled_end = now() + interval '4 hours' where id = b;
  perform tests.login(tests.id('c3'));
  perform public.cancel_booking(b);
  perform tests.logout();
  perform tests.eq((select count(*) from public.refunds where booking_id = b), 0::bigint, '<4h cancellation: no refund');
end $$;

-- Refund splits never lose or invent a minor unit, and cannot exceed the payment
do $$
declare b uuid; p uuid; f1 public.refunds; f2 public.refunds; f3 public.refunds;
begin
  b := tests.new_booking('c1', 'svc_clean', tests.slot(9, 9), 'w1', null, 150);
  p := tests.pay_booking(b);
  perform tests.logout();
  f1 := private.create_refund(p, 3333, 'service_issue', 't', null, 'system', 'approved', null, 'k1');
  f2 := private.create_refund(p, 3333, 'service_issue', 't', null, 'system', 'approved', null, 'k2');
  f3 := private.create_refund(p, (select amount_minor from public.payments where id = p) - 6666, 'service_issue', 't', null, 'system', 'approved', null, 'k3');
  perform tests.eq((select sum(tax_part_minor)::bigint from public.refunds where payment_id = p), (select tax_minor from public.bookings where id = b), 'tax parts sum exactly');
  perform tests.eq((select sum(commission_part_minor)::bigint from public.refunds where payment_id = p), (select commission_minor from public.bookings where id = b), 'commission parts sum exactly');
  perform tests.eq((select sum(earning_part_minor)::bigint from public.refunds where payment_id = p), (select worker_earning_minor from public.bookings where id = b), 'earning parts sum exactly');
  perform tests.throws(format($t$select private.create_refund(%L, 1, 'service_issue', 't', null, 'system', 'approved', null, 'k4')$t$, p), 'refund_exceeds_payment', 'cannot refund more than was paid');
  perform tests.logout();
end $$;

-- request/decide workflow and authorisation
do $$
declare b uuid; p uuid; f public.refunds;
begin
  b := tests.new_booking('c1', 'svc_elec', tests.slot(10, 10), 'w1');
  p := tests.pay_booking(b);
  perform tests.login(tests.id('w1'));
  perform public.worker_update_job_status(b, 'accepted'); perform public.worker_update_job_status(b, 'en_route');
  perform public.worker_update_job_status(b, 'arrived'); perform public.worker_update_job_status(b, 'in_progress');
  perform public.worker_update_job_status(b, 'awaiting_confirmation');
  perform tests.login(tests.id('c1'));
  f := public.request_refund(b, 5000, 'Not all work was done');
  perform tests.eq(f.status, 'requested', 'refund request waits for admin');
  perform tests.throws(format($t$select public.request_refund(%L, 100, 'again')$t$, b), 'refund_already_requested', 'only one open request');
  perform tests.throws(format($t$select public.decide_refund(%L, true)$t$, f.id), '42501', 'customer cannot approve own refund');
  perform tests.login(tests.id('support'));
  perform tests.throws(format($t$select public.decide_refund(%L, true)$t$, f.id), '42501', 'support cannot approve refunds');
  perform tests.login(tests.id('admin'));
  perform tests.eq((public.decide_refund(f.id, true, 'ok')).status, 'approved', 'admin approves refund');
  perform tests.eq((select count(*) from public.admin_audit_logs where action = 'refund.approve'), 1::bigint, 'approval written to audit log');
  perform tests.logout();
end $$;
rollback;
