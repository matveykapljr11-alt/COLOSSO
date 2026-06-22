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
