-- Personal fitness progress archive and optimized read-only training context.
-- Additive and idempotent: does not alter existing workout or nutrition tables.

create table if not exists public.fitness_profile (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  birth_date date,
  height_cm numeric(5,2),
  goal text,
  target_kcal integer,
  target_protein_g numeric(7,2),
  target_carbs_g numeric(7,2),
  target_fat_g numeric(7,2),
  training_frequency_min smallint,
  training_frequency_max smallint,
  activity_profile jsonb not null default '{}'::jsonb,
  preferences jsonb not null default '{}'::jsonb,
  constraints jsonb not null default '{}'::jsonb,
  notes text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint fitness_profile_height_positive check (height_cm is null or height_cm > 0),
  constraint fitness_profile_target_kcal_positive check (target_kcal is null or target_kcal > 0),
  constraint fitness_profile_frequency_range check (
    training_frequency_min is null or training_frequency_min between 0 and 14
  )
);

create table if not exists public.fitness_checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null,
  checkin_date date not null default current_date,
  checkin_data jsonb not null default '{}'::jsonb,
  physical_assessment text,
  training_assessment text,
  nutrition_assessment text,
  recovery_assessment text,
  next_period_focus jsonb not null default '{}'::jsonb,
  notes text,
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint fitness_checkins_user_source_unique unique (user_id, source_id)
);

create table if not exists public.fitness_measurements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  checkin_id uuid not null references public.fitness_checkins(id) on delete cascade,
  metric_key text not null,
  metric_value numeric(10,3) not null,
  unit text not null,
  side text not null default 'na',
  measured_at date not null default current_date,
  source text not null default 'self_reported'
    check (source in ('measured','self_reported','estimated')),
  notes text,
  created_at timestamptz not null default now(),
  constraint fitness_measurements_checkin_metric_unique unique (checkin_id, metric_key, side)
);

create table if not exists public.fitness_progress_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  checkin_id uuid not null references public.fitness_checkins(id) on delete cascade,
  storage_path text not null,
  photo_type text not null default 'other'
    check (photo_type in ('front','side','back','other')),
  caption text,
  mime_type text,
  created_at timestamptz not null default now(),
  constraint fitness_progress_photos_user_path_unique unique (user_id, storage_path)
);

create index if not exists fitness_checkins_user_date_idx
  on public.fitness_checkins(user_id, checkin_date desc);
create index if not exists fitness_measurements_user_metric_date_idx
  on public.fitness_measurements(user_id, metric_key, measured_at desc);
create index if not exists fitness_measurements_checkin_idx
  on public.fitness_measurements(checkin_id);
create index if not exists fitness_progress_photos_user_checkin_idx
  on public.fitness_progress_photos(user_id, checkin_id);

alter table public.fitness_profile enable row level security;
alter table public.fitness_checkins enable row level security;
alter table public.fitness_measurements enable row level security;
alter table public.fitness_progress_photos enable row level security;

grant select, insert, update, delete on public.fitness_profile,
  public.fitness_checkins, public.fitness_measurements,
  public.fitness_progress_photos to authenticated;

drop policy if exists "Users manage own fitness profile" on public.fitness_profile;
create policy "Users manage own fitness profile" on public.fitness_profile
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own fitness checkins" on public.fitness_checkins;
create policy "Users manage own fitness checkins" on public.fitness_checkins
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own fitness measurements" on public.fitness_measurements;
create policy "Users manage own fitness measurements" on public.fitness_measurements
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own fitness progress photos" on public.fitness_progress_photos;
create policy "Users manage own fitness progress photos" on public.fitness_progress_photos
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'fitness-progress-photos',
  'fitness-progress-photos',
  false,
  10485760,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do nothing;

