-- 0092 — close the anon/authenticated exposure on the 0087 rollback journal.
--
-- THE DEFECT
-- `0087_parser_validation_evidence.sql` creates
-- `public.sms_parsers_validation_reset_0087` to hold the pre-image of every
-- parser it demotes from `passed` to `pending`, so that migration is exactly
-- reversible. It creates the table and never says anything else about it: no
-- `ENABLE ROW LEVEL SECURITY`, no `REVOKE`.
--
-- On a hosted Supabase project that silence is not neutral. The platform ships
-- default privileges on schema `public` that grant `anon` and `authenticated`
-- the full table privilege set on every newly created table. Every other table
-- in this schema neutralises those defaults by enabling RLS with no permissive
-- policy; this one does not, so the defaults stand. Verified live on the
-- production project immediately after the 0001->0091 apply:
--
--   relrowsecurity = false
--   relacl = {postgres=arwdDxtm/postgres,
--             anon=arwdDxtm/postgres,
--             authenticated=arwdDxtm/postgres,
--             service_role=arwdDxtm/postgres}
--
-- It was the ONLY table in `public` with RLS disabled, and therefore the only
-- one where those defaults were still reachable. PostgREST exposes `public`, so
-- the grants are not theoretical: an unauthenticated caller could read, insert,
-- update, delete and TRUNCATE the journal over HTTP.
--
-- WHY THIS MATTERS MORE THAN IT FIRST LOOKS
-- Confidentiality is genuinely low: twelve rows of parser UUIDs and previous
-- status strings. No user data, no financial data, no secrets.
--
-- Integrity is the real exposure, and it is pointed directly at the control
-- 0087 exists to create. 0087's whole purpose is that `validation_status =
-- 'passed'` must MEAN something — that a parser carries golden-test evidence.
-- An anonymous caller who can write this journal can:
--
--   * TRUNCATE it, destroying the pre-image and with it the ability to roll
--     0087 back at all; or
--   * INSERT forged `(parser_id, previous_status = 'passed')` rows, so that a
--     later, entirely legitimate execution of the 0087 rollback promotes
--     attacker-chosen parsers to `passed` without a single golden test.
--
-- The second is the dangerous one. It converts a recovery procedure into a
-- privilege-escalation primitive, and it does so silently: the rollback would
-- report success, having done exactly what the journal told it to do.
--
-- WHY 0088 DID NOT ALREADY FIX THIS
-- `0088_explicit_owner_table_grants.sql` is the migration that reasons about
-- grants, but it is ADDITIVE ONLY by explicit design ("`GRANT` never removes a
-- privilege"), and its `REVOKE` block is deliberately left commented out. It
-- could not have closed this, and it should not be edited to try: 0088's
-- additive-only property is what makes it safe to re-run.
--
-- WHY THE DRY-RUN HARNESS DID NOT CATCH IT
-- `supabase/tools/dryrun_migrations.sh` applies the chain to a disposable
-- `postgres:17` container. That container has no `anon` or `authenticated`
-- roles and none of Supabase's default privileges on `public`, so the grants
-- under test here cannot exist there. The defect is only observable against a
-- real Supabase project. This is a gap in the harness, not in the review.
--
-- THE FIX
-- Two independent layers, either of which alone would close it:
--
--   1. Enable RLS with NO policy. Under RLS a table with no permissive policy
--      denies every row to every non-bypassing role. This matches how the other
--      61 tables in `public` are protected and how the thirteen zero-policy
--      service-role-only tables already work.
--   2. Revoke the table privileges outright, so the grant does not exist to be
--      relied on even if RLS were later disabled by accident.
--
-- WHAT DELIBERATELY DOES NOT CHANGE
--   * No permissive policy is added. This table is internal; nothing in the
--     mobile client or the admin UI reads it. Deny-all is the correct contract.
--   * `service_role` keeps its grants and continues to bypass RLS, so the
--     controlled 0087 rollback still works exactly as written.
--   * `postgres` remains the owner and is unaffected.
--   * RLS is enabled but NOT forced. Forcing it would also subject the owner to
--     the (empty) policy set and break administrative recovery, which is the
--     one legitimate use this journal has.
--   * No row is read, written, or deleted. The pre-image is preserved intact.
--
-- Idempotent: `ENABLE ROW LEVEL SECURITY` on an already-RLS table is a no-op,
-- and `REVOKE` of an absent privilege is a no-op. Guarded on table existence so
-- it is safe on a project where 0087 has not run.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name   = 'sms_parsers_validation_reset_0087'
  ) THEN
    RAISE NOTICE '0092: sms_parsers_validation_reset_0087 absent; nothing to lock down.';
    RETURN;
  END IF;

  -- Layer 1 — deny-all by RLS (no policy is created, intentionally).
  EXECUTE 'ALTER TABLE public.sms_parsers_validation_reset_0087 '
       || 'ENABLE ROW LEVEL SECURITY';

  -- Layer 2 — remove the platform-default grants entirely.
  EXECUTE 'REVOKE ALL ON TABLE public.sms_parsers_validation_reset_0087 '
       || 'FROM anon, authenticated';

  RAISE NOTICE '0092: journal locked down (RLS enabled, anon/authenticated revoked).';
END $$;

-- Verification. Fails the migration rather than reporting a success that did
-- not happen -- the failure mode this whole migration exists to prevent.
DO $$
DECLARE
  v_rls  BOOLEAN;
  v_anon INTEGER;
  v_auth INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name   = 'sms_parsers_validation_reset_0087'
  ) THEN
    RETURN;
  END IF;

  SELECT c.relrowsecurity INTO v_rls
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'sms_parsers_validation_reset_0087';

  SELECT count(*) INTO v_anon FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name   = 'sms_parsers_validation_reset_0087'
     AND grantee      = 'anon';

  SELECT count(*) INTO v_auth FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name   = 'sms_parsers_validation_reset_0087'
     AND grantee      = 'authenticated';

  IF NOT v_rls THEN
    RAISE EXCEPTION '0092 FAILED: RLS not enabled on sms_parsers_validation_reset_0087';
  END IF;
  IF v_anon <> 0 THEN
    RAISE EXCEPTION '0092 FAILED: anon retains % privilege(s) on the journal', v_anon;
  END IF;
  IF v_auth <> 0 THEN
    RAISE EXCEPTION '0092 FAILED: authenticated retains % privilege(s) on the journal', v_auth;
  END IF;
END $$;
