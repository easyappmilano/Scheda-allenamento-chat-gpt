-- Keep the preview schema compatible with workout persistence while the
-- get_training_context function replacement remains separately gated.
alter table public.workout_exercises
  add column if not exists exercise_type text;
