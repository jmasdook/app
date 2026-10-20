-- Row Level Security, explicit grants, storage policies, audit triggers.
-- Default-deny: every exposed table gets RLS and only the privileges listed below.
-- NEW TABLES/FUNCTIONS in later migrations must add their own RLS + grants (CI test enforces RLS).

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

do $$ declare t record; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Access helpers used by policies (SECURITY DEFINER so they do not recurse through RLS)
-- ---------------------------------------------------------------------------
create function public.can_access_booking(p_booking_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.id = p_booking_id
                 and (b.customer_id = auth.uid() or (b.worker_id = auth.uid() and b.status <> 'pending_payment')))
      or public.has_permission('bookings.read')
$$;

create function public.can_access_ticket(p_ticket_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.support_tickets t where t.id = p_ticket_id and t.user_id = auth.uid())
      or public.has_permission('support.manage')
$$;

create function public.owns_booking(p_booking_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.id = p_booking_id and b.customer_id = auth.uid())
$$;

create function public.is_booking_participant(p_booking_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.id = p_booking_id
                 and (b.customer_id = auth.uid() or (b.worker_id = auth.uid() and b.status <> 'pending_payment')))
$$;

grant execute on function public.has_role(public.app_role), public.has_permission(text), public.is_staff(),
  public.is_system(), public.can_access_booking(uuid), public.is_booking_participant(uuid), public.can_access_ticket(uuid), public.owns_booking(uuid),
  public.app_setting(text)
  to anon, authenticated;
-- app_setting returns raw values: restrict to what policies need, expose only via public_settings view.
revoke execute on function public.app_setting(text) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Audit triggers for configuration & privileged tables
-- ---------------------------------------------------------------------------
create function private.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not (public.is_system() or public.is_staff()) then return coalesce(new, old); end if;
  v_id := coalesce((to_jsonb(coalesce(new, old)) ->> 'id'), (to_jsonb(coalesce(new, old)) ->> 'key'));
  insert into public.admin_audit_logs (actor_id, actor_role, action, entity_type, entity_id, details)
  values (auth.uid(), (select string_agg(role::text, ',') from public.user_roles where user_id = auth.uid()),
          lower(tg_op), tg_table_name, v_id,
          jsonb_build_object('old', case when tg_op <> 'INSERT' then to_jsonb(old) end,
                             'new', case when tg_op <> 'DELETE' then to_jsonb(new) end));
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['services', 'service_categories', 'service_areas', 'service_pricing_rules', 'promotions',
                           'application_settings', 'user_roles', 'notification_templates', 'public_holidays', 'worker_skills'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.audit_row()',
                   t || '_audit', t);
  end loop;
end $$;

create function private.reviews_refresh_rating() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.refresh_worker_rating(coalesce(new.worker_id, old.worker_id));
  return null;
end $$;
create trigger reviews_rating after update of status on public.reviews
  for each row execute function private.reviews_refresh_rating();

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
-- profiles
grant select on public.profiles to authenticated;
grant update (full_name, phone, avatar_path, locale, marketing_opt_in) on public.profiles to authenticated;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.has_permission('customers.read'));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- roles & permissions (read-only to clients)
grant select on public.user_roles, public.role_permissions, public.booking_status_transitions to authenticated;
create policy user_roles_select on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or public.has_permission('roles.manage'));
create policy role_permissions_select on public.role_permissions for select to authenticated using (public.is_staff());
create policy transitions_select on public.booking_status_transitions for select to authenticated using (public.is_staff());

-- settings
grant select, insert, update on public.application_settings to authenticated;
create policy settings_select on public.application_settings for select to authenticated using (public.has_permission('settings.manage'));
create policy settings_insert on public.application_settings for insert to authenticated
  with check (public.has_permission('settings.manage') and key <> 'payments.live_enabled');
create policy settings_update on public.application_settings for update to authenticated
  using (public.has_permission('settings.manage'))
  with check (public.has_permission('settings.manage') and (key <> 'payments.live_enabled' or public.has_role('super_admin')));

