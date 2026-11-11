-- =====================================================================
-- 프로필 편집의 "소개": 내 소개 한 줄(최대 100자). 기본은 비어 있어요.
-- Supabase SQL Editor에서 이 파일 전체를 한 번에 실행하세요. (여러 번 실행해도 안전합니다)
--
-- 만들어지는 것
--   profiles.bio 칸 (비어 있으면 null)
--   내 프로필에서 bio 를 저장할 수 있는 권한 (다른 사람 것은 못 바꿔요: 기존 규칙 그대로)
-- =====================================================================

alter table profiles add column if not exists bio text;

-- 너무 긴 글을 막아요. (앱에서도 100자까지만 입력돼요)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_len') then
    alter table profiles add constraint profiles_bio_len check (bio is null or char_length(bio) <= 100);
  end if;
end $$;

-- 프로필 저장은 upsert 라서 insert / update 권한이 둘 다 필요해요.
grant insert (bio), update (bio) on profiles to authenticated;
