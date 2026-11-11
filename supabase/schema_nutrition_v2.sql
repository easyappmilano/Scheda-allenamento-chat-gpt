-- TRACCIAMENTO PERSONALE: schema unificato allenamento + alimentazione
-- Eseguire una volta in Supabase > SQL Editor > New query.
-- I dati sono protetti da Row Level Security: ogni utente vede solo i propri record.

-- Metadati delle schede AI e dei gruppi muscolari selezionati.
alter table public.workouts
  add column if not exists ai_generated boolean not null default false,
  add column if not exists selection_mode text,
  add column if not exists requested_groups text[];

alter table public.workout_exercises
  add column if not exists coaching_note text,
  add column if not exists target_rir text;

-- Un pasto è un contenitore (colazione, pranzo, cena...) con più ingredienti.
create table if not exists public.nutrition_meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  meal_date date not null default current_date,
  meal_type text not null,
  title text,
  status text not null default 'consumed'
    check (status in ('planned', 'consumed')),
  notes text,
  created_at timestamptz not null default now()
);

-- Catalogo personale, con valori nutrizionali riferiti a 100 g o 100 ml.
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
  data_source text not null default 'user_provided'
    check (data_source in ('label', 'user_provided', 'estimated')),
  created_at timestamptz not null default now(),
  unique(user_id, name)
);

-- Riga per ogni alimento che compone il pasto.
-- entry_date, meal_type e status restano anche come campi di compatibilità
-- con la prima versione del diario, qualora fosse già stata usata.
create table if not exists public.nutrition_entries (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid references public.nutrition_meals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
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
    check (data_source in ('label', 'user_provided', 'estimated')),
  source_note text,
  created_at timestamptz not null default now()
);

-- Aggiunge i nuovi campi se esiste già una tabella della prima versione.
alter table public.nutrition_foods
  add column if not exists unit text not null default 'g',
  add column if not exists data_source text not null default 'user_provided';

alter table public.nutrition_entries
  add column if not exists meal_id uuid,
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

-- Migra le righe esistenti della prima versione in contenitori-pasto.
do $do$
declare
  has_legacy_columns boolean;
begin
  select count(*) = 2 into has_legacy_columns
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'nutrition_entries'
    and column_name in ('entry_date', 'meal_type');

  if has_legacy_columns then
    insert into public.nutrition_meals (user_id, meal_date, meal_type, status)
    select distinct e.user_id, e.entry_date, coalesce(e.meal_type, 'Altro'),
           case when e.status = 'planned' then 'planned' else 'consumed' end
    from public.nutrition_entries e
    where e.meal_id is null
      and e.entry_date is not null
      and not exists (
        select 1
        from public.nutrition_meals m
        where m.user_id = e.user_id
          and m.meal_date = e.entry_date
          and m.meal_type = coalesce(e.meal_type, 'Altro')
          and m.status = case when e.status = 'planned' then 'planned' else 'consumed' end
      );

    update public.nutrition_entries e
    set meal_id = m.id
    from public.nutrition_meals m
    where e.meal_id is null
      and e.entry_date = m.meal_date
      and e.user_id = m.user_id
      and coalesce(e.meal_type, 'Altro') = m.meal_type
      and m.status = case when e.status = 'planned' then 'planned' else 'consumed' end;
  end if;
end $do$;

-- Vincoli e indici per collegare i dati e velocizzare il caricamento dello storico.
do $do$
begin
  if not exists (select 1 from pg_constraint where conname = 'nutrition_entries_meal_id_fkey') then
    alter table public.nutrition_entries
      add constraint nutrition_entries_meal_id_fkey
      foreign key (meal_id) references public.nutrition_meals(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'nutrition_entries_food_id_fkey') then
    alter table public.nutrition_entries
      add constraint nutrition_entries_food_id_fkey
      foreign key (food_id) references public.nutrition_foods(id) on delete set null;
  end if;
end $do$;

create index if not exists nutrition_meals_user_date_idx
  on public.nutrition_meals(user_id, meal_date desc);
create index if not exists nutrition_entries_meal_idx
  on public.nutrition_entries(meal_id);
create index if not exists nutrition_entries_user_idx
  on public.nutrition_entries(user_id);
create index if not exists nutrition_foods_user_idx
  on public.nutrition_foods(user_id);

-- Sicurezza: solo l'utente autenticato proprietario può leggere o modificare i dati.
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
create policy "Users manage own nutrition meals"
  on public.nutrition_meals for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own nutrition entries" on public.nutrition_entries;
create policy "Users manage own nutrition entries"
  on public.nutrition_entries for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users manage own nutrition foods" on public.nutrition_foods;
create policy "Users manage own nutrition foods"
  on public.nutrition_foods for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
