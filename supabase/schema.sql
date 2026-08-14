-- ============================================================
--  AI 오피스 — 데이터베이스 설계도
--  Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 RUN
--  여러 번 실행해도 안전합니다 (if not exists / drop policy 사용)
-- ============================================================


-- ─────────────────────────────────────────────
-- 1. 표(테이블) 만들기
-- ─────────────────────────────────────────────

-- 회의실 하나 = rooms 한 줄
create table if not exists public.rooms (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '새 회의실',
  owner_id    uuid not null references auth.users(id) on delete cascade,
  mode        text not null default 'meeting',   -- meeting|pipeline|workspace|compare
  doc         text not null default '',          -- 공유 문서 내용
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 그 회의실에 초대된 사람들
create table if not exists public.room_members (
  room_id     uuid not null references public.rooms(id) on delete cascade,
  user_id     uuid not null references auth.users(id)  on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (room_id, user_id)
);

-- 대화 한 줄 = messages 한 줄
create table if not exists public.messages (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references public.rooms(id) on delete cascade,
  author_type  text not null,          -- 'user' | 'agent' | 'system'
  author_name  text not null default '',
  author_color text,
  tag          text,
  user_id      uuid references auth.users(id) on delete set null,
  content      text not null default '',
  created_at   timestamptz not null default now()
);

-- 그 회의실의 AI 참가자 설정
create table if not exists public.agents (
  id            uuid primary key default gen_random_uuid(),
  room_id       uuid not null references public.rooms(id) on delete cascade,
  name          text not null,
  provider      text not null,          -- claude | gpt | gemini
  model         text not null,
  system_prompt text not null default '',
  color         text not null default '#7b61ff',
  enabled       boolean not null default true,
  sort_order    int not null default 0
);

-- 조회 속도용 색인
create index if not exists messages_room_time_idx on public.messages (room_id, created_at);
create index if not exists agents_room_idx        on public.agents (room_id, sort_order);
create index if not exists members_user_idx       on public.room_members (user_id);


-- ─────────────────────────────────────────────
-- 2. 접근 권한 판정 함수
--    "이 사람이 이 회의실에 들어갈 자격이 있나?"
--    security definer 라서 아래 규칙들이 서로 물고 늘어지지 않습니다.
-- ─────────────────────────────────────────────

create or replace function public.can_access_room(p_room uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.rooms        r where r.id = p_room and r.owner_id = auth.uid())
      or exists (select 1 from public.room_members m where m.room_id = p_room and m.user_id = auth.uid());
$$;

revoke all on function public.can_access_room(uuid) from public;
grant execute on function public.can_access_room(uuid) to authenticated;


-- ─────────────────────────────────────────────
-- 3. RLS 켜기
--    이걸 켜면 기본이 "전부 차단" 이 되고,
--    아래에서 허용할 것만 하나씩 열어줍니다.
-- ─────────────────────────────────────────────

alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;
alter table public.agents       enable row level security;


-- ─────────────────────────────────────────────
-- 3-B. 표 접근 권한 부여 (GRANT)
--
--   RLS 와 GRANT 는 서로 다른 자물쇠입니다.
--     GRANT = "이 역할이 이 표를 건드릴 수 있나?"  (문 자체)
--     RLS   = "그중 어떤 줄을 볼 수 있나?"          (문 안의 칸막이)
--   둘 다 열려야 접근됩니다.
--
--   프로젝트 생성 시 'Automatically expose new tables' 를 껐다면
--   이 GRANT 가 자동으로 붙지 않아 42501 오류가 납니다. 그래서 직접 부여합니다.
--
--   ※ anon(비로그인) 에게는 아무 권한도 주지 않습니다 — 로그인한 사람만 사용.
-- ─────────────────────────────────────────────

grant usage on schema public to authenticated;

grant select, insert, update, delete on
  public.rooms,
  public.room_members,
  public.messages,
  public.agents
to authenticated;


-- ─────────────────────────────────────────────
-- 4. 허용 규칙
-- ─────────────────────────────────────────────

-- rooms ------------------------------------------------------
drop policy if exists rooms_select on public.rooms;
create policy rooms_select on public.rooms for select to authenticated
  using (owner_id = auth.uid() or public.can_access_room(id));

drop policy if exists rooms_insert on public.rooms;
create policy rooms_insert on public.rooms for insert to authenticated
  with check (owner_id = auth.uid());          -- 남의 이름으로 못 만듦

drop policy if exists rooms_update on public.rooms;
create policy rooms_update on public.rooms for update to authenticated
  using (public.can_access_room(id))           -- 참여자면 문서 수정 가능
  with check (owner_id = auth.uid() or public.can_access_room(id));

drop policy if exists rooms_delete on public.rooms;
create policy rooms_delete on public.rooms for delete to authenticated
  using (owner_id = auth.uid());               -- 삭제는 방장만

-- room_members -----------------------------------------------
drop policy if exists members_select on public.room_members;
create policy members_select on public.room_members for select to authenticated
  using (user_id = auth.uid() or public.can_access_room(room_id));

drop policy if exists members_insert on public.room_members;
create policy members_insert on public.room_members for insert to authenticated
  with check (exists (select 1 from public.rooms r
                      where r.id = room_id and r.owner_id = auth.uid()));

drop policy if exists members_delete on public.room_members;
create policy members_delete on public.room_members for delete to authenticated
  using (user_id = auth.uid()                  -- 스스로 나가기
      or exists (select 1 from public.rooms r
                 where r.id = room_id and r.owner_id = auth.uid()));

-- messages ---------------------------------------------------
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.can_access_room(room_id));

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (public.can_access_room(room_id));

drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages for update to authenticated
  using (public.can_access_room(room_id));     -- AI 답변 스트리밍 중 갱신

drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages for delete to authenticated
  using (exists (select 1 from public.rooms r
                 where r.id = room_id and r.owner_id = auth.uid()));

-- agents -----------------------------------------------------
drop policy if exists agents_all on public.agents;
create policy agents_all on public.agents for all to authenticated
  using (public.can_access_room(room_id))
  with check (public.can_access_room(room_id));


-- ─────────────────────────────────────────────
-- 4-B. 최소 권한 보강 — 방의 중요 필드 잠그기
--
--   rooms_update 정책은 "참여자도 방을 수정할 수 있다"로 열려 있습니다.
--   공유 문서(doc)를 함께 편집하기 위해 필요한 권한입니다.
--   그런데 그대로 두면 참여자가 방 이름·모드까지 바꿀 수 있습니다.
--
--   RLS 정책은 '어떤 줄'만 가릴 뿐 '어떤 칸'은 못 가립니다.
--   그래서 트리거로 칸 단위 제한을 겁니다.
--
--     방장   → 전부 수정 가능
--     참여자 → doc / updated_at 만 수정 가능
-- ─────────────────────────────────────────────

create or replace function public.rooms_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 방장은 제한 없음
  if old.owner_id = auth.uid() then
    return new;
  end if;

  -- 참여자: 보호 대상 칸이 바뀌면 거부
  if new.id         is distinct from old.id
  or new.owner_id   is distinct from old.owner_id
  or new.name       is distinct from old.name
  or new.mode       is distinct from old.mode
  or new.created_at is distinct from old.created_at then
    raise exception '방 이름·모드·소유자는 방장만 변경할 수 있습니다.'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function public.rooms_guard() from public;

drop trigger if exists rooms_guard_trg on public.rooms;
create trigger rooms_guard_trg
  before update on public.rooms
  for each row execute function public.rooms_guard();


-- ─────────────────────────────────────────────
-- 5. 실시간(Realtime) 켜기
--    다른 사람 화면에 즉시 반영되게 합니다.
-- ─────────────────────────────────────────────

alter table public.messages replica identity full;
alter table public.rooms    replica identity full;

do $$
begin
  begin execute 'alter publication supabase_realtime add table public.messages'; exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.rooms';    exception when duplicate_object then null; end;
end $$;


-- ─────────────────────────────────────────────
-- 6. 확인
-- ─────────────────────────────────────────────

-- (1) RLS 가 켜졌는지 + 권한이 붙었는지
select
  t.tablename                                   as "표",
  t.rowsecurity                                 as "RLS 켜짐",
  has_table_privilege('authenticated', 'public.'||t.tablename, 'SELECT') as "읽기 권한",
  has_table_privilege('authenticated', 'public.'||t.tablename, 'INSERT') as "쓰기 권한"
from pg_tables t
where t.schemaname = 'public'
  and t.tablename in ('rooms','room_members','messages','agents')
order by t.tablename;
-- ↑ 4줄 모두 true / true / true 여야 정상입니다.

-- (2) 보호 트리거가 걸렸는지
select tgname as "트리거", tgenabled as "활성"
from pg_trigger
where tgrelid = 'public.rooms'::regclass
  and not tgisinternal;
-- ↑ rooms_guard_trg / O 로 나와야 정상입니다.
