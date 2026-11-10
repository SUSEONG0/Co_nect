-- 02-connections.sql 을 이미 실행한 경우, 아래만 실행해도 됩니다. (빠졌던 권한 수정 + 티켓 5장)
grant update (id, name, cohort, interests, color) on profiles to authenticated;
alter table profiles alter column tickets set default 5;
update profiles set tickets = 5 where tickets = 2;
