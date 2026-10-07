-- ROLLBACK for 0116_category_and_contribution_tombstones.sql
--
-- Drops the two tombstone RPCs. No client uses them while revision_cas is false
-- (the one exception is the goal-contribution delete, which falls back to the
-- pre-0116 behaviour, a visible dead letter, when the function is absent). They
-- own no data and changed no existing object, so nothing else needs restoring.
BEGIN;

DROP FUNCTION IF EXISTS public.sync_tombstone_goal_contribution(uuid, uuid);
DROP FUNCTION IF EXISTS public.sync_cas_tombstone_category(uuid, uuid, uuid, integer);

COMMIT;
