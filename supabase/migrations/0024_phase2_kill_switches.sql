-- Phase 2: temporary kill switches for Supabase-primary accounts/transactions.
-- Dark-launched, globally OFF. Per-user override via feature_flag_overrides
-- (same mechanism already used for ledger_dual_write in Phase 1 QA).

insert into public.feature_flags (
  key, value_type, value, description, rollout_percent, is_active
) values
  (
    'accounts_supabase_primary',
    'boolean',
    'false',
    'Phase 2: AccountRepository reads/writes go direct to Supabase instead of Drift.',
    0,
    false
  ),
  (
    'transactions_supabase_primary',
    'boolean',
    'false',
    'Phase 2: TransactionRepository reads/writes go direct to Supabase instead of Drift.',
    0,
    false
  )
on conflict (key) do nothing;
