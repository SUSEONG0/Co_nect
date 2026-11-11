-- =====================================================================
-- 아직 서버에 없는 것을 한 번에 만드는 파일 (04 → 05 → 06 → 07 → 08 순서로 이어 붙임)
-- Supabase 왼쪽 메뉴 SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run
-- 여러 번 실행해도 안전합니다. (이미 있는 표/함수는 건너뛰거나 덮어씁니다)
-- =====================================================================

-- #####################################################################
-- ## 04-rotation.sql
-- #####################################################################
-- =====================================================================
-- 로테이션 네트워킹: 라운드마다 누구와 대화했는지 기록  (SQL Editor에서 한 번에 실행)
-- =====================================================================

create table if not exists encounters (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles(id) on delete cascade,   -- 나
  met_id     uuid not null references profiles(id) on delete cascade,   -- 대화한 상대
  round_no   int  not null,
  started_at timestamptz default now(),
  ended_at   timestamptz,                  -- 비어 있으면 지금 대화 중
  check (user_id <> met_id),
  unique (user_id, round_no),              -- 한 라운드에 한 명
  unique (user_id, met_id)                 -- 같은 사람을 두 번 만난 것으로 기록하지 않음
);
-- 앱에서 직접 읽고 쓸 수 없게 잠급니다. (아래 함수로만 접근)
alter table encounters enable row level security;

-- 이름으로 사람 검색 (나는 제외, 이미 만난 사람은 met=true 로 표시)
create or replace function public.search_people(q text)
returns table (id uuid, name text, cohort int, interests text[], color text, met boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.cohort, p.interests, p.color,
         exists (select 1 from encounters e where e.user_id = auth.uid() and e.met_id = p.id) as met
  from profiles p
  where p.id <> auth.uid() and p.name is not null
    and (coalesce(trim(q), '') = ''
         or p.name ilike '%' || replace(replace(replace(trim(q), '\', '\\'), '%', '\%'), '_', '\_') || '%')
  order by met, p.name
  limit 30;
$$;

-- 내 로테이션 상태: 지금 라운드 / 지금 대화 중인 사람 / 지금까지 만난 사람
create or replace function public.rotation_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'round', coalesce(
      (select round_no from encounters where user_id = auth.uid() and ended_at is null),
      (select coalesce(max(round_no), 0) + 1 from encounters where user_id = auth.uid())),
    'current', (
      select json_build_object('id', p.id, 'name', p.name, 'cohort', p.cohort,
                               'interests', p.interests, 'color', p.color, 'started_at', e.started_at)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is null),
    'history', coalesce((
      select json_agg(json_build_object('round', e.round_no, 'id', p.id, 'name', p.name,
                                        'cohort', p.cohort, 'interests', p.interests, 'color', p.color)
                      order by e.round_no desc)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is not null), '[]'::json)
  );
$$;

-- 지금 대화하는 사람 선택 (대화 중인 사람이 있으면 그 사람으로 바꿈)
create or replace function public.rotation_pick(target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_logged_in'; end if;
  if target is null or target = me
     or not exists (select 1 from profiles where id = target and name is not null) then
    raise exception 'invalid_target';
  end if;
  perform 1 from profiles where id = me for update;      -- 같은 사람이 연타해도 꼬이지 않게
  if exists (select 1 from encounters where user_id = me and ended_at is null) then
    update encounters set met_id = target, started_at = now()
      where user_id = me and ended_at is null;
  else
    insert into encounters (user_id, met_id, round_no)
      select me, target, coalesce(max(round_no), 0) + 1 from encounters where user_id = me;
  end if;
  return public.rotation_state();
exception when unique_violation then
  raise exception 'already_met';
end $$;

-- 대화 끝: 이번 라운드를 마치고 다음 라운드로
create or replace function public.rotation_next()
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  update encounters set ended_at = now() where user_id = auth.uid() and ended_at is null;
  return public.rotation_state();
end $$;

revoke all on function public.search_people(text)  from public, anon;
revoke all on function public.rotation_state()     from public, anon;
revoke all on function public.rotation_pick(uuid)  from public, anon;
revoke all on function public.rotation_next()      from public, anon;
grant execute on function public.search_people(text)  to authenticated;
grant execute on function public.rotation_state()     to authenticated;
grant execute on function public.rotation_pick(uuid)  to authenticated;
grant execute on function public.rotation_next()      to authenticated;

-- #####################################################################
-- ## 05-rating.sql
-- #####################################################################
-- =====================================================================
-- 별점 + 로테이션 마치기  (04-rotation.sql 실행 후, SQL Editor에서 한 번에 실행)
-- =====================================================================

-- 1) 대화 상대마다 내가 준 별점(1~5) / 로테이션을 마쳤는지
alter table encounters add column if not exists rating int check (rating between 1 and 5);
create table if not exists rotation_status (
  user_id     uuid primary key references profiles(id) on delete cascade,
  finished_at timestamptz default now()
);
alter table rotation_status enable row level security;   -- 앱에서 직접 접근 불가, 함수로만

-- 2) 내 상태: 별점과 마침 여부도 함께 내려줌
create or replace function public.rotation_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'finished', exists (select 1 from rotation_status where user_id = auth.uid()),
    'round', coalesce(
      (select round_no from encounters where user_id = auth.uid() and ended_at is null),
      (select coalesce(max(round_no), 0) + 1 from encounters where user_id = auth.uid())),
    'current', (
      select json_build_object('id', p.id, 'name', p.name, 'cohort', p.cohort,
                               'interests', p.interests, 'color', p.color, 'started_at', e.started_at)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is null),
    'history', coalesce((
      select json_agg(json_build_object('round', e.round_no, 'rating', e.rating, 'id', p.id, 'name', p.name,
                                        'cohort', p.cohort, 'interests', p.interests, 'color', p.color)
                      order by e.round_no desc)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is not null), '[]'::json)
  );
$$;

-- 3) 마친 로테이션에는 더 기록할 수 없음 (기존 함수를 같은 이름으로 다시 정의)
create or replace function public.rotation_pick(target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from rotation_status where user_id = me) then raise exception 'finished'; end if;
  if target is null or target = me
     or not exists (select 1 from profiles where id = target and name is not null) then
    raise exception 'invalid_target';
  end if;
  perform 1 from profiles where id = me for update;
  if exists (select 1 from encounters where user_id = me and ended_at is null) then
    update encounters set met_id = target, started_at = now()
      where user_id = me and ended_at is null;
  else
    insert into encounters (user_id, met_id, round_no)
      select me, target, coalesce(max(round_no), 0) + 1 from encounters where user_id = me;
  end if;
  return public.rotation_state();
exception when unique_violation then
  raise exception 'already_met';
end $$;

-- 4) 대화 끝 + 별점 저장 (별점은 비워도 됨)
drop function if exists public.rotation_next();
create or replace function public.rotation_next(p_rating int default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  if p_rating is not null and p_rating not between 1 and 5 then raise exception 'invalid_rating'; end if;
  update encounters set ended_at = now(), rating = p_rating
    where user_id = auth.uid() and ended_at is null;
  return public.rotation_state();
end $$;

-- 5) 로테이션 마치기: 대화 중이던 사람이 있으면 그것도 끝내고, 결과(랭킹)를 볼 수 있게 됨
create or replace function public.rotation_finish()
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  update encounters set ended_at = now() where user_id = auth.uid() and ended_at is null;
  insert into rotation_status (user_id) values (auth.uid()) on conflict do nothing;
  return public.rotation_state();
