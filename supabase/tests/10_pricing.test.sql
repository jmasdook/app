begin;
do $$
declare q jsonb; v_start timestamptz := tests.slot(3, 10);
begin
  perform tests.eq(public.round_div(389970, 60), 6500::bigint, 'round_div rounds .5 up (4333 AED-cents/h x 90min)');
  perform tests.eq(public.round_div(1, 2), 1::bigint, 'round_div(1,2)=1');
  perform tests.eq(public.round_div(149, 100), 1::bigint, 'round_div(1.49)=1');

  q := public.calculate_pricing(tests.id('svc_elec'), v_start);
  perform tests.eq((q->>'base_minor')::bigint, 15000::bigint, 'electrician base 150.00');
  perform tests.eq((q->>'tax_minor')::bigint, 750::bigint, 'VAT 5% = 7.50');
  perform tests.eq((q->>'total_minor')::bigint, 15750::bigint, 'total 157.50');
  perform tests.eq((q->>'commission_minor')::bigint, 2250::bigint, 'commission 15% of 150.00');
  perform tests.eq((q->>'worker_earning_minor')::bigint, 12750::bigint, 'worker earning = net - commission');

  q := public.calculate_pricing(tests.id('svc_elec'), tests.slot(3, 19));
  perform tests.eq((q->>'surcharge_minor')::bigint, 3000::bigint, 'evening surcharge 20%');
  perform tests.eq((q->>'total_minor')::bigint, 18900::bigint, 'surcharge total incl. VAT');
  perform tests.eq((q->>'commission_minor')::bigint, 2700::bigint, 'commission includes surcharge');

  q := public.calculate_pricing(tests.id('svc_clean'), v_start, 180);
  perform tests.eq((q->>'base_minor')::bigint, 13500::bigint, 'hourly 3h = 135.00');
  perform tests.eq((q->>'commission_rate_bps')::int, 1000, 'category commission override (10%)');
  perform tests.eq((q->>'commission_minor')::bigint, 1350::bigint, 'category commission amount');
  perform tests.throws($t$select public.calculate_pricing(tests.id('svc_clean'), now(), 30)$t$, 'invalid_duration', 'hourly below minimum rejected');
  perform tests.throws($t$select public.calculate_pricing(tests.id('svc_elec'), now(), 240)$t$, 'invalid_duration', 'fixed-duration service rejects other durations');

  q := public.calculate_pricing(tests.id('svc_elec'), v_start, null, 'welcome10', tests.id('c1'));
  perform tests.eq((q->>'discount_minor')::bigint, 1500::bigint, 'promo 10% discount');
  perform tests.eq((q->>'tax_minor')::bigint, 675::bigint, 'tax computed after discount');
  perform tests.eq((q->>'total_minor')::bigint, 14175::bigint, 'total after discount');
  perform tests.eq((q->>'commission_minor')::bigint, 2025::bigint, 'commission on discounted amount');
  perform tests.eq((q->>'commission_minor')::bigint + (q->>'worker_earning_minor')::bigint, (q->>'service_net_minor')::bigint, 'commission + earning = net (no minor unit lost)');
  perform tests.throws($t$select public.calculate_pricing(tests.id('svc_elec'), now(), null, 'NOPE')$t$, 'promo_not_applicable', 'unknown promo rejected');

  perform tests.eq(public.refund_bps_for_cancellation('[{"hours_before":24,"refund_bps":10000},{"hours_before":4,"refund_bps":5000},{"hours_before":0,"refund_bps":0}]'::jsonb, now() + interval '30 hours'), 10000, 'refund 100% >=24h');
  perform tests.eq(public.refund_bps_for_cancellation('[{"hours_before":24,"refund_bps":10000},{"hours_before":4,"refund_bps":5000},{"hours_before":0,"refund_bps":0}]'::jsonb, now() + interval '10 hours'), 5000, 'refund 50% 4-24h');
  perform tests.eq(public.refund_bps_for_cancellation('[{"hours_before":24,"refund_bps":10000},{"hours_before":4,"refund_bps":5000},{"hours_before":0,"refund_bps":0}]'::jsonb, now() + interval '2 hours'), 0, 'refund 0% <4h');
end $$;

-- commission versioning preserves history
do $$
declare v_before int; v_old_ts timestamptz;
begin
  v_before := public.resolve_commission_rate_bps(tests.id('svc_elec'));
  perform tests.login(tests.id('admin'));
  perform public.set_commission_rate('service', null, tests.id('svc_elec'), 2000, 'test');
  perform tests.logout();
  perform tests.eq(public.resolve_commission_rate_bps(tests.id('svc_elec')), 2000, 'service-level commission takes precedence');
  perform tests.eq(v_before, 1500, 'previous rate was the global default');
  perform tests.eq((select count(*) from public.commission_policies where scope = 'service'), 1::bigint, 'new policy version stored');
  perform tests.throws($t$update public.commission_policies set rate_bps = 1 where scope = 'service'$t$, 'immutable', 'policy terms cannot be edited');
  perform tests.login(tests.id('w1'));
  perform tests.throws($t$select public.set_commission_rate('global', null, null, 0, 'x')$t$, '42501', 'worker cannot change commission');
end $$;
rollback;
