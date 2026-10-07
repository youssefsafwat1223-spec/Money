-- Seed for the 0103-0109 backfill proof (sync_foundation_0103_0114.sh).
-- Run on a LOCAL throwaway Postgres migrated through 0102 ONLY (before 0103),
-- as the table owner. Uses fixed ids so sync_foundation_0103_0114.sql can assert.
--   user c1: one row in every synced table, deliberately out-of-order updated_at,
--            consent TRUE/TRUE (the unproven default).
--   user c2: settings with consent FALSE/FALSE (explicit) and one account.
--   user c3: no rows at all (must still get a user_sync_state row).
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-0000000000c2'),
  ('00000000-0000-0000-0000-0000000000c3');

-- c1: oldest -> newest updated_at is account, tx2, tx1 (insert order differs on purpose)
INSERT INTO public.user_accounts (id, user_id, local_id, name, currency, type, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1', 'acc-1', 'Main', 'EGP', 'bank', '2026-01-01T00:00:00Z');
INSERT INTO public.user_transactions (id, user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c1', 'tx-1', 10, 'EGP', '2026-01-03', 'manual', 'debit', 'expense', '2026-01-03T00:00:00Z'),
       ('10000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000c1', 'tx-2', 20, 'EGP', '2026-01-02', 'manual', 'debit', 'expense', '2026-01-02T00:00:00Z');
INSERT INTO public.user_budgets (user_id, local_id, category_id, amount, period, start_date, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'bud-1', 'groceries', 100, 'monthly', '2026-01-01', '2026-02-01T00:00:00Z');
INSERT INTO public.user_goals (id, user_id, local_id, name, target_amount, saved_amount, vault_skin, status, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', 'goal-1', 'Trip', 1000, 0, 'default', 'active', '2026-02-02T00:00:00Z');
INSERT INTO public.user_goal_contributions (user_id, goal_id, client_request_id, amount, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000d1', 'gc-1', 5, '2026-02-03T00:00:00Z');
INSERT INTO public.user_plans (id, user_id, local_id, name, budget_amount, currency, start_date, end_date, status, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c1', 'plan-1', 'Plan', 500, 'EGP', '2026-01-01', '2026-02-01', 'active', '2026-02-04T00:00:00Z');
INSERT INTO public.user_plan_transaction_links (user_id, plan_id, transaction_id, client_request_id, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000e1', '10000000-0000-0000-0000-0000000000b1', 'pl-1', '2026-02-05T00:00:00Z');
INSERT INTO public.user_subscriptions (id, user_id, local_id, name, amount, currency, type, frequency, next_due_date, status, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'sub-1', 'Netflix', 9, 'EGP', 'subscription', 'monthly', '2026-03-01', 'active', '2026-02-06T00:00:00Z');
INSERT INTO public.user_bill_payments (user_id, subscription_id, client_request_id, amount, currency, period_start, period_end, paid_at, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000f1', 'bp-1', 9, 'EGP', '2026-02-01', '2026-03-01', '2026-02-07', '2026-02-07T00:00:00Z');
INSERT INTO public.user_cards (user_id, local_id, last4, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'card-1', '1234', '2026-02-08T00:00:00Z');
INSERT INTO public.user_categories (user_id, local_id, key, name_ar, icon, color, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'cat-1', 'custom_one', 'x', 'i', '#fff', '2026-02-09T00:00:00Z');
INSERT INTO public.user_settings (id, user_id, local_id, theme, updated_at)
VALUES ('10000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000c1', 'user_settings', 'dark', '2026-02-10T00:00:00Z');
INSERT INTO public.user_smart_inbox (user_id, type, title, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'insight', 'hello', '2026-02-11T00:00:00Z');
INSERT INTO public.sender_bank_mappings (user_id, sender_id, normalized_sender_id, suggested_bank_name, suggested_country, confidence, status, source, first_seen_at, last_seen_at, updated_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'CIB', 'cib', 'CIB', 'EG', 0.9, 'pending', 'user_manual', now(), now(), '2026-02-12T00:00:00Z');
-- gamification read models for c1 (user_streaks / user_xp_levels / user_achievements)
INSERT INTO public.user_streaks (user_id) VALUES ('00000000-0000-0000-0000-0000000000c1') ON CONFLICT DO NOTHING;
INSERT INTO public.user_xp_levels (user_id) VALUES ('00000000-0000-0000-0000-0000000000c1') ON CONFLICT DO NOTHING;
INSERT INTO public.user_achievements (user_id, achievement_key, unlocked_at)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'seed_ach', '2026-02-13T00:00:00Z') ON CONFLICT DO NOTHING;
-- consent: c1 = column defaults (TRUE/TRUE), c2 = explicit FALSE/FALSE
UPDATE public.user_settings SET ai_consent_granted = true, cloud_processing_enabled = true
 WHERE user_id = '00000000-0000-0000-0000-0000000000c1';
INSERT INTO public.user_settings (user_id, local_id, ai_consent_granted, cloud_processing_enabled)
VALUES ('00000000-0000-0000-0000-0000000000c2', 'user_settings', false, false);
INSERT INTO public.user_accounts (user_id, local_id, name, currency, type)
VALUES ('00000000-0000-0000-0000-0000000000c2', 'acc-c2', 'Cash', 'EGP', 'cash');
