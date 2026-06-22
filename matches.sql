-- ============================================================================
-- COLOSSO — Match history
-- Run in Supabase SQL Editor AFTER glr-xp.sql. Safe to re-run.
--
-- Adds a `matches` table (per-player record of finished games) and upgrades
-- finish_match() to also write a history row. The old 2-arg finish_match is
-- dropped and replaced by a 4-arg version (opponent + map are optional).
-- ============================================================================

create table if not exists matches (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references profiles(id) on delete cascade,
  lobby_id    uuid references lobbies(id) on delete set null,
  won         boolean,
  glr_delta   int,
  map         text,
  opponent    text,
  score       text,
  kind        text default 'Scrim',          -- Scrim | Torneio | Quick
  created_at  timestamptz default now()
);
create index if not exists matches_user_idx on matches(user_id, created_at desc);

alter table matches enable row level security;
drop policy if exists p_matches_read on matches;
create policy p_matches_read on matches for select using (user_id = auth.uid());
-- inserts happen inside finish_match (security definer); allow self-insert too
drop policy if exists p_matches_ins on matches;
create policy p_matches_ins on matches for insert with check (user_id = auth.uid());

-- ---------- replace finish_match with a version that records history ----------
drop function if exists finish_match(boolean, uuid);
drop function if exists finish_match(boolean, uuid, text, text);

create or replace function finish_match(
  p_won boolean default true,
  p_lobby uuid default null,
  p_opponent text default null,
  p_map text default null
)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
declare d_glr int; d_xp int; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_won then d_glr := 25; d_xp := 12; else d_glr := -15; d_xp := 5; end if;

  if p_lobby is not null then
    update lobbies set status = 'done' where id = p_lobby and status <> 'done';
  end if;

  insert into matches(user_id, lobby_id, won, glr_delta, map, opponent, kind)
  values (uid, p_lobby, p_won, d_glr, p_map, p_opponent, 'Scrim');

  insert into notifications(user_id, type, data)
  values (uid, 'match', jsonb_build_object('result', case when p_won then 'win' else 'loss' end, 'glr', d_glr, 'opp', p_opponent));

  return query select * from _award(uid, d_glr, d_xp);
end $$;

grant execute on function finish_match(boolean, uuid, text, text) to authenticated;
