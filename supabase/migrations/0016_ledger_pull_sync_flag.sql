-- Phase C: Seed the ledger_pull_sync feature flag.
-- OFF by default; toggled on when Phase C is ready for users.
INSERT INTO feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES (
  'ledger_pull_sync',
  'boolean',
  'false',
  'Phase C: pull user_transactions from Supabase into Drift for signed-in users',
  100,
  false
)
ON CONFLICT (key) DO NOTHING;