drop policy if exists "Fitness progress photos read own" on storage.objects;
create policy "Fitness progress photos read own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'fitness-progress-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Fitness progress photos insert own" on storage.objects;
create policy "Fitness progress photos insert own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'fitness-progress-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Fitness progress photos update own" on storage.objects;
create policy "Fitness progress photos update own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'fitness-progress-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'fitness-progress-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Fitness progress photos delete own" on storage.objects;
create policy "Fitness progress photos delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'fitness-progress-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create or replace function public.get_training_context(
  p_user_id uuid,
  p_as_of timestamptz default now()
)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $function$
with
params as (
  select p_user_id as uid, p_as_of as as_of
),
window_workouts as (
  select w.id, w.started_at, w.finished_at, w.duration_seconds, w.plan_title
  from public.workouts w
  cross join params p
  where w.user_id = p.uid
    and w.status = 'completed'
    and w.finished_at is not null
    and w.finished_at <= p.as_of
    and w.finished_at >= p.as_of - interval '42 days'
),
exercise_sessions as (
  select
    w.id as workout_id,
    w.finished_at,
    w.plan_title,
    w.duration_seconds,
    e.exercise_name,
    coalesce(nullif(btrim(e.muscle_group), ''), 'Non specificato') as muscle_group,
    e.registered,
    count(s.id) filter (
      where s.completed = true
        and (s.weight_kg is not null or s.reps is not null or s.rir is not null)
    )::integer as completed_sets,
    count(s.id) filter (
      where s.completed = true
        and s.rir is not null
        and (s.rir < 0 or s.rir > 5)
    )::integer as out_of_range_rir_sets,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'set_number', s.set_number,
          'weight_kg', s.weight_kg,
          'reps', s.reps,
          'rir', s.rir,
          'rest_seconds', s.rest_seconds
        ) order by s.set_number
      ) filter (
        where s.id is not null
          and s.completed = true
          and (s.weight_kg is not null or s.reps is not null or s.rir is not null)
      ),
      '[]'::jsonb
    ) as sets
  from window_workouts w
  join public.workout_exercises e
    on e.workout_id = w.id
   and e.user_id = p_user_id
   and e.removed = false
  left join public.workout_sets s
    on s.workout_id = w.id
   and s.workout_exercise_id = e.id
   and s.user_id = p_user_id
  group by w.id, w.finished_at, w.plan_title, w.duration_seconds,
           e.exercise_name, e.muscle_group, e.registered
),
session_rollup as (
  select
    es.workout_id,
    max(es.finished_at) as finished_at,
    max(es.plan_title) as plan_title,
    max(es.duration_seconds) as duration_seconds,
    count(*)::integer as exercise_count,
    count(*) filter (where es.registered = false)::integer as unregistered_exercises,
    sum(es.completed_sets)::integer as completed_sets,
    sum(es.out_of_range_rir_sets)::integer as out_of_range_rir_sets,
    array_agg(distinct es.muscle_group order by es.muscle_group) as muscle_groups,
    case
      when max(es.duration_seconds) is not null and max(es.duration_seconds) < 120
        then array['session_under_2_minutes']::text[]
      when sum(es.completed_sets) < 3
        then array['few_sets_recorded']::text[]
      else array[]::text[]
    end
    ||
    case when count(*) filter (where es.registered = false) > 0
      then array['one_or_more_exercises_not_registered']::text[]
      else array[]::text[] end
    ||
    case when sum(es.out_of_range_rir_sets) > 0
      then array['rir_outside_common_0_to_5_scale']::text[]
      else array[]::text[] end as data_quality_flags
  from exercise_sessions es
  group by es.workout_id
),
ranked_exercise_sessions as (
  select
    es.*,
    row_number() over (
      partition by lower(es.exercise_name), lower(es.muscle_group)
      order by es.finished_at desc
    ) as recency_rank
  from exercise_sessions es
  where es.completed_sets > 0
    and (es.duration_seconds is null or es.duration_seconds >= 120)
),
weekly_groups as (
  select
    es.muscle_group,
    max(es.finished_at) as last_trained_at,
    count(distinct es.workout_id)::integer as sessions_count,
    sum(es.completed_sets)::integer as completed_sets,
    array_agg(distinct es.exercise_name order by es.exercise_name) as exercises,
    bool_or(sr.completed_sets < 3 or cardinality(sr.data_quality_flags) > 0) as contains_low_confidence_data
  from exercise_sessions es
  join session_rollup sr on sr.workout_id = es.workout_id
  cross join params p
  where es.finished_at >= p.as_of - interval '7 days'
    and es.completed_sets > 0
    and (es.duration_seconds is null or es.duration_seconds >= 120)
  group by es.muscle_group
),
exercise_history as (
  select
    r.exercise_name,
    r.muscle_group,
    max(r.finished_at) as last_performed_at,
    jsonb_agg(
      jsonb_build_object(
        'performed_at', r.finished_at,
        'plan_title', r.plan_title,
        'completed_sets', r.completed_sets,
        'sets', r.sets,
        'out_of_range_rir_sets', r.out_of_range_rir_sets
      ) order by r.finished_at desc
    ) filter (where r.recency_rank <= 3) as last_three_sessions
  from ranked_exercise_sessions r
  group by r.exercise_name, r.muscle_group
),
recent_sessions as (
  select * from session_rollup
  order by finished_at desc
  limit 12
)
select jsonb_build_object(
  'generated_at', (select as_of from params),
  'windows', jsonb_build_object(
    'muscle_group_recency_days', 7,
    'exercise_performance_days', 42,
    'exercise_sessions_returned_per_movement', 3
  ),
  'profile', coalesce((
    select to_jsonb(fp) - 'id' - 'user_id'
    from public.fitness_profile fp
    where fp.user_id = p_user_id
    limit 1
  ), '{}'::jsonb),
  'latest_checkin', coalesce((
    select jsonb_build_object(
      'checkin_id', c.id,
      'checkin_date', c.checkin_date,
      'checkin_data', c.checkin_data,
      'physical_assessment', c.physical_assessment,
      'training_assessment', c.training_assessment,
      'nutrition_assessment', c.nutrition_assessment,
      'recovery_assessment', c.recovery_assessment,
      'next_period_focus', c.next_period_focus,
      'measurements', coalesce((
        select jsonb_agg(jsonb_build_object(
          'metric_key', m.metric_key,
          'value', m.metric_value,
          'unit', m.unit,
          'side', m.side,
          'source', m.source,
          'notes', m.notes
        ) order by m.metric_key, m.side)
        from public.fitness_measurements m
        where m.checkin_id = c.id
          and m.user_id = p_user_id
      ), '[]'::jsonb)
    )
    from public.fitness_checkins c
    where c.user_id = p_user_id
    order by c.checkin_date desc, c.completed_at desc
    limit 1
  ), '{}'::jsonb),
  'muscle_groups_last_7_days', coalesce((
    select jsonb_agg(to_jsonb(g) order by g.last_trained_at desc)
    from weekly_groups g
  ), '[]'::jsonb),
  'exercise_history_last_42_days', coalesce((
    select jsonb_agg(jsonb_build_object(
      'exercise_name', h.exercise_name,
      'muscle_group', h.muscle_group,
      'last_performed_at', h.last_performed_at,
      'last_three_sessions', h.last_three_sessions
    ) order by h.last_performed_at desc)
    from exercise_history h
  ), '[]'::jsonb),
  'recent_sessions_last_42_days', coalesce((
    select jsonb_agg(jsonb_build_object(
      'finished_at', s.finished_at,
      'plan_title', s.plan_title,
      'duration_seconds', s.duration_seconds,
      'exercise_count', s.exercise_count,
      'unregistered_exercises', s.unregistered_exercises,
      'completed_sets', s.completed_sets,
      'muscle_groups', s.muscle_groups,
      'data_quality_flags', s.data_quality_flags
    ) order by s.finished_at desc)
    from recent_sessions s
  ), '[]'::jsonb)
);
$function$;

revoke all on function public.get_training_context(uuid, timestamptz) from public;
revoke all on function public.get_training_context(uuid, timestamptz) from anon;
grant execute on function public.get_training_context(uuid, timestamptz) to authenticated;
