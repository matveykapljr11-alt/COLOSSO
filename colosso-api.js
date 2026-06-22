// ============================================================================
// COLOSSO — Supabase client + data layer (ES module, browser)
// Maps every prototype action to a real backend call.
// Usage:
//   import { COLOSSO } from './colosso-api.js'
//   await COLOSSO.auth.signInWithDiscord()
// Requires: <script type="module"> and the supabase-js CDN (see README).
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// --- 1. configure (use your project values; anon key is safe for the browser) ---
const SUPABASE_URL = window.COLOSSO_ENV?.SUPABASE_URL || 'https://YOUR-PROJECT.supabase.co';
const SUPABASE_ANON = window.COLOSSO_ENV?.SUPABASE_ANON_KEY || 'YOUR-ANON-KEY';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

// helper: throw on error, return data
const ok = ({ data, error }) => { if (error) throw error; return data; };

// ============================================================================
// AUTH  (Discord OAuth)
// ============================================================================
export const auth = {
  // opens Discord OAuth; on return, Supabase restores the session automatically
  async signInWithDiscord(redirectTo = window.location.origin) {
    return ok(await sb.auth.signInWithOAuth({
      provider: 'discord',
      options: { redirectTo, scopes: 'identify email' }
    }));
  },
  async signOut() { return ok(await sb.auth.signOut()); },
  async getUser() { const { data } = await sb.auth.getUser(); return data?.user || null; },
  onChange(cb) { return sb.auth.onAuthStateChange((_e, session) => cb(session?.user || null)); }
};

// ============================================================================
// PROFILE
// ============================================================================
export const profiles = {
  async me() {
    const u = await auth.getUser(); if (!u) return null;
    return ok(await sb.from('profiles').select('*').eq('id', u.id).single());
  },
  async get(id) { return ok(await sb.from('profiles').select('*').eq('id', id).single()); },
  async byHandle(h) { return ok(await sb.from('profiles').select('*').eq('handle', h).single()); },
  // onboarding / edit profile
  async update(patch) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('profiles').update(patch).eq('id', u.id).select().single());
  },
  async completeOnboarding({ nick, game, region, role, langs, avatar_url }) {
    return profiles.update({ nick, game, region, role, langs, avatar_url, onboarded: true });
  },
  // award GLR/XP after a match (server-side rules) + record history → { glr, xp, level }
  async finishMatch(won = true, lobbyId = null, opponent = null, map = null) {
    return ok(await sb.rpc('finish_match', { p_won: won, p_lobby: lobbyId, p_opponent: opponent, p_map: map }))?.[0] || null;
  },
  // avatar upload → Storage → returns public URL
  async uploadAvatar(file) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    const path = `${u.id}/${Date.now()}_${file.name}`;
    ok(await sb.storage.from('avatars').upload(path, file, { upsert: true }));
    const { data } = sb.storage.from('avatars').getPublicUrl(path);
    await profiles.update({ avatar_url: data.publicUrl });
    return data.publicUrl;
  }
};

// ============================================================================
// PLAYERS directory + LEADERBOARD
// ============================================================================
export const players = {
  list({ role, rank, region, lft, sort = 'glr' } = {}) {
    let q = sb.from('profiles').select('*');
    if (role) q = q.eq('role', role);
    if (rank) q = q.ilike('rank', `%${rank}%`);
    if (region) q = q.eq('region', region);
    const col = sort === 'kd' ? 'glr' : sort;        // map UI sort → column
    return q.order(col, { ascending: false }).limit(60).then(ok);
  }
};
export const leaderboard = {
  teams() { return sb.from('teams').select('*').order('glr', { ascending: false }).limit(100).then(ok); },
  playersTop() { return sb.from('profiles').select('*').order('glr', { ascending: false }).limit(100).then(ok); }
};

