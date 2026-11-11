-- =====================================================================
-- 탐색 탭 "평점 TOP 3": 모두가 준 별점의 평균이 높은 3명
-- 04-rotation.sql, 05-rating.sql 실행 후, SQL Editor에서 한 번에 실행
-- =====================================================================

-- 평균과 평가 수만 내려갑니다. 누가 몇 점을 줬는지는 알 수 없고,
-- 평가가 3개 미만인 사람은 집계에서 제외해서 한 사람의 별점이 드러나지 않게 합니다.
create or replace function public.top_rated()
returns table (id uuid, name text, cohort int, interests text[], color text,
               avg_rating numeric, n_ratings bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.cohort, p.interests, p.color,
         round(avg(e.rating)::numeric, 1) as avg_rating,
         count(e.rating)                  as n_ratings
  from encounters e
  join profiles p on p.id = e.met_id
  where e.rating is not null and p.name is not null
  group by p.id, p.name, p.cohort, p.interests, p.color
  having count(e.rating) >= 3
  order by avg(e.rating) desc, count(e.rating) desc, p.name
  limit 3;
$$;

revoke all on function public.top_rated() from public, anon;
grant execute on function public.top_rated() to authenticated;
