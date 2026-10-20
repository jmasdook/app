-- Booking state machine, job lifecycle, cancellation, rescheduling, extra time,
-- messaging, reviews, disputes. Every status change is validated and recorded here.

create function private.audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  select string_agg(role::text, ',' order by role) into v_role from public.user_roles where user_id = auth.uid();
  insert into public.admin_audit_logs (actor_id, actor_role, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(v_role, case when public.is_system() then 'system' end), p_action, p_entity, p_entity_id, p_details);
end $$;

-- ---------------------------------------------------------------------------
-- Core transition (internal). Callers pass an already-authenticated actor.
-- ---------------------------------------------------------------------------
create function private.transition_booking(
  p_booking_id uuid, p_to public.booking_status, p_actor_role text, p_actor_id uuid,
  p_reason text default null, p_refund_bps int default null)
returns public.bookings
language plpgsql security definer set search_path = public, private as $$
declare
  b public.bookings%rowtype; t public.booking_status_transitions%rowtype;
  v_from public.booking_status; v_vars jsonb;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then perform private.err('booking_not_found'); end if;
  v_from := b.status;
  select * into t from public.booking_status_transitions where from_status = b.status and to_status = p_to;
  if not found or not (p_actor_role = any (t.actors)) then
    perform private.err('invalid_transition', format('%s -> %s by %s', b.status, p_to, p_actor_role));
  end if;

  perform set_config('app.booking_transition', 'on', true);
  update public.bookings set
    status = p_to,
    accepted_at = case when p_to = 'accepted' then now() else accepted_at end,
    en_route_at = case when p_to = 'en_route' then now() else en_route_at end,
    arrived_at = case when p_to = 'arrived' then now() else arrived_at end,
    started_at = case when p_to = 'in_progress' then now() else started_at end,
    work_done_at = case when p_to = 'awaiting_confirmation' then now() else work_done_at end,
    completed_at = case when p_to = 'completed' then now() else completed_at end,
    cancelled_at = case when p_to = 'cancelled' then now() else cancelled_at end,
    cancelled_by = case when p_to = 'cancelled' then p_actor_id else cancelled_by end,
    cancelled_role = case when p_to = 'cancelled' then p_actor_role else cancelled_role end,
    cancellation_reason = case when p_to = 'cancelled' then p_reason else cancellation_reason end,
    worker_id = case when p_to = 'unassigned' then null else worker_id end
  where id = b.id returning * into b;
  perform set_config('app.booking_transition', 'off', true);

  insert into public.booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, reason)
  values (b.id, v_from, p_to, p_actor_id, p_actor_role, p_reason);

  v_vars := jsonb_build_object('ref', b.ref);

  if p_to = 'accepted' then
    update public.booking_assignments set response = 'accepted' where booking_id = b.id and ended_at is null;
    perform private.notify(b.customer_id, 'booking.accepted', v_vars, jsonb_build_object('booking_id', b.id));
  elsif p_to in ('en_route', 'arrived', 'awaiting_confirmation') then
    perform private.notify(b.customer_id, 'booking.' || p_to, v_vars, jsonb_build_object('booking_id', b.id));
  elsif p_to = 'unassigned' then
    update public.booking_assignments
       set ended_at = now(),
           response = case when p_actor_role = 'system' then 'timed_out'
                           when p_actor_role = 'worker' then (case when v_from = 'assigned' then 'rejected' else 'withdrawn' end)
                           else 'reassigned' end,
           note = p_reason
     where booking_id = b.id and ended_at is null;
    update public.worker_earnings set status = 'held', note = 'booking unassigned'
     where booking_id = b.id and status in ('pending', 'eligible');
    perform private.notify(b.customer_id, 'booking.unassigned', v_vars, jsonb_build_object('booking_id', b.id));
    perform private.notify_staff('bookings.manage', 'staff.booking_unassigned', v_vars, jsonb_build_object('booking_id', b.id));
  elsif p_to = 'completed' then
    perform private.notify(b.customer_id, 'booking.completed', v_vars, jsonb_build_object('booking_id', b.id));
    if b.worker_id is not null then
      perform private.notify(b.worker_id, 'booking.completed_worker', v_vars, jsonb_build_object('booking_id', b.id));
    end if;
  elsif p_to = 'disputed' then
    update public.worker_earnings set status = 'held', note = 'dispute open'
     where booking_id = b.id and status in ('pending', 'eligible');
  elsif p_to = 'cancelled' then
    update public.booking_assignments set ended_at = now(), response = 'withdrawn', note = p_reason
     where booking_id = b.id and ended_at is null;
    update public.promotion_redemptions set released_at = now() where booking_id = b.id and released_at is null;
    if v_from = 'pending_payment' then
      update public.payments set status = 'cancelled'
       where booking_id = b.id and status in ('pending', 'requires_action');
    else
      perform private.create_cancellation_refund(b, p_actor_role, p_actor_id, p_refund_bps, p_reason);
    end if;
    perform private.notify(b.customer_id, 'booking.cancelled', v_vars, jsonb_build_object('booking_id', b.id));
    if b.worker_id is not null then
      perform private.notify(b.worker_id, 'booking.cancelled', v_vars, jsonb_build_object('booking_id', b.id));
    end if;
  end if;
  return b;
