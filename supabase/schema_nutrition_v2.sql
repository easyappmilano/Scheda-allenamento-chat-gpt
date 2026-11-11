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
