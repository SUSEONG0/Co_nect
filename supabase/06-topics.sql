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