end $$;

-- ---------------------------------------------------------------------------
-- Public lifecycle RPCs (actor derived from the authenticated identity)
-- ---------------------------------------------------------------------------
create function public.worker_update_job_status(p_booking_id uuid, p_to public.booking_status, p_reason text default null)
returns public.bookings language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.worker_id is distinct from auth.uid() then perform private.err('booking_not_found'); end if;
  if p_to not in ('accepted', 'en_route', 'arrived', 'in_progress', 'awaiting_confirmation', 'unassigned') then
    perform private.err('invalid_transition', 'worker may not set ' || p_to);
  end if;
  if p_to = 'accepted' and not public.is_worker_bookable(auth.uid()) then
    perform private.err('worker_not_verified');
  end if;
  return private.transition_booking(p_booking_id, p_to, 'worker', auth.uid(), p_reason);
end $$;

create function public.confirm_completion(p_booking_id uuid) returns public.bookings
language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.customer_id <> auth.uid() then perform private.err('booking_not_found'); end if;
  return private.transition_booking(p_booking_id, 'completed', 'customer', auth.uid(), 'customer confirmed');
end $$;

create function public.cancel_booking(p_booking_id uuid, p_reason text default null) returns public.bookings
language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; v_bps int;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.customer_id <> auth.uid() then perform private.err('booking_not_found'); end if;
  v_bps := public.refund_bps_for_cancellation(b.cancellation_policy, b.scheduled_start);
  return private.transition_booking(p_booking_id, 'cancelled', 'customer', auth.uid(), p_reason, v_bps);
end $$;

create function public.open_dispute(p_booking_id uuid, p_reason text) returns public.disputes
language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; v_role text; d public.disputes; v_prior public.booking_status;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found then perform private.err('booking_not_found'); end if;
  v_role := case when b.customer_id = auth.uid() then 'customer' when b.worker_id = auth.uid() then 'worker'
                 when public.has_permission('disputes.manage') then 'admin' end;
  if v_role is null then perform private.err('booking_not_found'); end if;
  if b.status = 'completed' and v_role = 'customer'
     and b.completed_at < now() - make_interval(hours => public.app_setting_int('booking.dispute_window_hours', 72)) then
    perform private.err('dispute_window_closed');
  end if;
  v_prior := b.status;
  perform private.transition_booking(p_booking_id, 'disputed', v_role, auth.uid(), left(p_reason, 500));
  insert into public.disputes (booking_id, raised_by, raised_role, reason, prior_status)
  values (p_booking_id, auth.uid(), v_role, p_reason, v_prior) returning * into d;
  perform private.notify_staff('disputes.manage', 'staff.dispute_opened', jsonb_build_object('ref', b.ref),
                               jsonb_build_object('booking_id', b.id, 'dispute_id', d.id));
  return d;
end $$;