-- catalog (publicly browsable when active)
grant select on public.service_areas, public.service_categories, public.services, public.public_holidays to anon, authenticated;
grant insert, update, delete on public.service_areas, public.service_categories, public.services, public.public_holidays to authenticated;
create policy areas_select on public.service_areas for select to anon, authenticated using (active or public.has_permission('catalog.manage'));
create policy areas_write on public.service_areas for all to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('catalog.manage'));
create policy categories_select on public.service_categories for select to anon, authenticated using (active or public.has_permission('catalog.manage'));
create policy categories_write on public.service_categories for all to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('catalog.manage'));
create policy services_select on public.services for select to anon, authenticated using (active or public.has_permission('catalog.manage'));
create policy services_write on public.services for all to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('catalog.manage'));
create policy holidays_select on public.public_holidays for select to anon, authenticated using (true);
create policy holidays_write on public.public_holidays for all to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('catalog.manage'));

grant select, insert, update, delete on public.service_pricing_rules to authenticated;
create policy pricing_rules_all on public.service_pricing_rules for all to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('pricing.manage'));
grant select on public.commission_policies to authenticated;
create policy commission_select on public.commission_policies for select to authenticated
  using (public.has_permission('pricing.manage') or public.has_permission('finance.read'));
grant select, insert, update, delete on public.promotions to authenticated;
create policy promotions_all on public.promotions for all to authenticated
  using (public.has_permission('promotions.manage')) with check (public.has_permission('promotions.manage'));
grant select on public.promotion_redemptions to authenticated;
create policy redemptions_select on public.promotion_redemptions for select to authenticated using (public.has_permission('promotions.manage'));

-- addresses
grant select, insert, update, delete on public.customer_addresses to authenticated;
create policy addresses_own on public.customer_addresses for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy addresses_staff on public.customer_addresses for select to authenticated using (public.has_permission('customers.read'));

-- worker profile & credentials
grant select on public.worker_profiles to authenticated;
grant update (bio, years_experience, service_radius_km, base_latitude, base_longitude, is_available) on public.worker_profiles to authenticated;
create policy worker_profiles_select on public.worker_profiles for select to authenticated
  using (id = (select auth.uid()) or public.has_permission('workers.read'));
create policy worker_profiles_update_own on public.worker_profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

grant select, delete on public.worker_documents to authenticated;
grant insert (worker_id, doc_type, title, storage_path, expires_on) on public.worker_documents to authenticated;
create policy worker_documents_select on public.worker_documents for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.documents.read'));
create policy worker_documents_insert on public.worker_documents for insert to authenticated
  with check (worker_id = (select auth.uid()) and exists (select 1 from public.worker_profiles where id = worker_id and status in ('draft', 'rejected', 'expired_credentials')));
create policy worker_documents_delete on public.worker_documents for delete to authenticated
  using (worker_id = (select auth.uid()) and status = 'pending');

grant select, insert, delete on public.worker_skills to authenticated;
grant update (approved, years_experience) on public.worker_skills to authenticated;
create policy worker_skills_select on public.worker_skills for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.read'));
create policy worker_skills_insert on public.worker_skills for insert to authenticated
  with check (worker_id = (select auth.uid()) and exists (select 1 from public.worker_profiles where id = worker_id));
create policy worker_skills_update on public.worker_skills for update to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.manage'));
create policy worker_skills_delete on public.worker_skills for delete to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.manage'));

grant select, insert, delete on public.worker_service_areas to authenticated;
create policy worker_areas_select on public.worker_service_areas for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.read'));
create policy worker_areas_insert on public.worker_service_areas for insert to authenticated
  with check (worker_id = (select auth.uid()) and exists (select 1 from public.worker_profiles where id = worker_id));
create policy worker_areas_delete on public.worker_service_areas for delete to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.manage'));

grant select, insert, update, delete on public.worker_availability, public.worker_time_off to authenticated;
create policy availability_select on public.worker_availability for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.read'));
create policy availability_write on public.worker_availability for all to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.manage'))
  with check (worker_id = (select auth.uid()) or public.has_permission('workers.manage'));
create policy time_off_select on public.worker_time_off for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.read'));
create policy time_off_write on public.worker_time_off for all to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('workers.manage'))
  with check (worker_id = (select auth.uid()) or public.has_permission('workers.manage'));

