-- Idempotent ChatGPT companion helper functions; source definitions are the deployed definitions.
create index if not exists fitness_progress_photos_checkin_id_idx on public.fitness_progress_photos(checkin_id);

CREATE OR REPLACE FUNCTION public.enqueue_workout_plan(p_user_id uuid, p_source_id text, p_plan_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  if p_plan_data->>'schema' is distinct from 'fitness-assistant-response'
     or p_plan_data->>'version' is distinct from '1'
     or p_plan_data->>'type' is distinct from 'workout_plan'
     or jsonb_typeof(p_plan_data#>'{plan,exercises}') is distinct from 'array'
     or jsonb_array_length(coalesce(p_plan_data#>'{plan,exercises}','[]'::jsonb)) < 1 then
    raise exception 'plan_data non rispetta il formato workout_plan supportato';
  end if;

  -- Serialize enqueue attempts per user to avoid concurrent duplicate open plans.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  select * into v_plan
  from public.workout_plans
  where user_id = p_user_id and source_id = p_source_id
  limit 1;

  if found then
    return jsonb_build_object(
      'id',v_plan.id,'status',v_plan.status,'source_id',v_plan.source_id,
      'created_at',v_plan.created_at,'already_existed',true,
      'blocked_by_open_plan',false
    );
  end if;

  select * into v_plan
  from public.workout_plans
  where user_id = p_user_id and status in ('pending','in_progress')
  order by case when status='in_progress' then 0 else 1 end, created_at asc
  limit 1
  for update;

  if found then
    return jsonb_build_object(
      'id',v_plan.id,'status',v_plan.status,'source_id',v_plan.source_id,
      'created_at',v_plan.created_at,'already_existed',true,
      'blocked_by_open_plan',true
    );
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
    'source_id', v_plan.source_id,
    'created_at', v_plan.created_at,
    'already_existed', v_inserted = 0,
    'blocked_by_open_plan', false
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.save_body_weight_entry(p_user_id uuid, p_source_id text, p_measured_at timestamp with time zone, p_weight_kg numeric, p_data_source text DEFAULT 'self_reported'::text, p_context jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_id uuid;
begin
  if p_user_id is null or nullif(trim(p_source_id), '') is null
     or p_measured_at is null or p_weight_kg is null or p_weight_kg <= 0 then
    raise exception 'user_id, source_id, measured_at e peso valido sono obbligatori';
  end if;
  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Non autorizzato';
  end if;
  if p_data_source not in ('measured','self_reported','estimated') then
    raise exception 'data_source non valido';
  end if;

  insert into public.fitness_weight_entries (
    user_id, source_id, measured_at, weight_kg, data_source, context, notes
  ) values (
    p_user_id, p_source_id, p_measured_at, p_weight_kg,
    p_data_source, coalesce(p_context, '{}'::jsonb), p_notes
  )
  on conflict (user_id, source_id) do update set
    measured_at = excluded.measured_at,
    weight_kg = excluded.weight_kg,
    data_source = excluded.data_source,
    context = excluded.context,
    notes = excluded.notes
  returning id into v_id;

  return jsonb_build_object('weight_entry_id',v_id,'weight_kg',p_weight_kg);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.save_fitness_checkin(p_user_id uuid, p_source_id text, p_checkin_date date, p_checkin_data jsonb DEFAULT '{}'::jsonb, p_physical_assessment text DEFAULT NULL::text, p_training_assessment text DEFAULT NULL::text, p_nutrition_assessment text DEFAULT NULL::text, p_recovery_assessment text DEFAULT NULL::text, p_next_period_focus jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL::text, p_measurements jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_checkin_id uuid;
  v_measurement jsonb;
  v_count integer := 0;
  v_metric_key text;
  v_metric_value numeric;
  v_unit text;
  v_side text;
  v_measured_date date;
  v_data_source text;
  v_measurement_notes text;
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

  for v_measurement in
    select value from jsonb_array_elements(coalesce(p_measurements, '[]'::jsonb))
  loop
    v_metric_key := nullif(v_measurement->>'metric_key', '');
    v_unit := nullif(v_measurement->>'unit', '');
    if v_metric_key is null or v_unit is null
       or nullif(v_measurement->>'metric_value', '') is null then
      raise exception 'Ogni misurazione richiede metric_key, metric_value e unit';
    end if;

    v_metric_value := (v_measurement->>'metric_value')::numeric;
    v_side := coalesce(nullif(v_measurement->>'side', ''), 'na');
    v_measured_date := coalesce(
      nullif(v_measurement->>'measured_at', '')::date,
      p_checkin_date,
      current_date
    );
    v_data_source := case
      when v_measurement->>'source' in ('measured','self_reported','estimated')
        then v_measurement->>'source'
      else 'self_reported'
    end;
    v_measurement_notes := v_measurement->>'notes';

    insert into public.fitness_measurements (
      user_id, checkin_id, metric_key, metric_value, unit, side,
      measured_at, source, notes
    ) values (
      p_user_id, v_checkin_id, v_metric_key, v_metric_value, v_unit, v_side,
      v_measured_date, v_data_source, v_measurement_notes
    )
    on conflict (checkin_id, metric_key, side) do update set
      metric_value = excluded.metric_value,
      unit = excluded.unit,
      measured_at = excluded.measured_at,
      source = excluded.source,
      notes = excluded.notes;
    v_count := v_count + 1;

    -- Keep the periodic check-in weight in the independent rolling weight log too.
    if v_metric_key = 'body_weight' then
      insert into public.fitness_weight_entries (
        user_id, source_id, measured_at, weight_kg, data_source, context, notes
      ) values (
        p_user_id,
        p_source_id || '-weight-' || v_side,
        (v_measured_date::timestamp at time zone 'Europe/Rome'),
        v_metric_value,
        v_data_source,
        jsonb_build_object(
          'origin', 'fitness_checkin',
          'checkin_source_id', p_source_id,
          'checkin_data', coalesce(p_checkin_data, '{}'::jsonb)
        ),
        v_measurement_notes
      )
      on conflict (user_id, source_id) do update set
        measured_at = excluded.measured_at,
        weight_kg = excluded.weight_kg,
        data_source = excluded.data_source,
        context = excluded.context,
        notes = excluded.notes;
    end if;
  end loop;

  return jsonb_build_object(
    'checkin_id', v_checkin_id,
    'measurements_saved', v_count,
    'weight_entries_saved', (
      select count(*) from public.fitness_weight_entries
      where user_id = p_user_id
        and source_id like p_source_id || '-weight-%'
    )
  );
end;
$function$
;

revoke all on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) from public, anon;
grant execute on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) to authenticated;
revoke all on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) from public, anon;
grant execute on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) to authenticated;
revoke all on function public.enqueue_workout_plan(uuid,text,jsonb) from public, anon;
grant execute on function public.enqueue_workout_plan(uuid,text,jsonb) to authenticated;
