// ============================================================================
// COLOSSO — Edge Function: matchmaking
// Server-side quick-match queue. Pairs two waiting players with the service-role
// key (bypasses RLS), then creates a scrim + lobby for them.
//
// Request : POST { action: "join" | "poll" | "leave", game?, format?, server?, rank? }
// Replies :
//   join  → { matched:true, lobby:{…} }  OR  { matched:false, status:"waiting" }
//   poll  → { matched:true, lobby:{…} }  OR  { matched:false }
//   leave → { ok:true }
//
// Deploy : supabase functions deploy matchmaking
// (uses built-in SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY)
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function pass() { return "CLS-" + Math.floor(1000 + Math.random() * 9000); }

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // identify caller from their JWT
  const authHeader = req.headers.get("Authorization") || "";
  const asUser = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return json({ error: "not authenticated" }, 401);

  const admin = createClient(URL, SERVICE);
  const body = await req.json().catch(() => ({}));
  const action = body.action;
  const me = user.id;

  try {
    if (action === "leave") {
      await admin.from("matchmaking_queue").delete().eq("user_id", me);
      return json({ ok: true });
    }

    if (action === "poll") {
      const { data: row } = await admin.from("matchmaking_queue").select("*").eq("user_id", me).maybeSingle();
      if (row && row.status === "matched" && row.lobby_id) {
        const { data: lobby } = await admin.from("lobbies").select("*").eq("id", row.lobby_id).maybeSingle();
        return json({ matched: true, lobby });
      }
      return json({ matched: false });
    }

    if (action === "join") {
      const crit = {
        game: body.game || "free_fire",
        format: body.format || "Squad (4)",
        server: body.server || "BR · São Paulo",
        rank: body.rank || "Diamante",
      };
      // 1) enqueue / refresh my row as waiting
      await admin.from("matchmaking_queue").upsert({
        user_id: me, ...crit, status: "waiting", lobby_id: null, opponent_id: null, enqueued_at: new Date().toISOString(),
      });

      // 2) find the oldest other waiting player in the same game
      const { data: cands } = await admin
        .from("matchmaking_queue")
        .select("*")
        .eq("game", crit.game)
        .eq("status", "waiting")
        .neq("user_id", me)
        .order("enqueued_at", { ascending: true })
        .limit(1);
      const opp = cands && cands[0];
      if (!opp) return json({ matched: false, status: "waiting" });

      // 3) race-safe claim: only succeeds if they're still 'waiting'
      const { data: claimed } = await admin
        .from("matchmaking_queue")
        .update({ status: "matched", opponent_id: me })
        .eq("user_id", opp.user_id)
        .eq("status", "waiting")
        .select();
      if (!claimed || claimed.length === 0) return json({ matched: false, status: "waiting" });

      // 4) create scrim + lobby for the pair
      const { data: scrim } = await admin.from("scrims").insert({
        creator_id: opp.user_id, game: crit.game, format: crit.format,
        server: crit.server, rank: crit.rank, note: "Quick match", status: "scheduled",
      }).select().single();
      const { data: lobby } = await admin.from("lobbies").insert({
        scrim_id: scrim.id, server: crit.server, password: pass(), status: "veto",
        ranked: true, source: "matchmaking",   // opponent ASSIGNED → this match counts for GLR
      }).select().single();

      // register the joining player as a confirmed participant (opp is the scrim creator)
      // so both sides pass the finish_match participation check.
      await admin.from("scrim_responses").insert({
        scrim_id: scrim.id, responder_id: me, status: "confirmed",
      });

      // 5) finalize both queue rows
      await admin.from("matchmaking_queue").update({ status: "matched", lobby_id: lobby.id, opponent_id: me }).eq("user_id", opp.user_id);
      await admin.from("matchmaking_queue").update({ status: "matched", lobby_id: lobby.id, opponent_id: opp.user_id }).eq("user_id", me);

      // notify the opponent that a match was found
      await admin.from("notifications").insert({ user_id: opp.user_id, type: "match", data: { event: "quickmatch", lobby_id: lobby.id } });

      return json({ matched: true, lobby });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
