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
