-- Le schede create qui in ChatGPT vengono salvate con i relativi metadati.
alter table public.workouts
  add column if not exists ai_generated boolean not null default false,
  add column if not exists selection_mode text,
  add column if not exists requested_groups text[];

alter table public.workout_exercises
  add column if not exists coaching_note text,
  add column if not exists target_rir text;

-- Archivio personale di alimentazione, compatibile con la prima versione del diario.
-- Eseguire una volta da Supabase > SQL Editor > New query.
-- Le tabelle workout già esistenti non vengono cancellate né ricreate.

create table if not exists public.nutrition_meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text,
  meal_date date not null default current_date,
  meal_type text not null,
  title text,
  status text not null default 'consumed'
    check (status in ('planned','consumed')),
  notes text,
  legacy_description text,
  total_kcal numeric(10,2),
  total_protein_g numeric(10,2),
  total_carbs_g numeric(10,2),
  total_fat_g numeric(10,2),
  totals_source text,
  created_at timestamptz not null default now()
);

create table if not exists public.nutrition_foods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  category text,
  unit text not null default 'g',
  kcal_100g numeric(10,2) not null default 0,
  protein_100g numeric(10,2) not null default 0,
  carbs_100g numeric(10,2) not null default 0,
  fat_100g numeric(10,2) not null default 0,
  data_source text not null default 'estimated'
    check (data_source in ('label','user_provided','estimated')),
  barcode text,
  created_at timestamptz not null default now(),
  unique(user_id,name)
);

create table if not exists public.nutrition_entries (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid references public.nutrition_meals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text,
  food_id uuid references public.nutrition_foods(id) on delete set null,
  entry_date date,
  meal_type text,
  status text not null default 'consumed',
  food_name text not null,
  category text,
  quantity numeric(10,2) not null default 0,
  unit text not null default 'g',
  kcal_100g numeric(10,2) not null default 0,
  protein_100g numeric(10,2) not null default 0,
  carbs_100g numeric(10,2) not null default 0,
  fat_100g numeric(10,2) not null default 0,
  calories numeric(10,2) not null default 0,
  protein_g numeric(10,2) not null default 0,
  carbs_g numeric(10,2) not null default 0,
  fat_g numeric(10,2) not null default 0,
  data_source text not null default 'estimated'
    check (data_source in ('label','user_provided','estimated')),
  source_note text,
  created_at timestamptz not null default now()
);

-- Aggiornamento sicuro delle tabelle se erano già state create con la prima versione.
alter table public.nutrition_meals
  add column if not exists source_id text,
  add column if not exists legacy_description text,
  add column if not exists total_kcal numeric(10,2),
  add column if not exists total_protein_g numeric(10,2),
  add column if not exists total_carbs_g numeric(10,2),
  add column if not exists total_fat_g numeric(10,2),
  add column if not exists totals_source text;

alter table public.nutrition_foods
  add column if not exists unit text not null default 'g',
  add column if not exists data_source text not null default 'estimated',
  add column if not exists barcode text;

alter table public.nutrition_entries
  add column if not exists meal_id uuid,
  add column if not exists source_id text,
  add column if not exists food_id uuid,
  add column if not exists entry_date date,
  add column if not exists meal_type text,
  add column if not exists status text not null default 'consumed',
  add column if not exists kcal_100g numeric(10,2) not null default 0,
  add column if not exists protein_100g numeric(10,2) not null default 0,
  add column if not exists carbs_100g numeric(10,2) not null default 0,
  add column if not exists fat_100g numeric(10,2) not null default 0,
  add column if not exists data_source text not null default 'estimated',
  add column if not exists source_note text;

