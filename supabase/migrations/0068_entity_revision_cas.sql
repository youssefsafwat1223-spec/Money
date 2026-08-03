-- 0068_entity_revision_cas.sql
--
-- MALI-022 / MALI-052n / MALI-057n: real server-side optimistic concurrency.
--
-- Replaces the client-side "read remote → compare updated_at in Dart → write"
-- (TOCTOU last-write-wins) with an ATOMIC compare-and-set performed inside
-- PostgreSQL. Adds a server-owned monotonic `revision` to every mutable synced
-- entity and a BEFORE UPDATE trigger that increments it on any successful
-- mutation. The client's conflict-safe update becomes a single atomic statement:
--
--     UPDATE public.<table>
--     SET <patch...>
--     WHERE id = :id AND revision = :expected_revision      -- CAS predicate
--     RETURNING *;                                           -- new revision back
--
-- Row ownership stays enforced by the EXISTING per-table RLS owner policy
-- (user_id = auth.uid()) — this is a plain RLS-scoped UPDATE, so it runs as
-- SECURITY INVOKER with no new RPC, no SECURITY DEFINER, and no caller-supplied
-- user id. A stale `expected_revision` matches zero rows → RETURNING is empty →
-- the client observes a typed conflict and changes nothing. The trigger makes
-- `revision` monotonic and clock-independent (never derived from a client clock).
--
-- Typed client outcomes derivable from a CAS UPDATE:
--   applied      → 1 row returned (new revision = expected + 1)
--   conflict     → 0 rows returned AND the row exists at a different revision
--   not_found    → 0 rows AND the row does not exist / not owned (RLS)
--   forbidden    → RLS rejects (not owner)
--   validation   → check/not-null/FK error (23xxx)
--   idempotent   → a retried already-applied mutation (client_request_id) is a
--                  no-op create-upsert or a CAS whose row is already at target
--
-- ── Concurrency policy per entity ────────────────────────────────────────────
--  user_transactions   revision CAS (update + tombstone-delete via deleted_at)
--  user_accounts       revision CAS
--  user_budgets        revision CAS
--  user_subscriptions  revision CAS
--  user_goals          revision CAS
--  user_plans          revision CAS
--  user_cards          revision CAS
--  user_settings       revision CAS (single row; concurrent device edits)
--  user_categories     revision CAS
--  goal_contributions  APPEND-ONLY idempotent insert (client_request_id) +
--                      tombstone; no in-place update ⇒ no revision needed
--  bill_payments       APPEND-ONLY idempotent insert (client_request_id) +
--                      tombstone; no revision needed
--  plan_transaction_   APPEND-ONLY idempotent insert (client_request_id) +
--   links              tombstone; no revision needed
--
-- BACKWARD COMPATIBILITY (all additive):
--  • `revision` DEFAULT 1 ⇒ every existing row is valid immediately.
--  • Old clients that UPDATE without a revision predicate still work; the
--    trigger keeps `revision` monotonic, so they simply don't get CAS
--    protection (unchanged pre-existing LWW behaviour) — they do NOT break.
--  • The new client keeps its CAS capability OFF until 0068 is verified on the
--    live/staging server (see the client capability gate, Batch 3C).

-- Monotonic revision bump. SECURITY INVOKER (default) — a trigger function runs
-- as part of the triggering statement and needs no elevated privilege; it only
-- rewrites NEW.revision, never reads caller input.
CREATE OR REPLACE FUNCTION public.bump_revision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.revision = COALESCE(OLD.revision, 0) + 1;
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_transactions', 'user_accounts', 'user_budgets', 'user_subscriptions',
    'user_goals', 'user_plans', 'user_cards', 'user_settings', 'user_categories'
  ] LOOP
    -- Additive column (idempotent): existing rows default to revision 1.
    EXECUTE format(
      'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;',
      t
    );
    -- Bump revision on every UPDATE (idempotent trigger creation).
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_revision ON public.%I;', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%I_revision BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.bump_revision();',
      t, t
    );
  END LOOP;
END;
$$;