-- bookings (read-only for clients; every write goes through RPCs)
grant select on public.booking_slot_reservations, public.bookings, public.booking_status_history,
  public.booking_assignments, public.booking_attachments, public.booking_messages, public.extra_time_requests to authenticated;
create policy reservations_select on public.booking_slot_reservations for select to authenticated using (customer_id = (select auth.uid()));
create policy bookings_select on public.bookings for select to authenticated
  using (customer_id = (select auth.uid()) or public.has_permission('bookings.read'));
create policy history_select on public.booking_status_history for select to authenticated using (public.can_access_booking(booking_id));
create policy assignments_select on public.booking_assignments for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('bookings.read'));
create policy attachments_select on public.booking_attachments for select to authenticated using (public.can_access_booking(booking_id));
create policy messages_select on public.booking_messages for select to authenticated
  using (public.is_booking_participant(booking_id) or public.has_permission('support.manage'));
create policy extra_time_select on public.extra_time_requests for select to authenticated using (public.can_access_booking(booking_id));

-- money (customers see their own payments/refunds; staff need explicit finance permissions)
grant select on public.payments, public.refunds, public.payment_events, public.commissions, public.ledger_accounts,
  public.ledger_transactions, public.ledger_entries, public.worker_earnings, public.payout_batches,
  public.payout_items, public.reconciliation_runs to authenticated;
create policy payments_select on public.payments for select to authenticated
  using (public.owns_booking(booking_id) or public.has_permission('payments.read'));
create policy refunds_select on public.refunds for select to authenticated
  using (public.owns_booking(booking_id) or public.has_permission('payments.read'));
create policy payment_events_select on public.payment_events for select to authenticated using (public.has_permission('payments.read'));
create policy commissions_select on public.commissions for select to authenticated using (public.has_permission('finance.read'));
create policy ledger_accounts_select on public.ledger_accounts for select to authenticated using (public.has_permission('finance.read'));
create policy ledger_tx_select on public.ledger_transactions for select to authenticated using (public.has_permission('finance.read'));
create policy ledger_entries_select on public.ledger_entries for select to authenticated using (public.has_permission('finance.read'));
create policy earnings_select on public.worker_earnings for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('finance.read'));
create policy payout_batches_select on public.payout_batches for select to authenticated
  using (public.has_permission('finance.read') or public.has_permission('payouts.manage'));
create policy payout_items_select on public.payout_items for select to authenticated
  using (worker_id = (select auth.uid()) or public.has_permission('finance.read'));
create policy reconciliation_select on public.reconciliation_runs for select to authenticated using (public.has_permission('finance.read'));

-- reviews
grant select on public.reviews to anon, authenticated;
grant update (status, moderation_note) on public.reviews to authenticated;
create policy reviews_select on public.reviews for select to anon, authenticated
  using (status = 'published' or customer_id = (select auth.uid()) or public.has_permission('reviews.moderate'));
create policy reviews_moderate on public.reviews for update to authenticated
  using (public.has_permission('reviews.moderate')) with check (public.has_permission('reviews.moderate'));

-- notifications
grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy notifications_own on public.notifications for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert, update, delete on public.notification_templates to authenticated;
create policy templates_select on public.notification_templates for select to authenticated using (public.is_staff());
create policy templates_write on public.notification_templates for all to authenticated
  using (public.has_permission('notifications.manage')) with check (public.has_permission('notifications.manage'));
grant select, insert, update, delete on public.device_tokens to authenticated;
create policy device_tokens_own on public.device_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- support & disputes
grant select, insert on public.support_tickets, public.support_messages to authenticated;
grant update (status, priority, assigned_to) on public.support_tickets to authenticated;
create policy tickets_select on public.support_tickets for select to authenticated
  using (user_id = (select auth.uid()) or public.has_permission('support.manage'));
create policy tickets_insert on public.support_tickets for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'open' and assigned_to is null and priority = 'normal'
              and (booking_id is null or public.can_access_booking(booking_id)));
create policy tickets_update on public.support_tickets for update to authenticated
  using (public.has_permission('support.manage')) with check (public.has_permission('support.manage'));
