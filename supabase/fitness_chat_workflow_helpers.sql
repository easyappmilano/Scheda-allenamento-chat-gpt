-- Index for the fitness_progress_photos.checkin_id foreign key.
create index if not exists fitness_progress_photos_checkin_id_idx on public.fitness_progress_photos(checkin_id);

-- ChatGPT companion helpers. Additive only; existing workout/nutrition tables are unchanged.
-- The functions are SECURITY INVOKER and enforce the authenticated user's own user_id.

create or replace function public.save_fitness_checkin(
  p_user_id uuid,
  p_source_id text,
  p_checkin_date date,
  p_checkin_data jsonb default '{}'::jsonb,
  p_physical_assessment text default null,
  p_training_assessment text default null,
  p_nutrition_assessment text default null,
  p_recovery_assessment text default null,
  p_next_period_focus jsonb default '{}'::jsonb,
  p_notes text default null,
  p_measurements jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_checkin_id uuid;
  v_measurement jsonb;
  v_count integer := 0;
begin
  if p_user_id is null or nullif(trim(p_source_id), '') is null then
    raise exception 'user_id e source_id sono obbligatori';
  end if;
  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Non autorizzato';
  end if;
  if jsonb_typeof(coalesce(p_measurements, '[]'::jsonb)) <> 'array' then
    raise exception 'p_measurements deve essere un array JSON';
  end if;

  insert into public.fitness_checkins (
    user_id, source_id, checkin_date, checkin_data,
    physical_assessment, training_assessment, nutrition_assessment,
    recovery_assessment, next_period_focus, notes, completed_at
  ) values (
    p_user_id, p_source_id, coalesce(p_checkin_date, current_date),
    coalesce(p_checkin_data, '{}'::jsonb),
    p_physical_assessment, p_training_assessment, p_nutrition_assessment,
    p_recovery_assessment, coalesce(p_next_period_focus, '{}'::jsonb),
    p_notes, now()
  )
  on conflict (user_id, source_id) do update set
    checkin_date = excluded.checkin_date,
    checkin_data = excluded.checkin_data,
    physical_assessment = excluded.physical_assessment,
    training_assessment = excluded.training_assessment,
    nutrition_assessment = excluded.nutrition_assessment,
    recovery_assessment = excluded.recovery_assessment,
    next_period_focus = excluded.next_period_focus,
    notes = excluded.notes,
    completed_at = excluded.completed_at
  returning id into v_checkin_id;

  for v_measurement in select value from jsonb_array_elements(coalesce(p_measurements, '[]'::jsonb))
  loop
    if nullif(v_measurement->>'metric_key', '') is null
       or nullif(v_measurement->>'unit', '') is null
       or nullif(v_measurement->>'metric_value', '') is null then
      raise exception 'Ogni misurazione richiede metric_key, metric_value e unit';
    end if;

    insert into public.fitness_measurements (
      user_id, checkin_id, metric_key, metric_value, unit, side,
      measured_at, source, notes
    ) values (
      p_user_id, v_checkin_id,
      v_measurement->>'metric_key',
      (v_measurement->>'metric_value')::numeric,
      v_measurement->>'unit',
      coalesce(nullif(v_measurement->>'side', ''), 'na'),
      coalesce(nullif(v_measurement->>'measured_at', '')::date, p_checkin_date, current_date),
      case when v_measurement->>'source' in ('measured','self_reported','estimated')
        then v_measurement->>'source' else 'self_reported' end,
      v_measurement->>'notes'
    )
    on conflict (checkin_id, metric_key, side) do update set
      metric_value = excluded.metric_value,
      unit = excluded.unit,
      measured_at = excluded.measured_at,
      source = excluded.source,
      notes = excluded.notes;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('checkin_id', v_checkin_id, 'measurements_saved', v_count);
end;
$$;

create or replace function public.enqueue_workout_plan(
  p_user_id uuid,
  p_source_id text,
  p_plan_data jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_plan public.workout_plans%rowtype;
  v_inserted integer := 0;
begin
  if p_user_id is null or nullif(trim(p_source_id), '') is null or p_plan_data is null then
    raise exception 'user_id, source_id e plan_data sono obbligatori';
  end if;
  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Non autorizzato';
  end if;

  insert into public.workout_plans (user_id, source_id, plan_data, status)
  values (p_user_id, p_source_id, p_plan_data, 'pending')
  on conflict (user_id, source_id) do nothing;
  get diagnostics v_inserted = row_count;

  select * into v_plan
  from public.workout_plans
  where user_id = p_user_id and source_id = p_source_id;

  return jsonb_build_object(
    'id', v_plan.id,
    'status', v_plan.status,
    'created_at', v_plan.created_at,
    'already_existed', v_inserted = 0
  );
end;
$$;

revoke all on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) from public, anon;
grant execute on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) to authenticated;
revoke all on function public.enqueue_workout_plan(uuid,text,jsonb) from public, anon;
grant execute on function public.enqueue_workout_plan(uuid,text,jsonb) to authenticated;
