begin;
do $$
declare w public.worker_profiles; d1 uuid; d2 uuid; c3 uuid := tests.id('c3');
begin
  perform tests.login(c3);
  w := public.become_worker();
  perform tests.eq(w.status::text, 'draft', 'new worker starts as draft');
  perform tests.throws($t$select public.submit_worker_application()$t$, 'documents_missing', 'cannot submit without documents');
  insert into public.worker_documents (worker_id, doc_type, storage_path) values (c3, 'identity', c3 || '/id.pdf');
  perform tests.throws($t$insert into public.worker_documents (worker_id, doc_type, storage_path) values (auth.uid(), 'identity', 'someone-else/id.pdf')$t$, '42501', 'document path must live in own folder');
  insert into public.worker_documents (worker_id, doc_type, storage_path) values (c3, 'qualification', c3 || '/q.pdf');
  perform tests.eq((select status::text from public.worker_documents where doc_type = 'identity'), 'pending', 'client-supplied status ignored: documents start pending');
  insert into public.worker_skills (worker_id, service_id) values (c3, tests.id('svc_elec'));
  perform tests.eq((select approved from public.worker_skills where worker_id = c3), false, 'self-submitted skill is unapproved');
  insert into public.worker_service_areas values (c3, tests.id('area1'));
  perform tests.eq((public.submit_worker_application()).status::text, 'submitted', 'application submitted');
  perform tests.eq(tests.val(format('select public.is_worker_bookable(%L)', c3)), 'false', 'submitted worker is not bookable');

  perform tests.login(tests.id('support'));
  perform tests.throws(format($t$select public.review_worker(%L, 'approve')$t$, c3), '42501', 'support cannot approve');
  perform tests.login(tests.id('admin'));
  perform tests.throws(format($t$select public.review_worker(%L, 'approve')$t$, c3), 'required_documents_not_approved', 'cannot approve before documents are approved');
  perform public.review_worker(c3, 'start_review');
  for d1 in select id from public.worker_documents where worker_id = c3 loop perform public.review_document(d1, true); end loop;
  perform tests.throws(format($t$select public.review_worker(%L, 'approve')$t$, c3), 'no_approved_skill', 'needs an approved skill');
  update public.worker_skills set approved = true where worker_id = c3;
  perform tests.eq((public.review_worker(c3, 'approve')).status::text, 'approved', 'admin approves complete application');
  perform tests.eq(tests.val(format('select public.is_worker_bookable(%L)', c3)), 'true', 'approved worker with valid credentials is bookable');
  perform tests.logout();
  perform tests.eq((select count(*) from public.admin_audit_logs where action = 'worker.approve'), 1::bigint, 'approval audited');
  perform tests.eq((select count(*) from public.notifications where user_id = c3 and type = 'worker.approved'), 1::bigint, 'worker notified');

  -- suspension releases live bookings
  perform tests.pay_booking(tests.new_booking('c1', 'svc_elec', tests.slot(3, 10), 'w1'));
  perform tests.login(tests.id('admin'));
  perform tests.throws(format($t$select public.review_worker(%L, 'suspend')$t$, tests.id('w1')), 'reason_required', 'suspension needs a reason');
  perform public.review_worker(tests.id('w1'), 'suspend', 'misconduct report');
  perform tests.logout();
  perform tests.eq((select status::text from public.bookings where customer_id = tests.id('c1') and scheduled_start = tests.slot(3, 10)), 'unassigned', 'suspended worker bookings returned to the pool');
end $$;
rollback;
