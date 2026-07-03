-- Phase D: enable local→Supabase push sync for signed-in users.
-- OFF by default; enable via Supabase dashboard when ready to test.
INSERT INTO feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES (
  'ledger_push_sync', 'boolean', 'false',
  'Phase D: push local user_transactions writes to Supabase for signed-in users',
  100, false
)
ON CONFLICT (key) DO NOTHING;
