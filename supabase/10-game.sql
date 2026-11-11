-- =====================================================================
-- 홈 "오늘의 미니게임"(6x6 스도쿠): 결과 저장, 내 통계, 오늘의 랭킹
-- 02~08 실행 후, Supabase SQL Editor에서 이 파일 전체를 한 번에 실행하세요.
-- (여러 번 실행해도 안전합니다)
--
-- 만들어지는 것
--   표   game_results      한 사람당 하루 한 줄 (하루 한 번 도전을 서버가 보장)
--   함수 game_submit       클리어 기록 저장 (이미 오늘 기록이 있으면 무시)
--   함수 game_my_stats     내 연속 일수 / 최고 기록 / 완료 횟수 / 오늘 기록
--   함수 game_ranking      오늘의 TOP 5 + 내 순위 + 전체 참여자 수
--
-- 날짜는 모두 한국 시간(Asia/Seoul) 자정 기준입니다.
-- =====================================================================

create table if not exists game_results (
  user_id    uuid not null references profiles(id) on delete cascade,
  day        date not null,
  seconds    int  not null check (seconds between 5 and 3600),
  created_at timestamptz not null default now(),
  primary key (user_id, day)          -- 한 사람이 같은 날 두 줄을 넣을 수 없어요
);

create index if not exists game_results_day_idx on game_results (day, seconds);

-- 표는 앱이 직접 읽고 쓰지 못하게 잠그고, 아래 함수로만 접근해요.
alter table game_results enable row level security;
revoke all on game_results from anon, authenticated;

-- ---------------------------------------------------------------------
-- 클리어 기록 저장. 이미 오늘 기록이 있으면 아무것도 바꾸지 않아요.
-- p_day 는 앱이 푼 문제의 날짜이고, 오늘(또는 어제 자정 직후)만 허용해요.
-- ---------------------------------------------------------------------
create or replace function public.game_submit(p_day date, p_seconds int)
returns json
language plpgsql security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  n     int;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_day is null or p_day > today or p_day < today - 1 then
    raise exception 'invalid day';
  end if;
  if p_seconds is null or p_seconds < 5 or p_seconds > 3600 then
    raise exception 'invalid time';
  end if;
  if not exists (select 1 from profiles where id = me) then
    raise exception 'profile required';
  end if;

  insert into game_results (user_id, day, seconds) values (me, p_day, p_seconds)
  on conflict (user_id, day) do nothing;
  get diagnostics n = row_count;
  return json_build_object('saved', n > 0);
end $$;

-- ---------------------------------------------------------------------
-- 내 통계. 연속 일수는 오늘 또는 어제까지 이어진 기록의 길이예요.
-- ---------------------------------------------------------------------
create or replace function public.game_my_stats()
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  me     uuid := auth.uid();
  today  date := (now() at time zone 'Asia/Seoul')::date;
  streak int;
begin
  if me is null then raise exception 'not signed in'; end if;

  with d as (select day from game_results where user_id = me),
       g as (select day, day - (row_number() over (order by day))::int as grp from d),
       runs as (select count(*) as n, max(day) as last_day from g group by grp)
  select coalesce((select n from runs where last_day >= today - 1 order by last_day desc limit 1), 0)
    into streak;

  return json_build_object(
    'streak',        streak,
    'total',         (select count(*) from game_results where user_id = me),
    'best',          (select min(seconds) from game_results where user_id = me),
    'today_seconds', (select seconds from game_results where user_id = me and day = today)
  );
end $$;

-- ---------------------------------------------------------------------
-- 오늘의 랭킹. 친구가 아니어도 모두 포함해요.
-- 이름 / 기수 / 색 / 시간만 내려가요. 다른 사람의 id 는 내려가지 않아요.
-- ---------------------------------------------------------------------
create or replace function public.game_ranking(p_day date default null)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  d     date;
begin
  if me is null then raise exception 'not signed in'; end if;
  d := coalesce(p_day, today);
  if d > today or d < today - 60 then raise exception 'invalid day'; end if;

  return (
    with r as (
      select gr.user_id, gr.seconds,
             row_number() over (order by gr.seconds, gr.created_at, gr.user_id) as rk
      from game_results gr
      where gr.day = d
    )
    select json_build_object(
      'total', (select count(*) from r),
      'me',    (select json_build_object('rank', rk, 'seconds', seconds) from r where user_id = me),
      'top',   coalesce((
                 select json_agg(json_build_object(
                          'rank',    r.rk,
                          'name',    p.name,
                          'cohort',  p.cohort,
                          'color',   p.color,
                          'seconds', r.seconds,
                          'me',      r.user_id = me
                        ) order by r.rk)
                 from r join profiles p on p.id = r.user_id
                 where r.rk <= 5
               ), '[]'::json)
    )
  );
end $$;

-- 로그인한 사람만 실행할 수 있어요.
revoke all on function public.game_submit(date, int) from public, anon;
revoke all on function public.game_my_stats()        from public, anon;
revoke all on function public.game_ranking(date)     from public, anon;
grant execute on function public.game_submit(date, int) to authenticated;
grant execute on function public.game_my_stats()        to authenticated;
grant execute on function public.game_ranking(date)     to authenticated;

-- =====================================================================
-- 확인용 (필요할 때만 실행). 오늘의 기록을 이름과 함께 보기:
--   select p.name, g.seconds, g.created_at
--   from game_results g join profiles p on p.id = g.user_id
--   where g.day = (now() at time zone 'Asia/Seoul')::date
--   order by g.seconds;
-- 테스트 기록을 지우기:
--   delete from game_results;
-- =====================================================================
