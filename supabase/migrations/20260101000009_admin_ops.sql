-- Worker onboarding & verification, admin operations, disputes, maintenance, account lifecycle,
-- reporting, safe read-only views, notification templates.

-- ---------------------------------------------------------------------------
-- Worker onboarding
-- ---------------------------------------------------------------------------
create function public.become_worker() returns public.worker_profiles
language plpgsql security definer set search_path = public, private as $$
declare w public.worker_profiles;
begin
  if auth.uid() is null then perform private.err('not_authenticated'); end if;
  insert into public.worker_profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into public.user_roles (user_id, role) values (auth.uid(), 'worker') on conflict do nothing;
  select * into w from public.worker_profiles where id = auth.uid();
  return w;
end $$;

create function public.submit_worker_application() returns public.worker_profiles
language plpgsql security definer set search_path = public, private as $$
declare w public.worker_profiles; v_missing text;
begin
  select * into w from public.worker_profiles where id = auth.uid() for update;
  if not found then perform private.err('worker_profile_missing'); end if;
  if w.status not in ('draft', 'rejected', 'expired_credentials') then perform private.err('application_not_editable'); end if;
  select string_agg(r.t, ',') into v_missing
  from jsonb_array_elements_text(public.app_setting('worker.required_documents')) r (t)
  where not exists (select 1 from public.worker_documents d where d.worker_id = w.id and d.doc_type = r.t and d.status <> 'rejected');
  if v_missing is not null then perform private.err('documents_missing', v_missing); end if;
  if not exists (select 1 from public.worker_skills where worker_id = w.id) then perform private.err('skills_missing'); end if;
  if not exists (select 1 from public.worker_service_areas where worker_id = w.id) then perform private.err('areas_missing'); end if;
  perform set_config('app.internal_write', 'on', true);
  update public.worker_profiles set status = 'submitted', submitted_at = now(), status_reason = null
   where id = w.id returning * into w;
  perform set_config('app.internal_write', 'off', true);
  perform private.notify_staff('workers.review', 'staff.worker_submitted', '{}'::jsonb, jsonb_build_object('worker_id', w.id));
  return w;
end $$;

create function public.review_document(p_document_id uuid, p_approve boolean, p_note text default null)
returns public.worker_documents language plpgsql security definer set search_path = public, private as $$
declare d public.worker_documents%rowtype; w public.worker_profiles%rowtype;
begin
  perform private.require_permission('workers.documents.read');
  perform private.require_permission('workers.review');
  if not p_approve and coalesce(length(trim(p_note)), 0) < 3 then perform private.err('reason_required'); end if;
  update public.worker_documents set status = (case when p_approve then 'approved' else 'rejected' end)::public.document_status,
         reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
   where id = p_document_id returning * into d;
  if not found then perform private.err('document_not_found'); end if;
  select * into w from public.worker_profiles where id = d.worker_id;
  -- Renewed credentials restore a worker whose approval lapsed.
  if p_approve and w.status = 'expired_credentials' and public.worker_documents_valid(w.id) then
    perform set_config('app.internal_write', 'on', true);
    update public.worker_profiles set status = 'approved', status_reason = null where id = w.id;
    perform set_config('app.internal_write', 'off', true);
    perform private.notify(w.id, 'worker.reinstated', '{}'::jsonb);
  end if;
  perform private.audit('worker_document.' || case when p_approve then 'approve' else 'reject' end,
                        'worker_document', d.id::text, jsonb_build_object('worker_id', d.worker_id, 'note', p_note));
  return d;
end $$;

