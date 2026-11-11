-- =====================================================================
-- 미니게임 "도발하기": 결과 화면의 [친구에게 도발하기]를 누르면 내 친구 목록이
-- 팝업으로 뜨고, 친구를 고르면 그 친구의 알림(벨)에 "OO님이 도발했어요"가 남습니다.
-- 10-game.sql 실행 후, Supabase SQL Editor에서 이 파일 전체를 한 번에 실행하세요.
-- (여러 번 실행해도 안전합니다. 전에 11번을 이미 실행했어도 그대로 실행하면 돼요.)
--
-- 만들어지는 것
--   표   game_pokes          누가 누구에게 어느 날 도발했는지 (같은 날 같은 친구에게 한 번만)
--   함수 game_taunt_targets  도발할 수 있는 내 친구 목록 (오늘 이미 도발했는지 포함)
--   함수 game_taunt          친구에게 도발 보내기
--   함수 game_taunt_inbox    내가 받은 새 도발을 가져오고 '읽음' 처리
--
-- 규칙
--   - 서로 친구인 사이에만 보낼 수 있어요.
--   - 내가 오늘 미니게임을 푼 뒤에만 보낼 수 있어요. (알림에 내 기록이 들어가요)
--   - 같은 친구에게는 하루에 한 번만 보낼 수 있어요.
-- =====================================================================

create table if not exists game_pokes (
  from_id    uuid not null references profiles(id) on delete cascade,
  to_id      uuid not null references profiles(id) on delete cascade,
  day        date not null,
  created_at timestamptz not null default now(),
  seen       boolean not null default false,
  primary key (from_id, to_id, day),
  check (from_id <> to_id)
);

create index if not exists game_pokes_to_idx on game_pokes (to_id, seen);

-- 표는 앱이 직접 읽고 쓰지 못하게 잠그고, 아래 함수로만 접근해요.
alter table game_pokes enable row level security;
revoke all on game_pokes from anon, authenticated;

-- ---------------------------------------------------------------------
-- 도발할 수 있는 내 친구 목록. 친구의 이름 / 기수 / 색만 내려가요.
-- ---------------------------------------------------------------------
create or replace function public.game_taunt_targets()
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if me is null then raise exception 'not signed in'; end if;

  return coalesce((
    select json_agg(json_build_object(
             'id',      p.id,
             'name',    p.name,
             'cohort',  p.cohort,
             'color',   p.color,
             'taunted', exists (select 1 from game_pokes gp
                                where gp.from_id = me and gp.to_id = p.id and gp.day = today)
           ) order by p.name)
    from friendships f
    join profiles p on p.id = case when f.user_a = me then f.user_b else f.user_a end
    where f.user_a = me or f.user_b = me
  ), '[]'::json);
end $$;

-- ---------------------------------------------------------------------
-- 친구에게 도발 보내기
-- ---------------------------------------------------------------------
create or replace function public.game_taunt(p_to uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  n     int;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_to is null or p_to = me then raise exception 'invalid target'; end if;

  if not exists (
    select 1 from friendships f
    where (f.user_a = me and f.user_b = p_to) or (f.user_a = p_to and f.user_b = me)
  ) then
    raise exception 'friends only';
  end if;

  if not exists (select 1 from game_results where user_id = me and day = today) then
    raise exception 'play first';
  end if;

  insert into game_pokes (from_id, to_id, day) values (me, p_to, today)
  on conflict (from_id, to_id, day) do nothing;
  get diagnostics n = row_count;
  return json_build_object('sent', n > 0);
end $$;

-- ---------------------------------------------------------------------
-- 내가 받은 새 도발. 한 번 가져가면 '읽음'이 되어 다시 내려가지 않아요.
-- 보낸 사람의 이름과 그 사람의 그날 기록만 내려가요.
-- ---------------------------------------------------------------------
create or replace function public.game_taunt_inbox()
returns json
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  res json;
begin
  if me is null then raise exception 'not signed in'; end if;

  with got as (
    update game_pokes set seen = true
    where to_id = me and seen = false
    returning from_id, day, created_at
  )
  select coalesce(json_agg(json_build_object(
           'name',    p.name,
           'seconds', (select gr.seconds from game_results gr where gr.user_id = got.from_id and gr.day = got.day)
         ) order by got.created_at), '[]'::json)
    into res
  from got join profiles p on p.id = got.from_id;

  return res;
end $$;

revoke all on function public.game_taunt_targets() from public, anon;
revoke all on function public.game_taunt(uuid)     from public, anon;
revoke all on function public.game_taunt_inbox()   from public, anon;
grant execute on function public.game_taunt_targets() to authenticated;
grant execute on function public.game_taunt(uuid)     to authenticated;
grant execute on function public.game_taunt_inbox()   to authenticated;

-- =====================================================================
-- 테스트 기록을 지우려면:
--   delete from game_pokes;
-- =====================================================================
