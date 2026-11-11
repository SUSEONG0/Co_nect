-- =====================================================================
-- 탐색 탭에서 사람을 누르면 뜨는 "간단한 프로필 팝업"
-- 12-bio.sql 실행 후, Supabase SQL Editor에서 이 파일 전체를 한 번에 실행하세요.
-- (여러 번 실행해도 안전합니다)
--
-- 만들어지는 것
--   함수 profile_card(사람 id)   이름 / 기수 / 관심사 / 캐릭터 색 / 소개 / 나와 친구인지
--
-- 로그인한 사람만 실행할 수 있어요. 탐색 탭 목록에서 이미 보이는 정보(이름·기수·관심사)에
-- 소개 한 줄이 더해진 것만 내려가요. 연락처 같은 다른 정보는 내려가지 않아요.
-- =====================================================================

create or replace function public.profile_card(p_id uuid)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r  record;
begin
  if me is null then raise exception 'not signed in'; end if;

  select id, name, cohort, interests, color, bio
    into r
    from profiles
   where id = p_id and name is not null;

  if not found then return null; end if;

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

revoke all on function public.profile_card(uuid) from public, anon;
grant execute on function public.profile_card(uuid) to authenticated;
