-- ROLLBACK for 0102_feature_flag_admin_audit.sql
--
-- Drops the audit history (the append-only trail of who changed which flag) and
-- the RPC. Flag rows themselves and their values are untouched; only the
-- updated_at trigger is removed.
-- Export feature_flag_admin_audit first if the history must be kept.
DROP FUNCTION IF EXISTS public.admin_apply_feature_flag_changes(UUID, TEXT, UUID, JSONB);
DROP FUNCTION IF EXISTS public.admin_can_change_flag(UUID, TEXT);
DROP TABLE IF EXISTS public.feature_flag_admin_audit;
DROP FUNCTION IF EXISTS public.feature_flag_audit_append_only();
DROP TRIGGER IF EXISTS trg_feature_flags_updated_at ON public.feature_flags;
