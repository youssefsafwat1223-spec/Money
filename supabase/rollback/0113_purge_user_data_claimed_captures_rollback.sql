-- ROLLBACK for 0113_purge_user_data_claimed_captures.sql
--
-- Restores purge_user_data() to its 0084 definition: re-apply the function body
-- from supabase/migrations/0084_purge_user_data_restore.sql. Done as a fresh
-- CREATE OR REPLACE of that exact body, never by hand-editing this file.
-- psql usage:  \i supabase/migrations/0084_purge_user_data_restore.sql
-- (0084 is idempotent: create or replace + revoke/grant only.)
BEGIN;
\i supabase/migrations/0084_purge_user_data_restore.sql
COMMIT;
