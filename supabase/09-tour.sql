-- =====================================================================
-- 처음 사용 안내(튜토리얼)를 "계정별로 한 번만" 보여주기 위한 표시  (SQL Editor에서 실행)
-- 이 SQL을 실행하지 않아도 앱은 동작합니다. (그때는 이 기기에만 "봤음"이 저장됩니다)
-- =====================================================================
alter table profiles add column if not exists tour_done boolean not null default false;

-- 본인이 자기 "봤음" 표시만 바꿀 수 있게 허용 (티켓 등 다른 칸은 여전히 막혀 있음)
grant update (tour_done) on profiles to authenticated;
