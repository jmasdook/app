-- Catalog search with filters (category, text, price, area availability on a date, minimum rating).
create function public.search_services(
  p_query text default null, p_category uuid default null, p_max_price_minor bigint default null,
  p_area uuid default null, p_date date default null, p_min_rating numeric default null)
returns table (id uuid, slug text, name text, description text, image_url text, category_id uuid,
               pricing_model public.pricing_model, base_price_minor bigint, currency char(3), included_minutes int,
               popular boolean, rating_avg numeric, available boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.slug, s.name, s.description, s.image_url, s.category_id, s.pricing_model, s.base_price_minor,
         s.currency, s.included_minutes, s.popular, r.rating, a.available
  from public.services s
  join public.service_categories c on c.id = s.category_id and c.active
  left join lateral (
    select coalesce(round(avg(w.rating_avg) filter (where w.rating_count > 0), 2), 0) as rating
    from public.worker_skills k
    join public.worker_profiles w on w.id = k.worker_id and public.is_worker_bookable(w.id)
    where k.service_id = s.id and k.approved
      and (p_area is null or exists (select 1 from public.worker_service_areas wa where wa.worker_id = w.id and wa.area_id = p_area))
  ) r on true
  left join lateral (
    select case when p_area is not null and p_date is not null
                then exists (select 1 from public.available_slots(s.id, p_area, p_date))
                else exists (select 1 from public.worker_skills k join public.worker_profiles w on w.id = k.worker_id
                             where k.service_id = s.id and k.approved and public.is_worker_bookable(w.id)) end as available
  ) a on true
  where s.active
    and (p_category is null or s.category_id = p_category)
    and (p_query is null or p_query = '' or s.name ilike '%' || replace(replace(p_query, '%', ''), '_', '') || '%'
         or s.description ilike '%' || replace(replace(p_query, '%', ''), '_', '') || '%')
    and (p_max_price_minor is null or s.base_price_minor <= p_max_price_minor)
    and (p_min_rating is null or r.rating >= p_min_rating)
    and (p_date is null or p_area is null or a.available)
  order by s.popular desc, s.sort_order, s.name
$$;
revoke execute on function public.search_services(text, uuid, bigint, uuid, date, numeric) from public;
grant execute on function public.search_services(text, uuid, bigint, uuid, date, numeric) to anon, authenticated, service_role;