-- Migra vecchie righe senza contenitore-pasto, se esistono.
do $$
declare
  has_old_date boolean;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='nutrition_entries'
      and column_name='entry_date'
  ) into has_old_date;

  if has_old_date then
    insert into public.nutrition_meals
      (user_id,source_id,meal_date,meal_type,title,status)
    select distinct
      e.user_id,
      'legacy:' || e.user_id::text || ':' || e.entry_date::text || ':' ||
        coalesce(e.meal_type,'Altro') || ':' || coalesce(e.status,'consumed'),
      e.entry_date,
      coalesce(e.meal_type,'Altro'),
      coalesce(e.meal_type,'Altro'),
      case when e.status='planned' then 'planned' else 'consumed' end
    from public.nutrition_entries e
    where e.meal_id is null and e.entry_date is not null
      and not exists (
        select 1 from public.nutrition_meals m
        where m.user_id=e.user_id
          and m.source_id='legacy:' || e.user_id::text || ':' || e.entry_date::text || ':' ||
            coalesce(e.meal_type,'Altro') || ':' || coalesce(e.status,'consumed')
      );

    update public.nutrition_entries e
    set meal_id=m.id
    from public.nutrition_meals m
    where e.meal_id is null
      and e.entry_date=m.meal_date
      and e.user_id=m.user_id
      and coalesce(e.meal_type,'Altro')=m.meal_type
      and (case when e.status='planned' then 'planned' else 'consumed' end)=m.status;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='nutrition_entries_meal_id_fkey') then
    alter table public.nutrition_entries
      add constraint nutrition_entries_meal_id_fkey
      foreign key (meal_id) references public.nutrition_meals(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname='nutrition_entries_food_id_fkey') then
    alter table public.nutrition_entries
      add constraint nutrition_entries_food_id_fkey
      foreign key (food_id) references public.nutrition_foods(id) on delete set null;
  end if;
end $$;

drop index if exists public.nutrition_meals_user_source_uq;
create unique index nutrition_meals_user_source_uq
  on public.nutrition_meals(user_id,source_id);
drop index if exists public.nutrition_entries_user_source_uq;
create unique index nutrition_entries_user_source_uq
  on public.nutrition_entries(user_id,source_id);
create index if not exists nutrition_meals_user_date_idx
  on public.nutrition_meals(user_id,meal_date desc);
create index if not exists nutrition_entries_meal_idx
  on public.nutrition_entries(meal_id);
create index if not exists nutrition_foods_user_idx
  on public.nutrition_foods(user_id);

alter table public.nutrition_meals enable row level security;
alter table public.nutrition_entries enable row level security;
alter table public.nutrition_foods enable row level security;

revoke all on public.nutrition_meals from anon,authenticated;
revoke all on public.nutrition_entries from anon,authenticated;
revoke all on public.nutrition_foods from anon,authenticated;
grant select,insert,update,delete on public.nutrition_meals to authenticated;
grant select,insert,update,delete on public.nutrition_entries to authenticated;
grant select,insert,update,delete on public.nutrition_foods to authenticated;

drop policy if exists "Users manage own nutrition meals" on public.nutrition_meals;
create policy "Users manage own nutrition meals"
  on public.nutrition_meals for all to authenticated
  using ((select auth.uid())=user_id)
  with check ((select auth.uid())=user_id);

drop policy if exists "Users manage own nutrition entries" on public.nutrition_entries;
create policy "Users manage own nutrition entries"
  on public.nutrition_entries for all to authenticated
  using ((select auth.uid())=user_id)
  with check ((select auth.uid())=user_id);

drop policy if exists "Users manage own nutrition foods" on public.nutrition_foods;
create policy "Users manage own nutrition foods"
  on public.nutrition_foods for all to authenticated
  using ((select auth.uid())=user_id)
  with check ((select auth.uid())=user_id);


-- ---------------------------------------------------------------------------
-- Estensione 2026-11: coda piani ChatGPT, ricette, foto e riepilogo giornaliero
-- ---------------------------------------------------------------------------

create table if not exists public.workout_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null,
  plan_data jsonb not null,
  status text not null default 'pending'
    check (status in ('pending','in_progress','completed','cancelled')),
  started_at timestamptz,
  completed_at timestamptz,
  workout_id uuid references public.workouts(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(user_id,source_id)
);
create index if not exists workout_plans_user_status_idx
  on public.workout_plans(user_id,status,created_at desc);

create table if not exists public.nutrition_recipes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text,
  name text not null,
  description text,
  ingredients jsonb not null default '[]'::jsonb,
  instructions jsonb not null default '[]'::jsonb,
  servings numeric(8,2),
  total_kcal numeric(10,2),
  total_protein_g numeric(10,2),
  total_carbs_g numeric(10,2),
  total_fat_g numeric(10,2),
  photo_path text,
  created_at timestamptz not null default now()
);
create unique index if not exists nutrition_recipes_user_source_uq
  on public.nutrition_recipes(user_id,source_id);
create index if not exists nutrition_recipes_user_idx
  on public.nutrition_recipes(user_id);

