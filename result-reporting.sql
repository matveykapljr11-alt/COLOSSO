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
