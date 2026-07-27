# Synchronization Write-Path Audit

Every path that writes user data to Drift, and whether it enters the sync
pipeline (`Write → Drift → Outbox → Push → Supabase`). "Enqueues?" = does the
write place a row in `ledger_sync_outbox` / `planning_sync_outbox`.

## UI writes — all correct ✅

DI wires the outbox queue into every UI-facing repository provider
(`app_providers.dart` accounts/cards/budgets/goals/plans/bills/categories/
settings/transactions). Manual adds and edits all enqueue.

| Path | Repo (provider) | Entities | Enqueues? |
|---|---|---|---|
| Manual transaction add/edit/delete | `transactionRepositoryProvider` (+outbox) | transaction | ✅ |
| Account create/edit/delete | `accountRepositoryProvider` (+outbox) | account | ✅ |
| Card create/edit | `cardRepositoryProvider` (+outbox) | card | ✅ |
| Budget CRUD | `budgetRepositoryProvider` (+outbox) | budget | ✅ |
| Goal CRUD + contribution | `goalRepositoryProvider` (+outbox) | goal, goal_contribution | ✅ |
| Plan CRUD + transaction link | `planRepositoryProvider` (+outbox) | plan, plan_transaction_link | ✅ |
| Subscription + bill payment | `billRepositoryProvider` (+outbox) | subscription, bill_payment | ✅ |
| Category CRUD | `categoryRepositoryProvider` (+outbox) | category | ✅ |
| Settings change | `userSettingsRepositoryProvider` (+outbox) | settings | ✅ |

## Non-UI writes — bypasses 🔴

| # | Path | File / line | Entities | Enqueues? |
|---|---|---|---|---|
| B1 | SMS capture (relay) | `app_providers.dart:740` → `CaptureSyncService(DriftTransactionRepository(db))` | transaction | ❌ |
| B2 | SMS capture (native/background) | `captured_message_processor.dart:108` → `AddTransactionUseCase(DriftTransactionRepository(db))` | transaction | ❌ |
| B3 | Capture auto-account | `captured_message_processor.dart:147` → `DriftAccountRepository(db)` | account | ❌ |
| B4 | Capture auto-card | `captured_message_processor.dart:246` → `DriftCardRepository(db).create` | card | ❌ |
| B5 | Bootstrap card backfill | `bootstrap_runner.dart:176` → `DriftCardRepository(database).backfillFromTransactions()` | card | ❌ |
| B6 | Goal auto-save (bootstrap) | `bootstrap_runner.dart:161` → `RunGoalAutoSavesUseCase(DriftGoalRepository(database))` writes `addContribution` + `save` | goal, goal_contribution | ❌ |
| B7 | Default account (DB migration) | `app_database.dart:1496` `INSERT INTO accounts(...)` | account | ❌ (never through a repo) |

## Correct by design — do NOT enqueue ✅

| Path | Why |
|---|---|
| Pull import — `ledger_sync_service.dart:756` `DriftTransactionRepository(db)` (no outbox) | Data already came from server; enqueuing would re-push (loop). Sets `server_id` + `sync_status='synced'` directly. |
| Planning pull import (no outbox) | Same. |
| Smart Inbox (`DriftSmartInboxRepository`) | Server-authored; has its own `SmartInboxSyncService` (pull + status push). |
| Restore (`backup_service.dart`) | Already runs the backfill services (direct idempotent push). |
| Read-only helpers (`getCardAccountBreakdown`, `checkBudgetAlert`, category name lookups) | No writes. |

## Root cause of the empty server

The app's primary data source is **SMS capture (B1/B2)**, plus its side effects
(B3/B4). None enqueue. The default account (B7) and any pre-outbox data were
never enqueued either. The outbox therefore stays empty → push sends nothing →
Supabase stays empty. (See `docs/FORENSIC_AUDIT.md` C1/C2.)

## Completion plan

1. **Enqueue-at-write for live capture paths (B1–B4).** Thread the ledger +
   planning outbox queues into the repositories used by `CaptureSyncService`
   and `CapturedMessageProcessor` (transaction, auto-account, auto-card). New
   captures then sync immediately, exactly like manual adds. Queues gate on
   auth internally, so guests stay local-only.
2. **Enqueue-at-write for bootstrap writers (B5/B6).** Pass the queues to the
   card-backfill and goal-auto-save repos in `bootstrap_runner.dart`.
3. **One idempotent startup reconcile/backfill for existing + missed data
   (B7 + legacy + any capture that occurred with no active session).** Reuse
   the existing `AccountsBackfillService → TransactionsBackfillService →
   PlanningPrimaryBackfillService` chain (ordered, verified, ownership-checked,
   idempotent by `local_id` / `client_request_id`). Run once after a valid
   session, guarded so it is cheap when everything is already synced.
4. **Prove it** with a synchronization graph (every source → Supabase) and
   re-run the gates (`flutter analyze`, `flutter test`).
