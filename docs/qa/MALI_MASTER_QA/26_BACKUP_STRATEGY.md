# 26 — Backup Strategy

Related: [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md), [07_SECURITY.md](07_SECURITY.md), [08_FEATURES.md](08_FEATURES.md) §13.

## 1. Two distinct backup mechanisms

| Mechanism | Scope | Trigger | Storage |
|---|---|---|---|
| User-initiated Drift export/import | One user's on-device financial data | Manual, from Settings/Backup screen | Encrypted export uploaded to that user's private path in the `backups` Storage bucket |
| Supabase project-level backup | Entire project (all catalog + all `user_*` financial data for Supabase-primary users) | Supabase-managed, plan-dependent | Supabase infrastructure, outside this app's direct control |

## 2. User-initiated backup (`features/backup/`)

**Purpose**: the primary safety net for a user whose financial data lives mainly in the on-device Drift database (Supabase-primary flags OFF), since that data has no server-side copy otherwise.

**Export flow**:
1. User triggers export from Settings.
2. The local Drift database (or a defined subset/serialization of it — confirm exact current scope against the implementation rather than assuming "the whole file") is encrypted.
3. Uploaded to the user's own path within the private `backups` Storage bucket.
4. A `backups` metadata row is written (timestamp, size, perhaps a checksum) for later listing/selection.

**Restore flow**:
1. User selects a backup from Settings.
2. It's downloaded and decrypted.
3. The local Drift file is replaced.
4. App reopens the database.

**Failure modes to test** (see [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `BKUP-*` — extend the matrix with these if not already present):
- Restore attempted with a backup from an incompatible/older schema version — must trigger the normal Drift migration path on reopen, not crash.
- Restore interrupted mid-download/decrypt — must not leave the local database in a half-replaced, corrupted state; prefer a write-to-temp-then-atomic-swap pattern if not already implemented this way.
- Export attempted with insufficient device storage — must fail cleanly with a clear message, not silently produce a truncated backup.

## 3. What is and isn't covered by the user-initiated backup

**Covered**: whatever the export flow captures from the local Drift database at export time (transactions, accounts, budgets, goals, etc., as they existed locally).

**Not covered**: anything that only exists server-side and wasn't mirrored locally at export time — for a user with a Supabase-primary flag ON, the *server* copy is authoritative and this backup mechanism is a secondary convenience, not their primary safety net (the Supabase project-level backup, §4, is).

**A user's mental model matters here**: communicate clearly (in-app copy, not just this handbook) which case applies to them, since "I took a backup" means something different depending on their flag state.

## 4. Supabase project-level backups

Managed by Supabase's own infrastructure per the project's plan tier. This handbook does not control or configure this directly — verify the current plan's actual backup frequency/retention via the Supabase Dashboard (Project Settings → Backups) rather than assuming a specific schedule, since plan tiers differ significantly (some tiers offer daily backups with a short retention window; higher tiers offer point-in-time recovery).

**Action item for whoever manages the production Supabase project**: confirm the actual configured backup tier and retention window, and record it here once confirmed, since "we have backups" without knowing the retention window is not an actionable disaster-recovery fact. Until confirmed, treat this as **unverified** — do not assert a specific RPO/RTO in an incident response without checking the dashboard first.

## 5. Backup verification (don't just trust that backups work)

- Periodically (a real, scheduled practice, not a one-time check) perform an actual restore-from-backup test against a QA account, verifying the restored data matches what was exported.
- Confirm the `backups` Storage bucket's private-access RLS-equivalent policies (from migration `0001_init.sql`) still correctly scope each user to only their own backup files — this is a security property as much as a backup-integrity one.

## 6. Catalog/seed data backup

Catalog tables (banks, parsers, categories, feature flags) are primarily "backed up" by being defined in version-controlled migration/seed files under `supabase/migrations/` — the git history of this repository is the durable backup for catalog *structure and initial seed content*. Any catalog content added or edited later purely through the admin panel (not captured in a migration file) is **not** covered by this and relies entirely on the Supabase project-level backup (§4) — consider periodically exporting admin-panel-managed catalog state into a migration-like seed file if catalog content becomes operationally significant enough to warrant it.

## 7. Relationship to disaster recovery

See [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md) for how these backup mechanisms are actually invoked during a real incident. The short version: user-initiated backups protect individual users against local data loss; Supabase project-level backups (once their actual retention is confirmed per §4) are the last line of defense against a project-wide incident.
