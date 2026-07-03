-- Phase B: dual-write feature flag.
-- OFF by default. Flip is_active to true to enable dual-write for signed-in users.
-- Rollback: UPDATE feature_flags SET is_active = false WHERE key = 'ledger_dual_write';
INSERT INTO feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES (
  'ledger_dual_write',
  'boolean',
  'false',
  'Phase B: dual-write iOS captures to user_transactions for signed-in users only',
  100,
  false
)
ON CONFLICT (key) DO NOTHING;
