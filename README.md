# Scheda allenamento — Tracciamento personale

App personale pubblicata con GitHub Pages. L'app gestisce registrazione interattiva dell'allenamento, visualizzazione alimentazione giornaliera e backup JSON.

La pianificazione e l'analisi restano in ChatGPT; non è prevista alcuna API AI nell'app.

## Struttura
- `index.html`: applicazione web.
- `supabase/schema_nutrition_v2.sql`: schema cumulativo (migrazioni additive).
- `supabase/fitness_progress_and_training_context.sql`: profilo, check-in, misurazioni, foto e RPC di contesto.
- `supabase/fitness_weight_entries_and_progress_context.sql`: pesate puntuali, media 7 giorni e riepiloghi nutrizionali 14 giorni.
- `supabase/fitness_chat_workflow_helpers.sql`: funzioni transazionali per check-in, pesate, foto e accodamento schede.
- `supabase/CHATGPT_WORKFLOW.md`: protocollo conversazionale per ChatGPT.

## Flussi
- Allenamento: ChatGPT legge il contesto, propone opzioni, attende approvazione e inserisce una riga nella coda `workout_plans`. L'app mantiene il proprio flusso esistente.
- Aggiornamento forma fisica: questionario conversazionale in ChatGPT, registrazione in Supabase solo a risposte complete.
- Backup: JSON v4 completo con continuità tra conversazioni e ripristino compatibile con v3.

## Sicurezza
Le nuove tabelle hanno RLS abilitato e sono limitate all'utente autenticato. Le fotografie dei progressi sono conservate nel database con RLS, formato validato e limite di circa 10 MB per immagine.
