-- ============================================================================
-- COLOSSO — Matchmaking queue (used by the `matchmaking` Edge Function)
-- Run in Supabase SQL Editor (after schema.sql). Safe to re-run.
-- The Edge Function pairs players using the service-role key (bypasses RLS);
-- these RLS policies just let each player read/cancel their own queue row.
-- ============================================================================

create table if not exists matchmaking_queue (
  user_id     uuid primary key references profiles(id) on delete cascade,
  game        game_t default 'free_fire',
  format      text   default 'Squad (4)',
  server      text   default 'BR · São Paulo',
  rank        text   default 'Diamante',
  status      text   default 'waiting',   -- waiting | matched
  lobby_id    uuid references lobbies(id) on delete set null,
  opponent_id uuid references profiles(id) on delete set null,
  enqueued_at timestamptz default now()
);
create index if not exists mmq_wait_idx on matchmaking_queue(game, status, enqueued_at);

alter table matchmaking_queue enable row level security;

drop policy if exists p_mmq_read on matchmaking_queue;
create policy p_mmq_read on matchmaking_queue for select using (user_id = auth.uid());
drop policy if exists p_mmq_ins on matchmaking_queue;
create policy p_mmq_ins  on matchmaking_queue for insert with check (user_id = auth.uid());
drop policy if exists p_mmq_upd on matchmaking_queue;
create policy p_mmq_upd  on matchmaking_queue for update using (user_id = auth.uid());
drop policy if exists p_mmq_del on matchmaking_queue;
create policy p_mmq_del  on matchmaking_queue for delete using (user_id = auth.uid());

-- expose to realtime so a waiting client can react the moment it gets matched
do $$ begin
  alter publication supabase_realtime add table matchmaking_queue;
  exception when duplicate_object then null; end $$;