create table if not exists public.nutrition_food_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  food_id uuid references public.nutrition_foods(id) on delete cascade,
  storage_path text not null,
  image_data text,
  mime_type text,
  caption text,
  created_at timestamptz not null default now()
);
create unique index if not exists nutrition_food_photos_user_path_uq
  on public.nutrition_food_photos(user_id,storage_path);
create index if not exists nutrition_food_photos_food_idx
  on public.nutrition_food_photos(food_id);

create table if not exists public.daily_nutrition_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  summary_date date not null,
  total_kcal numeric(10,2) not null default 0,
  total_protein_g numeric(10,2) not null default 0,
  total_carbs_g numeric(10,2) not null default 0,
  total_fat_g numeric(10,2) not null default 0,
  notes text,
  source_id text,
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id,summary_date)
);

alter table public.nutrition_meals
  add column if not exists recipe_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='nutrition_meals_recipe_id_fkey'
  ) then
    alter table public.nutrition_meals
      add constraint nutrition_meals_recipe_id_fkey
      foreign key (recipe_id) references public.nutrition_recipes(id) on delete set null;
  end if;
end $$;

alter table public.nutrition_food_photos
  add column if not exists image_data text,
  add column if not exists mime_type text;

alter table public.workout_plans enable row level security;
alter table public.nutrition_recipes enable row level security;
alter table public.nutrition_food_photos enable row level security;
alter table public.daily_nutrition_summaries enable row level security;

revoke all on public.workout_plans,public.nutrition_recipes,
  public.nutrition_food_photos,public.daily_nutrition_summaries
  from anon,authenticated;
grant select,insert,update,delete on public.workout_plans,public.nutrition_recipes,
  public.nutrition_food_photos,public.daily_nutrition_summaries to authenticated;

drop policy if exists "Users manage own workout plans" on public.workout_plans;
create policy "Users manage own workout plans" on public.workout_plans
 for all to authenticated using ((select auth.uid())=user_id)
 with check ((select auth.uid())=user_id);

drop policy if exists "Users manage own nutrition recipes" on public.nutrition_recipes;
create policy "Users manage own nutrition recipes" on public.nutrition_recipes
 for all to authenticated using ((select auth.uid())=user_id)
 with check ((select auth.uid())=user_id);

drop policy if exists "Users manage own nutrition food photos" on public.nutrition_food_photos;
create policy "Users manage own nutrition food photos" on public.nutrition_food_photos
 for all to authenticated using ((select auth.uid())=user_id)
 with check ((select auth.uid())=user_id);

drop policy if exists "Users manage own daily nutrition summaries" on public.daily_nutrition_summaries;
create policy "Users manage own daily nutrition summaries" on public.daily_nutrition_summaries
 for all to authenticated using ((select auth.uid())=user_id)
 with check ((select auth.uid())=user_id);

insert into storage.buckets(id,name,public)
values ('nutrition-food-photos','nutrition-food-photos',false)
on conflict (id) do nothing;

