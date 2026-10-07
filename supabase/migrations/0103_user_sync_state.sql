-- 0103_user_sync_state.sql — WP-2 (manifest §7, numbered 0104 in the manifest;
-- renumbered to the next free active number because 0103 was deferred).
--
-- Per-user change-stream head + replica epoch. One row per user:
--   last_seq     the last sync_seq handed out to any of the user's synced rows
--   epoch        changes when the server history is no longer continuous
--                (purge / reset / restore); clients compare it on push and pull
--   epoch_reason why the epoch last changed (NULL only for rows that predate it)
--
-- The row is also the per-user WRITE LOCK: stamp_sync_seq() (0105) and the
-- sync_* RPCs (0107) take it first, so sequence allocation order equals commit
-- order for one user (READ COMMITTED: a second writer waits on the row lock and
-- then re-reads the committed last_seq).
--
-- Rows are created three ways, so a stamping UPDATE can never find zero rows:
--   1. backfill below for every existing auth.users row;
--   2. an auth.users AFTER INSERT trigger for new users;
--   3. lazily by the stamping function (INSERT .. ON CONFLICT DO UPDATE).
--
-- Client access: owner may SELECT own row (server-head short-circuit); no client
-- INSERT/UPDATE/DELETE grant exists, only SECURITY DEFINER code writes it.

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_sync_state (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seq     bigint NOT NULL DEFAULT 0,
  epoch        uuid NOT NULL DEFAULT gen_random_uuid(),
  epoch_reason text NULL CHECK (epoch_reason IN ('initial', 'purge', 'reset', 'restore')),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_sync_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_sync_state_owner_select ON public.user_sync_state;
CREATE POLICY user_sync_state_owner_select ON public.user_sync_state
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- The platform default privileges grant ALL to anon/authenticated on new tables;
-- take everything back, then give the owner read-only access.
REVOKE ALL ON TABLE public.user_sync_state FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.user_sync_state TO authenticated;
GRANT ALL ON TABLE public.user_sync_state TO service_role;

-- Backfill: every existing user. last_seq stays 0 here; 0104 raises it when it
-- numbers the existing rows.
INSERT INTO public.user_sync_state (user_id, epoch_reason)
SELECT id, 'initial' FROM auth.users
ON CONFLICT (user_id) DO NOTHING;

-- New-user hook. Trigger-bound SECURITY DEFINER (lint: trigger-bound or revoked;
-- both hold). Must never fail: a failure here would block sign-up.
CREATE OR REPLACE FUNCTION public.create_user_sync_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.user_sync_state (user_id, epoch_reason)
  VALUES (NEW.id, 'initial')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.create_user_sync_state() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS on_auth_user_created_sync_state ON auth.users;
CREATE TRIGGER on_auth_user_created_sync_state
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.create_user_sync_state();

COMMIT;