create function public.review_worker(p_worker_id uuid, p_decision text, p_reason text default null)
returns public.worker_profiles language plpgsql security definer set search_path = public, private as $$
declare w public.worker_profiles%rowtype; v_new public.worker_status; v_id uuid;
begin
  perform private.require_permission('workers.review');
  if p_decision = 'suspend' then perform private.require_permission('users.suspend'); end if;
  select * into w from public.worker_profiles where id = p_worker_id for update;
  if not found then perform private.err('worker_not_found'); end if;
  if p_decision in ('reject', 'suspend') and coalesce(length(trim(p_reason)), 0) < 3 then perform private.err('reason_required'); end if;

  if p_decision = 'start_review' and w.status = 'submitted' then v_new := 'under_review';
  elsif p_decision = 'approve' and w.status in ('submitted', 'under_review') then
    if not public.worker_documents_valid(w.id) then perform private.err('required_documents_not_approved'); end if;
    if not exists (select 1 from public.worker_skills where worker_id = w.id and approved) then perform private.err('no_approved_skill'); end if;
    if not exists (select 1 from public.worker_service_areas where worker_id = w.id) then perform private.err('areas_missing'); end if;
    v_new := 'approved';
  elsif p_decision = 'reject' and w.status in ('submitted', 'under_review') then v_new := 'rejected';
  elsif p_decision = 'suspend' and w.status in ('approved', 'expired_credentials') then v_new := 'suspended';
  elsif p_decision = 'reinstate' and w.status = 'suspended' then
    v_new := case when public.worker_documents_valid(w.id) then 'approved' else 'expired_credentials' end;
  else perform private.err('invalid_worker_decision', format('%s from %s', p_decision, w.status)); end if;

  perform set_config('app.internal_write', 'on', true);
  update public.worker_profiles set status = v_new, reviewed_by = auth.uid(), reviewed_at = now(),
         status_reason = case when v_new in ('rejected', 'suspended') then p_reason end
   where id = w.id returning * into w;
  perform set_config('app.internal_write', 'off', true);

  if v_new = 'suspended' then   -- release live, not-yet-started jobs for reassignment
    for v_id in select id from public.bookings where worker_id = w.id and status in ('assigned', 'accepted') loop
      perform private.transition_booking(v_id, 'unassigned', 'admin', auth.uid(), 'worker suspended');
    end loop;
  end if;
  perform private.audit('worker.' || p_decision, 'worker', w.id::text, jsonb_build_object('reason', p_reason, 'new_status', v_new));
  perform private.notify(w.id, 'worker.' || v_new, jsonb_build_object('reason', coalesce(p_reason, '')), jsonb_build_object('status', v_new));
  return w;
end $$;

