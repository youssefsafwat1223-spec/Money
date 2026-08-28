-- F-029 — detect budget rows whose `category_id` is a per-device local id
-- rather than a stable catalog key.
--
-- THE DEFECT
-- `PlanningOutboxQueue.enqueueBudget` serialised the local Drift category id
-- into `user_budgets.category_id`. The budgets pull resolves that column against
-- `categories.key`, so another device could not resolve an opaque per-device id
-- and silently re-categorised the budget to `other`. Seed category ids are
-- generated per install (`database_seed.dart`, `IdGenerator.next()`), so EVERY
-- budget pushed by a pre-fix client carries a corrupt value.
--
-- The client fix has landed (id -> key at enqueue, and fail-closed when the
-- category cannot be resolved), so no NEW corruption is produced. This migration
-- addresses the rows already on the server.
--
-- WHY THIS ONLY DETECTS, AND DOES NOT REPAIR
-- A per-device local id carries no information the server can use: it is an
-- opaque identifier whose meaning exists solely in the originating install's
-- database. There is no join, no heuristic and no default that recovers the
-- user's intended category from it.
--
-- Three options were considered and rejected:
--   * set them to 'other'      — that is the CORRUPTION, made permanent;
--   * NULL them                — silently deletes the user's categorisation;
--   * guess by amount/name     — invents financial classification from nothing.
--
-- The only party that still holds the truth is the device that wrote the row.
-- So the server's job is to make the damage VISIBLE and let the owning client
-- re-push the correct key. Detection is the honest deliverable here; a repair
-- that guesses would be worse than the bug.
--
-- SAFETY: read-only. Creates a view. Mutates nothing.

BEGIN;

-- Rows whose category_id is not a known catalog key. `all_expenses` is the
-- sentinel the client sends for a whole-account budget and is legitimate.
CREATE OR REPLACE VIEW public.budget_category_key_violations AS
SELECT
  b.id,
  b.user_id,
  b.category_id AS unresolvable_category_id,
  b.updated_at,
  -- A value shaped like a catalog key that simply is not seeded reads very
  -- differently from an opaque generated id; separating them tells the operator
  -- whether this is corruption or a missing catalog row.
  (b.category_id ~ '^[a-z][a-z0-9_]*$') AS looks_like_a_key
FROM public.user_budgets b
WHERE b.deleted_at IS NULL
  AND b.category_id IS NOT NULL
  AND b.category_id <> 'all_expenses'
  AND NOT EXISTS (
    SELECT 1 FROM public.categories c WHERE c.key = b.category_id
  );

COMMENT ON VIEW public.budget_category_key_violations IS
  'F-029: user_budgets rows whose category_id is not a stable catalog key. '
  'Detection only — the intended category is recoverable ONLY by the owning '
  'device re-pushing it. Never repair by defaulting to other/NULL.';

REVOKE ALL ON public.budget_category_key_violations FROM anon, authenticated;

COMMIT;

-- ─── OPERATOR NOTES ─────────────────────────────────────────────────────────
--
-- 1. Measure the blast radius before activating financial transport
--    (see docs/CAPABILITY_ACTIVATION_RUNBOOK.md, precondition P2):
--
--      SELECT count(*), count(DISTINCT user_id) FROM budget_category_key_violations;
--
-- 2. The repair path is CLIENT-side: a fixed client re-pushing its budgets
--    overwrites the corrupt value with the stable key. No server mutation is
--    correct here.
--
-- 3. Do NOT add a "cleanup" that sets these to 'other'. That is precisely the
--    silent re-categorisation the finding is about — it would convert a
--    detectable defect into permanent, invisible data loss.
--
-- ─── ROLLBACK ───────────────────────────────────────────────────────────────
-- BEGIN;
--   DROP VIEW IF EXISTS public.budget_category_key_violations;
-- COMMIT;
