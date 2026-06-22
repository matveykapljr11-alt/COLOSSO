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