// ============================================================================
// TEAMS
// ============================================================================
export const teams = {
  list({ game, region, rank, recruiting, lang } = {}) {
    let q = sb.from('teams').select('*, team_members(profile_id, role, is_captain)');
    if (game) q = q.eq('game', game);
    if (region) q = q.eq('region', region);
    if (rank) q = q.eq('rank', rank);
    if (recruiting) q = q.eq('recruiting', true);
    // language is a soft filter: match teams whose primary OR secondary language fits
    if (lang) q = q.or(`lang.eq.${lang},lang2.eq.${lang}`);
    return q.order('glr', { ascending: false }).then(ok);
  },
  get(id) { return sb.from('teams').select('*, team_members(*, profiles(nick,avatar_url,role))').eq('id', id).single().then(ok); },
  async create({ name, game, region, rank, open_roles = [], crest_color, lang = 'PT', lang2 = null }) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    const team = ok(await sb.from('teams').insert({
      name, slug, owner_id: u.id, game, region, rank,
      recruiting: open_roles.length > 0, open_roles, crest_color, lang, lang2
    }).select().single());
    await sb.from('team_members').insert({ team_id: team.id, profile_id: u.id, role: 'IGL', is_captain: true });
    return team;
  },
  async apply(team_id, message = '') {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('team_applications').insert({ team_id, applicant_id: u.id, message }).select().single());
  },
  // team owner: pending applications (with applicant profile)
  listApplications(team_id) {
    return sb.from('team_applications')
      .select('*, profiles:applicant_id(nick,avatar_url,handle,role)')
      .eq('team_id', team_id).eq('status', 'pending')
      .order('created_at', { ascending: true }).then(ok);
  },
  // accept → add member + notify; reject → just notify. (RLS: only the team owner)
  async respondApplication(app, accept, team_name = '') {
    const status = accept ? 'confirmed' : 'rejected';
    await sb.from('team_applications').update({ status }).eq('id', app.id);
    if (accept) {
      await sb.from('team_members').insert({ team_id: app.team_id, profile_id: app.applicant_id, role: 'Flex' });
    }
    await sb.from('notifications').insert({
      user_id: app.applicant_id, type: 'application',
      data: { team: team_name, status }
    });
    return status;
  }
};

// ============================================================================
// MATCH HISTORY
// ============================================================================
export const matches = {
  async list(limit = 20) {
    const u = await auth.getUser(); if (!u) return [];
    return sb.from('matches').select('*').eq('user_id', u.id)
      .order('created_at', { ascending: false }).limit(limit).then(ok);
  }
};

// ============================================================================
// SCRIMS / PRACCS  +  responses + lobby
// ============================================================================
export const scrims = {
  list({ rank, format, server, status = 'open' } = {}) {
    let q = sb.from('scrims').select('*, profiles!scrims_creator_id_fkey(nick,avatar_url), teams(name,crest_color)');
    if (status) q = q.eq('status', status);
    if (rank) q = q.eq('rank', rank);
    if (format) q = q.eq('format', format);
    if (server) q = q.eq('server', server);
    return q.order('created_at', { ascending: false }).then(ok);
  },
  async create({ team_id, game, format, server, rank, note, scheduled_at = null }) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('scrims').insert({
      creator_id: u.id, team_id, game, format, server, rank, note, scheduled_at
    }).select().single());
  },
  // "respond / accept" — creates a response and a lobby, marks scrim scheduled
  async accept(scrim_id, responder_team_id = null) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    await sb.from('scrim_responses').insert({ scrim_id, responder_id: u.id, responder_team_id, status: 'confirmed' });
    await sb.from('scrims').update({ status: 'scheduled' }).eq('id', scrim_id);
    const lobby = ok(await sb.from('lobbies').insert({
      scrim_id, password: 'CLS-' + Math.floor(1000 + Math.random() * 9000)
    }).select().single());
    return lobby;
  }
};

