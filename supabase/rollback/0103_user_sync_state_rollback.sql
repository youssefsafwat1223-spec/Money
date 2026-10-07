-- ROLLBACK for 0103_user_sync_state.sql
--
-- Drops the hook, the function and the table. Roll back 0114..0104 first: the
-- stamp trigger (0105) and the sync_* RPCs (0107) depend on this table.
-- Reversible: the table holds only derived counters (rebuilt by re-applying 0103
-- then 0104), never user data.
BEGIN;

DROP TRIGGER IF EXISTS on_auth_user_created_sync_state ON auth.users;
DROP FUNCTION IF EXISTS public.create_user_sync_state();
DROP TABLE IF EXISTS public.user_sync_state;

COMMIT;
