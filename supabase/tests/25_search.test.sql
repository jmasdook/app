begin;
do $$
begin
  perform tests.anon();
  perform tests.eq((select count(*) from public.search_services()), 4::bigint, 'anon can search the catalog');
  perform tests.eq((select count(*) from public.search_services('Home clean')), 1::bigint, 'text search');
  perform tests.eq((select count(*) from public.search_services(null, null, 10000)), 2::bigint, 'max price filter (<= 100.00)');
  perform tests.eq((select count(*) from public.search_services(null, 'c0000000-0000-0000-0000-000000000001'::uuid)), 1::bigint, 'category filter');
  perform tests.eq((select count(*) from public.search_services(null, null, null, tests.id('area1'), current_date + 3)), 4::bigint, 'availability filter keeps bookable services');
  perform tests.eq((select count(*) from public.search_services(null, null, null, tests.id('area3'), current_date + 3)), 0::bigint, 'availability filter hides services with no slots in the area');
  perform tests.eq((select count(*) from public.search_services('100%_')), 0::bigint, 'wildcards in user text are neutralised');
  perform tests.logout();
end $$;
rollback;