-- Customer reschedules (same worker, validated against live availability).
create function public.reschedule_booking(p_booking_id uuid, p_new_start timestamptz) returns public.bookings
language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; s public.services%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> auth.uid() then perform private.err('booking_not_found'); end if;
  if b.status not in ('assigned', 'accepted') then perform private.err('cannot_reschedule'); end if;
  if b.reschedule_count >= 2 then perform private.err('reschedule_limit_reached'); end if;
  if b.scheduled_start < now() + interval '4 hours' then perform private.err('too_close_to_start'); end if;
  select * into s from public.services where id = b.service_id;
  perform 1 from public.worker_profiles where id = b.worker_id for update;
  -- The booking itself holds the old slot; exclude it by checking against a temporary shift.
  if not exists (
       select 1 from public.available_slots(b.service_id, b.area_id, (p_new_start at time zone b.timezone)::date,
                                            b.duration_minutes, b.worker_id) a
       where a.slot_start = p_new_start) then
    perform private.err('slot_unavailable');
  end if;
  begin
    update public.bookings set scheduled_start = p_new_start,
           scheduled_end = p_new_start + make_interval(mins => b.duration_minutes),
           reschedule_count = reschedule_count + 1
     where id = b.id returning * into b;
  exception when exclusion_violation then perform private.err('slot_unavailable');
  end;
  if b.status = 'accepted' then   -- worker must re-confirm the new time
    perform set_config('app.booking_transition', 'on', true);
    update public.bookings set status = 'assigned', accepted_at = null,
           accept_by = now() + make_interval(mins => public.app_setting_int('booking.worker_accept_minutes', 60))
     where id = b.id returning * into b;
    perform set_config('app.booking_transition', 'off', true);
    update public.booking_assignments set response = 'pending' where booking_id = b.id and ended_at is null;
  end if;
  insert into public.booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, reason)
  values (b.id, b.status, b.status, auth.uid(), 'customer', 'rescheduled to ' || p_new_start::text);
  perform private.notify(b.worker_id, 'booking.rescheduled', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  return b;
end $$;

-- ---------------------------------------------------------------------------
-- Messaging between customer and assigned worker (only while a job is live)
-- ---------------------------------------------------------------------------
create function public.send_booking_message(p_booking_id uuid, p_body text) returns public.booking_messages
language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; m public.booking_messages; v_to uuid;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or auth.uid() not in (b.customer_id, coalesce(b.worker_id, b.customer_id)) then
    perform private.err('booking_not_found');
  end if;
  if b.worker_id is null
     or b.status not in ('assigned', 'accepted', 'en_route', 'arrived', 'in_progress', 'awaiting_confirmation')
        and not (b.status = 'completed' and b.completed_at > now() - interval '7 days') then
    perform private.err('messaging_closed');
  end if;
  insert into public.booking_messages (booking_id, sender_id, body) values (p_booking_id, auth.uid(), trim(p_body))
  returning * into m;
  v_to := case when auth.uid() = b.customer_id then b.worker_id else b.customer_id end;
  perform private.notify(v_to, 'booking.message', jsonb_build_object('ref', b.ref), jsonb_build_object('booking_id', b.id));
  return m;
end $$;

create function public.add_booking_attachment(p_booking_id uuid, p_path text, p_kind text)
returns public.booking_attachments language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; a public.booking_attachments;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or auth.uid() not in (b.customer_id, coalesce(b.worker_id, b.customer_id)) then
    perform private.err('booking_not_found');
  end if;
  if split_part(p_path, '/', 1) <> auth.uid()::text then perform private.err('invalid_attachment_path'); end if;
  if p_kind = 'issue_photo' and auth.uid() <> b.customer_id then perform private.err('forbidden'); end if;
  if p_kind in ('completion_evidence', 'extra_time_evidence') and auth.uid() is distinct from b.worker_id then
    perform private.err('forbidden');
  end if;
  insert into public.booking_attachments (booking_id, uploaded_by, storage_path, kind)
  values (p_booking_id, auth.uid(), p_path, p_kind) returning * into a;
  return a;
end $$;

-- ---------------------------------------------------------------------------
-- Extra time
-- ---------------------------------------------------------------------------
create function public.request_extra_time(p_booking_id uuid, p_minutes int, p_reason text,
                                          p_evidence text[] default '{}')
returns public.extra_time_requests language plpgsql security definer set search_path = public, private as $$
declare
  b public.bookings%rowtype; s public.services%rowtype; r public.extra_time_requests;
  v_net bigint; v_tax bigint; v_comm bigint; v_path text;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.worker_id is distinct from auth.uid() then perform private.err('booking_not_found'); end if;
  if b.status <> 'in_progress' then perform private.err('job_not_in_progress'); end if;
  if p_minutes <= 0 or p_minutes % 15 <> 0 then perform private.err('invalid_extension'); end if;
  select * into s from public.services where id = b.service_id;
  if b.extra_minutes + p_minutes > s.max_extension_minutes then perform private.err('extension_limit_exceeded'); end if;
  if b.extra_hour_rate_minor <= 0 then perform private.err('extra_time_not_chargeable'); end if;
  if exists (select 1 from public.extra_time_requests where booking_id = b.id and status in ('pending', 'awaiting_payment')) then
    perform private.err('extra_time_request_already_open');
  end if;
  -- The extension must not collide with the worker's next job.
  if exists (select 1 from public.bookings o
             where o.worker_id = b.worker_id and o.id <> b.id
               and o.status in ('pending_payment','assigned','accepted','en_route','arrived','in_progress','awaiting_confirmation')
               and o.blocked_during && tstzrange(b.scheduled_end, b.scheduled_end + make_interval(mins => p_minutes), '[)')) then
    perform private.err('extension_conflicts_with_next_booking');
  end if;
  foreach v_path in array coalesce(p_evidence, '{}') loop
    if split_part(v_path, '/', 1) <> auth.uid()::text then perform private.err('invalid_attachment_path'); end if;
  end loop;

  v_net := public.round_div(b.extra_hour_rate_minor::numeric * p_minutes, 60);
  v_tax := public.round_div(v_net::numeric * b.tax_rate_bps, 10000);
  v_comm := public.round_div(v_net::numeric * b.commission_rate_bps, 10000);
  insert into public.extra_time_requests (
    booking_id, worker_id, requested_minutes, reason, evidence_paths, currency, rate_minor, net_minor,
    tax_rate_bps, tax_minor, total_minor, commission_rate_bps, commission_minor, worker_earning_minor, expires_at)
  values (b.id, auth.uid(), p_minutes, trim(p_reason), coalesce(p_evidence, '{}'), b.currency, b.extra_hour_rate_minor, v_net,
          b.tax_rate_bps, v_tax, v_net + v_tax, b.commission_rate_bps, v_comm, v_net - v_comm,
          now() + make_interval(mins => public.app_setting_int('extra_time.response_minutes', 15)))
  returning * into r;
  perform private.notify(b.customer_id, 'extra_time.requested',
    jsonb_build_object('ref', b.ref, 'minutes', p_minutes),
    jsonb_build_object('booking_id', b.id, 'extra_time_request_id', r.id));
  return r;
end $$;

-- The customer's explicit decision. Approval authorises a *payment step*; it never charges by itself.
create function public.decide_extra_time(p_request_id uuid, p_approve boolean, p_note text default null)
returns public.extra_time_requests language plpgsql security definer set search_path = public, private as $$
declare r public.extra_time_requests%rowtype; b public.bookings%rowtype;
begin
  select * into r from public.extra_time_requests where id = p_request_id for update;
  if not found then perform private.err('request_not_found'); end if;
  select * into b from public.bookings where id = r.booking_id;
  if b.customer_id <> auth.uid() then perform private.err('request_not_found'); end if;
  if r.status <> 'pending' then perform private.err('request_not_pending'); end if;
  if r.expires_at <= now() then
    update public.extra_time_requests set status = 'expired' where id = r.id returning * into r;
    return r;   -- an error would roll the expiry back; callers must check status
  end if;
  if b.status <> 'in_progress' then perform private.err('job_not_in_progress'); end if;
  if p_approve then
    update public.extra_time_requests
       set status = 'awaiting_payment', decided_by = auth.uid(), decided_at = now(), decision_note = p_note,
           payment_expires_at = now() + make_interval(mins => public.app_setting_int('booking.payment_window_minutes', 15))
     where id = r.id returning * into r;
    perform private.notify(r.worker_id, 'extra_time.approved_pending_payment', jsonb_build_object('ref', b.ref),
                           jsonb_build_object('booking_id', b.id, 'extra_time_request_id', r.id));
  else
    update public.extra_time_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
     where id = r.id returning * into r;
    perform private.notify(r.worker_id, 'extra_time.rejected', jsonb_build_object('ref', b.ref),
                           jsonb_build_object('booking_id', b.id, 'extra_time_request_id', r.id));
  end if;
  return r;
end $$;

create function public.cancel_extra_time_request(p_request_id uuid) returns public.extra_time_requests
language plpgsql security definer set search_path = public, private as $$
declare r public.extra_time_requests;
begin
  update public.extra_time_requests set status = 'cancelled', decided_at = now()
   where id = p_request_id and worker_id = auth.uid() and status = 'pending' returning * into r;
  if not found then perform private.err('request_not_found'); end if;
  update public.payments set status = 'cancelled'
   where extra_time_request_id = r.id and status in ('pending', 'requires_action');
  return r;
end $$;

-- Customer unreachable / unresponsive: the request expires and no charge can ever be made.
-- The worker may escalate; an admin investigates but can never authorise charges for the customer.
create function public.escalate_extra_time(p_request_id uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare r public.extra_time_requests%rowtype; b public.bookings%rowtype; v_ticket uuid;
begin
  select * into r from public.extra_time_requests where id = p_request_id for update;
  if not found or r.worker_id <> auth.uid() then perform private.err('request_not_found'); end if;
  if r.status not in ('expired', 'rejected') then perform private.err('request_not_escalatable'); end if;
  select * into b from public.bookings where id = r.booking_id;
  update public.extra_time_requests set status = 'escalated' where id = r.id;
  insert into public.support_tickets (user_id, booking_id, category, subject, priority)
  values (auth.uid(), b.id, 'booking', 'Extra time unresolved for ' || b.ref, 'high') returning id into v_ticket;
  insert into public.support_messages (ticket_id, sender_id, body)
  values (v_ticket, auth.uid(), format('Extra time request (%s min) was %s. %s', r.requested_minutes, r.status, coalesce(p_note, '')));
  perform private.notify_staff('support.manage', 'staff.extra_time_escalated', jsonb_build_object('ref', b.ref),
                               jsonb_build_object('booking_id', b.id, 'ticket_id', v_ticket));
  return v_ticket;
end $$;

-- ---------------------------------------------------------------------------
-- Reviews
-- ---------------------------------------------------------------------------
create function public.submit_review(p_booking_id uuid, p_rating int, p_comment text default '')
returns public.reviews language plpgsql security definer set search_path = public, private as $$
declare b public.bookings%rowtype; rv public.reviews;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.customer_id <> auth.uid() then perform private.err('booking_not_found'); end if;
  if b.status <> 'completed' or b.worker_id is null then perform private.err('review_not_allowed'); end if;
  insert into public.reviews (booking_id, customer_id, worker_id, rating, comment)
  values (b.id, auth.uid(), b.worker_id, p_rating, left(coalesce(p_comment, ''), 1000)) returning * into rv;
  perform private.refresh_worker_rating(b.worker_id);
  perform private.notify(b.worker_id, 'review.received', jsonb_build_object('rating', p_rating), jsonb_build_object('booking_id', b.id));
  return rv;
end $$;

create function private.refresh_worker_rating(p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.internal_write', 'on', true);
  update public.worker_profiles w
     set rating_avg = coalesce((select round(avg(rating)::numeric, 2) from public.reviews
                                where worker_id = p_worker and status = 'published'), 0),
         rating_count = (select count(*) from public.reviews where worker_id = p_worker and status = 'published')
   where w.id = p_worker;
  perform set_config('app.internal_write', 'off', true);
end $$;