create policy support_messages_select on public.support_messages for select to authenticated
  using (public.can_access_ticket(ticket_id) and (not is_internal or public.has_permission('support.manage')));
create policy support_messages_insert on public.support_messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and public.can_access_ticket(ticket_id)
              and (not is_internal or public.has_permission('support.manage')));
grant select on public.disputes to authenticated;
create policy disputes_select on public.disputes for select to authenticated
  using (public.is_booking_participant(booking_id) or public.has_permission('disputes.read'));

-- audit log
grant select on public.admin_audit_logs to authenticated;
create policy audit_select on public.admin_audit_logs for select to authenticated using (public.has_permission('audit.read'));

-- Views
grant select on public.worker_public_profiles, public.public_settings to anon, authenticated;
grant select on public.booking_worker_info, public.worker_jobs, public.worker_earnings_detail to authenticated;

-- ---------------------------------------------------------------------------
-- RPC allow-list (everything else stays service_role-only)
-- ---------------------------------------------------------------------------
grant execute on function
  public.calculate_pricing(uuid, timestamptz, int, text, uuid),
  public.refund_bps_for_cancellation(jsonb, timestamptz, timestamptz),
  public.available_slots(uuid, uuid, date, int, uuid),
  public.reserve_slot(uuid, uuid, timestamptz, int, uuid),
  public.release_reservation(uuid),
  public.create_booking(uuid, uuid, text, text, text, text[]),
  public.worker_update_job_status(uuid, public.booking_status, text),
  public.confirm_completion(uuid), public.cancel_booking(uuid, text), public.open_dispute(uuid, text),
  public.reschedule_booking(uuid, timestamptz),
  public.send_booking_message(uuid, text), public.add_booking_attachment(uuid, text, text),
  public.request_extra_time(uuid, int, text, text[]), public.decide_extra_time(uuid, boolean, text),
  public.cancel_extra_time_request(uuid), public.escalate_extra_time(uuid, text),
  public.submit_review(uuid, int, text),
  public.prepare_payment(uuid, uuid, text),
  public.request_refund(uuid, bigint, text), public.decide_refund(uuid, boolean, text),
  public.create_payout_batch(text), public.mark_payout_item(uuid, text, text, text),
  public.add_earning_adjustment(uuid, bigint, text, uuid), public.reconcile_finance(),
  public.become_worker(), public.submit_worker_application(),
  public.review_document(uuid, boolean, text), public.review_worker(uuid, text, text),
  public.admin_assign_worker(uuid, uuid, text), public.admin_cancel_booking(uuid, text, int),
  public.admin_set_booking_status(uuid, public.booking_status, text),
  public.resolve_dispute(uuid, text, bigint, text),
  public.admin_set_role(uuid, public.app_role, boolean), public.set_commission_rate(text, uuid, uuid, int, text),
  public.request_account_deletion(), public.process_account_deletion(uuid),
  public.admin_dashboard(), public.report_bookings(date, date)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: private buckets, path-prefix ownership
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('worker-documents', 'worker-documents', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png']),
  ('booking-media', 'booking-media', false, 8388608, array['image/jpeg', 'image/png', 'image/webp']),
  ('service-images', 'service-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy worker_docs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'worker-documents' and (storage.foldername(name))[1] = auth.uid()::text);
create policy worker_docs_select on storage.objects for select to authenticated
  using (bucket_id = 'worker-documents'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.has_permission('workers.documents.read')));
create policy worker_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'worker-documents' and (storage.foldername(name))[1] = auth.uid()::text);

create policy booking_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'booking-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy booking_media_select on storage.objects for select to authenticated
  using (bucket_id = 'booking-media' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.booking_attachments ba where ba.storage_path = name and public.can_access_booking(ba.booking_id))));

create policy service_images_write on storage.objects for all to authenticated
  using (bucket_id = 'service-images' and public.has_permission('catalog.manage'))
  with check (bucket_id = 'service-images' and public.has_permission('catalog.manage'));

-- Functions created in this migration must also be callable by the service role.
grant execute on all functions in schema public to service_role;
