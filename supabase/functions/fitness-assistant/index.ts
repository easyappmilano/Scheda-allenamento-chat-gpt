// Supabase Edge Function: fitness-assistant
// Secrets da impostare in Supabase > Edge Functions > Secrets:
// OPENAI_API_KEY = chiave API OpenAI personale
// OPENAI_MODEL = gpt-6-luna (opzionale; modello predefinito economico)

import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getPublishableKey(): string {
  const raw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed.default) return parsed.default;
      const first = Object.values(parsed)[0];
      if (typeof first === "string") return first;
    } catch (_) {}
  }
  const legacy = Deno.env.get("SUPABASE_ANON_KEY");
  if (legacy) return legacy;
  throw new Error("Chiave pubblica Supabase non disponibile nell'ambiente Edge Function.");
}

function extractOutputText(data: any): string {
  if (typeof data.output_text === "string") return data.output_text;
  const parts: string[] = [];
  for (const item of data.output || []) {
    for (const content of item.content || []) {
      if (content.type === "output_text" && typeof content.text === "string") parts.push(content.text);
    }
  }
  return parts.join("\n").trim();
}

function parseJson(text: string): any {
  const cleaned = text.trim().replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "");
  return JSON.parse(cleaned);
}

async function loadContext(supabase: any, userId: string, action: string) {
  if (action === "generate_workout") {
    const wr = await supabase.from("workouts").select("id,finished_at,status,plan_title,started_at")
      .eq("user_id", userId).order("finished_at", { ascending: false }).limit(12);
    if (wr.error) throw wr.error;
    const ids = (wr.data || []).map((x: any) => x.id);
    let exercises: any[] = [];
    let sets: any[] = [];
    if (ids.length) {
      const er = await supabase.from("workout_exercises")
        .select("id,workout_id,exercise_name,muscle_group,exercise_order,planned_sets,rest_seconds,previous_reference,registered,removed")
        .eq("user_id", userId).in("workout_id", ids).order("exercise_order");
      if (er.error) throw er.error;
      exercises = er.data || [];
      const eids = exercises.map((x: any) => x.id);
      if (eids.length) {
        const sr = await supabase.from("workout_sets")
          .select("workout_exercise_id,set_number,weight_kg,reps,rir,completed")
          .eq("user_id", userId).in("workout_exercise_id", eids).order("set_number");
        if (sr.error) throw sr.error;
        sets = sr.data || [];
      }
    }
    return { workouts: wr.data || [], exercises, sets };
  }

  const [fr, mr] = await Promise.all([
    supabase.from("nutrition_foods").select("name,category,unit,kcal_100g,protein_100g,carbs_100g,fat_100g,data_source")
      .eq("user_id", userId).order("name").limit(100),
    supabase.from("nutrition_meals").select("id,meal_date,meal_type,title,status")
      .eq("user_id", userId).order("meal_date", { ascending: false }).limit(35),
  ]);
  if (fr.error) throw fr.error;
  if (mr.error) throw mr.error;
  const meals = mr.data || [];
  const ids = meals.map((x: any) => x.id);
  let entries: any[] = [];
  if (ids.length) {
    const er = await supabase.from("nutrition_entries")
      .select("meal_id,food_name,quantity,unit,calories,protein_g,carbs_g,fat_g,data_source")
      .eq("user_id", userId).in("meal_id", ids);
    if (er.error) throw er.error;
    entries = er.data || [];
  }
  return { saved_foods: fr.data || [], recent_meals: meals, recent_entries: entries };
}

