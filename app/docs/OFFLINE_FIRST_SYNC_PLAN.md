# Offline-First Sync Architecture — Migration Plan

**Target (approved):** Supabase = source of truth, Drift = local offline cache.
`User → UI → Drift → Sync Engine → Supabase`. **Never `UI → Supabase`.**
App works fully offline; syncs automatically on reconnect. One consistent pattern
for every entity: local persistence + background push + background pull + conflict
resolution + offline editing.

## The core finding (why offline breaks today)
Two competing patterns exist:

- **Pattern A — routed direct read (`*_supabase_primary` flags ON).**
  `routeFinancialOperation` does `return supabase()` with **no Drift fallback**
  (`lib/data/db/financial_cache_health.dart:110`). When the flag is ON the UI reads
  straight from Supabase → offline throws `_ClientSocketException` → screens break
  (exactly the pasted logs). **This is the anti-pattern to retire.**
- **Pattern B — background sync (flags OFF).** UI reads Drift; a pull service writes
  Supabase→Drift, an outbox + push service sends Drift→Supabase. **This is the target.**

The flags are mutually exclusive (`planning_*_sync` runs only when the matching
`*_supabase_primary` is OFF). So the migration is essentially: **turn Pattern A off,
make Pattern B complete and reliable for every entity, then delete Pattern A.**

## Per-entity gap map
| Entity | Local | Push | Pull | Conflict | UI reads Drift | Notes |
|---|---|---|---|---|---|---|
| Accounts | ✓ | ✓ accounts_push | ✓ accounts_pull | ✓ | ⚠️ only if primary OFF | retire Pattern A |
| Transactions | ✓ | ✓ ledger_push | ✓ ledger_sync/backfill | partial | ⚠️ only if primary OFF | retire Pattern A |
| Budgets/Goals/Subs/Plans | ✓ | ✓ planning_push | ✓ planning_pull | ✓ | ⚠️ flag | retire Pattern A |
| Smart Inbox | ✓ | ? | ? | ? | ⚠️ flag | audit completeness |
| Categories | ✓ | ? | routed | ? | routed | audit |
| **Cards** | ✓ | outbox enqueue **INERT** | ✗ none | ✗ | ✓ already Drift | build push+pull (table 0058) |
| **Settings** | ✓ | ✗ | ✗ | ✗ | ✓ local-only | greenfield: table + push/pull |

## Standard per-entity checklist (definition of done)
1. Drift table with sync columns (`server_id, synced_at, server_updated_at, sync_status, deleted_at`).
2. Repository writes Drift first, enqueues outbox op (offline editing works).
3. **Push** service drains outbox → Supabase (retry/backoff, idempotent by `local_id`).
4. **Pull** service Supabase→Drift (incremental by `server_updated_at`).
5. **Conflict** resolution: last-write-wins by `updated_at` + `sync_status='conflict'` guard.
6. UI provider reads **only** Drift; refreshes on `dbRevision`.
7. Supabase table + RLS + indexes; migration file delivered.
8. Tests: offline create/edit persists + enqueues; pull merges; conflict resolves.

## Phased plan (each phase: analyze + full tests, no commits)

### Phase S0 — Retire Pattern A (the offline fix) ★ highest impact
- Add Drift fallback to `routeFinancialOperation`: on network error while
  `useSupabase`, fall back to `drift()` (read cache) instead of throwing — immediate
  offline resilience without behaviour change online.
- Ensure every financial entity's **pull** runs in the background sync engine so the
  Drift cache stays fresh, then flip `*_supabase_primary` OFF by default so UI reads
  Drift. Keep Supabase repos only for the sync engine, not for UI reads.
- End state: routed repos' Supabase-read branch is dead → remove it later.

### Phase S1 — Cards sync (priority 1)
- Server: apply `0058_user_cards.sql`. Client: `cards_pull_service` + activate
  `enqueueCard` (add `card` to push dispatch `_entityTable`/`_toServerRow`/`_fromServerRow`
  + `_planningEntitySyncEnabled`). Conflict = `(account_id,last4)` LWW.

### Phase S2 — User Settings sync (priority 2)
- Server: `user_settings` table + RLS (or extend `profiles`). Client: sync columns on
  local `user_settings`, outbox support, push/pull, conflict. UI already reads Drift.

### Phase S3 — Remaining entities audit (priority 3)
- Verify Smart Inbox, Categories, Transactions conflict paths meet the checklist;
  fill any missing pull/push/conflict.

### Phase S4 — Offline-first verification (priority 4)
- Airplane-mode matrix: create/edit/delete each entity offline → persists + queued →
  reconnect → pushes + reconciles. Automated where possible + a manual checklist.

### Phase S5 — Cleanup
- Delete Pattern A (Supabase-read branch in routed repos, dead flags, obsolete engines).

### Phase A5.2+ — product features resume only after S0–S4 verified.
