-- DF-002 — declare the owner-table privileges the app depends on, instead of
-- inheriting them from Supabase's platform defaults.
--
-- THE DEFECT
-- Seventeen owner-scoped tables that the client reads AND writes have NO grant
-- statement anywhere in `supabase/migrations/`:
--   user_accounts, user_transactions, user_budgets, user_goals,
--   user_subscriptions, user_plans, user_cards, user_categories, user_settings,
--   user_smart_inbox, user_bill_payments, user_goal_contributions,
--   user_plan_transaction_links, profiles, backups, notification_logs,
--   feature_flag_overrides
--
-- They work in the hosted project only because Supabase's platform bootstrap
-- grants table privileges to `anon`/`authenticated` outside this migration set.
-- The repo itself proves the dependency: `0072` REVOKEs INSERT on `metrics`
-- from `authenticated`, and `0054` states that "Supabase's default table-level
-- GRANTs ... were left as the only gate" — you can only revoke what a default
-- granted.
--
-- Consequence: `supabase/migrations` alone cannot stand up a working
-- environment. A fresh local database, a self-host, or any non-Supabase
-- Postgres fails at the privilege layer BEFORE RLS is ever consulted, so it
-- cannot reproduce production behaviour. That makes every "verified on a clean
-- environment" claim unreproducible — which is what this migration fixes.
--
-- SCOPE AND SAFETY — read before extending this file
--   * ADDITIVE ONLY. `GRANT` never removes a privilege, so applying this to the
--     hosted project is a no-op: it re-states what the platform already granted.
--     The behavioural change is only on environments that never had defaults.
--   * The verb set mirrors the Supabase default (SELECT/INSERT/UPDATE/DELETE)
--     ON PURPOSE, so a fresh environment is privilege-IDENTICAL to production.
--     Tightening to least privilege is a genuine improvement — the sync layer
--     tombstones via UPDATE and issues no table DELETE except `backups` — but it
--     is a BEHAVIOUR CHANGE and must be its own reviewed migration, not a silent
--     rider on a reproducibility fix.
--   * `anon` is granted NOTHING here. Unauthenticated clients reach the catalog
--     through Edge Functions only (see DF-005 in QIRSH_MASTER_PLAN_V2.md).
--   * RLS is untouched and remains the row-ownership gate. These are
--     TABLE-level privileges; every one of these tables still enforces
--     `auth.uid()`-scoped policies.
--
-- DELIBERATELY EXCLUDED — do not add these without re-reading 0073/0079:
--   user_achievements, user_streaks, user_xp_levels   -- writes go through
--   user_engagement_events                            -- SECURITY DEFINER RPCs;
--   metrics, metrics_rate_limits                      -- 0073/0079 revoked DML
--   admin_users, ai_request_idempotency               -- and re-granted SELECT
--   gamification_awarded_transactions                 -- only. Granting DML here
--   coupon_metrics_daily                              -- would UNDO that
--   user_entitlement_state                            -- hardening.

BEGIN;

DO $$
DECLARE
  t TEXT;
  owner_tables CONSTANT TEXT[] := ARRAY[
    'user_accounts',
    'user_transactions',
    'user_budgets',
    'user_goals',
    'user_subscriptions',
    'user_plans',
    'user_cards',
    'user_categories',
    'user_settings',
    'user_smart_inbox',
    'user_bill_payments',
    'user_goal_contributions',
    'user_plan_transaction_links',
    'profiles',
    'backups',
    'notification_logs',
    'feature_flag_overrides'
  ];
BEGIN
  FOREACH t IN ARRAY owner_tables LOOP
    -- Tolerate a table that a given environment has not created yet: this
    -- migration must be safe to run against any point in the schema history.
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
       WHERE table_schema = 'public' AND table_name = t
    ) THEN
      EXECUTE format(
        'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated;',
        t
      );
    END IF;
  END LOOP;
END $$;

COMMIT;

-- ─── ROLLBACK (run manually; not executed by this migration) ─────────────────
-- Reverting is only meaningful on an environment that never had the platform
-- defaults — on the hosted project this REVOKE would remove privileges the
-- platform granted and BREAK the app. Do not run it there.
--
-- BEGIN;
--   DO $$
--   DECLARE t TEXT;
--   BEGIN
--     FOREACH t IN ARRAY ARRAY['user_accounts','user_transactions','user_budgets',
--       'user_goals','user_subscriptions','user_plans','user_cards',
--       'user_categories','user_settings','user_smart_inbox','user_bill_payments',
--       'user_goal_contributions','user_plan_transaction_links','profiles',
--       'backups','notification_logs','feature_flag_overrides'] LOOP
--       EXECUTE format(
--         'REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I FROM authenticated;', t);
--     END LOOP;
--   END $$;
-- COMMIT;