end $$;

revoke all on function public.rotation_state()        from public, anon;
revoke all on function public.rotation_pick(uuid)     from public, anon;
revoke all on function public.rotation_next(int)      from public, anon;
revoke all on function public.rotation_finish()       from public, anon;
grant execute on function public.rotation_state()        to authenticated;
grant execute on function public.rotation_pick(uuid)     to authenticated;
grant execute on function public.rotation_next(int)      to authenticated;
grant execute on function public.rotation_finish()       to authenticated;

-- #####################################################################
-- ## 06-topics.sql
-- #####################################################################
-- =====================================================================
-- 대화 끝에 남기는 "더 이야기하고 싶은 주제" (나만 보는 메모)
-- 04-rotation.sql, 05-rating.sql 실행 후, SQL Editor에서 한 번에 실행
-- =====================================================================

alter table encounters add column if not exists topics text[];

-- 내 상태: 주제도 함께 내려줌 (본인 기록만)
create or replace function public.rotation_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'finished', exists (select 1 from rotation_status where user_id = auth.uid()),
    'round', coalesce(
      (select round_no from encounters where user_id = auth.uid() and ended_at is null),
      (select coalesce(max(round_no), 0) + 1 from encounters where user_id = auth.uid())),
    'current', (
      select json_build_object('id', p.id, 'name', p.name, 'cohort', p.cohort,
                               'interests', p.interests, 'color', p.color, 'started_at', e.started_at)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is null),
    'history', coalesce((
      select json_agg(json_build_object('round', e.round_no, 'rating', e.rating, 'topics', e.topics,
                                        'id', p.id, 'name', p.name,
                                        'cohort', p.cohort, 'interests', p.interests, 'color', p.color)
                      order by e.round_no desc)
      from encounters e join profiles p on p.id = e.met_id
      where e.user_id = auth.uid() and e.ended_at is not null), '[]'::json)
  );
