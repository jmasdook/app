begin;
do $$
declare b1 uuid; b2 uuid; p1 uuid; v_n bigint;
begin
  b1 := tests.new_booking('c1', 'svc_elec', tests.slot(3, 10), 'w1');
  p1 := tests.pay_booking(b1);
  b2 := tests.new_booking('c2', 'svc_plumb', tests.slot(3, 14), 'w2');
  perform tests.pay_booking(b2);
  insert into public.worker_documents (worker_id, doc_type, storage_path, status) values (tests.id('w2'), 'other', tests.id('w2') || '/extra.pdf', 'pending');
  insert into public.support_tickets (user_id, subject) values (tests.id('c1'), 'Help with my booking');
  insert into public.support_messages (ticket_id, sender_id, body, is_internal)
    select id, tests.id('support'), 'internal note', true from public.support_tickets limit 1;

  -- anonymous
  perform tests.anon();
  perform tests.ok(tests.count('select 1 from public.service_categories') = 5, 'anon can browse active categories');
  perform tests.ok(tests.count('select 1 from public.services') = 4, 'anon can browse services');
  perform tests.throws('select * from public.bookings', 'permission denied', 'anon cannot read bookings');
  perform tests.throws('select * from public.profiles', 'permission denied', 'anon cannot read profiles');
  perform tests.throws('select public.reserve_slot(null,null,now())', 'permission denied', 'anon cannot call booking RPCs');
  perform tests.ok(tests.count('select 1 from public.public_settings') > 0, 'anon can read public settings view');
  perform tests.throws('select * from public.application_settings', 'permission denied', 'anon cannot read raw settings');

  -- customers see only their own data
  perform tests.login(tests.id('c1'));
  perform tests.eq(tests.count('select 1 from public.bookings'), 1::bigint, 'c1 sees own booking only');
  perform tests.eq(tests.count('select 1 from public.payments'), 1::bigint, 'c1 sees own payment only');
  perform tests.eq(tests.count('select 1 from public.customer_addresses'), 1::bigint, 'c1 sees own address only');
  perform tests.eq(tests.count('select 1 from public.profiles'), 1::bigint, 'c1 sees only own profile');
  perform tests.eq(tests.count('select 1 from public.support_messages where is_internal'), 0::bigint, 'customers cannot read internal notes');
  perform tests.eq(tests.count('select 1 from public.ledger_entries'), 0::bigint, 'customers cannot read the ledger');
  perform tests.eq(tests.count('select 1 from public.worker_earnings'), 0::bigint, 'customers cannot read earnings');
  perform tests.eq(tests.count('select 1 from public.worker_documents'), 0::bigint, 'customers cannot read worker documents');
  perform tests.eq(tests.count('select 1 from public.admin_audit_logs'), 0::bigint, 'customers cannot read audit logs');
  perform tests.eq(tests.count('select 1 from public.booking_worker_info'), 1::bigint, 'customer sees assigned worker info (limited view)');
  perform tests.eq((select display_name from public.booking_worker_info limit 1), 'W1 T', 'worker name abbreviated for customers');
end $$;

do $$
declare b1 uuid := (select id from public.bookings where customer_id = tests.id('c1') limit 1);
begin
  perform tests.login(tests.id('c1'));
  update public.profiles set full_name = 'Hacked' where id = tests.id('c2');
  perform tests.logout();
  perform tests.ok((select full_name from public.profiles where id = tests.id('c2')) <> 'Hacked', 'customer cannot edit another profile (0 rows)');
  perform tests.login(tests.id('c1'));
  perform tests.throws($t$update public.profiles set id = gen_random_uuid() where id = auth.uid()$t$, '42501', 'cannot modify protected profile columns');
  perform tests.throws($t$insert into public.user_roles (user_id, role) values (auth.uid(), 'super_admin')$t$, '42501', 'cannot grant self a role (no privilege)');
  perform tests.throws($t$select public.admin_set_role(auth.uid(), 'admin', true)$t$, '42501', 'privilege escalation via RPC refused');
  perform tests.throws($t$insert into public.service_categories (slug, name) values ('x', 'x')$t$, '42501', 'customer cannot create categories (RLS)');
end $$;

