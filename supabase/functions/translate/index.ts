// ============================================================================
// COLOSSO — Edge Function: translate
// Server-side translation so no API key lives in the browser and there's no CORS.
// Provider chain (first one configured wins, gtx is the keyless fallback):
//   1. DEEPL_API_KEY            → DeepL  (best quality)
//   2. GOOGLE_TRANSLATE_API_KEY → Google Cloud Translation v2
//   3. (none)                   → Google "gtx" endpoint, keyless
//
// Request : POST { "text": "olá, bora treinar", "target": "es" }
// Response: { "text": "hola, vamos a entrenar", "src": "pt" }
//
// Deploy  : supabase functions deploy translate
// Secrets : supabase secrets set DEEPL_API_KEY=...   (optional)
// ============================================================================

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonRes(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

async function viaGtx(text: string, target: string) {
  const url =
    `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${target}&dt=t&q=${encodeURIComponent(text)}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error("gtx " + r.status);
  const j = await r.json();
  const out = (j[0] || []).map((s: unknown[]) => s && s[0]).filter(Boolean).join("");
  const src = ((j[2] || "") + "").toLowerCase().split("-")[0];
  return { text: out || text, src };
}

async function viaDeepL(text: string, target: string, key: string) {
  const r = await fetch("https://api-free.deepl.com/v2/translate", {
    method: "POST",
    headers: {
      "Authorization": `DeepL-Auth-Key ${key}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ text, target_lang: target.toUpperCase() }),
  });
  if (!r.ok) throw new Error("deepl " + r.status);
  const j = await r.json();
  const t = j.translations?.[0];
  return { text: t?.text || text, src: (t?.detected_source_language || "").toLowerCase() };
}

async function viaGoogle(text: string, target: string, key: string) {
  const r = await fetch(
    `https://translation.googleapis.com/language/translate/v2?key=${key}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ q: text, target, format: "text" }),
    },
  );
  if (!r.ok) throw new Error("google " + r.status);
  const j = await r.json();
  const t = j.data?.translations?.[0];
  return {
    text: t?.translatedText || text,
    src: (t?.detectedSourceLanguage || "").toLowerCase(),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return jsonRes({ error: "POST only" }, 405);

  try {
    const { text, target } = await req.json();
    if (!text || !target) return jsonRes({ error: "text and target required" }, 400);

    const tgt = ("" + target).toLowerCase().split("-")[0];
    const deepl = Deno.env.get("DEEPL_API_KEY");
    const gkey = Deno.env.get("GOOGLE_TRANSLATE_API_KEY");

    let res;
    try {
      if (deepl) res = await viaDeepL(text, tgt, deepl);
      else if (gkey) res = await viaGoogle(text, tgt, gkey);
      else res = await viaGtx(text, tgt);
    } catch (_e) {
      res = await viaGtx(text, tgt); // last-resort fallback
    }

    // if detected source == target, nothing to translate — return original
    if (res.src && res.src === tgt) res.text = text;
    return jsonRes(res, 200);
  } catch (e) {
    return jsonRes({ error: String((e as Error)?.message || e) }, 500);
  }
});