-- ---------------------------------------------------------------------------
-- Admin booking operations
-- ---------------------------------------------------------------------------
create function public.admin_assign_worker(p_booking_id uuid, p_worker_id uuid, p_reason text default null)
returns public.bookings language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; v_old uuid; v_cur text; e record;
begin
  perform private.require_permission('bookings.manage');
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then perform private.err('booking_not_found'); end if;
  if b.status not in ('unassigned', 'assigned', 'accepted') then perform private.err('cannot_assign_in_status', b.status::text); end if;
  if not public.is_worker_bookable(p_worker_id)
     or not exists (select 1 from public.worker_skills where worker_id = p_worker_id and service_id = b.service_id and approved)
     or not exists (select 1 from public.worker_service_areas where worker_id = p_worker_id and area_id = b.area_id)
     or exists (select 1 from public.worker_time_off t where t.worker_id = p_worker_id and t.during && tstzrange(b.scheduled_start, b.scheduled_end, '[)')) then
    perform private.err('worker_not_eligible');
  end if;
  v_old := b.worker_id;
  if v_old is not null then
    update public.booking_assignments set ended_at = now(), response = 'reassigned', note = p_reason
     where booking_id = b.id and ended_at is null;
  else
    update public.booking_assignments set ended_at = now() where booking_id = b.id and ended_at is null;
  end if;
  begin
    update public.bookings set worker_id = p_worker_id,
           accept_by = now() + make_interval(mins => public.app_setting_int('booking.worker_accept_minutes', 60))
     where id = b.id returning * into b;
  exception when exclusion_violation then perform private.err('worker_not_available');
  end;
  insert into public.booking_assignments (booking_id, worker_id, assigned_by, assigned_via, note)
  values (b.id, p_worker_id, auth.uid(), 'admin', p_reason);

  -- Move the unpaid earnings (and the ledger payable) from the old worker to the new one.
  for e in select * from public.worker_earnings where booking_id = b.id and kind in ('job', 'extra_time')
           and status in ('pending', 'eligible', 'held') and worker_id <> p_worker_id loop
    update public.worker_earnings set status = 'void', note = 'reassigned' where id = e.id;
    insert into public.worker_earnings (worker_id, booking_id, extra_time_request_id, kind, amount_minor, currency, note)
    values (p_worker_id, e.booking_id, e.extra_time_request_id, e.kind, e.amount_minor, e.currency, 'reassigned from ' || e.worker_id);
    perform private.post_ledger('adjustment', 'Reassign payable ' || b.ref, b.id, null, null, e.currency, 'reassign:' || e.id,
      jsonb_build_array(
        jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'debit', 'amount', e.amount_minor, 'worker', e.worker_id),
        jsonb_build_object('account', 'WORKER_PAYABLE', 'dir', 'credit', 'amount', e.amount_minor, 'worker', p_worker_id)));
  end loop;

  if b.status <> 'assigned' then
    perform set_config('app.booking_transition', 'on', true);
    update public.bookings set status = 'assigned', accepted_at = null where id = b.id returning * into b;
    perform set_config('app.booking_transition', 'off', true);
  end if;
  insert into public.booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, reason)
  values (b.id, b.status, 'assigned', auth.uid(), 'admin', coalesce(p_reason, 'worker assigned by admin'));
  perform private.audit('booking.assign', 'booking', b.id::text, jsonb_build_object('from', v_old, 'to', p_worker_id, 'reason', p_reason));
  perform private.notify(p_worker_id, 'booking.assigned', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  if v_old is not null then perform private.notify(v_old, 'booking.reassigned_away', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id)); end if;
  perform private.notify(b.customer_id, 'booking.worker_changed', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  return b;
end $$;

create function public.admin_cancel_booking(p_booking_id uuid, p_reason text, p_refund_bps int default 10000)
returns public.bookings language plpgsql security definer set search_path = public, private as $$
declare b public.bookings;
begin
  perform private.require_permission('bookings.manage');
  if p_refund_bps not between 0 and 10000 or coalesce(length(trim(p_reason)), 0) < 3 then perform private.err('invalid_request'); end if;
  if p_refund_bps < 10000 then perform private.require_permission('refunds.approve'); end if;
  b := private.transition_booking(p_booking_id, 'cancelled', 'admin', auth.uid(), p_reason, p_refund_bps);
  perform private.audit('booking.cancel', 'booking', b.id::text, jsonb_build_object('reason', p_reason, 'refund_bps', p_refund_bps));
  return b;
end $$;

create function public.admin_set_booking_status(p_booking_id uuid, p_to public.booking_status, p_reason text)
returns public.bookings language plpgsql security definer set search_path = public, private as $$
declare b public.bookings;
begin
  perform private.require_permission('bookings.manage');
  if p_to = 'cancelled' then perform private.err('use_admin_cancel_booking'); end if;
  b := private.transition_booking(p_booking_id, p_to, 'admin', auth.uid(), p_reason);
  perform private.audit('booking.status', 'booking', b.id::text, jsonb_build_object('to', p_to, 'reason', p_reason));
  return b;
end $$;

create function public.resolve_dispute(p_dispute_id uuid, p_outcome text, p_refund_amount_minor bigint default null, p_note text default null)
returns public.disputes language plpgsql security definer set search_path = public, private as $$
declare d public.disputes%rowtype; b public.bookings%rowtype; p public.payments%rowtype; v_amt bigint; v_cancel boolean;
begin
  perform private.require_permission('disputes.manage');
  if p_outcome not in ('full_refund', 'partial_refund', 'no_refund') then perform private.err('invalid_outcome'); end if;
  select * into d from public.disputes where id = p_dispute_id for update;
  if not found or d.status not in ('open', 'investigating') then perform private.err('dispute_not_open'); end if;
  select * into b from public.bookings where id = d.booking_id for update;
  v_cancel := d.prior_status in ('assigned', 'accepted', 'en_route', 'arrived');

  if p_outcome <> 'no_refund' then
    perform private.require_permission('refunds.approve');
    select * into p from public.payments where booking_id = b.id and purpose = 'booking' and allocated;
    if not found then perform private.err('payment_not_refundable'); end if;
    v_amt := case when p_outcome = 'full_refund' then p.amount_minor - p.refunded_minor
                       - coalesce((select sum(amount_minor) from public.refunds where payment_id = p.id and status in ('requested','approved','processing')), 0)
                  else p_refund_amount_minor end;
    if coalesce(v_amt, 0) > 0 then
      perform private.create_refund(p.id, v_amt, 'dispute_resolution', p_note, auth.uid(), 'admin', 'approved',
                                    null, 'dispute:' || d.id);
    end if;
  end if;
  if v_cancel then
    perform private.transition_booking(b.id, 'cancelled', 'admin', auth.uid(), 'dispute resolved: ' || p_outcome, 0);
  else
    perform private.transition_booking(b.id, 'completed', 'admin', auth.uid(), 'dispute resolved: ' || p_outcome);
  end if;
  update public.worker_earnings set status = 'pending', note = null where booking_id = b.id and status = 'held';
  update public.disputes set status = 'resolved', outcome = p_outcome, resolution_note = p_note,
         resolved_by = auth.uid(), resolved_at = now() where id = d.id returning * into d;
  perform private.audit('dispute.resolve', 'dispute', d.id::text, jsonb_build_object('outcome', p_outcome, 'refund_minor', v_amt, 'note', p_note));
  perform private.notify(b.customer_id, 'dispute.resolved', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  if b.worker_id is not null then perform private.notify(b.worker_id, 'dispute.resolved', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id)); end if;
  return d;
end $$;

-- ---------------------------------------------------------------------------
-- Admin / roles / configuration
-- ---------------------------------------------------------------------------
create function public.admin_set_role(p_user_id uuid, p_role public.app_role, p_grant boolean) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_permission('roles.manage');
  if p_role in ('customer', 'worker') then perform private.err('role_managed_by_system'); end if;
  if p_user_id = auth.uid() then perform private.err('cannot_change_own_roles'); end if;
  if p_grant then
    insert into public.user_roles (user_id, role, granted_by) values (p_user_id, p_role, auth.uid()) on conflict do nothing;
  else
    if p_role = 'super_admin' and (select count(*) from public.user_roles where role = 'super_admin') <= 1 then
      perform private.err('last_super_admin');
    end if;
    delete from public.user_roles where user_id = p_user_id and role = p_role;
  end if;
  perform private.audit('role.' || case when p_grant then 'grant' else 'revoke' end, 'user', p_user_id::text, jsonb_build_object('role', p_role));
end $$;

-- One-time bootstrap, run by an operator with database/service-role credentials (never from a client).
create function public.bootstrap_first_admin(p_email text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid;
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  if exists (select 1 from public.user_roles where role = 'super_admin') then perform private.err('admin_already_bootstrapped'); end if;
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if v_id is null then perform private.err('user_not_found', 'create the user via Supabase Auth first'); end if;
  insert into public.user_roles (user_id, role) values (v_id, 'super_admin');
  perform private.audit('admin.bootstrap', 'user', v_id::text);
  return v_id;
end $$;

-- Commission change: closes the active policy for the scope and opens a new version.
create function public.set_commission_rate(p_scope text, p_category_id uuid, p_service_id uuid, p_rate_bps int, p_note text default null)
returns public.commission_policies language plpgsql security definer set search_path = public, private as $$
declare c public.commission_policies;
begin
  perform private.require_permission('pricing.manage');
  update public.commission_policies set effective_to = now()
   where scope = p_scope and effective_to is null and effective_from < now()
     and category_id is not distinct from p_category_id and service_id is not distinct from p_service_id;
  insert into public.commission_policies (scope, category_id, service_id, rate_bps, note, created_by, effective_from)
  values (p_scope, p_category_id, p_service_id, p_rate_bps, p_note, auth.uid(), now()) returning * into c;
  perform private.audit('commission.set', 'commission_policy', c.id::text,
                        jsonb_build_object('scope', p_scope, 'category_id', p_category_id, 'service_id', p_service_id, 'rate_bps', p_rate_bps));
  return c;
end $$;

-- ---------------------------------------------------------------------------
-- Account lifecycle
-- ---------------------------------------------------------------------------
create function public.request_account_deletion() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if auth.uid() is null then perform private.err('not_authenticated'); end if;
  update public.profiles set deletion_requested_at = coalesce(deletion_requested_at, now()) where id = auth.uid();
  perform private.notify_staff('users.suspend', 'staff.deletion_requested', '{}'::jsonb, jsonb_build_object('user_id', auth.uid()));
end $$;

-- Anonymises personal data while keeping financial records required for legal retention.
-- The Auth user itself is deleted afterwards by the admin Edge Function (service role).
create function public.process_account_deletion(p_user_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_permission('users.suspend');
  if exists (select 1 from public.bookings where customer_id = p_user_id
             and status in ('pending_payment','assigned','accepted','en_route','arrived','in_progress','awaiting_confirmation','disputed','unassigned'))
     or exists (select 1 from public.worker_earnings where worker_id = p_user_id and status in ('pending','eligible','held','in_payout'))
     or exists (select 1 from public.refunds r join public.bookings b on b.id = r.booking_id
                where b.customer_id = p_user_id and r.status in ('requested','approved','processing')) then
    perform private.err('open_obligations_prevent_deletion');
  end if;
  update public.profiles set full_name = 'Deleted user', phone = null, avatar_path = null, marketing_opt_in = false,
         anonymized_at = now(), deletion_requested_at = coalesce(deletion_requested_at, now()) where id = p_user_id;
  update public.bookings set address_snapshot = jsonb_build_object('area_id', area_id, 'redacted', true), description = ''
   where customer_id = p_user_id;
  delete from public.customer_addresses where user_id = p_user_id;
  delete from public.device_tokens where user_id = p_user_id;
  delete from public.notifications where user_id = p_user_id;
  delete from public.booking_attachments where uploaded_by = p_user_id;
  delete from public.worker_documents where worker_id = p_user_id;
  delete from public.user_roles where user_id = p_user_id and role in ('support', 'admin', 'super_admin');
  perform private.audit('account.anonymize', 'user', p_user_id::text);
end $$;

-- ---------------------------------------------------------------------------
-- Scheduled maintenance (run every minute via pg_cron or the `maintenance` Edge Function)
-- ---------------------------------------------------------------------------
create function public.run_maintenance() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v jsonb := '{}'::jsonb; n int; r record;
begin
  if not public.is_system() then perform private.err('forbidden'); end if;
  v := v || jsonb_build_object('reservations_expired', public.release_expired_reservations());

  n := 0;
  for r in select id from public.bookings where status = 'pending_payment' and payment_due_at <= now() loop
    begin perform private.transition_booking(r.id, 'cancelled', 'system', null, 'payment timeout'); n := n + 1;
    exception when others then raise warning 'maintenance: booking % not expired: %', r.id, sqlerrm; end;
  end loop;
  v := v || jsonb_build_object('unpaid_bookings_cancelled', n);

  update public.extra_time_requests set status = 'expired'
   where (status = 'pending' and expires_at <= now()) or (status = 'awaiting_payment' and payment_expires_at <= now());
  get diagnostics n = row_count;
  update public.payments p set status = 'cancelled'
   where p.purpose = 'extra_time' and p.status in ('pending', 'requires_action')
     and exists (select 1 from public.extra_time_requests e where e.id = p.extra_time_request_id and e.status = 'expired');
  v := v || jsonb_build_object('extra_time_expired', n);

  n := 0;
  for r in select id from public.bookings where status = 'assigned' and accept_by is not null and accept_by <= now() loop
    begin perform private.transition_booking(r.id, 'unassigned', 'system', null, 'worker did not respond'); n := n + 1;
    exception when others then raise warning 'maintenance: booking % not unassigned: %', r.id, sqlerrm; end;
  end loop;
  v := v || jsonb_build_object('timed_out_assignments', n);

  n := 0;
  for r in select id from public.bookings where status = 'awaiting_confirmation'
           and work_done_at <= now() - make_interval(hours => public.app_setting_int('booking.auto_complete_hours', 24)) loop
    begin perform private.transition_booking(r.id, 'completed', 'system', null, 'auto-completed: no customer response'); n := n + 1;
    exception when others then raise warning 'maintenance: booking % not completed: %', r.id, sqlerrm; end;
  end loop;
  v := v || jsonb_build_object('auto_completed', n);

  -- Reminders: the UPDATE ... RETURNING claims each booking exactly once.
  for r in update public.bookings set reminder_24h_sent_at = now()
           where status in ('assigned', 'accepted') and reminder_24h_sent_at is null
             and scheduled_start between now() + interval '1 hour' and now() + interval '24 hours'
           returning id, ref, customer_id, worker_id loop
    perform private.notify(r.customer_id, 'reminder.24h', jsonb_build_object('ref', r.ref), jsonb_build_object('booking_id', r.id));
    perform private.notify(r.worker_id, 'reminder.24h', jsonb_build_object('ref', r.ref), jsonb_build_object('booking_id', r.id));
  end loop;
  for r in update public.bookings set reminder_1h_sent_at = now()
           where status in ('assigned', 'accepted') and reminder_1h_sent_at is null
             and scheduled_start between now() and now() + interval '1 hour'
           returning id, ref, customer_id, worker_id loop
    perform private.notify(r.customer_id, 'reminder.1h', jsonb_build_object('ref', r.ref), jsonb_build_object('booking_id', r.id));
    perform private.notify(r.worker_id, 'reminder.1h', jsonb_build_object('ref', r.ref), jsonb_build_object('booking_id', r.id));
  end loop;

  -- Credential expiry: approved workers whose required documents lapsed stop being bookable.
  perform set_config('app.internal_write', 'on', true);
  n := 0;
  for r in select id from public.worker_profiles where status = 'approved' and not public.worker_documents_valid(id) loop
    update public.worker_profiles set status = 'expired_credentials', status_reason = 'required credential expired' where id = r.id;
    perform private.notify(r.id, 'worker.expired_credentials', '{}'::jsonb);
    n := n + 1;
  end loop;
  perform set_config('app.internal_write', 'off', true);
  v := v || jsonb_build_object('credentials_lapsed', n);

  v := v || jsonb_build_object('earnings_made_eligible', private.refresh_earning_eligibility());
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Dashboard / reports (permission-gated; financial figures need finance.read)
-- ---------------------------------------------------------------------------
create function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb; v_fin boolean := public.has_permission('finance.read') or public.is_system();
begin
  perform private.require_permission('bookings.read');
  select jsonb_build_object(
    'bookings_today', (select count(*) from public.bookings where scheduled_start::date = current_date and status <> 'pending_payment'),
    'bookings_by_status', coalesce((select jsonb_object_agg(status, c) from (select status, count(*) c from public.bookings group by status) s), '{}'),
    'pending_worker_reviews', (select count(*) from public.worker_profiles where status in ('submitted', 'under_review')),
    'open_disputes', (select count(*) from public.disputes where status in ('open', 'investigating')),
    'open_tickets', (select count(*) from public.support_tickets where status in ('open', 'pending')),
    'active_workers', (select count(*) from public.worker_profiles where status = 'approved' and is_available),
    'booking_trend', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'count', c) order by d)
        from (select g::date d, (select count(*) from public.bookings where created_at::date = g::date and status <> 'pending_payment') c
              from generate_series(current_date - 13, current_date, interval '1 day') g) t), '[]'),
    'revenue_minor', case when v_fin then (select coalesce(sum(amount_minor), 0) from public.payments where status in ('succeeded', 'partially_refunded', 'refunded') and allocated) end,
    'commission_minor', case when v_fin then (select coalesce(sum(amount_minor), 0) from public.commissions) end,
    'refunds_minor', case when v_fin then (select coalesce(sum(amount_minor), 0) from public.refunds where status = 'succeeded') end,
    'payment_exceptions', case when v_fin then (select count(*) from public.payments where needs_review) end
  ) into v;
  return v;
