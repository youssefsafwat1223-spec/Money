-- Review-only destructive rollback. Disable flags first and preserve data by
-- default; do not execute in production without an export.
update public.feature_flags
set value = 'false', rollout_percent = 0, is_active = false
where key in (
  'budgets_supabase_primary', 'goals_supabase_primary',
  'subscriptions_supabase_primary', 'plans_supabase_primary',
  'smart_inbox_supabase_primary'
);

drop function if exists public.plan_spent_summary(uuid);
drop function if exists public.plan_transactions(uuid);
drop function if exists public.delete_bill_payment(uuid);
drop function if exists public.record_bill_payment(uuid, uuid, text, text, numeric, text, timestamptz, timestamptz, timestamptz, integer, text);
drop function if exists public.add_goal_contribution(uuid, text, text, numeric, timestamptz, text);
-- Child tables and server_account_ids are intentionally retained to avoid
-- destructive data loss during an application rollback.
