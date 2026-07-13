update public.feature_flags
set value = 'false', rollout_percent = 0, is_active = false
where key in (
  'budgets_supabase_primary', 'goals_supabase_primary',
  'subscriptions_supabase_primary', 'plans_supabase_primary',
  'smart_inbox_supabase_primary', 'capture_direct_supabase_write'
);
