-- Kizuna — Supabase schema (§4.7: single schema, SQLite locally = Postgres here).
-- Run once in the Supabase dashboard → SQL Editor (or `supabase db push`).
--
-- Mirrors the five tables SupabaseSyncService syncs, plus a `user_id` owner column
-- on each row. Every table is RLS-scoped so a user can only ever touch their own
-- rows; the client's full-table pulls rely on that scoping instead of filtering.
-- Primary keys include user_id so one user's ids can never collide with another's.
--
-- Timestamps are timestamptz; the client encodes/decodes ISO-8601 (SyncKit
-- PostgRESTCoding), which PostgREST accepts and emits natively.

-- ── skill_state: FSRS memory state per (item, dimension). Last-write-wins by
--    last_review on the client; the server just stores the latest upsert.
create table if not exists public.skill_state (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  item_id     text not null,
  dimension   text not null,
  stability   double precision,
  difficulty  double precision,
  due         timestamptz,
  last_review timestamptz,
  reps        integer not null default 0,
  lapses      integer not null default 0,
  suspended   boolean not null default false,
  primary key (user_id, item_id, dimension)
);

-- ── review_event: append-only review log (merge by id, no conflicts).
create table if not exists public.review_event (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id         text not null,
  item_id    text not null,
  dimension  text not null,
  grade      integer not null,
  mode_id    text,
  session_id text,
  latency_ms integer,
  at         timestamptz not null,
  primary key (user_id, id)
);

-- ── error_event: append-only error taxonomy log (R8).
create table if not exists public.error_event (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id         text not null,
  session_id text,
  item_id    text,
  category   text not null,
  surface    text,
  expected   text,
  severity   text,
  at         timestamptz not null,
  primary key (user_id, id)
);

-- ── session: one row per learning session (upserted; score is a JSON string).
create table if not exists public.session (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id          text not null,
  mode_id     text not null,
  scenario_id text,
  started_at  timestamptz not null,
  ended_at    timestamptz,
  status      text,
  score       text,
  cost_usd    double precision,
  pipeline    text,
  primary key (user_id, id)
);

-- ── transcript_turn: per-turn transcript (R12; director_json is a JSON string).
create table if not exists public.transcript_turn (
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  session_id    text not null,
  seq           integer not null,
  role          text not null,
  text          text,
  audio_ref     text,
  director_json text,
  at            timestamptz not null,
  primary key (user_id, session_id, seq)
);

-- ── Row-level security: every operation is scoped to the row owner. No anon access
--    (auth.uid() is null for anon, so these policies deny it implicitly).
alter table public.skill_state     enable row level security;
alter table public.review_event    enable row level security;
alter table public.error_event     enable row level security;
alter table public.session         enable row level security;
alter table public.transcript_turn enable row level security;

create policy "own rows" on public.skill_state
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rows" on public.review_event
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rows" on public.error_event
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rows" on public.session
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rows" on public.transcript_turn
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Hot-path indexes (mirror the local ones that matter server-side).
create index if not exists idx_skill_state_user_due on public.skill_state (user_id, due) where suspended = false;
create index if not exists idx_review_event_user_item on public.review_event (user_id, item_id, dimension);
create index if not exists idx_error_event_user_session on public.error_event (user_id, session_id);
create index if not exists idx_transcript_turn_user_session on public.transcript_turn (user_id, session_id);
