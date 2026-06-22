-- ============================================================================
-- COLOSSO — FULL migration (all backend SQL in dependency order). Idempotent.
-- Paste into Supabase → SQL Editor → Run.  Generated 2026-06-22T13:03Z.
-- ============================================================================

-- ███  schema.sql

-- ============================================================================
-- COLOSSO — Supabase schema (PostgreSQL)
-- Run in Supabase: SQL Editor → paste → Run.  Safe to re-run (idempotent-ish).
-- Auth: Supabase Auth with Discord provider (auth.users is managed by Supabase).
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------- enums ----------
do $$ begin
  create type game_t       as enum ('free_fire','mobile_legends','wild_rift','pubg_mobile','r6_mobile');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type scrim_status as enum ('open','scheduled','played','cancelled');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type trn_status   as enum ('draft','reg_open','live','finished','soon');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type reg_status   as enum ('pending','confirmed','rejected');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type lobby_status as enum ('veto','ready','live','done');
  exception when duplicate_object then null; end $$;

-- ============================================================================
-- PROFILES (1-1 with auth.users)
-- ============================================================================
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  handle      text unique not null,
  nick        text not null,
  avatar_url  text,
  game        game_t default 'free_fire',
  region      text   default 'BR',
  role        text   default 'Flex',
  langs       text   default 'PT',
  bio         text   default '',
  rank        text   default 'Diamante',
  glr         int    default 1500,          -- Glória Rating (was "ELO")
  trust       int    default 100,
  level       int    default 1,
  xp          int    default 0,
  season      text   default 'Season 1',
  verified    boolean default false,
  onboarded   boolean default false,
  created_at  timestamptz default now()
);

-- auto-create a profile row when a user signs up (pull nick/avatar from Discord metadata)
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare base_handle text;
begin
  base_handle := lower(regexp_replace(
    coalesce(new.raw_user_meta_data->>'global_name',
             new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name',
             split_part(new.email,'@',1),
             'player'), '[^a-z0-9_]','','g'));
  if base_handle = '' then base_handle := 'player'; end if;
  -- ensure uniqueness
  if exists(select 1 from profiles where handle = base_handle) then
    base_handle := base_handle || substr(new.id::text,1,4);
  end if;
  insert into profiles (id, handle, nick, avatar_url)
  values (new.id, base_handle,
          coalesce(new.raw_user_meta_data->>'global_name', new.raw_user_meta_data->>'name', base_handle),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ============================================================================
-- TEAMS
-- ============================================================================
create table if not exists teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text unique,
  owner_id    uuid not null references profiles(id) on delete cascade,
  game        game_t default 'free_fire',
  region      text   default 'BR',
  rank        text   default 'Diamante',
  glr         int    default 1500,
  wins        int    default 0,
  losses      int    default 0,
  recruiting  boolean default false,
  open_roles  text[] default '{}',
  crest_color text   default '#ff5a2c',
  created_at  timestamptz default now()
);

create table if not exists team_members (
  team_id    uuid references teams(id) on delete cascade,
  profile_id uuid references profiles(id) on delete cascade,
  role       text default 'Flex',
  is_captain boolean default false,
  joined_at  timestamptz default now(),
  primary key (team_id, profile_id)
);

create table if not exists team_applications (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid references teams(id) on delete cascade,
  applicant_id uuid references profiles(id) on delete cascade,
  message     text,
  status      reg_status default 'pending',
  created_at  timestamptz default now(),
  unique (team_id, applicant_id)
);

-- ============================================================================
-- SCRIMS / PRACCS
-- ============================================================================
create table if not exists scrims (
  id          uuid primary key default gen_random_uuid(),
  creator_id  uuid not null references profiles(id) on delete cascade,
  team_id     uuid references teams(id) on delete set null,
  game        game_t default 'free_fire',
  format      text default 'Squad (4)',
  server      text default 'BR · São Paulo',
  rank        text default 'Diamante',
  scheduled_at timestamptz,                 -- null = "agora/open"
  note        text default '',
  status      scrim_status default 'open',
  created_at  timestamptz default now()
);

create table if not exists scrim_responses (
  id          uuid primary key default gen_random_uuid(),
  scrim_id    uuid references scrims(id) on delete cascade,
  responder_id uuid references profiles(id) on delete cascade,
  responder_team_id uuid references teams(id) on delete set null,
  status      reg_status default 'pending',
  created_at  timestamptz default now()
);

-- match lobby (map veto + ready-up), created when a scrim is accepted
create table if not exists lobbies (
  id          uuid primary key default gen_random_uuid(),
  scrim_id    uuid references scrims(id) on delete cascade,
  map_pool    text[] default array['Bermuda','Kalahari','Purgatório','Alpine','Nexterra'],
  bans        jsonb  default '[]'::jsonb,   -- [{map, by_team_id}]
  decider     text,
  server      text default 'BR · São Paulo',
  password    text,
  status      lobby_status default 'veto',
  created_at  timestamptz default now()
);

-- ============================================================================
-- TOURNAMENTS
-- ============================================================================
create table if not exists tournaments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  organizer_id uuid not null references profiles(id) on delete cascade,
  space_id    uuid,                         -- optional: belongs to an organizer space
  game        game_t default 'free_fire',
  format      text default 'Elim. simples · MD3',
  slots       int default 16,
  prize       numeric default 0,
  currency    text default 'BRL',
  buy_in      numeric default 0,
  starts_at   timestamptz,
  status      trn_status default 'reg_open',
  bracket     jsonb default '[]'::jsonb,
  created_at  timestamptz default now()
);

create table if not exists tournament_registrations (
  tournament_id uuid references tournaments(id) on delete cascade,
  team_id       uuid references teams(id) on delete cascade,
  status        reg_status default 'confirmed',
  seed          int,
  registered_by uuid references profiles(id) on delete set null,
  registered_at timestamptz default now(),
  primary key (tournament_id, team_id)
);

-- ============================================================================
-- ORGANIZER SPACES (branded pages)
-- ============================================================================
create table if not exists spaces (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profiles(id) on delete cascade,
  name        text not null,
  slug        text unique,
  game        game_t default 'free_fire',
  region      text default 'BR',
  format      text,
  currency    text default 'BRL',
  prize       text,
  buy_in      text,
  description text,
  banner_color text default 'linear-gradient(135deg,#ff5a2c,#ff2d9b)',
  created_at  timestamptz default now()
);

-- ============================================================================
-- MESSAGING
-- ============================================================================
create table if not exists conversations (
  id          uuid primary key default gen_random_uuid(),
  type        text default 'dm',            -- dm | team | scrim
  name        text,
  ref_id      uuid,                          -- team_id / scrim_id when type != dm
  created_at  timestamptz default now()
);

create table if not exists conversation_members (
  conversation_id uuid references conversations(id) on delete cascade,
  profile_id      uuid references profiles(id) on delete cascade,
  last_read_at    timestamptz default now(),
  primary key (conversation_id, profile_id)
);

create table if not exists messages (
  id          uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  sender_id   uuid references profiles(id) on delete set null,
  body        text not null,
  created_at  timestamptz default now()
);
create index if not exists messages_conv_idx on messages(conversation_id, created_at);

-- ============================================================================
-- NOTIFICATIONS
-- ============================================================================
create table if not exists notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references profiles(id) on delete cascade,
  type        text not null,                -- invite | application | match | tournament | system
  data        jsonb default '{}'::jsonb,
  read        boolean default false,
  created_at  timestamptz default now()
);
create index if not exists notifications_user_idx on notifications(user_id, read, created_at desc);

-- ============================================================================
-- HELPER: is the current user a member of a conversation / team
-- ============================================================================
create or replace function is_conv_member(conv uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from conversation_members where conversation_id=conv and profile_id=auth.uid());
$$;
create or replace function is_team_owner(t uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from teams where id=t and owner_id=auth.uid());
$$;

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table profiles                 enable row level security;
alter table teams                     enable row level security;
alter table team_members              enable row level security;
alter table team_applications         enable row level security;
alter table scrims                    enable row level security;
alter table scrim_responses           enable row level security;
alter table lobbies                   enable row level security;
alter table tournaments               enable row level security;
alter table tournament_registrations  enable row level security;
alter table spaces                    enable row level security;
alter table conversations             enable row level security;
alter table conversation_members      enable row level security;
alter table messages                  enable row level security;
alter table notifications             enable row level security;

-- profiles: everyone can read; only you can edit yours
drop policy if exists p_profiles_read on profiles;
create policy p_profiles_read on profiles for select using (true);
drop policy if exists p_profiles_upd on profiles;
create policy p_profiles_upd  on profiles for update using (id = auth.uid());

-- teams: public read; create when authed; edit by owner
drop policy if exists p_teams_read on teams;
create policy p_teams_read on teams for select using (true);
drop policy if exists p_teams_ins on teams;
create policy p_teams_ins  on teams for insert with check (owner_id = auth.uid());
drop policy if exists p_teams_upd on teams;
create policy p_teams_upd  on teams for update using (owner_id = auth.uid());
drop policy if exists p_teams_del on teams;
create policy p_teams_del  on teams for delete using (owner_id = auth.uid());

