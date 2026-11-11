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
