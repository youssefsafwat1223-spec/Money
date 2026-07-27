# S1 — Card Synchronization · Audit

**Goal:** Cards join offline-first sync using the **exact same architecture** as
Accounts/Budgets/Goals/Plans. No new pattern.
**Status:** ✅ analyze clean · ✅ 761 tests pass · no commits.

## Architecture confirmation — same as planning entities
Cards reuse the shared engine verbatim; nothing bespoke was added:
| Concern | Mechanism (shared) |
|---|---|
| Local persistence | `DriftCardRepository` writes `cards` (Drift) first |
| Outbox | `PlanningOutboxQueue.enqueueCard` (added A1) → `planning_sync_outbox` |
| Push | `PlanningPushService` — added `card → user_cards` to `_entityTable`/`_localTable` + one `_toServerRow` case. All upsert/tombstone/attach-server-id/conflict logic is generic and unchanged |
| Pull | `PlanningPullService` — added `card → user_cards` + `_insertCard`/`_updateCard`. `_processRow`/`_processTombstone`/conflict guard unchanged |
| Conflict | Same `sync_status` guard: local `pending`/`conflict` blocks server overwrite → marks `conflict` (LWW by `updated_at`) |
| Enablement | `_planningEntitySyncEnabled('card')` → follows the **accounts** flags (cards belong to accounts) |
| Background only | Runs inside `PlanningSyncEngine.sync()` (bootstrap + resume). No sync on the UI path |
| UI reads Drift | `cardRepositoryProvider` → `DriftCardRepository` (unchanged); UI never reads Supabase |

## Server
`supabase/migrations/0058_user_cards.sql` revised to match the planning pattern:
references the account by **`local_account_id` (text)**, not a server UUID FK;
`unique(user_id, local_id)`; active-unique `(user_id, local_account_id, last4)`;
`updated_at` trigger; RLS owner policy. **Owner must apply it.**

## Verified behaviours (test/features/planning_sync/card_sync_service_test.dart)
| Requirement | Test | Result |
|---|---|---|
| Manual cards sync | push → `user_cards` row, `source='manual'` | ✅ |
| Auto-detected cards sync | push → `source='auto'` | ✅ |
| Card edits sync | nickname/network update pushes | ✅ |
| Card moves between accounts sync | `local_account_id` updates to new account | ✅ |
| Delete syncs, keeps transactions | server tombstoned; local transaction row preserved | ✅ |
| Multi-device | device A push → device B (fresh DB) pull imports card | ✅ |
| Idempotent pull | second pull creates no duplicate | ✅ |
| Server uniqueness/conflict | duplicate `(account,last4)` upsert → 23505 → conflict path | ✅ (fake enforces) |

## Offline-first
- Card create/edit/move/delete write Drift + enqueue outbox **offline** (no network on the write path); push drains on reconnect. Pull refreshes Drift in the background.
- UI (`accountCardsProvider`, account detail, card form) reads **only** Drift.
- **Manual device Airplane-Mode check (owner):** add/edit/move/delete a card offline → persists; reconnect → appears in `user_cards`; second device pulls it. *(Cannot run here — needs devices + the migration applied.)*

## No new pattern introduced — confirmed
- No new sync service/engine/queue. Only map entries + 2 row-mapping cases added to the existing push/pull services.
- Same conflict model, same outbox, same enablement style as accounts.

## Follow-ups (not S1)
- **S2** User Settings sync · **S3** smart-inbox/category outbox + conflict audit · **S4** offline verification matrix · **S5** remove dead Pattern-A code.
- Owner: apply `0058_user_cards.sql`.
