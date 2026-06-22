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
