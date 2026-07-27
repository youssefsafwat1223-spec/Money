-- 0063: profile fields on user_settings.
-- display_name / phone_number / date_of_birth were device-local only, so a
-- sign-out (which wipes local data) destroyed them permanently. They are
-- personal-but-restorable profile data and belong in cloud settings like
-- currency/country. avatar stays device-local (it is a file, not a column).
alter table public.user_settings
  add column if not exists display_name text null,
  add column if not exists phone_number text null,
  add column if not exists date_of_birth text null;
