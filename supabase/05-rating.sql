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
