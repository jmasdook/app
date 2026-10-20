-- Payment processing (provider-agnostic), refunds, ledger posting, earnings, payouts, reconciliation.
-- Money only moves in our books as a result of verified provider events (service role) or
-- authorised admin actions. No client call can mark a payment successful.

insert into public.application_settings (key, value, description, is_public) values
  ('payments.provider', '"sandbox"', 'Active payment provider adapter (sandbox | stripe | ...)', false)
on conflict do nothing;

create function private.require_permission(p_permission text) returns void
language plpgsql stable as $$
begin
  if public.is_system() or public.has_permission(p_permission) then return; end if;
  raise exception 'forbidden' using errcode = '42501';
end $$;

-- ---------------------------------------------------------------------------
-- Ledger posting
-- entries: [{"account":"PROVIDER_CLEARING","dir":"debit","amount":1000,"worker":"<uuid>"?}, ...]
-- ---------------------------------------------------------------------------
create function private.post_ledger(
  p_kind text, p_desc text, p_booking uuid, p_payment uuid, p_refund uuid, p_currency text,
  p_key text, p_entries jsonb, p_payout_item uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; e jsonb; v_acc smallint;
begin
  select id into v_id from public.ledger_transactions where idempotency_key = p_key;
  if found then return v_id; end if;
  insert into public.ledger_transactions (kind, description, booking_id, payment_id, refund_id, payout_item_id,
                                          currency, idempotency_key, created_by)
  values (p_kind, p_desc, p_booking, p_payment, p_refund, p_payout_item, p_currency, p_key, auth.uid())
  returning id into v_id;
  for e in select * from jsonb_array_elements(p_entries) loop
    if (e ->> 'amount')::bigint > 0 then
      select id into v_acc from public.ledger_accounts where code = e ->> 'account';
      insert into public.ledger_entries (transaction_id, account_id, direction, amount_minor, worker_id)
      values (v_id, v_acc, e ->> 'dir', (e ->> 'amount')::bigint, nullif(e ->> 'worker', '')::uuid);
    end if;
  end loop;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Payment preparation (called by the payments Edge Function with the *user's* JWT)
-- The amount always comes from the database snapshot, never from the client.
-- ---------------------------------------------------------------------------
create function public.prepare_payment(p_booking_id uuid, p_extra_request_id uuid default null,
                                       p_idempotency_key text default null)
returns public.payments language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := auth.uid(); b public.bookings%rowtype; r public.extra_time_requests%rowtype;
  p public.payments; v_provider text; v_amount bigint; v_exp timestamptz;
begin
  if v_uid is null then perform private.err('not_authenticated'); end if;
  if p_idempotency_key is null or length(p_idempotency_key) < 8 then perform private.err('idempotency_key_required'); end if;
  select * into p from public.payments where idempotency_key = p_idempotency_key;
  if found then
    if p.created_by is distinct from v_uid then perform private.err('booking_not_found'); end if;
    return p;
  end if;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> v_uid then perform private.err('booking_not_found'); end if;

  if p_extra_request_id is null then
    if b.status <> 'pending_payment' then perform private.err('booking_not_payable'); end if;
    if b.payment_due_at <= now() then perform private.err('payment_window_closed'); end if;
    v_amount := b.total_minor; v_exp := b.payment_due_at;
    select * into p from public.payments
     where booking_id = b.id and purpose = 'booking' and status in ('pending', 'requires_action') and expires_at > now()
     order by created_at desc limit 1;
  else
    select * into r from public.extra_time_requests where id = p_extra_request_id and booking_id = b.id for update;
    if not found then perform private.err('request_not_found'); end if;
    if r.status <> 'awaiting_payment' or r.payment_expires_at <= now() then perform private.err('request_not_payable'); end if;
    v_amount := r.total_minor; v_exp := r.payment_expires_at;
    select * into p from public.payments
     where extra_time_request_id = r.id and status in ('pending', 'requires_action') and expires_at > now()
     order by created_at desc limit 1;
  end if;
  if found then return p; end if;

  v_provider := coalesce(public.app_setting('payments.provider') #>> '{}', 'sandbox');
  insert into public.payments (booking_id, extra_time_request_id, purpose, provider, amount_minor, currency,
                               is_sandbox, livemode, idempotency_key, expires_at, created_by)
  values (b.id, p_extra_request_id, case when p_extra_request_id is null then 'booking' else 'extra_time' end,
          v_provider, v_amount, b.currency, v_provider = 'sandbox', false, p_idempotency_key, v_exp, v_uid)
  returning * into p;
  if p_extra_request_id is not null then
    update public.extra_time_requests set payment_id = p.id where id = p_extra_request_id;
  end if;
  return p;
end $$;

create function public.attach_provider_ref(p_payment_id uuid, p_provider text, p_ref text, p_livemode boolean)
returns public.payments language plpgsql security definer set search_path = public, private as $$
declare p public.payments;
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  if p_livemode and coalesce((public.app_setting('payments.live_enabled') #>> '{}')::boolean, false) is not true then
    perform private.err('live_payments_disabled');
  end if;
  update public.payments set provider = p_provider, provider_ref = p_ref, livemode = p_livemode,
         is_sandbox = (p_provider = 'sandbox')
   where id = p_payment_id and status in ('pending', 'requires_action')
     and (provider_ref is null or provider_ref = p_ref)
  returning * into p;
  if not found then perform private.err('payment_not_found'); end if;
  return p;
end $$;

-- ---------------------------------------------------------------------------
-- Refunds
-- ---------------------------------------------------------------------------
create function private.refund_breakdown(p public.payments, p_amount bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings%rowtype; r public.extra_time_requests%rowtype;
  v_total bigint; v_tax bigint; v_fee bigint; v_comm bigint; v_net bigint;
  pr_amt bigint; pr_tax bigint; pr_fee bigint; pr_comm bigint; pr_earn bigint;
  t_tax bigint; t_fee bigint; t_comm bigint; t_earn bigint; v_service bigint;
begin
  if not p.allocated then
    return jsonb_build_object('tax', 0, 'fee', 0, 'commission', 0, 'earning', 0, 'unapplied', p_amount);
  end if;
  if p.purpose = 'booking' then
    select * into b from public.bookings where id = p.booking_id;
    v_total := b.total_minor; v_tax := b.tax_minor; v_fee := b.fee_minor; v_comm := b.commission_minor;
    v_net := b.subtotal_minor - b.discount_minor;
  else
    select * into r from public.extra_time_requests where id = p.extra_time_request_id;
    v_total := r.total_minor; v_tax := r.tax_minor; v_fee := 0; v_comm := r.commission_minor; v_net := r.net_minor;
  end if;
  select coalesce(sum(amount_minor), 0), coalesce(sum(tax_part_minor), 0), coalesce(sum(fee_part_minor), 0),
         coalesce(sum(commission_part_minor), 0), coalesce(sum(earning_part_minor), 0)
    into pr_amt, pr_tax, pr_fee, pr_comm, pr_earn
  from public.refunds where payment_id = p.id and status not in ('failed', 'rejected');
  if p_amount > p.amount_minor - pr_amt then perform private.err('refund_exceeds_payment'); end if;

  if p_amount = p.amount_minor - pr_amt then     -- final refund takes exactly what is left of each component
    t_tax := v_tax - pr_tax; t_fee := v_fee - pr_fee; t_comm := v_comm - pr_comm; t_earn := (v_net - v_comm) - pr_earn;
  else
    t_tax := least(v_tax - pr_tax, public.round_div(v_tax::numeric * p_amount, v_total));
    t_fee := least(v_fee - pr_fee, public.round_div(v_fee::numeric * p_amount, v_total));
    v_service := p_amount - t_tax - t_fee;
    t_comm := case when v_net = 0 then 0
                   else least(v_comm - pr_comm, public.round_div(v_comm::numeric * v_service, v_net)) end;
    t_earn := v_service - t_comm;
    if t_earn > (v_net - v_comm) - pr_earn then
      t_earn := (v_net - v_comm) - pr_earn; t_comm := v_service - t_earn;
    end if;
  end if;
  return jsonb_build_object('tax', t_tax, 'fee', t_fee, 'commission', t_comm, 'earning', t_earn, 'unapplied', 0);
end $$;

create function private.create_refund(
  p_payment_id uuid, p_amount bigint, p_reason_code text, p_reason text, p_requested_by uuid,
  p_role text, p_status text, p_refund_bps int, p_key text)
returns public.refunds language plpgsql security definer set search_path = public, private as $$
declare p public.payments%rowtype; f public.refunds; v_bd jsonb;
begin
  select * into f from public.refunds where idempotency_key = p_key;
  if found then return f; end if;
  select * into p from public.payments where id = p_payment_id for update;
  if not found or p.status not in ('succeeded', 'partially_refunded') then perform private.err('payment_not_refundable'); end if;
  if p_amount <= 0 then perform private.err('invalid_refund_amount'); end if;
  v_bd := private.refund_breakdown(p, p_amount);
  insert into public.refunds (payment_id, booking_id, amount_minor, currency, status, reason_code, reason, refund_bps,
      tax_part_minor, fee_part_minor, commission_part_minor, earning_part_minor, unapplied_part_minor,
      requested_by, requested_role, decided_by, decided_at, idempotency_key)
  values (p.id, p.booking_id, p_amount, p.currency, p_status, p_reason_code, p_reason, p_refund_bps,
      (v_bd ->> 'tax')::bigint, (v_bd ->> 'fee')::bigint, (v_bd ->> 'commission')::bigint,
      (v_bd ->> 'earning')::bigint, (v_bd ->> 'unapplied')::bigint,
      p_requested_by, p_role, case when p_status = 'approved' then p_requested_by end,
      case when p_status = 'approved' then now() end, p_key)
  returning * into f;
  return f;
end $$;

create function private.create_cancellation_refund(
  b public.bookings, p_actor_role text, p_actor_id uuid, p_bps int, p_reason text)
returns void language plpgsql security definer set search_path = public, private as $$
declare p public.payments%rowtype; v_bps int; v_amt bigint; f public.refunds;
begin
  select * into p from public.payments
   where booking_id = b.id and purpose = 'booking' and allocated and status in ('succeeded', 'partially_refunded');
  if not found then return; end if;
  v_bps := case when p_actor_role = 'customer' then coalesce(p_bps, 0) else coalesce(p_bps, 10000) end;
  v_amt := public.round_div(p.amount_minor::numeric * v_bps, 10000);
  if v_amt <= 0 then return; end if;
  f := private.create_refund(p.id, v_amt,
         case p_actor_role when 'customer' then 'customer_cancellation' when 'worker' then 'worker_cancellation'
                           else 'admin_cancellation' end,
         p_reason, p_actor_id, p_actor_role, 'approved', v_bps, 'cancel:' || b.id);
  perform private.notify(b.customer_id, 'refund.approved', jsonb_build_object('ref', b.ref),
                         jsonb_build_object('booking_id', b.id, 'refund_id', f.id));
end $$;

-- Customer asks for a refund (e.g. unsatisfactory work). Needs admin approval.
create function public.request_refund(p_booking_id uuid, p_amount_minor bigint, p_reason text)
returns public.refunds language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; p public.payments%rowtype; f public.refunds;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.customer_id <> auth.uid() then perform private.err('booking_not_found'); end if;
  if b.status not in ('awaiting_confirmation', 'completed', 'disputed') then perform private.err('refund_not_allowed'); end if;
  select * into p from public.payments where booking_id = b.id and purpose = 'booking' and allocated;
  if not found then perform private.err('payment_not_refundable'); end if;
  if exists (select 1 from public.refunds where payment_id = p.id and status = 'requested') then
    perform private.err('refund_already_requested');
  end if;
  f := private.create_refund(p.id, p_amount_minor, 'service_issue', left(p_reason, 1000), auth.uid(), 'customer',
                             'requested', null, 'req:' || gen_random_uuid());
  perform private.notify_staff('refunds.approve', 'staff.refund_requested', jsonb_build_object('ref', b.ref),
                               jsonb_build_object('booking_id', b.id, 'refund_id', f.id));
  return f;
end $$;

create function public.decide_refund(p_refund_id uuid, p_approve boolean, p_note text default null)
returns public.refunds language plpgsql security definer set search_path = public, private as $$
declare f public.refunds%rowtype; b public.bookings%rowtype;
begin
  perform private.require_permission('refunds.approve');
  select * into f from public.refunds where id = p_refund_id for update;
  if not found then perform private.err('refund_not_found'); end if;
  if f.status <> 'requested' then perform private.err('refund_not_pending'); end if;
  update public.refunds set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), reason = coalesce(reason, '') || coalesce(E'\nDecision: ' || p_note, '')
   where id = f.id returning * into f;
  select * into b from public.bookings where id = f.booking_id;
  perform private.audit(case when p_approve then 'refund.approve' else 'refund.reject' end, 'refund', f.id::text,
                        jsonb_build_object('amount_minor', f.amount_minor, 'note', p_note));
  perform private.notify(b.customer_id, case when p_approve then 'refund.approved' else 'refund.rejected' end,
                         jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id, 'refund_id', f.id));
  return f;
end $$;

-- Edge Function claims an approved refund before calling the provider.
create function public.begin_refund_processing(p_refund_id uuid) returns public.refunds
language plpgsql security definer set search_path = public, private as $$
declare f public.refunds;
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  update public.refunds set status = 'processing' where id = p_refund_id and status = 'approved' returning * into f;
  if not found then perform private.err('refund_not_claimable'); end if;
  return f;
end $$;

create function public.set_refund_provider_ref(p_refund_id uuid, p_ref text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  update public.refunds set provider_refund_ref = p_ref where id = p_refund_id;
end $$;

-- Provider confirmed the refund: post the reversal, adjust earnings and commissions.
create function private.apply_refund_succeeded(p_refund_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare f public.refunds%rowtype; p public.payments%rowtype; b public.bookings%rowtype; r public.extra_time_requests%rowtype;
        v_worker uuid; v_rate int; v_entries jsonb;
begin
  select * into f from public.refunds where id = p_refund_id for update;
  if f.status = 'succeeded' then return; end if;
  select * into p from public.payments where id = f.payment_id for update;
  select * into b from public.bookings where id = f.booking_id;
  update public.refunds set status = 'succeeded', succeeded_at = now() where id = f.id;
  update public.payments set refunded_minor = refunded_minor + f.amount_minor,
         status = case when refunded_minor + f.amount_minor >= amount_minor then 'refunded' else 'partially_refunded' end
   where id = p.id;

  if p.purpose = 'extra_time' then
    select * into r from public.extra_time_requests where id = p.extra_time_request_id;
    v_worker := r.worker_id; v_rate := r.commission_rate_bps;
  else
    v_worker := b.worker_id; v_rate := b.commission_rate_bps;
    if v_worker is null then   -- unassigned/cancelled booking: use the worker that earned it, if any
      select worker_id into v_worker from public.worker_earnings where booking_id = b.id and kind = 'job' order by created_at limit 1;
    end if;
  end if;
  v_entries := jsonb_build_array(
    jsonb_build_object('account', 'TAX_PAYABLE', 'dir', 'debit', 'amount', f.tax_part_minor),
    jsonb_build_object('account', 'FEE_REVENUE', 'dir', 'debit', 'amount', f.fee_part_minor),
    jsonb_build_object('account', 'COMMISSION_REVENUE', 'dir', 'debit', 'amount', f.commission_part_minor),
    jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'debit', 'amount', f.earning_part_minor, 'worker', v_worker),
    jsonb_build_object('account', 'CUSTOMER_UNAPPLIED', 'dir', 'debit', 'amount', f.unapplied_part_minor),
    jsonb_build_object('account', 'PROVIDER_CLEARING', 'dir', 'credit', 'amount', f.amount_minor));
  perform private.post_ledger('refund', 'Refund ' || f.id, f.booking_id, p.id, f.id, f.currency,
                              'refund:' || f.id, v_entries);
  if f.commission_part_minor > 0 then
    insert into public.commissions (booking_id, extra_time_request_id, refund_id, kind, rate_bps, amount_minor, currency)
    values (f.booking_id, p.extra_time_request_id, f.id, 'reversal', v_rate, -f.commission_part_minor, f.currency);
  end if;
  if f.earning_part_minor > 0 and v_worker is not null then
    insert into public.worker_earnings (worker_id, booking_id, extra_time_request_id, refund_id, kind, amount_minor, currency, note)
    values (v_worker, f.booking_id, p.extra_time_request_id, f.id, 'refund_adjustment', -f.earning_part_minor, f.currency,
            'refund ' || f.reason_code);
  end if;
  perform private.notify(b.customer_id, 'refund.succeeded', jsonb_build_object('ref', b.ref),
                         jsonb_build_object('booking_id', b.id, 'refund_id', f.id));
end $$;

-- ---------------------------------------------------------------------------
-- Payment success handling
-- ---------------------------------------------------------------------------
create function private.apply_payment_succeeded(p_payment_id uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare
  p public.payments%rowtype; b public.bookings%rowtype; r public.extra_time_requests%rowtype;
  v_ok boolean := false; v_worker uuid; v_entries jsonb; v_note text; f public.refunds;
begin
  select * into p from public.payments where id = p_payment_id for update;
  update public.payments set status = 'succeeded', succeeded_at = now(), failure_code = null where id = p.id;
  select * into b from public.bookings where id = p.booking_id for update;

  if p.purpose = 'booking' then
    v_ok := b.status = 'pending_payment'
            and not exists (select 1 from public.payments o where o.booking_id = b.id and o.purpose = 'booking'
                            and o.allocated and o.id <> p.id);
    v_note := case when exists (select 1 from public.payments o where o.booking_id = b.id and o.purpose = 'booking'
                                and o.allocated and o.id <> p.id) then 'duplicate_payment'
                   else 'booking_not_payable' end;
  else
    select * into r from public.extra_time_requests where id = p.extra_time_request_id for update;
    v_ok := r.status = 'awaiting_payment' and b.status = 'in_progress';
    v_note := 'extra_time_not_payable';
  end if;

  if not v_ok then
    -- Money arrived that cannot be applied (timeout, duplicate, cancelled): book it as unapplied and refund in full.
    perform private.post_ledger('payment_unallocated', 'Unapplied funds ' || p.id, p.booking_id, p.id, null, p.currency,
      'pay-unapplied:' || p.id, jsonb_build_array(
        jsonb_build_object('account', 'PROVIDER_CLEARING', 'dir', 'debit', 'amount', p.amount_minor),
        jsonb_build_object('account', 'CUSTOMER_UNAPPLIED', 'dir', 'credit', 'amount', p.amount_minor)));
    update public.payments set needs_review = true, review_reason = v_note where id = p.id;
    p.status := 'succeeded';
    f := private.create_refund(p.id, p.amount_minor,
           case when v_note = 'duplicate_payment' then 'duplicate_payment' else 'payment_timeout_late_capture' end,
           'automatic refund: ' || v_note, null, 'system', 'approved', 10000, 'unapplied:' || p.id);
    perform private.notify(b.customer_id, 'payment.refunded_late', jsonb_build_object('ref', b.ref),
                           jsonb_build_object('booking_id', b.id, 'refund_id', f.id));
    return 'unallocated:' || v_note;
  end if;

  update public.payments set allocated = true where id = p.id;
  if p.purpose = 'booking' then
    v_worker := b.worker_id;
    v_entries := jsonb_build_array(
      jsonb_build_object('account', 'PROVIDER_CLEARING', 'dir', 'debit', 'amount', b.total_minor),
      jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'credit', 'amount', b.worker_earning_minor, 'worker', v_worker),
      jsonb_build_object('account', 'COMMISSION_REVENUE', 'dir', 'credit', 'amount', b.commission_minor),
      jsonb_build_object('account', 'FEE_REVENUE', 'dir', 'credit', 'amount', b.fee_minor),
      jsonb_build_object('account', 'TAX_PAYABLE', 'dir', 'credit', 'amount', b.tax_minor));
    perform private.post_ledger('payment_captured', 'Booking payment ' || b.ref, b.id, p.id, null, p.currency,
                                'pay:' || p.id, v_entries);
    insert into public.commissions (booking_id, kind, rate_bps, amount_minor, currency)
    values (b.id, 'earned', b.commission_rate_bps, b.commission_minor, b.currency);
    insert into public.worker_earnings (worker_id, booking_id, kind, amount_minor, currency)
    values (v_worker, b.id, 'job', b.worker_earning_minor, b.currency);
    insert into public.booking_assignments (booking_id, worker_id, assigned_via) values (b.id, v_worker, 'auto');
    update public.bookings set accept_by = now() + make_interval(mins => public.app_setting_int('booking.worker_accept_minutes', 60))
     where id = b.id;
    perform private.transition_booking(b.id, 'assigned', 'system', null, 'payment confirmed');
    perform private.notify(b.customer_id, 'booking.confirmed', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
    perform private.notify(v_worker, 'booking.assigned', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  else
    v_entries := jsonb_build_array(
      jsonb_build_object('account', 'PROVIDER_CLEARING', 'dir', 'debit', 'amount', r.total_minor),
      jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'credit', 'amount', r.worker_earning_minor, 'worker', r.worker_id),
      jsonb_build_object('account', 'COMMISSION_REVENUE', 'dir', 'credit', 'amount', r.commission_minor),
      jsonb_build_object('account', 'TAX_PAYABLE', 'dir', 'credit', 'amount', r.tax_minor));
    perform private.post_ledger('payment_captured', 'Extra time ' || b.ref, b.id, p.id, null, p.currency,
                                'pay:' || p.id, v_entries);
    insert into public.commissions (booking_id, extra_time_request_id, kind, rate_bps, amount_minor, currency)
    values (b.id, r.id, 'earned', r.commission_rate_bps, r.commission_minor, r.currency);
    insert into public.worker_earnings (worker_id, booking_id, extra_time_request_id, kind, amount_minor, currency)
    values (r.worker_id, b.id, r.id, 'extra_time', r.worker_earning_minor, r.currency);
    update public.extra_time_requests set status = 'approved' where id = r.id;
    update public.bookings set extra_minutes = extra_minutes + r.requested_minutes where id = b.id;
    begin   -- extend the blocked window if still free; the approved charge stands either way
      update public.bookings set scheduled_end = scheduled_end + make_interval(mins => r.requested_minutes) where id = b.id;
    exception when exclusion_violation then null;
    end;
    perform private.notify(r.worker_id, 'extra_time.approved', jsonb_build_object('ref', b.ref),
                           jsonb_build_object('booking_id', b.id, 'extra_time_request_id', r.id));
  end if;
  perform private.notify(b.customer_id, 'payment.succeeded', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  return 'applied';
end $$;

-- ---------------------------------------------------------------------------
-- Provider event ingestion (service role only; signature already verified by the Edge Function)
-- ---------------------------------------------------------------------------
create function public.process_payment_event(
  p_provider text, p_event_id text, p_event_type text, p_provider_ref text,
  p_amount_minor bigint, p_currency text, p_livemode boolean, p_payload jsonb default '{}'::jsonb,
  p_refund_ref text default null)
returns jsonb language plpgsql security definer set search_path = public, private as $$
declare
  v_evt uuid; p public.payments%rowtype; f public.refunds%rowtype;
  v_status text := 'processed'; v_note text; v_res text;
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  insert into public.payment_events (provider, provider_event_id, event_type, livemode, payload)
  values (p_provider, p_event_id, p_event_type, p_livemode, coalesce(p_payload, '{}'))
  on conflict (provider, provider_event_id) do nothing returning id into v_evt;
  if v_evt is null then return jsonb_build_object('result', 'duplicate'); end if;

  select * into p from public.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then
    update public.payment_events set processing_status = 'error', processing_note = 'unknown payment', processed_at = now() where id = v_evt;
    return jsonb_build_object('result', 'unknown_payment');
  end if;
  update public.payment_events set payment_id = p.id where id = v_evt;

  if p_livemode and coalesce((public.app_setting('payments.live_enabled') #>> '{}')::boolean, false) is not true then
    v_status := 'ignored'; v_note := 'live events rejected while payments.live_enabled=false';
  elsif p_livemode is distinct from p.livemode then
    v_status := 'error'; v_note := 'livemode mismatch';
    update public.payments set needs_review = true, review_reason = v_note where id = p.id;
  elsif p_event_type = 'payment.succeeded' then
    if p_amount_minor is distinct from p.amount_minor or upper(p_currency) is distinct from p.currency then
      v_status := 'error'; v_note := format('amount mismatch: provider %s %s vs expected %s %s', p_amount_minor, p_currency, p.amount_minor, p.currency);
      update public.payments set needs_review = true, review_reason = v_note where id = p.id;
    elsif p.status in ('succeeded', 'partially_refunded', 'refunded') then
      v_status := 'ignored'; v_note := 'already succeeded';
    else
      v_res := private.apply_payment_succeeded(p.id); v_note := v_res;
    end if;
  elsif p_event_type in ('payment.failed', 'payment.cancelled') then
    if p.status in ('pending', 'requires_action', 'authorized') then
      update public.payments set status = case when p_event_type = 'payment.failed' then 'failed' else 'cancelled' end,
             failure_code = p_payload ->> 'failure_code' where id = p.id;
      perform private.notify((select customer_id from public.bookings where id = p.booking_id), 'payment.failed',
        jsonb_build_object('ref', (select ref from public.bookings where id = p.booking_id)),
        jsonb_build_object('booking_id', p.booking_id));
    else v_status := 'ignored'; v_note := 'payment already ' || p.status; end if;
  elsif p_event_type = 'payment.requires_action' then
    if p.status = 'pending' then update public.payments set status = 'requires_action' where id = p.id;
    else v_status := 'ignored'; end if;
  elsif p_event_type = 'payment.authorized' then
    if p.status in ('pending', 'requires_action') then update public.payments set status = 'authorized' where id = p.id;
    else v_status := 'ignored'; end if;
  elsif p_event_type in ('refund.succeeded', 'refund.failed') then
    select * into f from public.refunds where payment_id = p.id and provider_refund_ref = p_refund_ref for update;
    if not found then
      v_status := 'error'; v_note := 'unknown refund';
    elsif p_event_type = 'refund.succeeded' then
      if f.status in ('processing', 'approved') then perform private.apply_refund_succeeded(f.id);
      else v_status := 'ignored'; v_note := 'refund already ' || f.status; end if;
    else
      if f.status in ('processing', 'approved') then update public.refunds set status = 'failed' where id = f.id;
      else v_status := 'ignored'; end if;
    end if;
  else
    v_status := 'ignored'; v_note := 'unhandled event type';
  end if;

  update public.payment_events set processing_status = v_status, processing_note = v_note, processed_at = now() where id = v_evt;
  return jsonb_build_object('result', v_status, 'note', v_note, 'payment_id', p.id);
end $$;

-- ---------------------------------------------------------------------------
-- Earnings, payouts
-- ---------------------------------------------------------------------------
create function private.refresh_earning_eligibility() returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_hold interval := make_interval(hours => public.app_setting_int('payouts.hold_hours', 24));
begin
  update public.worker_earnings e set status = 'eligible', eligible_at = now()
    from public.bookings b
   where e.booking_id = b.id and e.status = 'pending' and e.kind in ('job', 'extra_time', 'refund_adjustment')
     and ((b.status = 'completed' and b.completed_at + v_hold <= now())
          or (b.status = 'cancelled' and b.cancelled_at + v_hold <= now()))
     and not exists (select 1 from public.disputes d where d.booking_id = b.id and d.status in ('open', 'investigating'))
     and not exists (select 1 from public.refunds r where r.booking_id = b.id and r.status in ('requested', 'approved', 'processing'));
  get diagnostics n = row_count;
  return n;
end $$;

create function public.create_payout_batch(p_idempotency_key text) returns public.payout_batches
language plpgsql security definer set search_path = public, private as $$
declare
  v_batch public.payout_batches; g record; v_item public.payout_items; v_total bigint := 0; v_count int := 0;
begin
  perform private.require_permission('payouts.manage');
  select * into v_batch from public.payout_batches where idempotency_key = p_idempotency_key;
  if found then return v_batch; end if;
  perform private.refresh_earning_eligibility();
  insert into public.payout_batches (currency, idempotency_key, created_by)
  values (public.app_setting('platform.currency') #>> '{}', p_idempotency_key, auth.uid()) returning * into v_batch;

  for g in
    select e.worker_id, e.currency, sum(e.amount_minor) as net, array_agg(e.id) as ids
    from (select * from public.worker_earnings where status = 'eligible' order by id for update skip locked) e
    join public.worker_profiles w on w.id = e.worker_id and w.status <> 'suspended'
    group by e.worker_id, e.currency
  loop
    if g.net > 0 then
      insert into public.payout_items (batch_id, worker_id, amount_minor, currency)
      values (v_batch.id, g.worker_id, g.net, g.currency) returning * into v_item;
      update public.worker_earnings set status = 'in_payout', payout_item_id = v_item.id where id = any (g.ids);
      v_total := v_total + g.net; v_count := v_count + 1;
    elsif g.net = 0 then
      update public.worker_earnings set status = 'netted' where id = any (g.ids);
    end if;   -- negative balance: left eligible and carried into a future payout
  end loop;
  update public.payout_batches set total_minor = v_total, item_count = v_count,
         status = case when v_count = 0 then 'completed' else 'processing' end,
         completed_at = case when v_count = 0 then now() end
   where id = v_batch.id returning * into v_batch;
  perform private.audit('payout_batch.create', 'payout_batch', v_batch.id::text,
                        jsonb_build_object('total_minor', v_total, 'items', v_count));
  return v_batch;
end $$;

create function public.mark_payout_item(p_item_id uuid, p_status text, p_ref text default null, p_reason text default null)
returns public.payout_items language plpgsql security definer set search_path = public, private as $$
declare i public.payout_items%rowtype; v_open int;
begin
  perform private.require_permission('payouts.manage');
  if p_status not in ('paid', 'failed') then perform private.err('invalid_status'); end if;
  select * into i from public.payout_items where id = p_item_id for update;
  if not found then perform private.err('payout_item_not_found'); end if;
  if i.status = p_status then return i; end if;          -- idempotent
  if i.status in ('paid', 'failed') then perform private.err('payout_item_final'); end if;

  if p_status = 'paid' then
    update public.payout_items set status = 'paid', provider_payout_ref = p_ref, paid_at = now() where id = i.id returning * into i;
    update public.worker_earnings set status = 'paid' where payout_item_id = i.id;
    perform private.post_ledger('payout', 'Payout ' || i.id, null, null, null, i.currency, 'payout:' || i.id,
      jsonb_build_array(
        jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'debit', 'amount', i.amount_minor, 'worker', i.worker_id),
        jsonb_build_object('account', 'PROVIDER_CLEARING', 'dir', 'credit', 'amount', i.amount_minor)), i.id);
    perform private.notify(i.worker_id, 'payout.paid', jsonb_build_object('amount', to_char(i.amount_minor / 100.0, 'FM999999990.00')),
                           jsonb_build_object('payout_item_id', i.id));
  else
    update public.payout_items set status = 'failed', failure_reason = p_reason where id = i.id returning * into i;
    update public.worker_earnings set status = 'eligible', payout_item_id = null where payout_item_id = i.id;
    perform private.notify(i.worker_id, 'payout.failed', '{}'::jsonb, jsonb_build_object('payout_item_id', i.id));
  end if;
  select count(*) into v_open from public.payout_items where batch_id = i.batch_id and status in ('pending', 'processing');
  if v_open = 0 then
    update public.payout_batches set status = case when exists (select 1 from public.payout_items where batch_id = i.batch_id and status = 'failed')
                                                    then 'failed' else 'completed' end,
           completed_at = now() where id = i.batch_id;
  end if;
  perform private.audit('payout_item.' || p_status, 'payout_item', i.id::text, jsonb_build_object('ref', p_ref, 'reason', p_reason));
  return i;
end $$;

-- Manual earnings adjustment (compensating entry). Positive = bonus/compensation, negative = deduction.
create function public.add_earning_adjustment(p_worker_id uuid, p_amount_minor bigint, p_reason text, p_booking_id uuid default null)
returns public.worker_earnings language plpgsql security definer set search_path = public, private as $$
declare e public.worker_earnings; v_cur text := public.app_setting('platform.currency') #>> '{}';
begin
  perform private.require_permission('payouts.manage');
  if p_amount_minor = 0 or coalesce(length(trim(p_reason)), 0) < 5 then perform private.err('invalid_adjustment'); end if;
  insert into public.worker_earnings (worker_id, booking_id, kind, amount_minor, currency, status, eligible_at, note, created_by)
  values (p_worker_id, p_booking_id, 'manual_adjustment', p_amount_minor, v_cur, 'eligible', now(), p_reason, auth.uid())
  returning * into e;
  perform private.post_ledger('adjustment', 'Manual adjustment: ' || p_reason, p_booking_id, null, null, v_cur, 'adj:' || e.id,
    jsonb_build_array(
      jsonb_build_object('account', 'COMMISSION_REVENUE', 'dir', case when p_amount_minor > 0 then 'debit' else 'credit' end, 'amount', abs(p_amount_minor)),
      jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', case when p_amount_minor > 0 then 'credit' else 'debit' end, 'amount', abs(p_amount_minor), 'worker', p_worker_id)));
  perform private.audit('earning.adjustment', 'worker', p_worker_id::text, jsonb_build_object('amount_minor', p_amount_minor, 'reason', p_reason));
  return e;
end $$;

-- ---------------------------------------------------------------------------
-- Reconciliation
-- ---------------------------------------------------------------------------
create function public.reconcile_finance() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_unbalanced int; v_worker_mismatch jsonb; v_payout_mismatch jsonb; v_payments_unreconciled jsonb; v_mismatches int; v_out jsonb;
begin
  perform private.require_permission('finance.read');
  select count(*) into v_unbalanced from (
    select transaction_id from public.ledger_entries group by transaction_id
    having sum(amount_minor) filter (where direction = 'debit') is distinct from sum(amount_minor) filter (where direction = 'credit')) x;

  -- Ledger WORKER_PAYABLE per worker must equal the earnings that are not yet paid out (excluding voided rows).
  select coalesce(jsonb_agg(jsonb_build_object('worker_id', w, 'ledger_minor', l, 'earnings_minor', e)), '[]') into v_worker_mismatch
  from (
    select coalesce(l.worker_id, e.worker_id) w, coalesce(l.bal, 0) l, coalesce(e.bal, 0) e
    from (select worker_id, sum(case direction when 'credit' then amount_minor else -amount_minor end) bal
          from public.ledger_entries le join public.ledger_accounts a on a.id = le.account_id and a.code = 'WORKER_PAYABLE'
          group by worker_id) l
    full join (select worker_id, sum(amount_minor) bal from public.worker_earnings
               where status not in ('paid', 'void') group by worker_id) e on e.worker_id = l.worker_id
    where coalesce(l.bal, 0) <> coalesce(e.bal, 0)) m;

  select coalesce(jsonb_agg(jsonb_build_object('batch_id', b.id, 'batch_total', b.total_minor, 'items_total', i.s, 'earnings_total', e.s)), '[]')
    into v_payout_mismatch
  from public.payout_batches b
  left join lateral (select coalesce(sum(amount_minor), 0) s from public.payout_items where batch_id = b.id) i on true
  left join lateral (select coalesce(sum(we.amount_minor), 0) s from public.worker_earnings we
                     join public.payout_items pi on pi.id = we.payout_item_id where pi.batch_id = b.id and pi.status <> 'failed') e on true
  where b.total_minor <> i.s or (i.s <> e.s and not exists (select 1 from public.payout_items where batch_id = b.id and status = 'failed'));

  -- Payments marked succeeded must have a captured ledger transaction; ledger captures need a succeeded payment.
  select coalesce(jsonb_agg(p.id), '[]') into v_payments_unreconciled
  from public.payments p
  where p.status in ('succeeded', 'partially_refunded', 'refunded')
    and not exists (select 1 from public.ledger_transactions t where t.payment_id = p.id and t.kind in ('payment_captured', 'payment_unallocated'));

  v_mismatches := v_unbalanced + jsonb_array_length(v_worker_mismatch) + jsonb_array_length(v_payout_mismatch)
                  + jsonb_array_length(v_payments_unreconciled);
  v_out := jsonb_build_object('unbalanced_transactions', v_unbalanced, 'worker_payable_mismatches', v_worker_mismatch,
                              'payout_mismatches', v_payout_mismatch, 'payments_without_ledger', v_payments_unreconciled,
                              'mismatch_count', v_mismatches);
  insert into public.reconciliation_runs (kind, run_by, mismatches, summary) values ('ledger', auth.uid(), v_mismatches, v_out);
  return v_out;
end $$;
