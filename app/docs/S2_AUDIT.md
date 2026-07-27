# S2 — User Settings Synchronization · Audit

**Goal:** Sync user *preferences* offline-first using the **same engine** as
Accounts/Cards. Device-local and security settings never leave the device.
**Status:** ✅ analyze clean · ✅ 765 tests pass · no commits.

## Settings classification (reviewed & approved)
### ☁️ Cloud (synced)
`theme` · `currency` · `language` · `country` · `input_method` ·
`notifications_json` · `privacy_mode_enabled` · `ai_consent_granted` ·
`cloud_processing_enabled`

### 📱 Device-local — NEVER synced (verified by test)
| Setting | Reason |
|---|---|
| `db_encryption_key_ref` | **security** — local DB key, must never leave device |
| `avatar_path` | local file path (meaningless cross-device) |
| `display_name` / `phone_number` / `date_of_birth` | profile data — excluded from S2 (lives in `profiles`) |
| `id` | local singleton identity |
| biometric lock, onboarding state, feature-flag overrides, install id, OS permissions, debug flags | live outside `user_settings`; untouched by S2 |

## Architecture — same engine, no new pattern
| Concern | Mechanism |
|---|---|
| Local persistence | `DriftUserSettingsRepository` writes `user_settings` (Drift) + `updated_at` |
| Outbox | `PlanningOutboxQueue.enqueueSettings` → shared `planning_sync_outbox` |
| Push | `PlanningPushService` — added `settings → user_settings` map entries + one `_toServerRow` case sending **cloud columns only** |
| Pull | `PlanningPullService` — added map entries + singleton `_processSettingsRow`/`_updateSettings` (cloud columns only) |
| Conflict | Same `sync_status` guard: local `pending` edit blocks server overwrite → `conflict` |
| Enablement | `_planningEntitySyncEnabled('settings')` follows the accounts flags |
| Background only | Runs inside `PlanningSyncEngine.sync()`; UI never reads Supabase |

### The one singleton adaptation (approved)
`user_settings` is one row per user. Two minimal deviations, both inside the
shared engine (analogous to per-entity `_insertX`/`_updateX`):
1. Constant `local_id = 'user_settings'` → one server row per user across devices.
2. Pull `_processSettingsRow` updates the single existing row (never inserts a
   second), and `_updateSettings` writes **only cloud columns** — device-local
   columns are left untouched.
No new engine, queue, or scheduler.

## Verified (test/features/planning_sync/settings_sync_service_test.dart)
| Requirement | Result |
|---|---|
| Cloud setting change pushes | ✅ `theme`/`currency` reach `user_settings` |
| **Device-local never sent** | ✅ server row has no `db_encryption_key_ref` / `avatar_path` / profile keys |
| Offline editing | ✅ save writes Drift + enqueues (no network on write path) |
| Pull merges cloud, preserves device-local | ✅ `theme` updated; `avatar_path` + key ref preserved |
| Multi-device consistency | ✅ device A change → device B pull; still **one** settings row |
| Conflict handling | ✅ local pending edit not overwritten by pull |

## Server
`supabase/migrations/0060_user_settings.sql` — cloud columns only, `updated_at`
trigger, `unique(user_id, local_id)`, RLS owner policy. **Owner must apply it.**

## Offline-first
- Preference edits write Drift + enqueue offline; push drains on reconnect; pull
  refreshes in the background. UI reads Drift exclusively.
- **Manual Airplane-Mode check (owner):** change theme/currency offline → persists;
  reconnect → row in `user_settings`; second device pulls it; local avatar/key
  unchanged. *(Needs devices + the migration applied.)*

## Follow-ups
- **S3** smart-inbox/category outbox + conflict audit · **S4** offline verification
  matrix · **S5** remove dead Pattern-A code.
- Owner: apply `0058_user_cards.sql` (S1) and `0060_user_settings.sql` (S2).
