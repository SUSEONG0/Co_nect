-- =====================================================================
-- 누가 내 프로필을 확인하면, 내 알림(벨)에 "누군가 내 프로필을 확인했어요"가 남아요.
-- 13-profile-card.sql 실행 후, Supabase SQL Editor에서 이 파일 전체를 한 번에 실행하세요.
-- (여러 번 실행해도 안전합니다)
--
-- 만들어지는 것
--   표   profile_views          누가 누구의 프로필을 어느 날 봤는지 (같은 사람이 같은 날 한 번만 기록)
--   함수 profile_card           (다시 만듦) 프로필을 내려주면서 '봤다'는 기록도 남겨요
--   함수 profile_views_inbox    내 프로필을 본 새 기록의 '수'만 가져가고 읽음 처리
--
-- 개인정보
--   - 누가 봤는지는 상대에게 전달되지 않아요. 알림에는 사람 수만 나와요. ("누군가")
--   - 표는 앱이 직접 읽지 못해요. 서버 함수로만 접근해요.
--   - 내 프로필을 내가 본 것은 기록하지 않아요.
-- =====================================================================

create table if not exists profile_views (
  viewer_id  uuid not null references profiles(id) on delete cascade,
  target_id  uuid not null references profiles(id) on delete cascade,
  day        date not null,
  created_at timestamptz not null default now(),
  seen       boolean not null default false,
  primary key (viewer_id, target_id, day),
  check (viewer_id <> target_id)
);

create index if not exists profile_views_target_idx on profile_views (target_id, seen);

alter table profile_views enable row level security;
revoke all on table profile_views from anon, authenticated;

-- ---------------------------------------------------------------------
-- 프로필 카드 (13번의 것을 다시 만들어요). 다른 사람의 프로필이면 '봤다'를 기록해요.
-- 같은 사람이 같은 날 같은 프로필을 여러 번 봐도 기록은 한 번만 남아요.
-- ---------------------------------------------------------------------
create or replace function public.profile_card(p_id uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  r     record;
begin
  if me is null then raise exception 'not signed in'; end if;

  select id, name, cohort, interests, color, bio
    into r
    from profiles
   where id = p_id and name is not null;

  if not found then return null; end if;

  if p_id <> me then
    insert into profile_views (viewer_id, target_id, day) values (me, p_id, today)
    on conflict (viewer_id, target_id, day) do nothing;
  end if;

  return json_build_object(
    'id',        r.id,
    'name',      r.name,
    'cohort',    r.cohort,
    'interests', r.interests,
    'color',     r.color,
    'bio',       r.bio,
    'friend',    exists (select 1 from friendships f
                         where (f.user_a = me and f.user_b = p_id) or (f.user_a = p_id and f.user_b = me))
  );
end $$;

-- ---------------------------------------------------------------------
-- 내 프로필을 본 새 기록의 수. 한 번 가져가면 읽음 처리돼서 다시 내려가지 않아요.
-- ---------------------------------------------------------------------
create or replace function public.profile_views_inbox()
returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n  int;
begin
  if me is null then raise exception 'not signed in'; end if;

  with got as (
    update profile_views set seen = true
    where target_id = me and seen = false
    returning 1
  )
  select count(*) into n from got;

  return json_build_object('count', n);
end $$;

revoke all on function public.profile_card(uuid)      from public, anon;
revoke all on function public.profile_views_inbox()   from public, anon;
grant execute on function public.profile_card(uuid)    to authenticated;
grant execute on function public.profile_views_inbox() to authenticated;

-- =====================================================================
-- 테스트 기록을 지우려면:
--   delete from profile_views;
-- =====================================================================
