-- ROLLBACK for 0087_parser_validation_evidence.sql (C-1 / F-011)
--
-- 0087 is EXACTLY reversible by construction: before returning evidence-free
-- `passed` parsers to `pending`, it wrote every affected id and its previous
-- status into `public.sms_parsers_validation_reset_0087`. This replays that
-- journal.
--
-- Order matters. The CHECK constraint must be dropped FIRST — restoring a
-- `passed` status while it is still in force would violate it and abort the
-- whole transaction, which is precisely what the constraint is for.
--
-- WHAT YOU LOSE: `validation_status = 'passed'` stops meaning "has golden-test
-- evidence". `catalog-delta` serves only passed parsers, so rolling back can
-- put untested regexes back in front of real users' money. Prefer fixing the
-- parser's evidence over rolling this back.

begin;

-- 1. Drop the structural invariant first.
alter table public.sms_parsers
  drop constraint if exists sms_parsers_passed_requires_evidence;

-- 2. Replay the pre-image journal.
update public.sms_parsers p
   set validation_status = j.previous_status
  from public.sms_parsers_validation_reset_0087 j
 where p.id = j.parser_id;

-- 3. The journal has served its purpose.
--    Kept, not dropped: it is the only record of which rows 0087 touched, and
--    re-applying 0087 afterwards is safe because its INSERT is ON CONFLICT DO
--    NOTHING. Drop it manually once you are certain you will not roll forward.
-- drop table if exists public.sms_parsers_validation_reset_0087;

commit;
