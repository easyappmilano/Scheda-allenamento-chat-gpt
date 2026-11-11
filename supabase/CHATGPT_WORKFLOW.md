# ChatGPT workflow — Tracciamento personale

## Architectural rule
ChatGPT is the only reasoning/planning layer. The app must not call an AI API or add an in-app assistant. Supabase is the durable personal archive. Do not change the existing three app tabs or the current workout session persistence/save logic for these workflows.

## Command: "Aggiornamento forma fisica"
1. Read the current context with `get_training_context(p_user_id)`.
2. Read missing profile/check-in details only. Ask conversationally; do not request information that is already current and confirmed.
3. Capture only user-confirmed values. Distinguish measured, self-reported, and estimated values. Never infer missing measurements.
4. Once the required answers are complete, write one idempotent row to `fitness_checkins` using a unique `source_id` (for example `chatgpt-checkin-YYYY-MM-DD-<stable-id>`).
5. Write each measurement to `fitness_measurements` linked to the new check-in. Use stable metric keys (e.g. `body_weight`, `body_fat_percent`, `waist`, `chest`, `arm`, `thigh`, `hips`) and `side` to distinguish left/right values.
6. Store individual weigh-ins in `fitness_weight_entries`, with a unique source_id, timestamp, kg, source and context. Use the 7-day average in `get_training_context`; do not mix non-standardized weigh-ins with standardized readings without flagging the context.
7. If photos are supplied, upload them to the private `fitness-progress-photos` bucket under `<auth-user-id>/<checkin-id>/...`, then insert references in `fitness_progress_photos`.
8. Verify the inserted rows with SELECT. Do not ask for a second approval once the complete check-in answers have already been given.

## Command: "Scheda allenamento"
1. Call `get_training_context(p_user_id)` once. It returns muscle groups from 7 days, exercise history from 42 days, the last three usable sessions per movement, quality flags, 7-day weight trend and 14-day nutrition summaries.
2. Use only actually recorded sets as completed work. Treat data quality flags as cautions; exclude sessions under two minutes from muscle-group and progression decisions. Do not treat planned or blank sets as completed.
3. Ask the user for available time if not already provided. Then show 2–3 relevant workout options, based on the 7-day split and 42-day performance history.
4. After the user chooses an option, create the workout and request explicit approval.
5. Only after approval, insert one row in `workout_plans` with a unique `user_id,source_id`, status `pending`, and `plan_data` matching:
   - schema: `fitness-assistant-response`
   - version: `1`
   - type: `workout_plan`
   - plan: title, focus, duration_minutes, warmup_minutes, warmup_notes, selection_mode, requested_groups, reasoning_summary, exercises.
6. Each exercise needs name, muscle_group, planned_sets, rep_range, rest_seconds, previous_reference, coaching_note and target_rir.
7. Check for an existing open pending/in-progress plan before inserting. Never intentionally create duplicate open plans. Verify the inserted plan by reading it back.
8. The app's existing polling and workout save flow remains unchanged.

## Nutrition
- Continue to use existing nutrition tables and the current operational targets in the profile.
- Record meals/ingredients and daily summaries only after the user confirms the day's food log.
- Do not change kcal/macros targets unless explicitly approved by the user.
- The training context contains up to 14 days of daily nutrition summaries for trend analysis.

## Backup and continuity
- Backup schema: `fitness-diary-backup`, version 4.
- Include workouts, sets, nutrition meals/entries/foods/recipes/photos/summaries, fitness profile, check-ins, measurements, progress photos, weight entries, and `continuity_data`.
- Embed binary photo data in the JSON backup so restore does not depend on old private Storage paths.
- Keep version 3 restore compatibility.
- On restore, map old check-in IDs to the newly upserted check-in IDs before restoring measurements/photos.
- Never automatically reactivate a historical workout plan during backup restore.
