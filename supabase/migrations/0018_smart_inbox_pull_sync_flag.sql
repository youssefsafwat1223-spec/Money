-- Phase F: Smart Inbox pull-sync feature flag (OFF by default).
-- Seeds the flag as inactive so all clients default to disabled
-- without any Supabase network calls.

INSERT INTO feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES (
  'smart_inbox_pull_sync',
  'boolean',
  'false',
  'Phase F: pull user_smart_inbox rows from Supabase into local Drift smart_inbox_items cache',
  0,
  false
)
ON CONFLICT (key) DO NOTHING;
