-- User preference settings — cloud sync (S2), same offline-first engine as
-- user_accounts / user_cards. This is a per-user SINGLETON: one row per user,
-- addressed by a constant local_id = 'user_settings'.
--
-- SECURITY / PRIVACY: this table intentionally stores ONLY cross-device
-- preferences. It must NEVER contain device-local values:
--   • db_encryption_key_ref (local DB key — must never leave the device)
--   • avatar_path (a local file path)
--   • display_name / phone_number / date_of_birth (profile data — lives in
--     `profiles`, excluded from settings sync by design).

create table if not exists user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text not null,
  theme text,
  currency text,
  language text,
  country text,
  input_method text,
  notifications_json text,
  privacy_mode_enabled boolean not null default false,
  ai_consent_granted boolean not null default true,
  cloud_processing_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (user_id, local_id)
);

create index if not exists idx_user_settings_owner on user_settings(user_id);

create or replace function set_user_settings_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_user_settings_updated_at on user_settings;
create trigger trg_user_settings_updated_at
  before update on user_settings
  for each row execute function set_user_settings_updated_at();

alter table user_settings enable row level security;

drop policy if exists user_settings_owner on user_settings;
create policy user_settings_owner on user_settings
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