-- team_members: public read; manage by team owner or self-leave
drop policy if exists p_tm_read on team_members;
create policy p_tm_read on team_members for select using (true);
drop policy if exists p_tm_ins on team_members;
create policy p_tm_ins  on team_members for insert with check (is_team_owner(team_id) or profile_id = auth.uid());
drop policy if exists p_tm_del on team_members;
create policy p_tm_del  on team_members for delete using (is_team_owner(team_id) or profile_id = auth.uid());

-- team_applications: applicant creates; team owner & applicant can read; owner updates status
drop policy if exists p_ta_read on team_applications;
create policy p_ta_read on team_applications for select using (applicant_id = auth.uid() or is_team_owner(team_id));
drop policy if exists p_ta_ins on team_applications;
create policy p_ta_ins  on team_applications for insert with check (applicant_id = auth.uid());
drop policy if exists p_ta_upd on team_applications;
create policy p_ta_upd  on team_applications for update using (is_team_owner(team_id));

-- scrims: public read; create when authed; edit by creator
drop policy if exists p_scr_read on scrims;
create policy p_scr_read on scrims for select using (true);
drop policy if exists p_scr_ins on scrims;
create policy p_scr_ins  on scrims for insert with check (creator_id = auth.uid());
drop policy if exists p_scr_upd on scrims;
create policy p_scr_upd  on scrims for update using (creator_id = auth.uid());
drop policy if exists p_scr_del on scrims;
create policy p_scr_del  on scrims for delete using (creator_id = auth.uid());

-- scrim_responses: responder creates; scrim creator & responder read
drop policy if exists p_sr_read on scrim_responses;
create policy p_sr_read on scrim_responses for select using (
  responder_id = auth.uid() or exists(select 1 from scrims s where s.id=scrim_id and s.creator_id=auth.uid()));
drop policy if exists p_sr_ins on scrim_responses;
create policy p_sr_ins  on scrim_responses for insert with check (responder_id = auth.uid());

-- lobbies: readable/updatable by either side of the scrim
drop policy if exists p_lob_read on lobbies;
create policy p_lob_read on lobbies for select using (true);
drop policy if exists p_lob_ins on lobbies;
create policy p_lob_ins  on lobbies for insert with check (auth.uid() is not null);
drop policy if exists p_lob_upd on lobbies;
create policy p_lob_upd  on lobbies for update using (auth.uid() is not null);

-- tournaments: public read; create when authed; edit by organizer
drop policy if exists p_trn_read on tournaments;
create policy p_trn_read on tournaments for select using (true);
drop policy if exists p_trn_ins on tournaments;
create policy p_trn_ins  on tournaments for insert with check (organizer_id = auth.uid());
drop policy if exists p_trn_upd on tournaments;
create policy p_trn_upd  on tournaments for update using (organizer_id = auth.uid());

-- registrations: public read; team owner registers their team
drop policy if exists p_treg_read on tournament_registrations;
create policy p_treg_read on tournament_registrations for select using (true);
drop policy if exists p_treg_ins on tournament_registrations;
create policy p_treg_ins  on tournament_registrations for insert with check (is_team_owner(team_id));
drop policy if exists p_treg_del on tournament_registrations;
create policy p_treg_del  on tournament_registrations for delete using (is_team_owner(team_id));

-- spaces: public read; owner manages
drop policy if exists p_sp_read on spaces;
create policy p_sp_read on spaces for select using (true);
drop policy if exists p_sp_ins on spaces;
create policy p_sp_ins  on spaces for insert with check (owner_id = auth.uid());
drop policy if exists p_sp_upd on spaces;
create policy p_sp_upd  on spaces for update using (owner_id = auth.uid());

-- messaging: only members can read/post
drop policy if exists p_conv_read on conversations;
create policy p_conv_read on conversations for select using (is_conv_member(id));
drop policy if exists p_conv_ins on conversations;
create policy p_conv_ins  on conversations for insert with check (auth.uid() is not null);
drop policy if exists p_cm_read on conversation_members;
create policy p_cm_read on conversation_members for select using (profile_id = auth.uid() or is_conv_member(conversation_id));
drop policy if exists p_cm_ins on conversation_members;
create policy p_cm_ins  on conversation_members for insert with check (auth.uid() is not null);
drop policy if exists p_msg_read on messages;
create policy p_msg_read on messages for select using (is_conv_member(conversation_id));
drop policy if exists p_msg_ins on messages;
create policy p_msg_ins  on messages for insert with check (sender_id = auth.uid() and is_conv_member(conversation_id));

-- notifications: only the recipient
drop policy if exists p_ntf_read on notifications;
create policy p_ntf_read on notifications for select using (user_id = auth.uid());
drop policy if exists p_ntf_upd on notifications;
create policy p_ntf_upd  on notifications for update using (user_id = auth.uid());
drop policy if exists p_ntf_ins on notifications;
create policy p_ntf_ins  on notifications for insert with check (true); -- allow server/triggers to insert

-- ============================================================================
-- REALTIME: expose messages, lobbies, notifications to Realtime
-- ============================================================================
do $$ begin
  alter publication supabase_realtime add table messages;
  exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table lobbies;
  exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table notifications;
  exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table scrim_responses;
  exception when duplicate_object then null; end $$;

-- ============================================================================
-- STORAGE: avatars bucket (run once; or create in dashboard → Storage)
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('avatars','avatars', true)
on conflict (id) do nothing;

drop policy if exists p_av_read on storage.objects;
create policy p_av_read on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists p_av_write on storage.objects;
create policy p_av_write on storage.objects for insert
  with check (bucket_id = 'avatars' and auth.uid() is not null);
drop policy if exists p_av_update on storage.objects;
create policy p_av_update on storage.objects for update
  using (bucket_id = 'avatars' and owner = auth.uid());


-- ███  glr-xp.sql

-- ============================================================================
-- COLOSSO — GLR / XP awarding after matches
-- Run in Supabase SQL Editor (after schema.sql). Safe to re-run.
--
-- Two ways a match awards points:
--   A) RPC finish_match(p_won) — the client calls it when a lobby finishes.
--   B) Trigger on lobbies — when status flips to 'done', auto-award participants.
-- Both go through the same internal helper so the rules stay in one place.
-- ============================================================================

-- ---------- internal: apply GLR + XP (rolls level every 100 XP) ----------
create or replace function _award(p_user uuid, p_glr int, p_xp int)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
declare new_xp int; new_level int; cur_level int;
begin
  if p_user is null then return; end if;
  select level into cur_level from profiles where id = p_user;
  cur_level := coalesce(cur_level, 1);

  update profiles
     set glr = greatest(0, glr + p_glr),
         xp  = xp + greatest(0, p_xp)
   where id = p_user
   returning xp, level into new_xp, new_level;

  -- roll levels: every 100 XP = +1 level
  while new_xp >= 100 loop
    new_xp := new_xp - 100;
    new_level := new_level + 1;
  end loop;

  update profiles set xp = new_xp, level = new_level where id = p_user
    returning glr, xp, level into glr, xp, level;

  -- notify on level-up
  if new_level > cur_level then
    insert into notifications(user_id, type, data)
    values (p_user, 'system', jsonb_build_object('event','levelup','level',new_level));
  end if;
  return next;
end $$;

-- ---------- A) RPC the client calls when a match ends ----------
-- win:  +25 GLR, +12 XP     loss: -15 GLR, +5 XP
create or replace function finish_match(p_won boolean default true, p_lobby uuid default null)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
declare d_glr int; d_xp int; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_won then d_glr := 25; d_xp := 12; else d_glr := -15; d_xp := 5; end if;

  if p_lobby is not null then
    update lobbies set status = 'done' where id = p_lobby and status <> 'done';
  end if;

  insert into notifications(user_id, type, data)
  values (uid, 'match', jsonb_build_object('result', case when p_won then 'win' else 'loss' end, 'glr', d_glr));

  return query select * from _award(uid, d_glr, d_xp);
end $$;

grant execute on function finish_match(boolean, uuid) to authenticated;

-- ---------- B) Trigger: when a lobby is marked 'done', award both sides ----------
-- Winner side gets the win reward, the other side the loss reward.
-- lobbies.result expected shape: {"winner_team_id": "...", "glr_win": 25, "glr_loss": -15}
alter table lobbies add column if not exists winner_team_id uuid;
alter table lobbies add column if not exists result jsonb default '{}'::jsonb;

create or replace function on_lobby_done()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  s record; win_team uuid := new.winner_team_id;
  rec record;
begin
  if new.status = 'done' and (old.status is distinct from 'done') then
    select * into s from scrims where id = new.scrim_id;
    if s.id is null then return new; end if;

    -- creator side
    perform _award(s.creator_id,
      case when win_team is not null and s.team_id = win_team then 25 else -15 end,
      case when win_team is not null and s.team_id = win_team then 12 else 5 end);

    -- responders side
    for rec in select responder_id, responder_team_id from scrim_responses where scrim_id = s.id and status = 'confirmed' loop
      perform _award(rec.responder_id,
        case when win_team is not null and rec.responder_team_id = win_team then 25 else -15 end,
        case when win_team is not null and rec.responder_team_id = win_team then 12 else 5 end);
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists trg_lobby_done on lobbies;
create trigger trg_lobby_done
  after update on lobbies
  for each row execute function on_lobby_done();


