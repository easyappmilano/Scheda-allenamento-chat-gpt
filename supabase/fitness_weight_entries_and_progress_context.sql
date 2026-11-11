
-- Add daily/periodic body weight entries and extend the aggregate context.
create table if not exists public.fitness_weight_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null,
  measured_at timestamptz not null default now(),
  weight_kg numeric(6,2) not null,
  data_source text not null default 'self_reported'
    check (data_source in ('measured','self_reported','estimated')),
  context jsonb not null default '{}'::jsonb,
  notes text,
  created_at timestamptz not null default now(),
  constraint fitness_weight_entries_positive check (weight_kg > 0),
  constraint fitness_weight_entries_user_source_unique unique (user_id, source_id)
);
create index if not exists fitness_weight_entries_user_date_idx
  on public.fitness_weight_entries(user_id, measured_at desc);
alter table public.fitness_weight_entries enable row level security;
grant select, insert, update, delete on public.fitness_weight_entries to authenticated;
drop policy if exists "Users manage own fitness weight entries" on public.fitness_weight_entries;
create policy "Users manage own fitness weight entries" on public.fitness_weight_entries
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
CREATE OR REPLACE FUNCTION public.get_training_context(p_user_id uuid, p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
),
weight_entries_7d as (
  select we.measured_at,we.weight_kg,we.data_source,we.context,we.notes
  from public.fitness_weight_entries we
  cross join params p
  where we.user_id=p.uid
    and we.measured_at<=p.as_of
    and we.measured_at>=p.as_of-interval '7 days'
),
weight_trend as (
  select
    count(*)::integer as readings,
    round(avg(weight_kg),2) as average_kg,
    round((array_agg(weight_kg order by measured_at desc))[1],2) as latest_kg
  from weight_entries_7d
  where coalesce(
    (context->>'include_in_average')::boolean,
    (context->>'standardized')::boolean,
    true
  ) = true
),
nutrition_days as (
  select ns.summary_date,ns.total_kcal,ns.total_protein_g,ns.total_carbs_g,ns.total_fat_g
  from public.daily_nutrition_summaries ns
  cross join params p
  where ns.user_id=p.uid
    and ns.summary_date >= (p.as_of at time zone 'Europe/Rome')::date-13
    and ns.summary_date <= (p.as_of at time zone 'Europe/Rome')::date
  order by ns.summary_date desc
)
select jsonb_build_object(
  'generated_at', (select as_of from params),
  'windows', jsonb_build_object(
    'muscle_group_recency_days', 7,
    'exercise_performance_days', 42,
    'exercise_sessions_returned_per_movement', 3,
    'weight_average_days', 7,
    'nutrition_summary_days', 14
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
  'body_weight_last_7_days', coalesce((
    select jsonb_agg(jsonb_build_object(
      'measured_at',w.measured_at,'weight_kg',w.weight_kg,
      'data_source',w.data_source,'context',w.context,'notes',w.notes
    ) order by w.measured_at desc)
    from weight_entries_7d w
  ), '[]'::jsonb),
  'body_weight_average_7_days', (select average_kg from weight_trend),
  'body_weight_latest_7_days', (select latest_kg from weight_trend),
  'body_weight_readings_7_days', (select readings from weight_trend),
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
  ), '[]'::jsonb),
  'nutrition_last_14_days', coalesce((
    select jsonb_agg(jsonb_build_object(
      'date',n.summary_date,'kcal',n.total_kcal,'protein_g',n.total_protein_g,
      'carbs_g',n.total_carbs_g,'fat_g',n.total_fat_g
    ) order by n.summary_date desc)
    from nutrition_days n
  ), '[]'::jsonb),
  'nutrition_average_14_days', coalesce((
    select jsonb_build_object(
      'days_recorded',count(*)::integer,
      'kcal',round(avg(total_kcal),1),
      'protein_g',round(avg(total_protein_g),1),
      'carbs_g',round(avg(total_carbs_g),1),
      'fat_g',round(avg(total_fat_g),1)
    ) from nutrition_days
  ), '{}'::jsonb)
);
$function$
;
;

revoke all on function public.get_training_context(uuid, timestamptz) from public;
revoke all on function public.get_training_context(uuid, timestamptz) from anon;
grant execute on function public.get_training_context(uuid, timestamptz) to authenticated;
