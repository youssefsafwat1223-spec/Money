-- ROLLBACK for 0101_sender_mapping_accepted_by.sql
--
-- Drops the provenance column (and its CHECK constraint with it). Loses only
-- the user | ai_validated provenance; the mapping rows themselves stay.
ALTER TABLE public.sender_bank_mappings DROP COLUMN IF EXISTS accepted_by;