drop policy if exists "Users read own nutrition food photos" on storage.objects;
create policy "Users read own nutrition food photos" on storage.objects
 for select to authenticated
 using (bucket_id='nutrition-food-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users upload own nutrition food photos" on storage.objects;
create policy "Users upload own nutrition food photos" on storage.objects
 for insert to authenticated
 with check (bucket_id='nutrition-food-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users update own nutrition food photos" on storage.objects;
create policy "Users update own nutrition food photos" on storage.objects
 for update to authenticated
 using (bucket_id='nutrition-food-photos' and (storage.foldername(name))[1]=(select auth.uid())::text)
 with check (bucket_id='nutrition-food-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users delete own nutrition food photos" on storage.objects;
create policy "Users delete own nutrition food photos" on storage.objects
 for delete to authenticated
 using (bucket_id='nutrition-food-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);

create or replace function public.refresh_daily_nutrition_summary(p_date date)
returns public.daily_nutrition_summaries
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_result public.daily_nutrition_summaries;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  insert into public.daily_nutrition_summaries (
    user_id,summary_date,total_kcal,total_protein_g,total_carbs_g,total_fat_g,finalized_at
  )
  select v_user,p_date,
    coalesce(sum(coalesce(m.total_kcal,e.kcal)),0),
    coalesce(sum(coalesce(m.total_protein_g,e.protein_g)),0),
    coalesce(sum(coalesce(m.total_carbs_g,e.carbs_g)),0),
    coalesce(sum(coalesce(m.total_fat_g,e.fat_g)),0),
    now()
  from public.nutrition_meals m
  left join lateral (
    select sum(n.calories) kcal,sum(n.protein_g) protein_g,
      sum(n.carbs_g) carbs_g,sum(n.fat_g) fat_g
    from public.nutrition_entries n
    where n.meal_id=m.id and n.user_id=v_user
  ) e on true
  where m.user_id=v_user and m.meal_date=p_date and m.status='consumed'
  on conflict (user_id,summary_date) do update set
    total_kcal=excluded.total_kcal,
    total_protein_g=excluded.total_protein_g,
    total_carbs_g=excluded.total_carbs_g,
    total_fat_g=excluded.total_fat_g,
    finalized_at=excluded.finalized_at
  returning * into v_result;
  return v_result;
end;
$$;
grant execute on function public.refresh_daily_nutrition_summary(date) to authenticated;


-- Indici FK mancanti e policy RLS ottimizzate per l'utente autenticato.
create index if not exists workout_exercises_user_id_idx on public.workout_exercises(user_id);
create index if not exists workout_sets_user_id_idx on public.workout_sets(user_id);
create index if not exists workout_sets_workout_id_idx on public.workout_sets(workout_id);
create index if not exists workout_plans_workout_id_idx on public.workout_plans(workout_id);
create index if not exists nutrition_entries_food_id_idx on public.nutrition_entries(food_id);

drop policy if exists "Owner manages workouts" on public.workouts;
create policy "Owner manages workouts" on public.workouts
 for all to authenticated using (user_id=(select auth.uid()))
 with check (user_id=(select auth.uid()));

drop policy if exists "Owner manages exercises" on public.workout_exercises;
create policy "Owner manages exercises" on public.workout_exercises
 for all to authenticated
 using (
  user_id=(select auth.uid())
  and exists (select 1 from public.workouts w
    where w.id=workout_exercises.workout_id and w.user_id=(select auth.uid()))
 )
 with check (
  user_id=(select auth.uid())
  and exists (select 1 from public.workouts w
    where w.id=workout_exercises.workout_id and w.user_id=(select auth.uid()))
 );

drop policy if exists "Owner manages sets" on public.workout_sets;
create policy "Owner manages sets" on public.workout_sets
 for all to authenticated
 using (
  user_id=(select auth.uid())
  and exists (select 1 from public.workouts w
    where w.id=workout_sets.workout_id and w.user_id=(select auth.uid()))
 )
 with check (
  user_id=(select auth.uid())
  and exists (select 1 from public.workouts w
    where w.id=workout_sets.workout_id and w.user_id=(select auth.uid()))
 );


-- ================================================================
-- Additive migration: fitness profile and progress archive
-- ================================================================
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


-- ================================================================
-- Additive migration: daily weight tracking and extended context
-- ================================================================

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

revoke all on function public.get_training_context(uuid, timestamptz) from public;
revoke all on function public.get_training_context(uuid, timestamptz) from anon;
grant execute on function public.get_training_context(uuid, timestamptz) to authenticated;



-- ================================================================
-- Additive migration: hardened ChatGPT workflow helpers
-- ================================================================
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

;
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

;
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

;
;

revoke all on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) from public, anon;
grant execute on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) to authenticated;
revoke all on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) from public, anon;
grant execute on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) to authenticated;
revoke all on function public.enqueue_workout_plan(uuid,text,jsonb) from public, anon;
grant execute on function public.enqueue_workout_plan(uuid,text,jsonb) to authenticated;


-- ================================================================
-- Additive migration: inline progress photos and ChatGPT helper finalization
-- ================================================================
-- Additive inline-photo support and deployed ChatGPT workflow helper definitions.
alter table public.fitness_progress_photos add column if not exists image_data text;
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

