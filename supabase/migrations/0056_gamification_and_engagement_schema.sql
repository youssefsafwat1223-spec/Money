-- Reconstructed from the actual Dart/Edge Function code, which already
-- assumes this schema exists (commit 8bf8259b) — the original migration
-- 0056 was apparently never written to git or applied live, even though
-- code depending on it was committed, deployed, and the version bumped.
-- Confirmed live: user_budgets/user_goals had none of these columns, and
-- user_achievements/user_streaks/user_xp_levels didn't exist at all, so
-- every budget/goal save was failing with "column does not exist".

-- ── Budgets: replace the one-shot boolean alert flags with quantitative
--    tracking, so a notification fires once per +10% increment crossed
--    (not just once ever) — matches BudgetEntity.lastNotifiedSpentAmount /
--    lastNotifiedPeriodStart and the local Drift schema in app_database.dart.
alter table user_budgets
  add column if not exists last_notified_spent_amount numeric not null default 0,
  add column if not exists last_notified_period_start timestamptz not null default '2000-01-01T00:00:00Z';

alter table user_budgets drop column if exists alert_80_sent;
alter table user_budgets drop column if exists alert_100_sent;

-- ── Goals: track the saved amount at the last milestone notification,
--    matching GoalEntity.lastNotifiedSavedAmount.
alter table user_goals
  add column if not exists last_notified_saved_amount numeric not null default 0;

-- ── Gamification tables (server-side XP/streaks/achievements, replacing
--    the previously local-only Drift tables — see achievements/streaks/
--    xp_levels in app_database.dart for the local shape being mirrored).
create table if not exists user_xp_levels (
  user_id uuid primary key references auth.users(id) on delete cascade,
  xp integer not null default 0,
  level integer not null default 1,
  updated_at timestamptz not null default now()
);

create table if not exists user_streaks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_streak integer not null default 0,
  longest_streak integer not null default 0,
  last_active_date timestamptz not null default now(),
  freezes_available integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists user_achievements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text,
  achievement_key text not null,
  unlocked_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, achievement_key)
);

alter table user_xp_levels enable row level security;
alter table user_streaks enable row level security;
alter table user_achievements enable row level security;

-- Owner reads their own row; service_role (the Edge Functions, which use
-- the service key) bypasses RLS entirely so it can write on the user's
-- behalf — same pattern as every other user_* table in this schema.
create policy user_xp_levels_owner_select on user_xp_levels
  for select to authenticated using (user_id = auth.uid());
create policy user_streaks_owner_select on user_streaks
  for select to authenticated using (user_id = auth.uid());
create policy user_achievements_owner_select on user_achievements
  for select to authenticated using (user_id = auth.uid());

alter publication supabase_realtime add table user_xp_levels;
alter publication supabase_realtime add table user_streaks;
alter publication supabase_realtime add table user_achievements;