export const lobbies = {
  get(id) { return sb.from('lobbies').select('*').eq('id', id).single().then(ok); },
  // Create a lobby over an existing scrim shell.
  // RANKED lobbies (opponent ASSIGNED by matchmaking / tournament) award GLR;
  // friendly scrims (opponent self-picked) are GLR-neutral. The matchmaking Edge
  // Function and tournament-match flow must create their lobby with ranked:true.
  create({ scrim_id, ranked = false, source = 'scrim', password } = {}) {
    return sb.from('lobbies').insert({
      scrim_id, ranked, source,
      password: password || ('CLS-' + Math.floor(1000 + Math.random() * 9000))
    }).select().single().then(ok);
  },
  banMap(id, map, by_team_id) {
    return sb.rpc('lobby_ban_map', { p_lobby: id, p_map: map, p_team: by_team_id }).then(ok);
    // (or do it client-side then .update bans/decider — see README note)
  },
  ready(id) { return sb.from('lobbies').update({ status: 'ready' }).eq('id', id).select().single().then(ok); },
  // Two-sided result reporting. Returns { status: 'pending'|'settled'|'disputed', glr?, xp?, level?, winner? }.
  // Both sides must report the same outcome to settle; a conflict opens a dispute.
  reportResult(lobbyId, won, score = null, screenshotUrl = null) {
    return sb.rpc('report_result', { p_lobby: lobbyId, p_won: won, p_score: score, p_screenshot: screenshotUrl }).then(ok);
  },
  // realtime: react to opponent bans/ready
  subscribe(id, cb) {
    return sb.channel('lobby:' + id)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'lobbies', filter: `id=eq.${id}` }, p => cb(p.new))
      .subscribe();
  }
};

// ============================================================================
// TOURNAMENTS
// ============================================================================
export const tournaments = {
  list() { return sb.from('tournaments').select('*').order('starts_at', { ascending: true }).then(ok); },
  get(id) {
    return sb.from('tournaments')
      .select('*, tournament_registrations(team_id, seed, teams(name,crest_color))')
      .eq('id', id).single().then(ok);
  },
  async create({ name, game, format, slots, prize, currency, buy_in, starts_at }) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('tournaments').insert({
      name, organizer_id: u.id, game, format, slots, prize, currency, buy_in, starts_at
    }).select().single());
  },
  // register a TEAM (caller must own the team — enforced by RLS)
  async register(tournament_id, team_id) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('tournament_registrations')
      .insert({ tournament_id, team_id, registered_by: u.id }).select().single());
  },
  // organizer: seed the bracket from registered teams + go live → returns bracket jsonb
  async seed(tournament_id) {
    return ok(await sb.rpc('seed_bracket', { p_tournament: tournament_id }));
  },
  // organizer: report a bracket match → zero-sum team GLR + advance the winner.
  // round/match are 0-based indices into the bracket; winnerTeamId is a teams.id.
  reportMatch(tournament_id, round, match, winnerTeamId, scoreA = null, scoreB = null) {
    return sb.rpc('report_tournament_match', {
      p_tournament: tournament_id, p_round: round, p_match: match,
      p_winner_team: winnerTeamId, p_score_a: scoreA, p_score_b: scoreB
    }).then(ok);
  }
};

// ============================================================================
// ADMIN / MODERATION (server enforces authority; non-admins just get empty/denied)
// ============================================================================
export const admin = {
  // open disputes the caller is allowed to see (admin: all; players: their own)
  disputes() {
    return sb.from('disputes').select('*').eq('status', 'open').order('created_at', { ascending: true }).then(ok);
  },
  // admin only: settle a disputed lobby by picking the winning side ('A' | 'B')
  resolveDispute(lobbyId, winnerSide) {
    return sb.rpc('resolve_dispute', { p_lobby: lobbyId, p_winner_side: winnerSide }).then(ok);
  },
  // admin only: triage anti-cheat flags (returns nothing for non-admins)
  flags(signal = null) { return sb.rpc('list_flags', { p_signal: signal }).then(ok); },
  // admin only: triage user/content reports
  reports(status = 'open') { return sb.rpc('list_reports', { p_status: status }).then(ok); }
};

// ============================================================================
// REPORTS (any user can flag a player / team / message / scrim)
// ============================================================================
export const reports = {
  async create(target_type, target_id, reason = '') {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('reports').insert({
      reporter_id: u.id, target_type, target_id: String(target_id), reason
    }).select().single());
  }
};

