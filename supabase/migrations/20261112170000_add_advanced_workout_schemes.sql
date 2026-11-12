alter table public.workout_exercises
  add column if not exists execution_mode text not null default 'standard',
  add column if not exists set_scheme jsonb not null default '[]'::jsonb,
  add column if not exists circuit_id text,
  add column if not exists circuit_order integer,
  add column if not exists work_duration_seconds integer,
  add column if not exists transition_rest_seconds integer,
  add column if not exists round_rest_seconds integer,
  add column if not exists circuit_rounds integer;

alter table public.workout_sets
  add column if not exists scheme_type text not null default 'straight',
  add column if not exists scheme_data jsonb not null default '{}'::jsonb,
  add column if not exists duration_seconds integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='workout_exercises_execution_mode_chk'
      and conrelid='public.workout_exercises'::regclass
  ) then
    alter table public.workout_exercises
      add constraint workout_exercises_execution_mode_chk
      check (execution_mode in ('standard','circuit'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='workout_exercises_set_scheme_array_chk'
      and conrelid='public.workout_exercises'::regclass
  ) then
    alter table public.workout_exercises
      add constraint workout_exercises_set_scheme_array_chk
      check (jsonb_typeof(set_scheme)='array');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='workout_sets_scheme_type_chk'
      and conrelid='public.workout_sets'::regclass
  ) then
    alter table public.workout_sets
      add constraint workout_sets_scheme_type_chk
      check (scheme_type in ('straight','warmup','top_set','backoff','drop_set','rest_pause','cluster','myo_reps','tempo','isometric','amrap'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='workout_sets_scheme_data_object_chk'
      and conrelid='public.workout_sets'::regclass
  ) then
    alter table public.workout_sets
      add constraint workout_sets_scheme_data_object_chk
      check (jsonb_typeof(scheme_data)='object');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='workout_sets_duration_seconds_chk'
      and conrelid='public.workout_sets'::regclass
  ) then
    alter table public.workout_sets
      add constraint workout_sets_duration_seconds_chk
      check (duration_seconds is null or duration_seconds >= 0);
  end if;
end $$;
