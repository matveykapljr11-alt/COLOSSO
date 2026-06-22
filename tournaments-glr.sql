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
