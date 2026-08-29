-- ROLLBACK for 0089_force_update_arming_authority.sql (C-2a-2)
--
-- Lifted from the inline ROLLBACK block at the end of 0089 so it lives with the
-- other rollbacks instead of only in a comment.
--
-- 0089 made arming a client-blocking force-update a server-authorised, audited
-- operation. Before it, confirmation was a caller-supplied boolean on an
-- ordinary announcements write — any writer could block EVERY installed client
-- with no audit trail.
--
-- WHAT YOU LOSE: exactly that protection. Prefer calling `arm_force_update()`
-- over removing the guard; only run this if the trigger is demonstrably
-- blocking a legitimate operation.

begin;

drop trigger if exists trg_guard_force_update_arming on public.announcements;
drop function if exists public.arm_force_update(uuid, text, uuid);
drop function if exists public.guard_force_update_arming();
drop function if exists public.announcement_blocks_clients(text, boolean, timestamptz);

-- The audit table and its rows are deliberately KEPT. They are the record of
-- who armed what, and deleting an audit trail as part of a rollback is how an
-- incident becomes unreconstructable.
-- drop table if exists public.announcement_admin_audit;

commit;