$$;

-- 대화 끝: 별점 + 주제 저장 (주제는 최대 2개, 각 20자 이내)
drop function if exists public.rotation_next(int);
drop function if exists public.rotation_next(int, text[]);
create or replace function public.rotation_next(p_rating int default null, p_topics text[] default null)
returns json language plpgsql security definer set search_path = public as $$
declare t text; clean text[] := '{}';
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  if p_rating is not null and p_rating not between 1 and 5 then raise exception 'invalid_rating'; end if;
  if p_topics is not null then
    foreach t in array p_topics loop
      t := left(trim(t), 20);
      if t <> '' then clean := clean || t; end if;
    end loop;
    if coalesce(array_length(clean, 1), 0) > 2 then raise exception 'too_many_topics'; end if;
  end if;
  update encounters
     set ended_at = now(), rating = p_rating, topics = nullif(clean, '{}')
   where user_id = auth.uid() and ended_at is null;
  return public.rotation_state();
end $$;

revoke all on function public.rotation_state()               from public, anon;
revoke all on function public.rotation_next(int, text[])     from public, anon;
grant execute on function public.rotation_state()            to authenticated;
grant execute on function public.rotation_next(int, text[])  to authenticated;

-- #####################################################################
-- ## 07-top-rated.sql
-- #####################################################################
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

-- #####################################################################
-- ## 08-qr-friends.sql
-- #####################################################################
-- =====================================================================
-- 현장 QR로 친구 추가  (SQL Editor에서 한 번에 실행)
-- 이미 만든 friendships(친구) 표를 그대로 사용합니다.
-- =====================================================================

-- 내 QR에 들어갈 "임시 코드". 90초만 유효하고, 앱이 60초마다 새로 받아 갑니다.
-- (내 ID를 그대로 QR에 넣으면, 추천 목록에서 ID를 알아낸 사람이 현장에 없어도 친구로 추가할 수 있어서
--  반드시 이렇게 만료되는 임시 코드를 씁니다.)
create table if not exists qr_tokens (
  token      text primary key,
  user_id    uuid not null references profiles(id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists qr_tokens_user_idx on qr_tokens (user_id);
alter table qr_tokens enable row level security;    -- 앱에서 직접 읽고 쓸 수 없음 (함수로만)

create or replace function public.my_qr_token()
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); tok text;
begin
  if me is null then raise exception 'not_logged_in'; end if;
  if not exists (select 1 from profiles where id = me and name is not null) then
    raise exception 'no_profile';
  end if;
  delete from qr_tokens where expires_at < now();                      -- 만료된 코드 청소
  delete from qr_tokens where token in (                              -- 내 코드는 최신 2개만 남기고 정리
    select token from qr_tokens where user_id = me order by expires_at desc offset 2);
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');   -- 추측 불가능한 긴 값
  insert into qr_tokens (token, user_id, expires_at) values (tok, me, now() + interval '90 seconds');
  return json_build_object('token', tok, 'ttl', 90);
end $$;

-- QR을 스캔해서 친구 추가: 코드가 유효하면 그 자리에서 서로 친구가 됨
create or replace function public.add_friend_by_qr(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); owner uuid; a uuid; b uuid; info json; was boolean;
begin
  if me is null then raise exception 'not_logged_in'; end if;
  if not exists (select 1 from profiles where id = me and name is not null) then
    raise exception 'no_profile';
  end if;
  select user_id into owner from qr_tokens where token = p_token and expires_at > now();
  if owner is null then raise exception 'invalid_or_expired'; end if;
  if owner = me then raise exception 'own_qr'; end if;

  select json_build_object('id', p.id, 'name', p.name, 'cohort', p.cohort,
                           'interests', p.interests, 'color', p.color)
    into info from profiles p where p.id = owner and p.name is not null;
  if info is null then raise exception 'invalid_or_expired'; end if;

  a := least(me, owner); b := greatest(me, owner);
  was := exists (select 1 from friendships where user_a = a and user_b = b);
  if not was then
    -- 스캔한 쪽은 바로 본 것으로, QR을 보여준 쪽은 "새 친구" 알림이 뜨도록 처리
    insert into friendships (user_a, user_b, a_seen, b_seen) values (a, b, a = me, b = me);
    delete from connections
      where (from_id = me and to_id = owner) or (from_id = owner and to_id = me);  -- 예전 연결 요청 정리
  end if;
  return json_build_object('status', case when was then 'already' else 'added' end, 'friend', info);
end $$;

revoke all on function public.my_qr_token()              from public, anon;
revoke all on function public.add_friend_by_qr(text)     from public, anon;
grant execute on function public.my_qr_token()           to authenticated;
grant execute on function public.add_friend_by_qr(text)  to authenticated;