do $$
begin
  perform tests.login(tests.id('c1'));
  update public.services set base_price_minor = 1;
  perform tests.logout();
  perform tests.ok((select min(base_price_minor) from public.services) > 1, 'customer cannot reprice services');
  perform tests.login(tests.id('c1'));
  perform tests.throws($t$insert into public.reviews (booking_id, customer_id, worker_id, rating) select id, customer_id, worker_id, 5 from public.bookings limit 1$t$, 'permission denied', 'reviews only via RPC');
  perform tests.throws($t$select public.submit_review(gen_random_uuid(), 5)$t$, 'booking_not_found', 'cannot review unknown booking');

  -- workers
  perform tests.login(tests.id('w1'));
end $$;

do $$
declare b1 uuid := (select id from public.bookings where customer_id = tests.id('c1') limit 1);
begin
  perform tests.login(tests.id('w1'));
  perform tests.eq(tests.count('select 1 from public.bookings'), 0::bigint, 'workers have no direct access to the bookings table (financial fields)');
  perform tests.eq(tests.count('select 1 from public.worker_jobs'), 1::bigint, 'worker sees only own job in the job view');
  perform tests.eq((select customer_phone from public.worker_jobs limit 1), null, 'customer phone hidden before en route');
  perform tests.eq(tests.count('select 1 from public.worker_earnings'), 1::bigint, 'worker sees own earnings');
  perform tests.eq(tests.count('select 1 from public.payments'), 0::bigint, 'worker cannot see payments');
  perform tests.eq(tests.count('select 1 from public.worker_documents'), 2::bigint, 'worker sees only own documents');
  perform tests.eq(tests.count('select 1 from public.profiles'), 1::bigint, 'worker cannot read customer profiles directly');
end $$;

do $$
begin
  perform tests.login(tests.id('w1'));
  perform tests.throws($t$update public.worker_profiles set status = 'suspended', rating_avg = 5 where id = auth.uid()$t$, '42501', 'worker cannot change status/rating (column privileges)');
  perform tests.throws($t$insert into public.worker_earnings (worker_id, kind, amount_minor, currency) values (auth.uid(), 'manual_adjustment', 100000, 'AED')$t$, 'permission denied', 'worker cannot create earnings');
  perform tests.throws($t$insert into public.payments (booking_id, purpose, provider, amount_minor, currency, idempotency_key) select id, 'booking', 'x', 1, 'AED', 'zzzzzzzzzz' from public.worker_jobs$t$, 'permission denied', 'worker cannot write payments');
  perform tests.throws($t$select public.set_commission_rate('global', null, null, 0)$t$, '42501', 'worker cannot change commission');
  perform tests.throws($t$select public.review_worker(auth.uid(), 'approve')$t$, '42501', 'worker cannot approve self');
  perform tests.throws($t$update public.worker_documents set status = 'approved'$t$, 'permission denied', 'worker cannot approve own documents');
  perform tests.logout();
  update public.worker_skills set approved = false where worker_id = tests.id('w1');
  perform tests.login(tests.id('w1'));
  perform tests.throws($t$update public.worker_skills set approved = true$t$, 'only administrators', 'worker cannot approve own skills');
end $$;

do $$
begin
  -- support: tickets, bookings, customers — but not money or identity documents
  perform tests.login(tests.id('support'));
  perform tests.ok(tests.count('select 1 from public.bookings') >= 2, 'support can read bookings');
  perform tests.ok(tests.count('select 1 from public.profiles') >= 5, 'support can read customer profiles');
  perform tests.eq(tests.count('select 1 from public.payments'), 0::bigint, 'support cannot read payments');
  perform tests.eq(tests.count('select 1 from public.ledger_entries'), 0::bigint, 'support cannot read ledger');
  perform tests.eq(tests.count('select 1 from public.worker_earnings'), 0::bigint, 'support cannot read earnings');
  perform tests.eq(tests.count('select 1 from public.worker_documents'), 0::bigint, 'support cannot read identity documents');
  perform tests.eq(tests.count('select 1 from public.support_messages where is_internal'), 1::bigint, 'support sees internal notes');
  perform tests.eq(tests.count('select 1 from public.admin_audit_logs'), 0::bigint, 'support cannot read audit log');
  perform tests.throws($t$select public.review_worker(gen_random_uuid(), 'approve')$t$, '42501', 'support cannot approve workers');
  perform tests.throws($t$select public.create_payout_batch('support-batch')$t$, '42501', 'support cannot create payouts');
end $$;

