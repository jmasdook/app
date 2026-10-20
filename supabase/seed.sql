-- FICTIONAL DEVELOPMENT DATA ONLY. Never run against production.
-- Users are created via auth.users (local/dev only); passwords are managed by Supabase Auth in real projects.
insert into public.service_areas (id, city, name) values
  ('a0000000-0000-0000-0000-000000000001', 'Dubai', 'Dubai Marina'),
  ('a0000000-0000-0000-0000-000000000002', 'Dubai', 'Jumeirah Lakes Towers'),
  ('a0000000-0000-0000-0000-000000000003', 'Abu Dhabi', 'Al Reem Island');

insert into public.service_categories (id, slug, name, description, sort_order, image_url) values
  ('c0000000-0000-0000-0000-000000000001', 'electrical', 'Electrical', 'Wiring, lighting, sockets and fault finding by licensed electricians.', 1, 'https://images.unsplash.com/photo-1621905252507-b35492cc74b4?w=800'),
  ('c0000000-0000-0000-0000-000000000002', 'plumbing', 'Plumbing', 'Leaks, blockages, fittings and water heaters.', 2, 'https://images.unsplash.com/photo-1585704032915-c3400ca199e7?w=800'),
  ('c0000000-0000-0000-0000-000000000003', 'cleaning', 'Home & office cleaning', 'Deep and routine cleaning for homes and offices.', 3, 'https://images.unsplash.com/photo-1581578731548-c64695cc6952?w=800'),
  ('c0000000-0000-0000-0000-000000000004', 'ac-service', 'AC servicing', 'Servicing, gas top-up and repairs for split and central AC.', 4, 'https://images.unsplash.com/photo-1631545806609-4ad1d7bfa4c8?w=800'),
  ('c0000000-0000-0000-0000-000000000005', 'handyman', 'Handyman', 'Mounting, assembly, repairs and odd jobs.', 5, 'https://images.unsplash.com/photo-1504148455328-c376907d081c?w=800');

insert into public.services (id, category_id, slug, name, description, included, excluded, pricing_model, base_price_minor,
                             included_minutes, extra_hour_rate_minor, max_extension_minutes, popular) values
  ('d0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'electrician-visit', 'Electrician visit',
   'Diagnose and fix common electrical faults.', '{"Fault diagnosis","Minor repairs up to 2 hours"}', '{"Materials","Rewiring"}',
   'base_plus_extra', 15000, 120, 6000, 180, true),
  ('d0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'plumber-visit', 'Plumber visit',
   'Leak repair and fitting replacement.', '{"Leak diagnosis","Standard fittings labour"}', '{"Spare parts"}',
   'base_plus_extra', 12000, 60, 7000, 120, true),
  ('d0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'home-cleaning', 'Home cleaning (hourly)',
   'Professional cleaner with supplies.', '{"Cleaning supplies","Kitchen & bathrooms"}', '{"Exterior windows"}',
   'hourly', 4500, 120, 0, 240, true),
  ('d0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'ac-service-split', 'Split AC service',
   'Cleaning and inspection of one split unit.', '{"Filter and coil cleaning","Performance check"}', '{"Gas refill"}',
   'fixed', 9000, 60, 5000, 60, false);

insert into public.service_pricing_rules (service_id, name, kind, value, applies_dow, start_minute, end_minute) values
  ('d0000000-0000-0000-0000-000000000001', 'Evening surcharge', 'surcharge_bps', 2000, '{0,1,2,3,4,5,6}', 1080, 1440);

insert into public.commission_policies (scope, rate_bps, note) values ('global', 1500, 'development default');
insert into public.commission_policies (scope, category_id, rate_bps, note)
values ('category', 'c0000000-0000-0000-0000-000000000003', 1000, 'development cleaning rate');

insert into public.promotions (code, kind, value, max_discount_minor) values ('WELCOME10', 'percent_bps', 1000, 5000);
