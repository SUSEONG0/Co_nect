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
