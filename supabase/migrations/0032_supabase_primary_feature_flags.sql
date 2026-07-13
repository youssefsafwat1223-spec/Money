-- Complete the temporary Supabase-primary kill switches. All remain globally
-- OFF and require an explicit per-user QA override.
insert into public.feature_flags(
  key, value_type, value, description, rollout_percent, is_active
) values
  ('budgets_supabase_primary', 'boolean', 'false',
   'Phase 4: BudgetRepository reads and writes use user_budgets.', 0, false),
  ('goals_supabase_primary', 'boolean', 'false',
   'Phase 4: GoalRepository and contributions use Supabase.', 0, false),
  ('subscriptions_supabase_primary', 'boolean', 'false',
   'Phase 4: subscriptions and bill payments use Supabase.', 0, false),
  ('plans_supabase_primary', 'boolean', 'false',
   'Phase 4: plans and transaction links use Supabase.', 0, false),
  ('smart_inbox_supabase_primary', 'boolean', 'false',
   'Phase 4: Smart Inbox is refreshed directly from user_smart_inbox.', 0, false),
  ('capture_direct_supabase_write', 'boolean', 'false',
   'Phase 5: process-ios-sms writes canonical user_transactions while retaining relay.', 0, false)
on conflict (key) do update set
  value_type = 'boolean',
  value = 'false',
  rollout_percent = 0,
  is_active = false;
