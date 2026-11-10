-- =====================================================================
-- 연결 / 티켓 / 매칭  (Supabase SQL Editor에서 한 번에 실행)
-- =====================================================================

-- 1) 연결 기록 (내가 누구를 선택했는지) / 친구(서로 선택한 사이)
create table if not exists connections (
  from_id    uuid not null references profiles(id) on delete cascade,
  to_id      uuid not null references profiles(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (from_id, to_id),
  check (from_id <> to_id)
);
create table if not exists friendships (
  user_a     uuid not null references profiles(id) on delete cascade,
  user_b     uuid not null references profiles(id) on delete cascade,
  created_at timestamptz default now(),
  a_seen     boolean default false,   -- user_a 가 매칭 알림을 봤는지
  b_seen     boolean default false,
  primary key (user_a, user_b),
  check (user_a < user_b)
);

-- 두 표는 앱에서 직접 읽고 쓸 수 없게 잠급니다. (아래 함수로만 접근)
-- 그래서 "누가 나를 선택했는지"는 매칭되기 전까지 누구도 볼 수 없습니다.
alter table connections enable row level security;
alter table friendships enable row level security;

-- 2) 티켓은 서버 함수만 바꿀 수 있게 막기 (본인이 직접 늘리는 것 차단)
revoke insert, update on profiles from authenticated, anon;
grant insert (id, name, cohort, interests, color) on profiles to authenticated;
-- 주의: 앱의 저장(upsert)은 id 칸도 함께 쓰므로 update 권한에 id 가 있어야 합니다.
-- (id 는 RLS 정책 auth.uid() = id 때문에 다른 사람 값으로는 바꿀 수 없습니다.)
grant update (id, name, cohort, interests, color) on profiles to authenticated;

-- 새로 가입하면 연결 티켓 5장으로 시작
alter table profiles alter column tickets set default 5;
-- 아직 한 장도 쓰지 않은 기존 사용자(2장)도 5장으로 맞춤
update profiles set tickets = 5 where tickets = 2;

-- 3) 연결하기: 티켓 1장 차감 + 선택 저장, 상대도 이미 나를 선택했으면 바로 친구 성사
create or replace function public.connect_to(target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t int; a uuid; b uuid; matched boolean := false;
begin
  if me is null then raise exception 'not_logged_in'; end if;
  if target is null or target = me then raise exception 'invalid_target'; end if;

  -- 두 사람이 동시에 눌러도 꼬이지 않게 순서를 정해 잠금
  perform 1 from profiles where id in (me, target) order by id for update;

  if not exists (select 1 from profiles where id = me and name is not null) then
    raise exception 'no_profile';
  end if;
  if not exists (select 1 from profiles where id = target and name is not null) then
    raise exception 'invalid_target';
  end if;

  a := least(me, target); b := greatest(me, target);
  if exists (select 1 from friendships where user_a = a and user_b = b) then
    raise exception 'already_friends';
  end if;

  select tickets into t from profiles where id = me;
  if exists (select 1 from connections where from_id = me and to_id = target) then
    return json_build_object('status', 'pending', 'tickets', t);   -- 이미 선택함
  end if;
  if t <= 0 then raise exception 'no_tickets'; end if;

  update profiles set tickets = tickets - 1 where id = me returning tickets into t;

  if exists (select 1 from connections where from_id = target and to_id = me) then
    delete from connections
      where (from_id = me and to_id = target) or (from_id = target and to_id = me);
    insert into friendships (user_a, user_b, a_seen, b_seen)
      values (a, b, a = me, b = me);        -- 성사시킨 쪽은 바로 본 것으로 처리
    matched := true;
  else
    insert into connections (from_id, to_id) values (me, target);
  end if;

  return json_build_object('status', case when matched then 'matched' else 'pending' end,
                           'tickets', t);
end $$;

-- 4) 선택 취소: 아직 매칭 전이면 티켓 1장 돌려받기
create or replace function public.cancel_connect(target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t int; n int;
begin
  if me is null then raise exception 'not_logged_in'; end if;
  perform 1 from profiles where id = me for update;
  delete from connections where from_id = me and to_id = target;
  get diagnostics n = row_count;
  if n > 0 then update profiles set tickets = tickets + 1 where id = me; end if;
  select tickets into t from profiles where id = me;
  return json_build_object('tickets', t);
end $$;

-- 5) 내 상태: 남은 티켓 / 내가 선택한 사람 / 내 친구 (나를 선택한 사람은 절대 안 내려감)
create or replace function public.get_my_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'tickets', (select tickets from profiles where id = auth.uid()),
    'sent', coalesce((select json_agg(to_id) from connections where from_id = auth.uid()), '[]'::json),
    'friends', coalesce((
      select json_agg(json_build_object(
               'id', p.id, 'name', p.name, 'cohort', p.cohort,
               'interests', p.interests, 'color', p.color,
               'is_new', not (case when f.user_a = auth.uid() then f.a_seen else f.b_seen end))
             order by f.created_at desc)
      from friendships f
      join profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
      where f.user_a = auth.uid() or f.user_b = auth.uid()
    ), '[]'::json)
  );
$$;

-- 6) 매칭 알림을 확인했다고 표시
create or replace function public.mark_friends_seen()
returns void language sql security definer set search_path = public as $$
  update friendships set a_seen = true where user_a = auth.uid();
  update friendships set b_seen = true where user_b = auth.uid();
$$;

-- 7) 추천 목록: 이미 친구가 된 사람은 제외
drop function if exists public.get_recommendations();
create function public.get_recommendations()
returns table (id uuid, name text, cohort int, interests text[], color text)
language sql stable security definer set search_path = public as $$
  with me as (select interests from profiles where id = auth.uid())
  select p.id, p.name, p.cohort, p.interests, p.color
  from profiles p left join me on true
  where p.id <> auth.uid() and p.name is not null
    and not exists (select 1 from friendships f
                    where f.user_a = least(p.id, auth.uid()) and f.user_b = greatest(p.id, auth.uid()))
  order by cardinality(array(
      select unnest(p.interests) intersect select unnest(coalesce(me.interests, '{}'))
    )) desc,
    p.created_at desc
  limit 50;
$$;

-- 8) 로그인한 사용자만 호출 가능
revoke all on function public.connect_to(uuid)       from public, anon;
revoke all on function public.cancel_connect(uuid)   from public, anon;
revoke all on function public.get_my_state()         from public, anon;
revoke all on function public.mark_friends_seen()    from public, anon;
revoke all on function public.get_recommendations()  from public, anon;
grant execute on function public.connect_to(uuid)       to authenticated;
grant execute on function public.cancel_connect(uuid)   to authenticated;
grant execute on function public.get_my_state()         to authenticated;
grant execute on function public.mark_friends_seen()    to authenticated;
grant execute on function public.get_recommendations()  to authenticated;
