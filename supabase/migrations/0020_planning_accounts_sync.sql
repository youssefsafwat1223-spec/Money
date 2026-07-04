-- Phase G1: planning accounts sync foundation.
--
-- Dark launch only. Flutter UI continues to read Drift/local tables.
-- All planning sync flags are seeded OFF and inactive by default.

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.user_accounts (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  local_id        TEXT        NULL,

  name            TEXT        NOT NULL,
  currency        TEXT        NOT NULL,
  type            TEXT        NOT NULL CHECK (type IN ('cash', 'bank', 'wallet', 'card')),
  initial_balance NUMERIC     NULL,
  current_balance NUMERIC     NULL,
  is_default      BOOLEAN     NOT NULL DEFAULT FALSE,
  sort_order      INTEGER     NOT NULL DEFAULT 0,
  metadata        JSONB       NOT NULL DEFAULT '{}'::JSONB,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at      TIMESTAMPTZ NULL
);

ALTER TABLE public.user_accounts ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_accounts_user_local
  ON public.user_accounts(user_id, local_id)
  WHERE local_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_accounts_user_deleted
  ON public.user_accounts(user_id, deleted_at);

CREATE INDEX IF NOT EXISTS idx_user_accounts_user_sort
  ON public.user_accounts(user_id, sort_order, created_at);

DROP POLICY IF EXISTS user_accounts_owner ON public.user_accounts;
CREATE POLICY user_accounts_owner
  ON public.user_accounts
  FOR ALL
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP TRIGGER IF EXISTS trg_user_accounts_updated_at ON public.user_accounts;
CREATE TRIGGER trg_user_accounts_updated_at
  BEFORE UPDATE ON public.user_accounts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES
  (
    'planning_accounts_sync',
    'boolean',
    'false',
    'Phase G1: sync accounts between Drift and user_accounts for signed-in users',
    100,
    false
  ),
  (
    'planning_budgets_sync',
    'boolean',
    'false',
    'Phase G2: sync budgets between Drift and Supabase',
    100,
    false
  ),
  (
    'planning_subscriptions_sync',
    'boolean',
    'false',
    'Phase G3: sync subscriptions and bills between Drift and Supabase',
    100,
    false
  ),
  (
    'planning_goals_sync',
    'boolean',
    'false',
    'Phase G4: sync goals and goal contributions between Drift and Supabase',
    100,
    false
  ),
  (
    'planning_plans_sync',
    'boolean',
    'false',
    'Phase G5: sync plans and plan transaction links between Drift and Supabase',
    100,
    false
  ),
  (
    'capture_direct_ledger_write',
    'boolean',
    'false',
    'Phase H placeholder: allow signed-in captures to bypass processed_captures after explicit approval',
    100,
    false
  )
ON CONFLICT (key) DO NOTHING;
