-- Estensioni della scheda allenamento per conservare i dettagli generati in ChatGPT.
alter table public.workouts
  add column if not exists ai_generated boolean not null default false,
  add column if not exists selection_mode text,
  add column if not exists requested_groups text[];

alter table public.workout_exercises
  add column if not exists coaching_note text,
  add column if not exists target_rir text;

-- Tracciamento personale: schema alimentazione + campi AI allenamento
-- Eseguire in Supabase > SQL Editor > New query.

alter table public.workouts
  add column if not exists ai_generated boolean not null default false,
  add column if not exists selection_mode text,
  add column if not exists requested_groups text[];

create table if not exists public.nutrition_meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  meal_date date not null default current_date,
  meal_type text not null,
  title text,
  status text not null default 'consumed' check (status in ('planned', 'consumed')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.nutrition_entries (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references public.nutrition_meals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  food_id uuid,
  food_name text not null,
  category text,
  quantity numeric(10,2) not null check (quantity >= 0),
  unit text not null default 'g',
  kcal_100g numeric(10,2) not null default 0,
  protein_100g numeric(10,2) not null default 0,
  carbs_100g numeric(10,2) not null default 0,
  fat_100g numeric(10,2) not null default 0,
  calories numeric(10,2) not null default 0,
  protein_g numeric(10,2) not null default 0,
  carbs_g numeric(10,2) not null default 0,
  fat_g numeric(10,2) not null default 0,
  data_source text not null default 'estimated' check (data_source in ('label', 'user_provided', 'estimated')),
  source_note text,
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
  data_source text not null default 'user_provided' check (data_source in ('label', 'user_provided', 'estimated')),
  created_at timestamptz not null default now(),
  unique(user_id, name)
);


-- Compatibilità con la prima versione del diario alimentare, nel caso fosse già stata creata.
alter table public.nutrition_foods
  add column if not exists unit text not null default 'g',
  add column if not exists data_source text not null default 'user_provided';

alter table public.nutrition_entries
  add column if not exists meal_id uuid,
  add column if not exists food_id uuid,
  add column if not exists kcal_100g numeric(10,2) not null default 0,
  add column if not exists protein_100g numeric(10,2) not null default 0,
  add column if not exists carbs_100g numeric(10,2) not null default 0,
  add column if not exists fat_100g numeric(10,2) not null default 0,
  add column if not exists data_source text not null default 'estimated',
  add column if not exists source_note text;

-- Se erano già presenti record nel vecchio diario, li raggruppa per giorno e tipo di pasto.
do $
declare
  has_legacy_columns boolean;
begin
  select count(*) = 2 into has_legacy_columns
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'nutrition_entries'
    and column_name in ('entry_date', 'meal_type');

  if has_legacy_columns then
    execute $m$
      insert into public.nutrition_meals (user_id, meal_date, meal_type, status)
      select distinct e.user_id, e.entry_date, e.meal_type, 'consumed'
      from public.nutrition_entries e
      where e.meal_id is null
        and not exists (
          select 1 from public.nutrition_meals m
          where m.user_id = e.user_id
            and m.meal_date = e.entry_date
            and m.meal_type = e.meal_type
        )
    $m$;

    execute $u$
      update public.nutrition_entries e
      set meal_id = m.id
      from public.nutrition_meals m
      where e.meal_id is null
        and m.user_id = e.user_id
        and m.meal_date = e.entry_date
        and m.meal_type = e.meal_type
    $u$;
  end if;
end $;


do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'nutrition_entries_food_id_fkey') then
    alter table public.nutrition_entries
      add constraint nutrition_entries_food_id_fkey
      foreign key (food_id) references public.nutrition_foods(id) on delete set null;
  end if;
end $$;

create index if not exists nutrition_meals_user_date_idx on public.nutrition_meals(user_id, meal_date desc);
create index if not exists nutrition_entries_meal_idx on public.nutrition_entries(meal_id);
create index if not exists nutrition_entries_user_idx on public.nutrition_entries(user_id);
create index if not exists nutrition_foods_user_idx on public.nutrition_foods(user_id);

alter table public.nutrition_meals enable row level security;
alter table public.nutrition_entries enable row level security;
alter table public.nutrition_foods enable row level security;

revoke all on public.nutrition_meals from anon, authenticated;
revoke all on public.nutrition_entries from anon, authenticated;
revoke all on public.nutrition_foods from anon, authenticated;
grant select, insert, update, delete on public.nutrition_meals to authenticated;
grant select, insert, update, delete on public.nutrition_entries to authenticated;
grant select, insert, update, delete on public.nutrition_foods to authenticated;

drop policy if exists "Users manage own nutrition meals" on public.nutrition_meals;
create policy "Users manage own nutrition meals" on public.nutrition_meals for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own nutrition entries" on public.nutrition_entries;
create policy "Users manage own nutrition entries" on public.nutrition_entries for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own nutrition foods" on public.nutrition_foods;
create policy "Users manage own nutrition foods" on public.nutrition_foods for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
