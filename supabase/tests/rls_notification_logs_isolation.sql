-- Manual two-user RLS isolation test for notification_logs / notification_retry_queue
-- (Phase 1 notification tracking — supabase/migrations/0052_notification_logs.sql).
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor → New query).
-- Not automated: requires two real auth.users rows and simulates their JWTs
-- via `request.jwt.claims`, which only works inside an interactive session.
-- Follows the same pattern as rls_two_user_isolation.sql.
--
-- 1. Get two real user ids first:
--      select id, email from auth.users limit 2;
--    Replace <USER_A_ID> and <USER_B_ID> below with two DIFFERENT ids.

-- ── Setup: seed one row owned by User A (as service_role / table owner) ────
insert into public.notification_logs
  (user_id, install_id, notification_type, channel, status)
values
  ('<USER_A_ID>', 'install-a', 'budget_warning', 'local_ios', 'pending')
returning id;
-- Copy the returned id into <LOG_ID> below.

-- ── User B must not see or touch User A's row ───────────────────────────────
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_B_ID>", "role": "authenticated"}';

select count(*) from public.notification_logs where id = '<LOG_ID>';         -- expect 0
update public.notification_logs set status = 'opened' where id = '<LOG_ID>'; -- expect 0 rows

-- User B cannot insert a row claiming to be User A's, even by setting user_id
-- explicitly to A's id — WITH CHECK (auth.uid() = user_id) rejects it.
insert into public.notification_logs
  (user_id, install_id, notification_type, channel, status)
values
  ('<USER_A_ID>', 'install-a', 'budget_warning', 'local_ios', 'pending');
-- Expect: ERROR — new row violates row-level security policy for table "notification_logs"

reset role;

-- ── User A has full read/update access to their own row ─────────────────────
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';

select count(*) from public.notification_logs where id = '<LOG_ID>';         -- expect 1
update public.notification_logs set status = 'sent' where id = '<LOG_ID>';   -- expect 1 row
select status from public.notification_logs where id = '<LOG_ID>';           -- expect 'sent'

-- install_id alone must never substitute for ownership — User A reading by
-- install_id across all rows must still only surface their own (user_id-owned)
-- rows, never User B's, even if both installs happen to share an install_id
-- (e.g. a reused/spoofed value). RLS filters on auth.uid() = user_id only;
-- install_id is not part of the policy predicate.
select count(*) from public.notification_logs
  where install_id = 'install-a' and user_id != '<USER_A_ID>';               -- expect 0

reset role;

-- ── Anonymous users cannot access notification_logs at all ─────────────────
set local role anon;
select count(*) from public.notification_logs where id = '<LOG_ID>';         -- expect 0
insert into public.notification_logs
  (user_id, install_id, notification_type, channel, status)
values
  ('<USER_A_ID>', 'install-a', 'budget_warning', 'local_ios', 'pending');
-- Expect: ERROR — new row violates row-level security policy (anon has no
-- insert/select policy at all on notification_logs)

reset role;

-- ── Status can never regress (monotonic-transition trigger) ────────────────
-- User A tries to move their own 'sent' row backward to 'queued'.
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';

update public.notification_logs set status = 'queued' where id = '<LOG_ID>';
select status from public.notification_logs where id = '<LOG_ID>';
-- Expect: still 'sent' — trg_notification_logs_status_monotonic silently
-- keeps the higher-ranked status instead of erroring, so the UPDATE
-- statement itself succeeds (0 error) but the status column doesn't move.

reset role;

-- ── Service role can create and update rows for any user (used by Edge
--    Functions via SUPABASE_SERVICE_ROLE_KEY, which bypasses RLS entirely) ──
set local role service_role;

update public.notification_logs set status = 'opened' where id = '<LOG_ID>';
select status from public.notification_logs where id = '<LOG_ID>';           -- expect 'opened'

reset role;

-- ── notification_retry_queue is not directly accessible to normal clients ──
-- (Edge-Function/service-role only — matches capture_devices/processed_captures
-- convention from 0012_ios_capture_pipeline.sql: USING(false) WITH CHECK(false).)

set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';

select count(*) from public.notification_retry_queue;                        -- expect 0 rows visible
insert into public.notification_retry_queue
  (notification_log_id, install_id_hash, payload_id)
values
  ('<LOG_ID>', 'hash', 'payload-1');
-- Expect: ERROR — new row violates row-level security policy for table
-- "notification_retry_queue" (notification_retry_queue_no_direct_access:
-- USING(false) WITH CHECK(false) blocks every authenticated/anon operation)

reset role;

-- claim_notification_retries() must not be callable by authenticated/anon —
-- it is REVOKEd from PUBLIC/anon/authenticated and only service_role retains
-- EXECUTE (see 0052_notification_logs.sql).
set local role authenticated;
set local request.jwt.claims = '{"sub": "<USER_A_ID>", "role": "authenticated"}';
select * from public.claim_notification_retries(10);
-- Expect: ERROR — permission denied for function claim_notification_retries
reset role;

-- ── Cleanup (as service_role / table owner) ─────────────────────────────────
delete from public.notification_logs where id = '<LOG_ID>';
delete from public.notification_retry_queue where notification_log_id = '<LOG_ID>';

-- This script only covers notification_logs / notification_retry_queue.
-- Requires Docker + `supabase start` to run live — see
-- docs owner checklist for how to execute this against a local instance.
