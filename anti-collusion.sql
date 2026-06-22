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