CREATE OR REPLACE FUNCTION public.save_fitness_checkin_with_photos(p_user_id uuid, p_source_id text, p_checkin_date date, p_checkin_data jsonb DEFAULT '{}'::jsonb, p_physical_assessment text DEFAULT NULL::text, p_training_assessment text DEFAULT NULL::text, p_nutrition_assessment text DEFAULT NULL::text, p_recovery_assessment text DEFAULT NULL::text, p_next_period_focus jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL::text, p_measurements jsonb DEFAULT '[]'::jsonb, p_photos jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_result jsonb;
  v_checkin_id uuid;
  v_photo jsonb;
  v_photo_count integer := 0;
  v_idx integer := 0;
  v_image_data text;
  v_mime_type text;
  v_photo_type text;
  v_storage_path text;
begin
  if jsonb_typeof(coalesce(p_photos, '[]'::jsonb)) <> 'array' then
    raise exception 'p_photos deve essere un array JSON';
  end if;

  v_result := public.save_fitness_checkin(
    p_user_id,p_source_id,p_checkin_date,p_checkin_data,
    p_physical_assessment,p_training_assessment,p_nutrition_assessment,
    p_recovery_assessment,p_next_period_focus,p_notes,p_measurements
  );
  v_checkin_id := (v_result->>'checkin_id')::uuid;

  for v_photo in select value from jsonb_array_elements(coalesce(p_photos,'[]'::jsonb))
  loop
    v_image_data := coalesce(v_photo->>'image_data',v_photo->>'backup_image_data');
    if nullif(v_image_data,'') is null then
      raise exception 'Ogni foto deve contenere image_data o backup_image_data';
    end if;
    if length(v_image_data) > 14000000 then
      raise exception 'Ogni immagine deve essere inferiore a circa 10 MB';
    end if;

    v_mime_type := coalesce(nullif(v_photo->>'mime_type',''),'image/jpeg');
    if v_mime_type not in ('image/jpeg','image/png','image/webp') then
      raise exception 'Formato foto non supportato: %',v_mime_type;
    end if;
    if left(v_image_data,length('data:' || v_mime_type || ';base64,')) <> ('data:' || v_mime_type || ';base64,') then
      raise exception 'Immagine non valida: usare un data URL base64 che corrisponda al mime type';
    end if;

    v_photo_type := coalesce(nullif(v_photo->>'photo_type',''),'other');
    if v_photo_type not in ('front','side','back','other') then
      raise exception 'photo_type non valido: %',v_photo_type;
    end if;

    v_storage_path := 'inline-data:' || p_source_id || '-photo-' || v_idx::text || '-' || v_photo_type;
    insert into public.fitness_progress_photos (
      user_id,checkin_id,storage_path,photo_type,caption,mime_type,image_data
    ) values (
      p_user_id,v_checkin_id,v_storage_path,v_photo_type,
      v_photo->>'caption',v_mime_type,v_image_data
    )
    on conflict (user_id,storage_path) do update set
      checkin_id=excluded.checkin_id,
      photo_type=excluded.photo_type,
      caption=excluded.caption,
      mime_type=excluded.mime_type,
      image_data=excluded.image_data;
    v_photo_count := v_photo_count + 1;
    v_idx := v_idx + 1;
  end loop;

  return v_result || jsonb_build_object('photos_saved',v_photo_count);
end;
$function$
;

;
;

revoke all on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) from public, anon;
grant execute on function public.save_fitness_checkin(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb) to authenticated;
revoke all on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) from public, anon;
grant execute on function public.save_body_weight_entry(uuid,text,timestamptz,numeric,text,jsonb,text) to authenticated;
revoke all on function public.enqueue_workout_plan(uuid,text,jsonb) from public, anon;
grant execute on function public.enqueue_workout_plan(uuid,text,jsonb) to authenticated;
revoke all on function public.save_fitness_checkin_with_photos(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb,jsonb) from public, anon;
grant execute on function public.save_fitness_checkin_with_photos(uuid,text,date,jsonb,text,text,text,text,jsonb,text,jsonb,jsonb) to authenticated;


-- Check and cap inline progress photo payloads.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fitness_progress_photos_image_data_format_check'
      and conrelid = 'public.fitness_progress_photos'::regclass
  ) then
    alter table public.fitness_progress_photos
      add constraint fitness_progress_photos_image_data_format_check
      check (
        image_data is null
        or (
          length(image_data) <= 14000000
          and (
            (mime_type = 'image/jpeg' and image_data like 'data:image/jpeg;base64,%')
            or (mime_type = 'image/png' and image_data like 'data:image/png;base64,%')
            or (mime_type = 'image/webp' and image_data like 'data:image/webp;base64,%')
          )
        )
      );
  end if;
end;
$$;
