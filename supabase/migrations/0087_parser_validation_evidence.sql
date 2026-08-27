-- C-1 / F-011 — make `sms_parsers.validation_status = 'passed'` mean something.
--
-- THE DEFECT
-- `catalog-delta` already refuses to serve unvalidated parsers:
--     -- Parsers: only serve rules that have passed golden-test validation.
--     baseItemQuery.eq('validation_status', 'passed')
--   (supabase/functions/catalog-delta/index.ts)
-- That gate is correct. It was defeated at the DATA layer by 0004_parser_lab.sql:15:
--     UPDATE sms_parsers SET validation_status = 'passed' WHERE validation_status = 'pending';
-- a blanket backfill that stamped every pre-existing parser `passed` without
-- running a single golden test. The 12 seeded rules (0002_catalog_mvp.sql) —
-- NBE, CIB, Banque Misr, QNB, SNB, Al Rajhi, Riyad, STC Pay, Vodafone/Orange/
-- Etisalat Cash, Fawry — therefore satisfy a gate they were never tested against.
--
-- Once the client-side catalog authority (F-016) is live those rules become the
-- first parsing authority for the app's two primary markets, so an unvalidated
-- regex could set CONFIRMED money with no human review.
--
-- THE FIX
-- Validation evidence already exists on the table (0004 added golden_test_count,
-- validated_at, validated_by). A row stamped by the backfill is exactly
-- identifiable: it claims `passed` while carrying NO evidence. This migration
-- (1) returns those rows to `pending`, and (2) makes the invariant structural so
-- no future backfill, manual edit or admin-panel write can re-create the state.
--
-- Deliberately NOT a blanket reset: a genuinely validated rule keeps its status.
--
-- SAFETY
-- Additive + reversible. The pre-image is preserved in
-- `sms_parsers_validation_reset_0087` so the change can be undone exactly (see
-- the ROLLBACK block at the foot of this file). No parser is deleted, no rule
-- content is modified — only the status field moves, and only for rows that
-- were never validated. Effect on clients: those parsers stop being served by
-- catalog-delta until they pass validation in the Parser Lab, which is the
-- intended behaviour of the gate that already exists.

BEGIN;

-- 1. Preserve the pre-image so this migration is exactly reversible.
CREATE TABLE IF NOT EXISTS public.sms_parsers_validation_reset_0087 (
  parser_id           UUID PRIMARY KEY,
  previous_status     TEXT        NOT NULL,
  reset_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.sms_parsers_validation_reset_0087 (parser_id, previous_status)
SELECT id, validation_status
  FROM public.sms_parsers
 WHERE validation_status = 'passed'
   AND (validated_at IS NULL OR golden_test_count = 0)
ON CONFLICT (parser_id) DO NOTHING;

-- 2. Return evidence-free "passed" rows to pending.
UPDATE public.sms_parsers
   SET validation_status = 'pending'
 WHERE validation_status = 'passed'
   AND (validated_at IS NULL OR golden_test_count = 0);

-- 3. Make the invariant structural: `passed` REQUIRES evidence.
--    Any future blanket UPDATE, admin-panel write or manual flip now fails loudly
--    instead of silently granting money authority to an untested regex.
ALTER TABLE public.sms_parsers
  DROP CONSTRAINT IF EXISTS sms_parsers_passed_requires_evidence;

ALTER TABLE public.sms_parsers
  ADD CONSTRAINT sms_parsers_passed_requires_evidence
  CHECK (
    validation_status <> 'passed'
    OR (validated_at IS NOT NULL AND golden_test_count > 0)
  );

COMMIT;

-- ─── ROLLBACK (run manually; not executed by this migration) ─────────────────
-- BEGIN;
--   ALTER TABLE public.sms_parsers
--     DROP CONSTRAINT IF EXISTS sms_parsers_passed_requires_evidence;
--   UPDATE public.sms_parsers AS p
--      SET validation_status = r.previous_status
--     FROM public.sms_parsers_validation_reset_0087 AS r
--    WHERE p.id = r.parser_id;
--   DROP TABLE public.sms_parsers_validation_reset_0087;
-- COMMIT;