end $$;

create function public.report_bookings(p_from date, p_to date)
returns table (ref text, status text, scheduled_start timestamptz, service text, customer_id uuid, worker_id uuid,
               currency text, total_minor bigint, commission_minor bigint, worker_earning_minor bigint)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_permission('reports.export');
  perform private.require_permission('finance.read');
  perform private.audit('report.export', 'report', 'bookings', jsonb_build_object('from', p_from, 'to', p_to));
  return query select b.ref, b.status::text, b.scheduled_start, s.name, b.customer_id, b.worker_id, b.currency::text,
                      b.total_minor, b.commission_minor, b.worker_earning_minor
               from public.bookings b join public.services s on s.id = b.service_id
               where b.scheduled_start >= p_from and b.scheduled_start < p_to + 1 and b.status <> 'pending_payment'
               order by b.scheduled_start;
end $$;

-- ---------------------------------------------------------------------------
-- Safe views (owned by the migration role, filtered by the caller's identity)
-- ---------------------------------------------------------------------------
create view public.worker_public_profiles as
  select w.id, split_part(p.full_name, ' ', 1) || ' ' || left(split_part(p.full_name, ' ', 2), 1) as display_name,
         p.avatar_path, w.bio, w.years_experience, w.rating_avg, w.rating_count
  from public.worker_profiles w join public.profiles p on p.id = w.id
  where public.is_worker_bookable(w.id);

create view public.booking_worker_info as
  select b.id as booking_id, w.id as worker_id,
         split_part(p.full_name, ' ', 1) || ' ' || left(split_part(p.full_name, ' ', 2), 1) as display_name,
         p.avatar_path, w.rating_avg, w.rating_count
  from public.bookings b
  join public.worker_profiles w on w.id = b.worker_id
  join public.profiles p on p.id = w.id
  where b.customer_id = auth.uid() and b.status <> 'pending_payment';

-- Workers see job details; precise address & phone only once they are on their way.
create view public.worker_jobs as
  select b.id, b.ref, b.status, b.service_id, b.scheduled_start, b.scheduled_end, b.duration_minutes, b.extra_minutes,
         b.timezone, b.description, b.currency, b.worker_earning_minor, b.commission_minor, b.commission_rate_bps,
         b.accept_by, b.area_id,
         split_part(cp.full_name, ' ', 1) as customer_first_name,
         case when b.status in ('en_route', 'arrived', 'in_progress', 'awaiting_confirmation') then b.address_snapshot
              else jsonb_build_object('area_id', b.area_id) end as address,
         case when b.status in ('en_route', 'arrived', 'in_progress', 'awaiting_confirmation') then cp.phone end as customer_phone
  from public.bookings b join public.profiles cp on cp.id = b.customer_id
  where b.worker_id = auth.uid() and b.status <> 'pending_payment';

create view public.worker_earnings_detail as
  select e.id, e.kind, e.status, e.amount_minor, e.currency, e.eligible_at, e.created_at, e.booking_id,
         b.ref as booking_ref, case when e.kind = 'job' then b.commission_minor end as commission_minor,
         e.payout_item_id, pi.status as payout_status, pi.paid_at
  from public.worker_earnings e
  left join public.bookings b on b.id = e.booking_id
  left join public.payout_items pi on pi.id = e.payout_item_id
  where e.worker_id = auth.uid();

create view public.public_settings as
  select key, value from public.application_settings where is_public;

-- ---------------------------------------------------------------------------
-- Notification templates (English; Arabic rows can be added by admins)
-- ---------------------------------------------------------------------------
insert into public.notification_templates (key, locale, title, body) values
  ('booking.confirmed', 'en', 'Booking confirmed', 'Your booking {{ref}} is confirmed and we are notifying your professional.'),
  ('booking.assigned', 'en', 'New job assigned', 'You have a new job {{ref}}. Please accept it soon.'),
  ('booking.accepted', 'en', 'Professional confirmed', 'Your professional accepted booking {{ref}}.'),
  ('booking.en_route', 'en', 'On the way', 'Your professional is on the way for {{ref}}.'),
  ('booking.arrived', 'en', 'Professional arrived', 'Your professional has arrived for {{ref}}.'),
  ('booking.awaiting_confirmation', 'en', 'Please confirm completion', 'The work on {{ref}} is finished. Confirm completion or report a problem.'),
  ('booking.completed', 'en', 'Job completed', 'Booking {{ref}} is complete. How did it go? Leave a review.'),
  ('booking.completed_worker', 'en', 'Job completed', 'Booking {{ref}} is marked complete.'),
  ('booking.cancelled', 'en', 'Booking cancelled', 'Booking {{ref}} was cancelled.'),
  ('booking.unassigned', 'en', 'Finding a new professional', 'We are assigning a new professional to {{ref}}. No action needed.'),
  ('booking.rescheduled', 'en', 'Booking rescheduled', 'The customer rescheduled {{ref}}. Please confirm the new time.'),
  ('booking.reassigned_away', 'en', 'Job reassigned', 'Booking {{ref}} was reassigned by the operations team.'),
  ('booking.worker_changed', 'en', 'Professional updated', 'A new professional has been assigned to {{ref}}.'),
  ('booking.message', 'en', 'New message', 'You have a new message about {{ref}}.'),
  ('reminder.24h', 'en', 'Appointment tomorrow', 'Reminder: booking {{ref}} is within 24 hours.'),
  ('reminder.1h', 'en', 'Appointment soon', 'Reminder: booking {{ref}} starts within the hour.'),
  ('extra_time.requested', 'en', 'Extra time requested', 'Your professional asks for {{minutes}} more minutes on {{ref}}. Review and decide.'),
  ('extra_time.approved_pending_payment', 'en', 'Customer approved extra time', 'Waiting for the customer to complete payment for {{ref}}.'),
  ('extra_time.approved', 'en', 'Extra time confirmed', 'Extra time on {{ref}} is approved and paid. You may continue.'),
  ('extra_time.rejected', 'en', 'Extra time declined', 'The customer declined extra time on {{ref}}. Please finish within the booked time.'),
  ('payment.succeeded', 'en', 'Payment received', 'Payment for {{ref}} was received.'),
  ('payment.failed', 'en', 'Payment failed', 'Your payment for {{ref}} did not go through. You can try again.'),
  ('payment.refunded_late', 'en', 'Payment refunded', 'A payment for {{ref}} arrived after it could be applied and is being refunded.'),
  ('refund.approved', 'en', 'Refund approved', 'A refund for {{ref}} was approved and is being processed.'),
  ('refund.rejected', 'en', 'Refund declined', 'Your refund request for {{ref}} was declined.'),
  ('refund.succeeded', 'en', 'Refund issued', 'Your refund for {{ref}} has been issued.'),
  ('payout.paid', 'en', 'Payout sent', 'A payout of AED {{amount}} was sent.'),
  ('payout.failed', 'en', 'Payout failed', 'A payout could not be completed. Support will contact you.'),
  ('dispute.resolved', 'en', 'Dispute resolved', 'The dispute on {{ref}} has been resolved.'),
  ('review.received', 'en', 'New review', 'You received a {{rating}}-star review.'),
  ('worker.submitted', 'en', 'Application received', 'Your application is with our verification team.'),
  ('worker.under_review', 'en', 'Application under review', 'Our team is reviewing your application.'),
  ('worker.approved', 'en', 'You are approved', 'Your account is verified. You can now receive bookings.'),
  ('worker.rejected', 'en', 'Application not approved', 'Your application was not approved. {{reason}}'),
  ('worker.suspended', 'en', 'Account suspended', 'Your account has been suspended. {{reason}}'),
  ('worker.expired_credentials', 'en', 'Credential expired', 'A required credential expired. Upload a renewed document to receive bookings again.'),
  ('worker.reinstated', 'en', 'Account restored', 'Your credentials are valid again and your account is active.'),
  ('staff.booking_unassigned', 'en', 'Booking needs a worker', 'Booking {{ref}} has no worker assigned.'),
  ('staff.dispute_opened', 'en', 'Dispute opened', 'A dispute was opened on {{ref}}.'),
  ('staff.refund_requested', 'en', 'Refund requested', 'A refund was requested on {{ref}}.'),
  ('staff.worker_submitted', 'en', 'Worker application', 'A worker application awaits review.'),
  ('staff.extra_time_escalated', 'en', 'Extra time escalated', 'Extra time on {{ref}} was escalated by the worker.'),
  ('staff.deletion_requested', 'en', 'Account deletion requested', 'A user requested account deletion.');
