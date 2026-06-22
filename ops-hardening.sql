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