function buildInstructions(action: string, payload: any, context: any): string {
  const base = [
    "Sei l'assistente personale di tracciamento fitness e nutrizione.",
    "Rispondi esclusivamente con un oggetto JSON valido, senza markdown e senza testo esterno.",
    "Non inventare dati storici, carichi o valori letti da etichette. Distingui dati verificati e stime.",
    "Non fare diagnosi mediche e non consigliare di allenarsi attraverso dolore acuto o infortuni."
  ];
  if (action === "generate_workout") return base.concat([
    "Crea una sola proposta di allenamento eseguibile.",
    "Usa lo storico per considerare recupero, frequenza, carichi e serie precedenti.",
    "Rispetta i minuti allenanti comunicati: i 5 minuti di riscaldamento sono già sottratti.",
    "In modalità auto scegli tu i gruppi più opportuni; in modalità manuale rispetta i gruppi selezionati.",
    "Programma serie, range ripetizioni, recuperi e note tecniche. Evita il cedimento sistematico e indica un target RIR ragionevole.",
    "Non inventare carichi precedenti; se assenti scrivi Nessun riferimento registrato.",
    'Schema JSON: {"title":"...","focus":"...","duration_minutes":45,"warmup_minutes":5,"selection_mode":"auto|manual","requested_groups":["..."],"exercises":[{"name":"...","muscle_group":"...","planned_sets":3,"rep_range":"8-12","rest_seconds":90,"previous_reference":"...","coaching_note":"...","target_rir":"1-3"}],"reasoning_summary":"breve spiegazione"}',
    "RICHIESTA: " + JSON.stringify(payload),
    "STORICO: " + JSON.stringify(context)
  ]).join("\n");

  return base.concat([
    "Interpreta un diario alimentare oppure crea un pasto/ricetta adatto alla richiesta.",
    "Target giornalieri fissi: 1900 kcal, proteine 129 g, carboidrati 192 g, grassi 68 g. Non modificarli.",
    "Se l'utente registra pasti, estrai tutti gli alimenti e suddividili per pasto. Se manca una quantità ma la stima è ragionevole, segnalala; se non lo è, formula una domanda.",
    "Se l'utente chiede una ricetta, usa prima ingredienti dichiarati e catalogo salvato. Mira ai macro richiesti senza forzare valori impossibili.",
    "Distingui programmato e consumato. Per ogni alimento indica dati per 100 g/ml, quantità, valori calcolati della porzione e provenienza. Non inventare dati di etichette.",
    "Unità ammesse: g e ml. Mantieni esplicito se il peso si riferisce a alimento crudo o cotto.",
    'Schema JSON: {"summary":"...","questions":[],"warnings":[],"meals":[{"meal_type":"Colazione|Spuntino mattina|Pranzo|Spuntino pomeriggio|Cena|Altro","title":"...","status":"consumed|planned","items":[{"food_name":"...","category":"...","quantity":100,"unit":"g","kcal_100g":100,"protein_100g":10,"carbs_100g":10,"fat_100g":10,"calories":100,"protein_g":10,"carbs_g":10,"fat_g":10,"data_source":"estimated|label|user_provided","source_note":"..."}]}],"day_totals":{"consumed":{"kcal":0,"protein_g":0,"carbs_g":0,"fat_g":0},"planned":{"kcal":0,"protein_g":0,"carbs_g":0,"fat_g":0}}}',
    "TARGET: " + JSON.stringify({ kcal: 1900, protein_g: 129, carbs_g: 192, fat_g: 68 }),
    "RICHIESTA: " + JSON.stringify(payload),
    "CONTESTO: " + JSON.stringify(context)
  ]).join("\n");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Metodo non consentito." }, 405);
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) return jsonResponse({ error: "Effettua il login." }, 401);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const openAiKey = Deno.env.get("OPENAI_API_KEY");
    const model = Deno.env.get("OPENAI_MODEL") || "gpt-6-luna";
    if (!supabaseUrl) throw new Error("SUPABASE_URL non configurato.");
    if (!openAiKey) throw new Error("OPENAI_API_KEY non configurata nei Secrets Supabase.");

    const supabase = createClient(supabaseUrl, getPublishableKey(), {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return jsonResponse({ error: "Sessione non valida. Accedi nuovamente." }, 401);
    const userId = userData.user.id;

    const body = await req.json();
    const action = body.action;
    if (!["generate_workout", "nutrition_assist"].includes(action)) return jsonResponse({ error: "Azione non supportata." }, 400);
    const payload = body.payload || {};
    if (JSON.stringify(payload).length > 7000) return jsonResponse({ error: "Richiesta troppo lunga. Dividila in più operazioni." }, 413);

    const since = new Date(Date.now() - 86400000).toISOString();
    const usage = await supabase.from("assistant_usage").select("id", { count: "exact", head: true })
      .eq("user_id", userId).gte("created_at", since);
    if (usage.error) throw usage.error;
    if ((usage.count || 0) >= 35) return jsonResponse({ error: "Limite temporaneo: 35 richieste AI nelle ultime 24 ore." }, 429);
    const log = await supabase.from("assistant_usage").insert({ user_id: userId, action });
    if (log.error) throw log.error;

    const context = await loadContext(supabase, userId, action);
    const aiResponse = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Authorization": "Bearer " + openAiKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        instructions: buildInstructions(action, payload, context),
        input: "Genera il risultato richiesto in JSON.",
        text: { format: { type: "json_object" } },
        max_output_tokens: action === "generate_workout" ? 2500 : 3500
      })
    });
    const responseBody = await aiResponse.json();
    if (!aiResponse.ok) return jsonResponse({ error: responseBody?.error?.message || "Errore del servizio AI." }, aiResponse.status);
    const output = extractOutputText(responseBody);
    if (!output) throw new Error("Il modello non ha restituito un risultato testuale.");
    return jsonResponse({ result: parseJson(output), model, usage: responseBody.usage || null });
  } catch (error) {
    console.error("fitness-assistant:", error);
    return jsonResponse({ error: error instanceof Error ? error.message : "Errore interno." }, 500);
  }
});
