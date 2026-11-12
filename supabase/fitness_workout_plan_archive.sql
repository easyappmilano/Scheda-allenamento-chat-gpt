
-- Preserve imported workout plans as history, never as live queue records.
create table if not exists public.fitness_workout_plan_archive (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  archive_key text not null,
  original_plan_id text,
  source_id text,
  original_status text not null
    check (original_status in ('pending','in_progress','completed','cancelled')),
  plan_data jsonb not null,
  original_created_at timestamptz,
  original_started_at timestamptz,
  original_completed_at timestamptz,
  original_workout_id text,
  archive_source text not null default 'backup_restore',
  created_at timestamptz not null default now(),
  constraint fitness_workout_plan_archive_user_key_unique unique(user_id,archive_key)
);
create index if not exists fitness_workout_plan_archive_user_date_idx
  on public.fitness_workout_plan_archive(user_id,original_created_at desc);
alter table public.fitness_workout_plan_archive enable row level security;
grant select,insert,update,delete on public.fitness_workout_plan_archive to authenticated;
drop policy if exists "Users manage own archived workout plans" on public.fitness_workout_plan_archive;
create policy "Users manage own archived workout plans"
  on public.fitness_workout_plan_archive
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