// ============================================================================
// ORGANIZER SPACES
// ============================================================================
export const spaces = {
  list() { return sb.from('spaces').select('*').order('created_at', { ascending: false }).then(ok); },
  async create(payload) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    const slug = (payload.name || 'space').toLowerCase().replace(/[^a-z0-9]+/g, '-');
    return ok(await sb.from('spaces').insert({ ...payload, slug, owner_id: u.id }).select().single());
  }
};

// ============================================================================
// MESSAGING  (+ realtime)
// ============================================================================
export const chat = {
  list() {
    return sb.from('conversations')
      .select('*, messages(body,created_at,sender_id)')
      .order('created_at', { foreignTable: 'messages', ascending: false })
      .then(ok);
  },
  thread(conversation_id) {
    return sb.from('messages').select('*, profiles(nick,avatar_url)')
      .eq('conversation_id', conversation_id).order('created_at').then(ok);
  },
  async send(conversation_id, body) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    return ok(await sb.from('messages').insert({ conversation_id, sender_id: u.id, body }).select().single());
  },
  // open or create a DM with another profile
  async openDM(other_profile_id) {
    const u = await auth.getUser(); if (!u) throw new Error('not authed');
    const conv = ok(await sb.from('conversations').insert({ type: 'dm' }).select().single());
    await sb.from('conversation_members').insert([
      { conversation_id: conv.id, profile_id: u.id },
      { conversation_id: conv.id, profile_id: other_profile_id }
    ]);
    return conv;
  },
  subscribe(conversation_id, cb) {
    return sb.channel('chat:' + conversation_id)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `conversation_id=eq.${conversation_id}` }, p => cb(p.new))
      .subscribe();
  }
};

// ============================================================================
// NOTIFICATIONS (+ realtime)
// ============================================================================
export const notifications = {
  async list() {
    const u = await auth.getUser(); if (!u) return [];
    return sb.from('notifications').select('*').eq('user_id', u.id)
      .order('created_at', { ascending: false }).limit(30).then(ok);
  },
  markAllRead: async () => {
    const u = await auth.getUser(); if (!u) return;
    return ok(await sb.from('notifications').update({ read: true }).eq('user_id', u.id).eq('read', false));
  },
  markRead: (id) => sb.from('notifications').update({ read: true }).eq('id', id).then(ok),
  async subscribe(cb) {
    const u = await auth.getUser(); if (!u) return null;
    return sb.channel('ntf:' + u.id)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications', filter: `user_id=eq.${u.id}` }, p => cb(p.new))
      .subscribe();
  }
};

// ============================================================================
// QUICK MATCH (matchmaking) — server-side queue via Edge Function
//   join → pairs you with another waiting player and returns a real lobby
//   poll → check if you've been matched while waiting
//   leave → cancel your spot in the queue
// ============================================================================
export const matchmaking = {
  async join({ game, format, server, rank }) {
    const { data, error } = await sb.functions.invoke('matchmaking', { body: { action: 'join', game, format, server, rank } });
    if (error) throw error; return data;            // {matched, lobby?} | {matched:false,status:'waiting'}
  },
  async poll() {
    const { data, error } = await sb.functions.invoke('matchmaking', { body: { action: 'poll' } });
    if (error) throw error; return data;            // {matched, lobby?}
  },
  async leave() {
    const { data, error } = await sb.functions.invoke('matchmaking', { body: { action: 'leave' } });
    if (error) throw error; return data;
  }
};

// ============================================================================
// TRANSLATE (Edge Function) — server-side; keeps API keys out of the browser
// ============================================================================
export const translate = {
  // returns { text, src }
  async text(q, target) {
    const { data, error } = await sb.functions.invoke('translate', { body: { text: q, target } });
    if (error) throw error;
    return data;
  }
};

export const COLOSSO = { sb, auth, profiles, players, leaderboard, teams, scrims, lobbies, tournaments, spaces, chat, notifications, matchmaking, translate, matches, admin, reports };
export default COLOSSO;
