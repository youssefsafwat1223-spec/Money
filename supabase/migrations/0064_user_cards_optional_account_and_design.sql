-- Optional account link + card design customization (mirrors client Drift v27).
-- Two changes to user_cards:
--   1. local_account_id becomes NULLABLE — a card may be unassigned (no owning
--      account). This matches the client, where account_id is now nullable.
--   2. Add cosmetic design columns color_theme + accent_hex (both nullable).
-- All additive/relaxing → backward compatible: existing rows keep working, and
-- older clients that never send these columns are unaffected.
--
-- After deploying this migration, set `kUserCardsCloudV2 = true` in the Flutter
-- client (lib/features/planning_sync/services/planning_outbox_queue.dart) to
-- start syncing unassigned cards and the design fields.

alter table user_cards
  alter column local_account_id drop not null;

alter table user_cards
  add column if not exists color_theme text null;

alter table user_cards
  add column if not exists accent_hex text null;

-- The active-uniqueness index (user_id, local_account_id, last4) WHERE
-- deleted_at IS NULL is left unchanged: Postgres treats NULL local_account_id
-- values as distinct in a unique index, so multiple unassigned cards with the
-- same last4 are allowed — mirroring the client's SQLite behavior.