-- ███  matchmaking.sql

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


-- ███  bracket.sql

-- ============================================================================
-- COLOSSO — Tournament bracket seeding
-- Run in Supabase SQL Editor (after schema.sql). Safe to re-run.
--
-- seed_bracket(p_tournament) — organizer-only. Reads registered teams, assigns
-- seeds, builds a single-elimination bracket (padded to a power of two with BYEs),
-- writes it to tournaments.bracket and flips status to 'live'. Returns the bracket.
--
-- Bracket shape (matches the prototype's renderer):
--   [ { "name": "Quartas", "m": [ ["LOUD","—","Fluxo","—"], ... ] }, ... ]
-- ============================================================================

create or replace function _round_name(teams int)
returns text language sql immutable as $$
  select case teams
    when 2  then 'Final'
    when 4  then 'Semis'
    when 8  then 'Quartas'
    when 16 then 'Oitavas'
    when 32 then '1/16'
    else 'Rodada de ' || teams end;
$$;

create or replace function seed_bracket(p_tournament uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  org uuid; names text[]; n int; size int; entering int; i int; r int := 0;
  matches jsonb; rounds jsonb := '[]'::jsonb;
begin
  select organizer_id into org from tournaments where id = p_tournament;
  if org is null then raise exception 'tournament not found'; end if;
  if org <> auth.uid() then raise exception 'only the organizer can seed this tournament'; end if;

  -- assign seeds (random draw) to confirmed registrations
  with ord as (
    select team_id, row_number() over (order by random()) rn
    from tournament_registrations
    where tournament_id = p_tournament
  )
  update tournament_registrations t
     set seed = ord.rn
    from ord
   where t.tournament_id = p_tournament and t.team_id = ord.team_id;

  -- team names in seed order
  select array_agg(tm.name order by tr.seed)
    into names
    from tournament_registrations tr
    join teams tm on tm.id = tr.team_id
   where tr.tournament_id = p_tournament;

  n := coalesce(array_length(names, 1), 0);
  if n < 2 then raise exception 'need at least 2 registered teams to seed (have %)', n; end if;

  -- next power of two, pad with BYE
  size := 2;
  while size < n loop size := size * 2; end loop;
  for i in (n + 1)..size loop names := array_append(names, 'BYE'); end loop;

  -- build rounds: round 0 has real names, later rounds are TBD placeholders
  entering := size;
  while entering >= 2 loop
    matches := '[]'::jsonb;
    if r = 0 then
      i := 1;
      while i <= size loop
        matches := matches || jsonb_build_array(jsonb_build_array(names[i], '—', names[i + 1], '—'));
        i := i + 2;
      end loop;
    else
      for i in 1..(entering / 2) loop
        matches := matches || jsonb_build_array(jsonb_build_array('TBD', '—', 'TBD', '—'));
      end loop;
    end if;
    rounds := rounds || jsonb_build_array(jsonb_build_object('name', _round_name(entering), 'm', matches));
    entering := entering / 2; r := r + 1;
  end loop;

  update tournaments set bracket = rounds, status = 'live' where id = p_tournament;
  return rounds;
end $$;

grant execute on function seed_bracket(uuid) to authenticated;


-- ███  matches.sql

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


-- ███  team-language.sql

-- ============================================================================
-- COLOSSO — Team language  (run anytime after schema.sql; safe to re-run)
--
-- Teams get a PRIMARY comms language (required) + an optional SECONDARY one.
-- This is a soft signal: it powers LFG/recruitment filtering and the team card,
-- but does NOT restrict who can play whom. Scrims and tournaments stay
-- cross-language by design — opponents barely talk, and chat is auto-translated.
-- ============================================================================
alter table teams add column if not exists lang  text default 'PT';   -- primary comms language
alter table teams add column if not exists lang2 text;                 -- optional secondary (nullable)

create index if not exists teams_lang_idx on teams(lang);


-- ███  security-hardening.sql

-- ============================================================================
-- COLOSSO — Security hardening (RUN LAST, after all other .sql files)
-- Fixes from the RLS audit. Safe to re-run. None of these break app features
-- (invites, team responses, both-sides lobby veto, matchmaking, GLR/XP).
-- ============================================================================

-- ---- 1. Lobbies: only the two sides of the scrim can read/update -----------
-- (was: anyone authenticated — let outsiders rewrite bans/winner & read passwords)
drop policy if exists p_lob_read on lobbies;
create policy p_lob_read on lobbies for select using (
  exists (select 1 from scrims s where s.id = lobbies.scrim_id and s.creator_id = auth.uid())
  or exists (select 1 from scrim_responses r where r.scrim_id = lobbies.scrim_id and r.responder_id = auth.uid())
);
drop policy if exists p_lob_upd on lobbies;
create policy p_lob_upd on lobbies for update using (
  exists (select 1 from scrims s where s.id = lobbies.scrim_id and s.creator_id = auth.uid())
  or exists (select 1 from scrim_responses r where r.scrim_id = lobbies.scrim_id and r.responder_id = auth.uid())
);

-- ---- 2+3. finish_match: gate on participation, single award path ----------
-- (was: any user could self-award GLR/XP unboundedly; trigger double-awarded)
drop trigger if exists trg_lobby_done on lobbies;   -- finish_match is now the sole award path

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

  -- caller must be a participant of this lobby's scrim
  if p_lobby is null or not exists (
    select 1 from lobbies l join scrims s on s.id = l.scrim_id
    where l.id = p_lobby
      and ( s.creator_id = uid
            or exists (select 1 from scrim_responses r where r.scrim_id = s.id and r.responder_id = uid) )
  ) then raise exception 'not a participant of this match'; end if;

  -- idempotency: a finished lobby cannot be awarded again
  if exists (select 1 from lobbies where id = p_lobby and status = 'done') then
    raise exception 'match already finished';
  end if;

  if p_won then d_glr := 25; d_xp := 12; else d_glr := -15; d_xp := 5; end if;

  update lobbies set status = 'done' where id = p_lobby;
  insert into matches(user_id, lobby_id, won, glr_delta, map, opponent, kind)
  values (uid, p_lobby, p_won, d_glr, p_map, p_opponent, 'Scrim');
  insert into notifications(user_id, type, data)
  values (uid, 'match', jsonb_build_object('result', case when p_won then 'win' else 'loss' end, 'glr', d_glr, 'opp', p_opponent));

  return query select * from _award(uid, d_glr, d_xp);
end $$;
grant execute on function finish_match(boolean, uuid, text, text) to authenticated;

-- ---- 4. Notifications: clients may only insert invite/application ----------
-- (system/match/level-up come from SECURITY DEFINER fns, which bypass RLS)
drop policy if exists p_ntf_ins on notifications;
create policy p_ntf_ins on notifications for insert with check (type in ('invite','application'));

-- ---- 5. Matches: history is written only by finish_match (definer) ---------
drop policy if exists p_matches_ins on matches;

-- ---- 7. Team members: self-join only with an accepted application ----------
drop policy if exists p_tm_ins on team_members;
create policy p_tm_ins on team_members for insert with check (
  is_team_owner(team_id)
  or exists (select 1 from team_applications a
             where a.team_id = team_members.team_id and a.applicant_id = auth.uid() and a.status = 'confirmed')
);

-- ---- 9. Avatars: uploads namespaced to the user's own folder + cleanup -----
drop policy if exists p_av_write on storage.objects;
create policy p_av_write on storage.objects for insert with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists p_av_del on storage.objects;
create policy p_av_del on storage.objects for delete using (
  bucket_id = 'avatars' and owner = auth.uid()
);

-- ---- 6/8. Additive: let owners withdraw/delete their own rows --------------
drop policy if exists p_ta_del on team_applications;
create policy p_ta_del on team_applications for delete using (applicant_id = auth.uid() or is_team_owner(team_id));
drop policy if exists p_trn_del on tournaments;
create policy p_trn_del on tournaments for delete using (organizer_id = auth.uid());
drop policy if exists p_sp_del on spaces;
create policy p_sp_del on spaces for delete using (owner_id = auth.uid());


-- ███  anti-collusion.sql

-- ============================================================================
-- COLOSSO — Anti-collusion & rating integrity  (RUN LAST, after security-hardening.sql)
-- Safe to re-run (idempotent). Does not break existing app features.
--
-- Implements the three structural defenses against match-fixing / boosting:
--
--   1) RANKED GATING — you only gain GLR when the opponent was ASSIGNED to you
--      (matchmaking / tournament). Scrims = self-arranged = friendly, GLR-neutral.
--      You can't pre-arrange a collusion partner if you don't pick who you face.
--
--   2) ZERO-SUM ELO — rating is a real Elo settlement: the winner gains exactly
--      what the loser loses. Pumping someone's rating costs another account real
--      rating, so collusion is never "free". The remaining risk (smurf/paid
--      sacrifices) is caught structurally by anomaly scans, not per-match.
--
--   3) DECAY + RATE LIMIT — GLR gain against the SAME opponent decays toward zero
--      with each recent rematch, and a daily cap throttles per-account farming.
--      Win-trading "in a loop" loses throughput even if a single match slips through.
--
-- Tunable knobs are constants at the top of finish_match / settlement — search
-- for "TUNABLE".
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Schema additions
-- ----------------------------------------------------------------------------

