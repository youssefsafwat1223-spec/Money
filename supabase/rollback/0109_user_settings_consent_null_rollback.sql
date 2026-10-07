-- ROLLBACK for 0109_user_settings_consent_null.sql
--
-- DATA CHANGE: this restores the column DEFAULTS and NOT NULL only. It CANNOT
-- restore the data: the old TRUE values the migration turned into NULL are gone.
-- Only PITR / a pre-migration dump can bring them back. Here every NULL becomes
-- FALSE (the conservative value) so NOT NULL can be re-imposed, which means a
-- user who never answered is stored as an explicit "no".
--
-- Also drops consent_version and consent_granted_at (any recorded grant version
-- is lost). Re-deploy the previous ai_endpoint.ts if you roll this back, or JWT AI
-- stays denied for every user (its read of consent_version would fail).
BEGIN;

ALTER TABLE public.user_settings DISABLE TRIGGER USER;
UPDATE public.user_settings
   SET ai_consent_granted = COALESCE(ai_consent_granted, false),
       cloud_processing_enabled = COALESCE(cloud_processing_enabled, false)
 WHERE ai_consent_granted IS NULL OR cloud_processing_enabled IS NULL;
ALTER TABLE public.user_settings ENABLE TRIGGER USER;

ALTER TABLE public.user_settings
  ALTER COLUMN ai_consent_granted SET DEFAULT true,
  ALTER COLUMN ai_consent_granted SET NOT NULL,
  ALTER COLUMN cloud_processing_enabled SET DEFAULT true,
  ALTER COLUMN cloud_processing_enabled SET NOT NULL;

ALTER TABLE public.user_settings
  DROP COLUMN IF EXISTS consent_granted_at,
  DROP COLUMN IF EXISTS consent_version;

COMMIT;
