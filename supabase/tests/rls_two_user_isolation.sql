-- Manual two-user RLS isolation test.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor → New query).
-- Not automated: requires two real auth.users rows and simulates their JWTs
-- via `request.jwt.claims`, which only works inside an interactive session.
--
-- 1. Get two real user ids first:
--      select id, email from auth.users limit 2;
--    Replace <USER_A_ID> and <USER_B_ID> below with two DIFFERENT ids.

-- ── Setup: seed one row owned by User A (as service_role / table owner) ────
insert into public.user_transactions
  (user_id, amount, currency, direction, transaction_type, occurred_at, source)
values
  ('<USER_A_ID>', 42, 'EGP', 'debit', 'expense', now(), 'manual')
returning id;
-- Copy the returned id into <TX_ID> below.

-- ── User B must see and touch NOTHING belonging to User A ──────────────────
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_B_ID>", "role": "authenticated"}';

select count(*) from public.user_transactions where id = '<TX_ID>';        -- expect 0
update public.user_transactions set amount = 999 where id = '<TX_ID>';     -- expect 0 rows
delete from public.user_transactions where id = '<TX_ID>';                 -- expect 0 rows

reset role;

-- ── User A must have full access to their own row ───────────────────────────
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';

select count(*) from public.user_transactions where id = '<TX_ID>';        -- expect 1
update public.user_transactions set amount = 50 where id = '<TX_ID>';      -- expect 1 row
select amount from public.user_transactions where id = '<TX_ID>';          -- expect 50

reset role;

-- ── Ownership trigger check: User A cannot attach another user's account ───
-- Requires a real account id owned by User B — get one via:
--   select id from public.user_accounts where user_id = '<USER_B_ID>' limit 1;
-- If User B has no account row yet, create one first (as service_role):
--   insert into public.user_accounts (user_id, name, currency, type)
--   values ('<USER_B_ID>', 'Test', 'EGP', 'bank') returning id;

set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';

update public.user_transactions
  set server_account_id = '<USER_B_ACCOUNT_ID>'
  where id = '<TX_ID>';
-- Expect: ERROR — "account <id> does not belong to user <id>"
-- (raised by trg_user_transactions_ownership, not by RLS)

reset role;

-- ── Cleanup (as service_role / table owner) ─────────────────────────────────
delete from public.user_transactions where id = '<TX_ID>';
-- delete the test user_accounts row created above, if any, too.

-- Repeat the same three-block pattern (seed → foreign read/write/delete
-- attempt → owner read/write) for user_accounts, user_budgets, user_goals,
-- user_subscriptions, user_plans, and user_smart_inbox before trusting RLS
-- across the full schema — this script only covers user_transactions.