-- Lobbies learn whether they are ranked and where they came from.
-- Default = friendly scrim (GLR-neutral). Matchmaking / tournament code must
-- create lobbies with ranked = true and the matching source.
alter table lobbies add column if not exists ranked  boolean default false;
alter table lobbies add column if not exists source  text    default 'scrim';  -- scrim | matchmaking | tournament

-- Matches get structured opponent identity (needed for pair analytics) + flags.
alter table matches add column if not exists team_id          uuid references teams(id)    on delete set null;
alter table matches add column if not exists opponent_id      uuid references profiles(id) on delete set null;
alter table matches add column if not exists opponent_team_id uuid references teams(id)    on delete set null;
alter table matches add column if not exists ranked           boolean default false;
alter table matches add column if not exists decay            numeric default 1;

-- One authoritative row per settled lobby. This is the idempotency anchor and
-- the source of truth for anomaly scans.
create table if not exists match_settlements (
  lobby_id     uuid primary key references lobbies(id) on delete cascade,
  ranked       boolean not null default false,
  source       text    not null default 'scrim',
  -- side A = scrim creator side, side B = responder side
  team_a_id    uuid references teams(id)    on delete set null,
  team_b_id    uuid references teams(id)    on delete set null,
  player_a_id  uuid references profiles(id) on delete set null,
  player_b_id  uuid references profiles(id) on delete set null,
  rating_a     int,
  rating_b     int,
  winner_side  char(1),          -- 'A' | 'B'
  base_delta   int,              -- raw Elo points before decay/cap
  decay_factor numeric,          -- 0..1 applied to base_delta
  glr_applied  int,              -- |GLR| actually moved between the two sides
  created_at   timestamptz default now()
);
create index if not exists ms_pair_idx    on match_settlements(team_a_id, team_b_id, created_at desc);
create index if not exists ms_created_idx on match_settlements(created_at desc);

alter table match_settlements enable row level security;
-- Participants may read their own settlements; writes happen only inside the
-- SECURITY DEFINER settlement function (which bypasses RLS). No insert policy = no
-- client can forge a settlement.
drop policy if exists p_ms_read on match_settlements;
create policy p_ms_read on match_settlements for select using (
  player_a_id = auth.uid() or player_b_id = auth.uid()
  or is_team_owner(team_a_id) or is_team_owner(team_b_id)
);


-- ----------------------------------------------------------------------------
-- 1. Helpers
-- ----------------------------------------------------------------------------

-- Elo expectation for side A given both ratings.
create or replace function _elo_expected(r_a numeric, r_b numeric)
returns numeric language sql immutable as $$
  select 1.0 / (1.0 + power(10.0, (r_b - r_a) / 400.0));
$$;

-- Rating of a side: team GLR if the side fields a team, else the player's GLR.
create or replace function _side_rating(p_team uuid, p_player uuid)
returns int language sql stable set search_path = public as $$
  select coalesce(
    (select glr from teams    where id = p_team),
    (select glr from profiles where id = p_player),
    1500
  );
$$;

-- How many ranked settlements this exact (unordered) pair already had in the
-- recent window. Pairs are keyed by team when present, else by player.
create or replace function _recent_h2h(
  p_team_a uuid, p_team_b uuid, p_player_a uuid, p_player_b uuid
)
returns int language sql stable set search_path = public as $$
  select count(*)::int
  from match_settlements ms
  where ms.ranked
    and ms.created_at > now() - interval '14 days'   -- TUNABLE: H2H window
    and (
      -- same team pairing (either orientation)
      (p_team_a is not null and p_team_b is not null and (
         (ms.team_a_id = p_team_a and ms.team_b_id = p_team_b) or
         (ms.team_a_id = p_team_b and ms.team_b_id = p_team_a)))
      or
      -- same player pairing (either orientation) — used when sides have no team
      ((p_team_a is null or p_team_b is null) and (
         (ms.player_a_id = p_player_a and ms.player_b_id = p_player_b) or
         (ms.player_a_id = p_player_b and ms.player_b_id = p_player_a)))
    );
$$;

-- How many ranked GLR-GAINING matches this user already banked today.
create or replace function _ranked_gains_today(p_user uuid)
returns int language sql stable set search_path = public as $$
  select count(*)::int
  from matches m
  where m.user_id = p_user
    and m.ranked
    and m.glr_delta > 0
    and m.created_at >= date_trunc('day', now());
$$;

-- Fix a latent ambiguity bug in _award (from glr-xp.sql): its RETURNS TABLE
-- columns glr/xp/level collided with the same-named profile columns, so the
-- function raised "column reference is ambiguous" the moment it actually ran.
-- The "#variable_conflict use_column" directive resolves bare names to the
-- column; INTO targets stay variables. Logic is otherwise identical.
create or replace function _award(p_user uuid, p_glr int, p_xp int)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare new_xp int; new_level int; cur_level int;
begin
  if p_user is null then return; end if;
  select level into cur_level from profiles where id = p_user;
  cur_level := coalesce(cur_level, 1);

  update profiles
     set glr = greatest(0, glr + p_glr),
         xp  = xp + greatest(0, p_xp)
   where id = p_user
   returning xp, level into new_xp, new_level;

  while new_xp >= 100 loop
    new_xp := new_xp - 100;
    new_level := new_level + 1;
  end loop;

  update profiles set xp = new_xp, level = new_level where id = p_user
    returning glr, xp, level into glr, xp, level;

  if new_level > cur_level then
    insert into notifications(user_id, type, data)
    values (p_user, 'system', jsonb_build_object('event','levelup','level',new_level));
  end if;
  return next;
end $$;


-- Awards one participant: applies the side's GLR move (gains throttled by the
-- daily cap), grants XP, writes a structured match-history row + notification.
create or replace function _settle_participant(
  p_user uuid, p_team uuid,
  won boolean, glr_move int, ranked boolean, src text,
  opp_player uuid, opp_team uuid, p_map text,
  win_xp int, loss_xp int, daily_cap int
)
returns void language plpgsql security definer set search_path = public as $$
declare
  d_glr int; d_xp int; opp_nick text; kind text;
begin
  if p_user is null then return; end if;

  -- GLR: winner +move, loser -move. Gains beyond the daily cap are zeroed
  -- (throttle), but losses always apply so being a "farm partner" still hurts.
  if won then
    d_glr := glr_move;
    if ranked and _ranked_gains_today(p_user) >= daily_cap then
      d_glr := 0;
    end if;
  else
    d_glr := -glr_move;
  end if;

  d_xp := case when won then win_xp else loss_xp end;
  kind := case src when 'tournament' then 'Torneio'
                   when 'matchmaking' then 'Ranqueada'
                   else 'Scrim' end;

  select nick into opp_nick from profiles where id = opp_player;

  insert into matches(user_id, team_id, won, glr_delta, map, opponent,
                      opponent_id, opponent_team_id, ranked, kind)
  values (p_user, p_team, won, d_glr, p_map, opp_nick,
          opp_player, opp_team, ranked, kind);

  insert into notifications(user_id, type, data)
  values (p_user, 'match',
    jsonb_build_object('result', case when won then 'win' else 'loss' end,
                       'glr', d_glr, 'ranked', ranked, 'opp', opp_nick));

  perform _award(p_user, d_glr, d_xp);
end $$;


