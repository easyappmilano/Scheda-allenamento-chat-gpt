-- Isolated local preview baseline. This migration creates schema only; no production data is copied.
create table public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  client_session_id uuid not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  duration_seconds integer,
  status text not null default 'in_progress'
    check (status in ('in_progress','completed','abandoned')),
  notes text,
  created_at timestamptz not null default now(),
  plan_id text,
  plan_title text,
  selected_duration text,
  constraint workouts_user_id_client_session_id_key unique(user_id,client_session_id)
);

create table public.workout_exercises (
  id uuid primary key default gen_random_uuid(),
  workout_id uuid not null references public.workouts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_name text not null,
  muscle_group text,
  exercise_order integer not null default 0,
  notes text,
  removed boolean not null default false,
  created_at timestamptz not null default now(),
  registered boolean not null default false,
  rep_range text,
  planned_sets integer,
  rest_seconds integer,
  previous_reference text
);

create table public.workout_sets (
  id uuid primary key default gen_random_uuid(),
  workout_id uuid not null references public.workouts(id) on delete cascade,
  workout_exercise_id uuid not null references public.workout_exercises(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  set_number integer not null,
  weight_kg numeric,
  reps integer,
  rir numeric,
  rest_seconds integer,
  completed boolean not null default false,
  notes text,
  created_at timestamptz not null default now()
);

create index idx_exercises_workout on public.workout_exercises(workout_id,exercise_order);
create index idx_sets_exercise on public.workout_sets(workout_exercise_id,set_number);
create index idx_workouts_user_date on public.workouts(user_id,started_at desc);

alter table public.workouts enable row level security;
alter table public.workout_exercises enable row level security;
alter table public.workout_sets enable row level security;

create table public.fitness_continuity_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  record_key text not null,
  domain text not null check (domain in ('training','nutrition','app','rules','general')),
  record_type text not null default 'context',
  title text not null,
  payload jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default now(),
  source text not null default 'chatgpt',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fitness_continuity_records_user_id_record_key_key unique(user_id,record_key)
);
create index fitness_continuity_records_user_domain_idx
  on public.fitness_continuity_records(user_id,domain,recorded_at desc);
alter table public.fitness_continuity_records enable row level security;

create policy "Users can read own continuity records"
  on public.fitness_continuity_records for select to authenticated
  using (auth.uid()=user_id);
create policy "Users can insert own continuity records"
  on public.fitness_continuity_records for insert to authenticated
  with check (auth.uid()=user_id);
create policy "Users can update own continuity records"
  on public.fitness_continuity_records for update to authenticated
  using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "Users can delete own continuity records"
  on public.fitness_continuity_records for delete to authenticated
  using (auth.uid()=user_id);