do $$
declare d jsonb;
begin
  perform tests.login(tests.id('support'));
  d := public.admin_dashboard();
  perform tests.eq(d -> 'revenue_minor', 'null'::jsonb, 'dashboard hides revenue from support');
  perform tests.ok(d ->> 'open_tickets' is not null, 'dashboard shows operational counts to support');

  perform tests.login(tests.id('admin'));
  perform tests.ok(tests.count('select 1 from public.payments') >= 2, 'admin reads payments');
  perform tests.ok(tests.count('select 1 from public.worker_documents') >= 7, 'admin reads worker documents');
  perform tests.ok(tests.count('select 1 from public.ledger_entries') > 0, 'admin reads ledger');
  d := public.admin_dashboard();
  perform tests.ok((d ->> 'revenue_minor')::bigint > 0, 'admin dashboard includes revenue');
  perform tests.throws($t$select public.admin_set_role(gen_random_uuid(), 'admin', true)$t$, '42501', 'admin (not super admin) cannot manage roles');
end $$;

do $$
declare v_other uuid := tests.id('c3');
begin
  perform tests.login(tests.id('admin'));
  perform tests.throws($t$update public.application_settings set value = 'true' where key = 'payments.live_enabled'$t$, 'row-level security', 'admin cannot switch live payments on');
  perform tests.logout();
  perform tests.eq((public.app_setting('payments.live_enabled') #>> '{}'), 'false', 'only a super admin can switch live payments on');
  perform tests.login(tests.id('root'));
  update public.application_settings set value = 'true' where key = 'payments.live_enabled';
  perform tests.eq((select value #>> '{}' from public.application_settings where key = 'payments.live_enabled'), 'true', 'super admin can switch live payments on');
  update public.application_settings set value = 'false' where key = 'payments.live_enabled';
  perform public.admin_set_role(v_other, 'support', true);
  perform tests.eq(tests.count(format('select 1 from public.user_roles where user_id = %L and role = %L', v_other, 'support')), 1::bigint, 'super admin grants staff role');
  perform tests.throws(format($t$select public.admin_set_role(%L, 'customer', true)$t$, v_other), 'role_managed_by_system', 'customer/worker roles are system-managed');
  perform tests.throws($t$select public.admin_set_role(auth.uid(), 'support', true)$t$, 'cannot_change_own_roles', 'cannot edit own roles');
  perform tests.ok(tests.count('select 1 from public.admin_audit_logs') >= 3, 'privileged changes were audited');
  perform tests.throws($t$update public.admin_audit_logs set action = 'x'$t$, 'permission denied', 'audit log cannot be edited');
  perform tests.throws($t$delete from public.ledger_entries$t$, 'permission denied', 'ledger entries cannot be deleted via API');
  perform tests.logout();
  perform tests.throws($t$delete from public.ledger_entries$t$, 'append-only', 'ledger is append-only even for the table owner');
  perform tests.throws($t$update public.ledger_transactions set description = 'x'$t$, 'append-only', 'ledger transactions immutable');
  perform tests.throws($t$delete from public.admin_audit_logs$t$, 'append-only', 'audit log immutable');
end $$;
rollback;

-- structural guarantees
do $$
declare v_missing text; v_exposed text;
begin
  select string_agg(tablename, ', ') into v_missing from pg_tables
   where schemaname = 'public' and not rowsecurity;
  perform tests.ok(v_missing is null, 'RLS enabled on every public table' || coalesce(' (missing: ' || v_missing || ')', ''));

  select string_agg(p.proname, ', ') into v_exposed
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
    and p.proname not in ('has_role', 'has_permission', 'is_staff', 'is_system', 'can_access_booking',
                          'can_access_ticket', 'owns_booking', 'is_booking_participant');
  perform tests.ok(v_exposed is null, 'anon can only execute policy helper functions' || coalesce(' (exposed: ' || v_exposed || ')', ''));

  select string_agg(p.proname, ', ') into v_exposed
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname in ('process_payment_event', 'attach_provider_ref', 'run_maintenance', 'bootstrap_first_admin',
                      'begin_refund_processing', 'set_refund_provider_ref', 'release_expired_reservations');
  perform tests.ok(v_exposed is null, 'authenticated cannot execute service-only functions' || coalesce(' (exposed: ' || v_exposed || ')', ''));

  perform tests.ok(not has_table_privilege('authenticated', 'public.ledger_entries', 'insert'), 'no client insert on ledger');
  perform tests.ok(not has_table_privilege('authenticated', 'public.bookings', 'update'), 'no client update on bookings');
  perform tests.ok(not has_table_privilege('authenticated', 'public.payments', 'insert'), 'no client insert on payments');
  perform tests.ok(not has_schema_privilege('authenticated', 'private', 'usage'), 'private schema not usable by clients');
end $$;