-- ----------------------------------------------------------------------------
-- 2. finish_match — same signature the client already calls, new internals
--    Settles the WHOLE match atomically on the first participant call, then is
--    idempotent: a later call just returns that caller's resulting standing.
-- ----------------------------------------------------------------------------
create or replace function finish_match(
  p_won boolean default true,
  p_lobby uuid default null,
  p_opponent text default null,
  p_map text default null
)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column   -- bare glr/xp/level -> profile columns; INTO targets stay variables
declare
  -- ---- TUNABLE knobs -------------------------------------------------------
  K_FACTOR        int := 32;   -- Elo K
  WIN_XP          int := 12;   -- XP for a win  (progression, NOT zero-sum)
  LOSS_XP         int := 5;    -- XP for a loss
  DAILY_GAIN_CAP  int := 20;   -- max ranked matches/day that can still GAIN GLR
  -- -------------------------------------------------------------------------
  uid uuid := auth.uid();
  lob record; scr record;
  resp record;
  is_ranked boolean; src text;
  caller_side char(1);
  winner_side char(1);
  team_a uuid; team_b uuid; player_a uuid; player_b uuid;
  rating_a int; rating_b int;
  exp_a numeric; base_delta int;
  prior_h2h int; decay numeric; glr_applied int;
  caller_row record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_lobby is null then raise exception 'p_lobby is required'; end if;

  select * into lob from lobbies where id = p_lobby;
  if lob.id is null then raise exception 'lobby not found'; end if;

  -- caller must be a participant of this lobby's scrim
  select * into scr from scrims where id = lob.scrim_id;
  if scr.id is null then raise exception 'lobby has no scrim'; end if;

  if scr.creator_id = uid then
    caller_side := 'A';
  elsif exists (select 1 from scrim_responses r
                where r.scrim_id = scr.id and r.responder_id = uid and r.status = 'confirmed') then
    caller_side := 'B';
  else
    raise exception 'not a participant of this match';
  end if;

  -- ---- idempotency: already settled? return caller's standing -------------
  if exists (select 1 from match_settlements where lobby_id = p_lobby) then
    select glr, xp, level into caller_row from profiles where id = uid;
    glr := caller_row.glr; xp := caller_row.xp; level := caller_row.level;
    return next; return;
  end if;

  -- ---- identify the two sides --------------------------------------------
  -- side A = creator side
  player_a := scr.creator_id;
  team_a   := scr.team_id;
  -- side B = first confirmed responder side
  select responder_id, responder_team_id into resp
    from scrim_responses
   where scrim_id = scr.id and status = 'confirmed'
   order by created_at asc limit 1;
  player_b := resp.responder_id;
  team_b   := resp.responder_team_id;

  winner_side := case
    when caller_side = 'A' and p_won then 'A'
    when caller_side = 'A' and not p_won then 'B'
    when caller_side = 'B' and p_won then 'B'
    else 'A' end;

  -- ---- MECHANISM 1: ranked gating ----------------------------------------
  is_ranked := coalesce(lob.ranked, false);
  src       := coalesce(lob.source, 'scrim');

  -- ---- MECHANISM 2: zero-sum Elo -----------------------------------------
  rating_a := _side_rating(team_a, player_a);
  rating_b := _side_rating(team_b, player_b);
  exp_a    := _elo_expected(rating_a, rating_b);
  -- base points the WINNER takes from the LOSER (always positive, symmetric)
  if winner_side = 'A' then
    base_delta := round(K_FACTOR * (1 - exp_a));         -- A overperformed
  else
    base_delta := round(K_FACTOR * (1 - (1 - exp_a)));   -- B overperformed
  end if;

  -- ---- MECHANISM 3: decay on rematch -------------------------------------
  prior_h2h := _recent_h2h(team_a, team_b, player_a, player_b);
  decay := case
             when prior_h2h >= 4 then 0          -- 5th+ rematch in window pays nothing
             else 1.0 / (1 + prior_h2h)          -- 1, 1/2, 1/3, 1/4 ...
           end;

  if is_ranked then
    glr_applied := round(base_delta * decay);
  else
    glr_applied := 0;                            -- friendly scrim: GLR-neutral
  end if;

  -- ---- record the authoritative settlement -------------------------------
  update lobbies set status = 'done' where id = p_lobby;

  insert into match_settlements(
    lobby_id, ranked, source, team_a_id, team_b_id, player_a_id, player_b_id,
    rating_a, rating_b, winner_side, base_delta, decay_factor, glr_applied)
  values (p_lobby, is_ranked, src, team_a, team_b, player_a, player_b,
    rating_a, rating_b, winner_side, base_delta, decay, glr_applied);

  -- ---- award every participant -------------------------------------------
  -- side A
  perform _settle_participant(player_a, team_a,
            won := (winner_side = 'A'), glr_move := glr_applied,
            ranked := is_ranked, src := src,
            opp_player := player_b, opp_team := team_b, p_map := p_map,
            win_xp := WIN_XP, loss_xp := LOSS_XP, daily_cap := DAILY_GAIN_CAP);
  -- side B (all confirmed responders share the side's outcome/rating move)
  for resp in select responder_id, responder_team_id from scrim_responses
              where scrim_id = scr.id and status = 'confirmed' loop
    perform _settle_participant(resp.responder_id, resp.responder_team_id,
              won := (winner_side = 'B'), glr_move := glr_applied,
              ranked := is_ranked, src := src,
              opp_player := player_a, opp_team := team_a, p_map := p_map,
              win_xp := WIN_XP, loss_xp := LOSS_XP, daily_cap := DAILY_GAIN_CAP);
  end loop;

  -- ---- team win/loss + team GLR (ranked only) ----------------------------
  if is_ranked then
    if team_a is not null then
      update teams set
        wins   = wins   + (winner_side = 'A')::int,
        losses = losses + (winner_side <> 'A')::int,
        glr    = greatest(0, glr + case when winner_side = 'A' then glr_applied else -glr_applied end)
      where id = team_a;
    end if;
    if team_b is not null then
      update teams set
        wins   = wins   + (winner_side = 'B')::int,
        losses = losses + (winner_side <> 'B')::int,
        glr    = greatest(0, glr + case when winner_side = 'B' then glr_applied else -glr_applied end)
      where id = team_b;
    end if;
  end if;

  -- ---- return the caller's resulting standing ----------------------------
  select glr, xp, level into caller_row from profiles where id = uid;
  glr := caller_row.glr; xp := caller_row.xp; level := caller_row.level;
  return next;
end $$;

grant execute on function finish_match(boolean, uuid, text, text) to authenticated;


-- ----------------------------------------------------------------------------
-- 3. ANOMALY DETECTION (mechanism #2's real defense — catch what slips through)
--    Cheap, runs over data you already have. Meant to be run on a schedule
--    (pg_cron) or by an admin Edge Function with the service-role key.
--    Nothing here is granted to `authenticated` — clients can't read or run it.
-- ----------------------------------------------------------------------------

create table if not exists anti_cheat_flags (
  id         uuid primary key default gen_random_uuid(),
  signal     text not null,                 -- repeat_pair | one_way_flow | fresh_accounts | night_burst
  severity   text not null default 'medium',-- low | medium | high
  subject    jsonb not null,                -- the team/player ids + the evidence
  detail     text,
  created_at timestamptz default now()
);
create index if not exists acf_signal_idx on anti_cheat_flags(signal, created_at desc);

alter table anti_cheat_flags enable row level security;   -- no policy => clients blocked; service role bypasses

-- A read-only view of recent ranked pairings with aggregate stats. Restricted
-- to the service role (revoked from anon/authenticated below).
create or replace view suspicious_pairs as
select
  least(coalesce(team_a_id::text, player_a_id::text), coalesce(team_b_id::text, player_b_id::text)) as side_lo,
  greatest(coalesce(team_a_id::text, player_a_id::text), coalesce(team_b_id::text, player_b_id::text)) as side_hi,
  count(*)                                              as matches_7d,
  sum(case when winner_side = 'A' then glr_applied else -glr_applied end) as net_flow_to_a,
  sum(glr_applied)                                     as glr_churned,
  min(created_at)                                      as first_seen,
  max(created_at)                                      as last_seen
from match_settlements
where ranked and created_at > now() - interval '7 days'
group by 1, 2;

-- Scan: writes fresh flags for the last 7 days. Idempotent-ish — clears prior
-- auto-flags first so re-running doesn't pile up duplicates.
create or replace function scan_anomalies()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  delete from anti_cheat_flags where created_at > now() - interval '7 days';

  -- (a) REPEAT PAIR — same two sides grinding each other
  insert into anti_cheat_flags(signal, severity, subject, detail)
  select 'repeat_pair',
         case when matches_7d >= 10 then 'high' else 'medium' end,
         jsonb_build_object('side_lo', side_lo, 'side_hi', side_hi,
                            'matches_7d', matches_7d, 'glr_churned', glr_churned),
         matches_7d || ' ranked matches between the same pair in 7 days'
  from suspicious_pairs
  where matches_7d >= 5;                                      -- TUNABLE
  get diagnostics n = row_count;

  -- (b) ONE-WAY FLOW — rating pumped consistently in one direction (boosting)
  insert into anti_cheat_flags(signal, severity, subject, detail)
  select 'one_way_flow', 'high',
         jsonb_build_object('side_lo', side_lo, 'side_hi', side_hi,
                            'net_flow_to_a', net_flow_to_a, 'matches_7d', matches_7d),
         'net ' || abs(net_flow_to_a) || ' GLR flowed one way across ' || matches_7d || ' matches'
  from suspicious_pairs
  where matches_7d >= 3 and abs(net_flow_to_a) >= 80;        -- TUNABLE

  -- (c) FRESH ACCOUNTS — two recently-created accounts playing mostly each other
  insert into anti_cheat_flags(signal, severity, subject, detail)
  select 'fresh_accounts', 'high',
         jsonb_build_object('player_a', ms.player_a_id, 'player_b', ms.player_b_id,
                            'matches', count(*)),
         'both accounts created < 3 days apart and < 14 days old'
  from match_settlements ms
  join profiles pa on pa.id = ms.player_a_id
  join profiles pb on pb.id = ms.player_b_id
  where ms.ranked and ms.created_at > now() - interval '7 days'
    and pa.created_at > now() - interval '14 days'
    and abs(extract(epoch from (pa.created_at - pb.created_at))) < 3*86400
  group by ms.player_a_id, ms.player_b_id
  having count(*) >= 3;                                       -- TUNABLE

  -- (d) NIGHT BURST — many ranked matches in the 02:00–05:00 UTC window in a day
  insert into anti_cheat_flags(signal, severity, subject, detail)
  select 'night_burst', 'medium',
         jsonb_build_object('user_id', user_id, 'day', d, 'matches', c),
         c || ' ranked matches between 02:00–05:00 UTC in one day'
  from (
    select user_id, date_trunc('day', created_at) d, count(*) c
    from matches
    where ranked and created_at > now() - interval '7 days'
      and extract(hour from created_at) between 2 and 4
    group by user_id, date_trunc('day', created_at)
  ) q
  where c >= 8;                                               -- TUNABLE

  select count(*) into n from anti_cheat_flags where created_at > now() - interval '1 minute';
  return n;
end $$;

-- lock the analytics surface down to service-role only
revoke all on suspicious_pairs from anon, authenticated;
revoke all on function scan_anomalies() from anon, authenticated;

-- Optional: schedule a nightly scan (requires the pg_cron extension).
-- select cron.schedule('colosso-anomaly-scan', '0 5 * * *', 'select scan_anomalies()');


-- ███  result-reporting.sql

-- ============================================================================
-- COLOSSO — Result reporting + dispute flow  (run AFTER anti-collusion.sql)
-- Safe to re-run.
--
-- The integrity story so far made GLR worth gaming only structurally; this file
-- closes the "who actually won?" gap WITHOUT trusting a single self-report:
--
--   * Each side reports its own result (win/loss + optional score + screenshot).
--   * Both sides AGREE  -> the match auto-settles (real Elo, via _settle_lobby).
--   * Sides DISAGREE    -> the lobby goes to `disputed`; a human (admin, or the
--                          tournament organizer) resolves it with resolve_dispute().
--
-- Settlement logic now lives in ONE place — _settle_lobby() — reused by:
--   * finish_match()   (legacy single-call path, kept for back-compat / demo)
--   * report_result()  (the new two-sided confirmation path)
-- ============================================================================

-- a 'disputed' flag (kept off the lobby_status enum to avoid ALTER TYPE-in-tx
-- issues) + a minimal admin flag (no admin model existed before)
alter table lobbies  add column if not exists disputed boolean default false;
alter table profiles add column if not exists is_admin boolean default false;

create or replace function is_admin()
returns boolean language sql stable set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;


-- ----------------------------------------------------------------------------
-- 1. _settle_lobby — single source of truth for settling a lobby's GLR/XP.
--    Idempotent (no-op if already settled). Driven by the AGREED winner side.
-- ----------------------------------------------------------------------------
create or replace function _settle_lobby(p_lobby uuid, p_winner_side char, p_map text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  K_FACTOR        int := 32;   -- Elo K        (keep in sync with finish_match)
  WIN_XP          int := 12;
  LOSS_XP         int := 5;
  DAILY_GAIN_CAP  int := 20;
  lob record; scr record; resp record;
  is_ranked boolean; src text; map_used text;
  team_a uuid; team_b uuid; player_a uuid; player_b uuid;
  rating_a int; rating_b int; exp_a numeric; base_delta int;
  prior_h2h int; decay numeric; glr_applied int;
begin
  if p_winner_side not in ('A','B') then raise exception 'winner side must be A or B'; end if;

  select * into lob from lobbies where id = p_lobby;
  if lob.id is null then raise exception 'lobby not found'; end if;
  if exists (select 1 from match_settlements where lobby_id = p_lobby) then return; end if;  -- idempotent

  select * into scr from scrims where id = lob.scrim_id;
  if scr.id is null then raise exception 'lobby has no scrim'; end if;

  player_a := scr.creator_id; team_a := scr.team_id;
  select responder_id, responder_team_id into resp
    from scrim_responses where scrim_id = scr.id and status = 'confirmed'
    order by created_at asc limit 1;
  player_b := resp.responder_id; team_b := resp.responder_team_id;

  is_ranked := coalesce(lob.ranked, false);
  src       := coalesce(lob.source, 'scrim');
  map_used  := coalesce(p_map, lob.decider);

  -- MECHANISM 2: zero-sum Elo
  rating_a := _side_rating(team_a, player_a);
  rating_b := _side_rating(team_b, player_b);
  exp_a    := _elo_expected(rating_a, rating_b);
  if p_winner_side = 'A' then base_delta := round(K_FACTOR * (1 - exp_a));
  else                       base_delta := round(K_FACTOR * exp_a); end if;

  -- MECHANISM 3: decay on rematch
  prior_h2h := _recent_h2h(team_a, team_b, player_a, player_b);
  decay := case when prior_h2h >= 4 then 0 else 1.0 / (1 + prior_h2h) end;
  glr_applied := case when is_ranked then round(base_delta * decay) else 0 end;

  update lobbies set status = 'done', disputed = false where id = p_lobby;

  insert into match_settlements(
    lobby_id, ranked, source, team_a_id, team_b_id, player_a_id, player_b_id,
    rating_a, rating_b, winner_side, base_delta, decay_factor, glr_applied)
  values (p_lobby, is_ranked, src, team_a, team_b, player_a, player_b,
    rating_a, rating_b, p_winner_side, base_delta, decay, glr_applied);

  perform _settle_participant(player_a, team_a,
            won := (p_winner_side = 'A'), glr_move := glr_applied,
            ranked := is_ranked, src := src,
            opp_player := player_b, opp_team := team_b, p_map := map_used,
            win_xp := WIN_XP, loss_xp := LOSS_XP, daily_cap := DAILY_GAIN_CAP);
  for resp in select responder_id, responder_team_id from scrim_responses
              where scrim_id = scr.id and status = 'confirmed' loop
    perform _settle_participant(resp.responder_id, resp.responder_team_id,
              won := (p_winner_side = 'B'), glr_move := glr_applied,
              ranked := is_ranked, src := src,
              opp_player := player_a, opp_team := team_a, p_map := map_used,
              win_xp := WIN_XP, loss_xp := LOSS_XP, daily_cap := DAILY_GAIN_CAP);
  end loop;

  if is_ranked then
    if team_a is not null then
      update teams set wins = wins + (p_winner_side='A')::int,
                       losses = losses + (p_winner_side<>'A')::int,
                       glr = greatest(0, glr + case when p_winner_side='A' then glr_applied else -glr_applied end)
      where id = team_a;
    end if;
    if team_b is not null then
      update teams set wins = wins + (p_winner_side='B')::int,
                       losses = losses + (p_winner_side<>'B')::int,
                       glr = greatest(0, glr + case when p_winner_side='B' then glr_applied else -glr_applied end)
      where id = team_b;
    end if;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 2. finish_match — now a thin wrapper over _settle_lobby (back-compat).
--    Caller reports only their OWN result; kept for the demo / single-call path.
-- ----------------------------------------------------------------------------
create or replace function finish_match(
  p_won boolean default true, p_lobby uuid default null,
  p_opponent text default null, p_map text default null)
returns table(glr int, xp int, level int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare uid uuid := auth.uid(); lob record; scr record; caller_side char(1); me record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_lobby is null then raise exception 'p_lobby is required'; end if;
  select * into lob from lobbies where id = p_lobby;
  if lob.id is null then raise exception 'lobby not found'; end if;
  select * into scr from scrims where id = lob.scrim_id;
  if scr.id is null then raise exception 'lobby has no scrim'; end if;

  if scr.creator_id = uid then caller_side := 'A';
  elsif exists (select 1 from scrim_responses r where r.scrim_id = scr.id and r.responder_id = uid and r.status='confirmed')
    then caller_side := 'B';
  else raise exception 'not a participant of this match'; end if;

  perform _settle_lobby(p_lobby,
    case when (caller_side='A') = p_won then 'A' else 'B' end,  -- caller_side wins iff p_won
    p_map);

  select glr, xp, level into me from profiles where id = uid;
  glr := me.glr; xp := me.xp; level := me.level; return next;
end $$;
grant execute on function finish_match(boolean, uuid, text, text) to authenticated;


-- ----------------------------------------------------------------------------
-- 3. Two-sided result reporting
-- ----------------------------------------------------------------------------
create table if not exists match_reports (
  lobby_id       uuid references lobbies(id) on delete cascade,
  side           char(1) not null,            -- reporter's side: 'A' | 'B'
  reporter_id    uuid references profiles(id) on delete set null,
  claimed_winner char(1) not null,            -- which side the reporter says won
  score          text,
  screenshot_url text,
  created_at     timestamptz default now(),
  primary key (lobby_id, side)
);
alter table match_reports enable row level security;
-- writes go through report_result() (SECURITY DEFINER); clients only read their match's rows
drop policy if exists p_mr_read on match_reports;
create policy p_mr_read on match_reports for select using (
  exists (select 1 from scrims s where s.id =
            (select scrim_id from lobbies where id = match_reports.lobby_id)
          and (s.creator_id = auth.uid()
               or exists (select 1 from scrim_responses r where r.scrim_id = s.id and r.responder_id = auth.uid())))
);

create table if not exists disputes (
  lobby_id         uuid primary key references lobbies(id) on delete cascade,
  reported_a       char(1),     -- side A's claimed winner
  reported_b       char(1),     -- side B's claimed winner
  status           text default 'open',     -- open | resolved
  resolved_winner  char(1),
  resolved_by      uuid references profiles(id) on delete set null,
  created_at       timestamptz default now(),
  resolved_at      timestamptz
);
alter table disputes enable row level security;
drop policy if exists p_disp_read on disputes;
create policy p_disp_read on disputes for select using (
  is_admin() or exists (select 1 from scrims s where s.id =
            (select scrim_id from lobbies where id = disputes.lobby_id)
          and (s.creator_id = auth.uid()
               or exists (select 1 from scrim_responses r where r.scrim_id = s.id and r.responder_id = auth.uid())))
);

-- report_result: record the caller's own result; auto-settle on agreement,
-- open a dispute on conflict. Returns a jsonb status the UI can render.
create or replace function report_result(
  p_lobby uuid, p_won boolean, p_score text default null, p_screenshot text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); lob record; scr record; caller_side char(1); my_claim char(1);
  other record; me record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into lob from lobbies where id = p_lobby;
  if lob.id is null then raise exception 'lobby not found'; end if;
  select * into scr from scrims where id = lob.scrim_id;
  if scr.id is null then raise exception 'lobby has no scrim'; end if;

  if scr.creator_id = uid then caller_side := 'A';
  elsif exists (select 1 from scrim_responses r where r.scrim_id = scr.id and r.responder_id = uid and r.status='confirmed')
    then caller_side := 'B';
  else raise exception 'not a participant of this match'; end if;

  -- already settled? just hand back the standing
  if exists (select 1 from match_settlements where lobby_id = p_lobby) then
    select glr, xp, level into me from profiles where id = uid;
    return jsonb_build_object('status','settled','glr',me.glr,'xp',me.xp,'level',me.level);
  end if;

  my_claim := case when p_won then caller_side else case when caller_side='A' then 'B' else 'A' end end;

  insert into match_reports(lobby_id, side, reporter_id, claimed_winner, score, screenshot_url)
  values (p_lobby, caller_side, uid, my_claim, p_score, p_screenshot)
  on conflict (lobby_id, side) do update
    set claimed_winner = excluded.claimed_winner, reporter_id = excluded.reporter_id,
        score = excluded.score, screenshot_url = excluded.screenshot_url, created_at = now();

  -- the other side's report, if any
  select * into other from match_reports
   where lobby_id = p_lobby and side <> caller_side limit 1;

  if other.lobby_id is null then
    update lobbies set status = 'live' where id = p_lobby and status = 'veto';
    return jsonb_build_object('status','pending');   -- waiting on the opponent
  end if;

  if other.claimed_winner = my_claim then
    -- both sides agree → settle for real
    perform _settle_lobby(p_lobby, my_claim, lob.decider);
    select glr, xp, level into me from profiles where id = uid;
    return jsonb_build_object('status','settled','winner',my_claim,'glr',me.glr,'xp',me.xp,'level',me.level);
  else
    -- conflict → dispute, hands off to a human
    update lobbies set disputed = true where id = p_lobby;
    insert into disputes(lobby_id, reported_a, reported_b)
    values (p_lobby,
            case when caller_side='A' then my_claim else other.claimed_winner end,
            case when caller_side='B' then my_claim else other.claimed_winner end)
    on conflict (lobby_id) do update
      set reported_a = excluded.reported_a, reported_b = excluded.reported_b, status='open';
    insert into notifications(user_id, type, data)
      select p, 'match', jsonb_build_object('event','disputed','lobby', p_lobby)
      from (select scr.creator_id p union select responder_id from scrim_responses where scrim_id=scr.id and status='confirmed') q;
    return jsonb_build_object('status','disputed');
  end if;
end $$;
grant execute on function report_result(uuid, boolean, text, text) to authenticated;

-- resolve_dispute: a platform admin picks the winner of a disputed lobby.
-- (Tournament matches don't go through this — organizers report them directly
--  via report_tournament_match() in tournaments-glr.sql.)
create or replace function resolve_dispute(p_lobby uuid, p_winner_side char)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if p_winner_side not in ('A','B') then raise exception 'winner side must be A or B'; end if;
  if not is_admin() then raise exception 'only an admin can resolve disputes'; end if;

  perform _settle_lobby(p_lobby, p_winner_side, null);
  update disputes set status='resolved', resolved_winner=p_winner_side,
                      resolved_by=auth.uid(), resolved_at=now()
   where lobby_id = p_lobby;
  return jsonb_build_object('status','resolved','winner',p_winner_side);
end $$;
grant execute on function resolve_dispute(uuid, char) to authenticated;


-- ███  tournaments-glr.sql

-- ============================================================================
-- COLOSSO — Tournament results: GLR + bracket advancement  (run AFTER anti-collusion.sql)
-- Safe to re-run.
--
-- Before: tournaments seeded a bracket (bracket.sql) but reported nothing — no
-- result, no GLR, no advancement. This wires the organizer-reported result for
-- a tournament match into:
--   * zero-sum Elo between the two TEAMS (source='tournament', ranked),
--   * GLR/XP for every member of both teams + match-history rows,
--   * winner advanced into the next round of the bracket jsonb,
--   * tournament flipped to 'finished' when the final is reported.
--
-- Trust model: in a tournament the OPERATOR is the source of truth (they run the
-- lobby / see the scores), and brackets randomize who you face — so organizer
-- report is the right authority here, unlike self-arranged scrims.
-- ============================================================================

-- idempotency + audit: one settled result per (tournament, round, match)
create table if not exists tournament_results (
  tournament_id uuid references tournaments(id) on delete cascade,
  round         int,
  match         int,
  team_a_id     uuid references teams(id) on delete set null,
  team_b_id     uuid references teams(id) on delete set null,
  winner_team_id uuid references teams(id) on delete set null,
  glr_applied   int,
  reported_by   uuid references profiles(id) on delete set null,
  created_at    timestamptz default now(),
  primary key (tournament_id, round, match)
);
alter table tournament_results enable row level security;
drop policy if exists p_tr_read on tournament_results;
create policy p_tr_read on tournament_results for select using (true);  -- public results

create or replace function report_tournament_match(
  p_tournament uuid, p_round int, p_match int, p_winner_team uuid,
  p_score_a text default null, p_score_b text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  WIN_XP int := 15; LOSS_XP int := 6; K_FACTOR int := 32;
  org uuid; br jsonb; slot jsonb; name_a text; name_b text;
  team_a uuid; team_b uuid; loser uuid;
  rating_w int; rating_l int; delta int; win_name text;
  n_rounds int; next_match int; pos int; mem record;
begin
  select organizer_id, bracket into org, br from tournaments where id = p_tournament;
  if org is null then raise exception 'tournament not found'; end if;
  if org <> auth.uid() then raise exception 'only the organizer can report results'; end if;
  if exists (select 1 from tournament_results where tournament_id=p_tournament and round=p_round and match=p_match)
    then raise exception 'this match was already reported'; end if;

  slot   := br -> p_round -> 'm' -> p_match;
  if slot is null then raise exception 'no such match in the bracket'; end if;
  name_a := slot ->> 0; name_b := slot ->> 2;

  -- resolve registered teams by name (BYE/TBD resolve to null → no GLR, just advance)
  select tr.team_id into team_a from tournament_registrations tr join teams tm on tm.id=tr.team_id
    where tr.tournament_id=p_tournament and tm.name=name_a limit 1;
  select tr.team_id into team_b from tournament_registrations tr join teams tm on tm.id=tr.team_id
    where tr.tournament_id=p_tournament and tm.name=name_b limit 1;

  if team_a is not null and team_b is not null then
    if p_winner_team not in (team_a, team_b) then raise exception 'winner is not in this match'; end if;
    loser := case when p_winner_team = team_a then team_b else team_a end;

    -- zero-sum Elo between the two teams
    rating_w := _side_rating(p_winner_team, null);
    rating_l := _side_rating(loser, null);
    delta := round(K_FACTOR * (1 - _elo_expected(rating_w, rating_l)));

    update teams set glr = greatest(0, glr + delta), wins = wins + 1 where id = p_winner_team;
    update teams set glr = greatest(0, glr - delta), losses = losses + 1 where id = loser;

    -- per-member GLR/XP + history
    select name into win_name from teams where id = p_winner_team;
    for mem in select tm.profile_id pid, (tm.team_id = p_winner_team) won,
                      case when tm.team_id = p_winner_team then name_b else name_a end opp
               from team_members tm where tm.team_id in (p_winner_team, loser) loop
      perform _award(mem.pid, case when mem.won then delta else -delta end,
                              case when mem.won then WIN_XP else LOSS_XP end);
      insert into matches(user_id, team_id, won, glr_delta, opponent, opponent_team_id, ranked, kind)
      values (mem.pid, case when mem.won then p_winner_team else loser end, mem.won,
              case when mem.won then delta else -delta end, mem.opp,
              case when mem.won then loser else p_winner_team end, true, 'Torneio');
    end loop;
  else
    delta := 0;  -- BYE / placeholder match: no rating change
  end if;

  -- record result (write scores into the slot)
  insert into tournament_results(tournament_id, round, match, team_a_id, team_b_id, winner_team_id, glr_applied, reported_by)
  values (p_tournament, p_round, p_match, team_a, team_b, p_winner_team, delta, auth.uid());

  br := jsonb_set(br, array[p_round::text,'m',p_match::text],
        jsonb_build_array(name_a, coalesce(p_score_a,'—'), name_b, coalesce(p_score_b,'—')));

  -- advance the winner's NAME into the next round, or finish the tournament
  select name into win_name from teams where id = p_winner_team;
  n_rounds := jsonb_array_length(br);
  if p_round + 1 < n_rounds then
    next_match := p_match / 2;                       -- integer division
    pos := case when p_match % 2 = 0 then 0 else 2 end;
    br := jsonb_set(br, array[(p_round+1)::text,'m',next_match::text,pos::text], to_jsonb(win_name));
    update tournaments set bracket = br where id = p_tournament;
    return jsonb_build_object('status','advanced','winner',win_name,'glr',delta);
  else
    update tournaments set bracket = br, status = 'finished' where id = p_tournament;
    return jsonb_build_object('status','champion','winner',win_name,'glr',delta);
  end if;
end $$;
grant execute on function report_tournament_match(uuid, int, int, uuid, text, text) to authenticated;


-- ███  lobby-ban-map.sql

-- ============================================================================
-- COLOSSO — lobby_ban_map RPC  (run AFTER schema.sql; safe to re-run)
--
-- The client (COLOSSO.lobbies.banMap) referenced rpc('lobby_ban_map') but the
-- function never existed. This implements it server-side: a participant of the
-- match appends a map ban to lobbies.bans (RLS already limits writes to the two
-- sides). The decider is computed automatically when one map remains.
-- ============================================================================
create or replace function lobby_ban_map(p_lobby uuid, p_map text, p_team uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); lob record; scr record;
  new_bans jsonb; banned text[]; remaining text[]; dec text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into lob from lobbies where id = p_lobby;
  if lob.id is null then raise exception 'lobby not found'; end if;
  select * into scr from scrims where id = lob.scrim_id;
  if scr.id is null then raise exception 'lobby has no scrim'; end if;

  if not (scr.creator_id = uid
          or exists (select 1 from scrim_responses r
                     where r.scrim_id = scr.id and r.responder_id = uid and r.status = 'confirmed'))
    then raise exception 'not a participant of this match'; end if;

  if not (p_map = any(lob.map_pool)) then raise exception 'map not in this lobby pool'; end if;

  -- already banned? no-op (keeps the call idempotent)
  if exists (select 1 from jsonb_array_elements(coalesce(lob.bans,'[]'::jsonb)) b where b->>'map' = p_map) then
    return jsonb_build_object('bans', lob.bans, 'decider', lob.decider);
  end if;

  new_bans := coalesce(lob.bans,'[]'::jsonb) || jsonb_build_array(jsonb_build_object('map', p_map, 'by_team_id', p_team));
  select array_agg(b->>'map') into banned from jsonb_array_elements(new_bans) b;
  select array_agg(x) into remaining from unnest(lob.map_pool) x where not (x = any(coalesce(banned,'{}')));
  dec := case when array_length(remaining,1) = 1 then remaining[1] else null end;

  update lobbies set bans = new_bans, decider = dec where id = p_lobby;
  return jsonb_build_object('bans', new_bans, 'decider', dec, 'remaining', remaining);
end $$;
grant execute on function lobby_ban_map(uuid, text, uuid) to authenticated;


-- ███  ops-hardening.sql

-- ============================================================================
-- COLOSSO — Operational hardening  (run AFTER result-reporting.sql; safe to re-run)
--
--   1. Rate limiting — anti-spam BEFORE INSERT caps per user/min on scrims,
--      responses, applications, messages. Server (service-role) inserts skip it.
--   2. Content guard — blocked-term filter on nicknames and chat messages.
--   3. Trust penalty — whoever filed the losing claim in a resolved dispute
--      loses trust, so false reports cost something.
--   4. Anomaly scan schedule (pg_cron) + list_flags() admin triage RPC.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Rate limiting
-- ----------------------------------------------------------------------------
-- Generic guard: TG_ARGV = (max_count, window_seconds, user_column).
create or replace function _rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  maxn int := TG_ARGV[0]::int; secs int := TG_ARGV[1]::int; ucol text := TG_ARGV[2];
  uid uuid := auth.uid(); cnt int;
begin
  if uid is null then return new; end if;   -- service-role / trigger inserts are exempt
  execute format(
    'select count(*) from %I where %I = $1 and created_at > now() - make_interval(secs => $2)',
    TG_TABLE_NAME, ucol) into cnt using uid, secs;
  if cnt >= maxn then
    raise exception 'rate limit: too many %, max % per % s', TG_TABLE_NAME, maxn, secs
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists rl_scrims on scrims;
create trigger rl_scrims before insert on scrims
  for each row execute function _rate_limit('10','60','creator_id');
drop trigger if exists rl_responses on scrim_responses;
create trigger rl_responses before insert on scrim_responses
  for each row execute function _rate_limit('20','60','responder_id');
drop trigger if exists rl_applications on team_applications;
create trigger rl_applications before insert on team_applications
  for each row execute function _rate_limit('10','60','applicant_id');
drop trigger if exists rl_messages on messages;
create trigger rl_messages before insert on messages
  for each row execute function _rate_limit('30','60','sender_id');


-- ----------------------------------------------------------------------------
-- 2. Content guard (nicknames + chat)
-- ----------------------------------------------------------------------------
create table if not exists blocked_terms (term text primary key);
-- seed a couple of obvious ones; admins extend this list. Matching is case-insensitive substring.
insert into blocked_terms(term) values ('slur'), ('spamlink'), ('cp') on conflict do nothing;
alter table blocked_terms enable row level security;   -- no policy → admins/service-role only

create or replace function _contains_blocked(p text)
returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from blocked_terms t where p ilike '%' || t.term || '%');
$$;

create or replace function _guard_nick()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.nick is not null and _contains_blocked(new.nick) then
    raise exception 'nickname contains a blocked term' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists guard_nick on profiles;
create trigger guard_nick before update on profiles
  for each row execute function _guard_nick();

create or replace function _guard_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.body is not null and _contains_blocked(new.body) then
    raise exception 'message contains a blocked term' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists guard_message on messages;
create trigger guard_message before insert on messages
  for each row execute function _guard_message();


-- ----------------------------------------------------------------------------
-- 3. Trust penalty for the losing claim in a resolved dispute
-- ----------------------------------------------------------------------------
create or replace function _trust_on_resolve()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.status = 'resolved' and (old.status is distinct from 'resolved') and new.resolved_winner is not null then
    for r in select reporter_id, claimed_winner from match_reports where lobby_id = new.lobby_id loop
      if r.claimed_winner <> new.resolved_winner and r.reporter_id is not null then
        update profiles set trust = greatest(0, trust - 5) where id = r.reporter_id;  -- false report costs trust
      end if;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists trust_on_resolve on disputes;
create trigger trust_on_resolve after update on disputes
  for each row execute function _trust_on_resolve();


-- ----------------------------------------------------------------------------
-- 4. Anomaly scan schedule + admin triage
-- ----------------------------------------------------------------------------
-- Enable pg_cron in Supabase (Dashboard → Database → Extensions, or the line below),
-- then schedule the nightly scan:
--   create extension if not exists pg_cron;
--   select cron.schedule('colosso-anomaly-scan', '0 5 * * *', 'select scan_anomalies()');

-- Admins read flags through this RPC (returns nothing for non-admins).
create or replace function list_flags(p_signal text default null)
returns setof anti_cheat_flags language sql security definer set search_path = public as $$
  select * from anti_cheat_flags
   where is_admin() and (p_signal is null or signal = p_signal)
   order by created_at desc;
$$;
grant execute on function list_flags(text) to authenticated;


-- ███  realtime-and-reports.sql

-- ============================================================================
-- COLOSSO — Realtime scrims feed + user/content reports
-- Run AFTER result-reporting.sql and ops-hardening.sql (needs is_admin / _rate_limit).
-- Safe to re-run.
-- ============================================================================

-- 1) expose `scrims` to Realtime so new open scrims appear live in everyone's feed
do $$ begin
  alter publication supabase_realtime add table scrims;
  exception when duplicate_object then null; end $$;

-- 2) reports: players flag a user / team / message / scrim; admins triage
create table if not exists reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid references profiles(id) on delete set null,
  target_type text not null,                 -- player | team | message | scrim
  target_id   text not null,                 -- uuid or name
  reason      text,
  status      text default 'open',           -- open | reviewed | dismissed
  created_at  timestamptz default now()
);
create index if not exists reports_status_idx on reports(status, created_at desc);

alter table reports enable row level security;
drop policy if exists p_reports_ins on reports;
create policy p_reports_ins on reports for insert with check (reporter_id = auth.uid());
drop policy if exists p_reports_read on reports;
create policy p_reports_read on reports for select using (is_admin() or reporter_id = auth.uid());
drop policy if exists p_reports_upd on reports;
create policy p_reports_upd on reports for update using (is_admin());

-- anti-spam: max 5 reports / minute / user (reuses _rate_limit from ops-hardening)
drop trigger if exists rl_reports on reports;
create trigger rl_reports before insert on reports
  for each row execute function _rate_limit('5','60','reporter_id');

-- admin triage RPC (returns nothing for non-admins)
create or replace function list_reports(p_status text default 'open')
returns setof reports language sql security definer set search_path = public as $$
  select * from reports
   where is_admin() and (p_status is null or status = p_status)
   order by created_at desc;
$$;
grant execute on function list_reports(text) to authenticated;

