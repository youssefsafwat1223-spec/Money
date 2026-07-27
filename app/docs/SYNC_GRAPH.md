# Synchronization Graph — every user-data source reaches Supabase

Status after completing the sync architecture. Gates: `flutter analyze` clean,
`flutter test` 789 passing (+8 new reconcile tests).

## The two ways any local row reaches the server

```
                       ┌─────────────────────── WRITE PATHS ───────────────────────┐
                       │                                                            │
  Manual UI add ───────┤                                                            │
  SMS capture (relay) ─┤   Repo.write ──► Drift row ──► Outbox enqueue ──►┐         │
  SMS capture (native)─┤   (queue is auth-gated:                           │         │
  Auto-account ────────┤    guest → local-only,                           │         │
  Auto-card ───────────┤    signed-in → enqueues)                         │         │
  Goal auto-save ──────┤                                                   │         │
  Bootstrap card backfill                                                  │         │
                       │                                                   ▼         │
                       │                                          ledger_sync_outbox │
                       │                                          planning_sync_outbox
                       │                                                   │         │
                       │                          app_shell sync cycle ──► Push ──► Supabase
                       │                          (startup / resume /       (idempotent upsert
                       │                           wakeup / 30s)              on user_id,local_id
                       │                                                      / client_request_id)
                       │                                                            │
  Pre-outbox data ─────┤   ┌── STARTUP RECONCILE (one-shot per session, guarded) ──┐│
  Default account (B7) ┤   │  hasUnsyncedLocalData()?  (server_id IS NULL &&        ││
  No-session capture ──┤   │     not already on the outbox)                         ││
                       │   │        │ yes                                           ││
                       │   │        ▼                                               ││
                       │   │  AccountsBackfill ─► TransactionsBackfill ─► Supabase  ││
                       │   │  (idempotent direct upsert, ordered, ownership-checked)││
                       │   └────────────────────────────────────────────────────────┘│
                       └────────────────────────────────────────────────────────────┘
                                                   │
                                                   ▼
                              Supabase (source of truth) ──► Pull ──► Drift ──► UI
```

## Per-source proof

| Source | Entity | Reaches Supabase via | Enqueues now? | Evidence |
|---|---|---|---|---|
| Manual add/edit (UI) | transaction | outbox push | ✅ (always did) | `transactionRepositoryProvider` |
| Account/budget/goal/plan/bill/category/settings (UI) | those | outbox push | ✅ (always did) | entity repo providers |
| Goal contribution / plan link / bill payment (UI) | children | outbox push | ✅ (always did) | goal/plan/bill repo providers |
| **SMS capture — relay** | transaction | outbox push | ✅ **fixed** | `captureSyncServiceProvider` now wires `ledgerOutboxQueueProvider` |
| **SMS capture — native/background** | transaction | outbox push | ✅ **fixed** | `captured_message_processor.dart` builds queues via `outbox_queue_factory` |
| **Capture auto-account** | account | outbox push | ✅ **fixed** | `AddTransactionUseCase` account repo now wired |
| **Capture auto-card** | card | outbox push | ✅ **fixed** | `_autoDetectCard` card repo now wired |
| **Bootstrap card backfill** | card | outbox push | ✅ **fixed** | `bootstrap_runner.dart:176` wired |
| **Goal auto-save (bootstrap)** | goal + contribution | outbox push | ✅ **fixed** | `bootstrap_runner.dart:161` wired |
| **Default account (DB migration)** | account | startup reconcile | ✅ **fixed** | `StartupSyncReconcileService` → AccountsBackfill |
| **Pre-outbox legacy rows** | account, transaction | startup reconcile | ✅ **fixed** | reconcile guard catches `server_id IS NULL` |
| **Background capture with no session** | account, transaction | startup reconcile (next launch) | ✅ **fixed** | guard is `server_id IS NULL && not queued` |
| Import / Restore | all | backfill services (already) | ✅ | `backup_service.dart` |
| Pull import (server→local) | all | n/a — does NOT re-enqueue | ✅ correct | outbox-less repos by design |
| Smart Inbox | smart_inbox | own `SmartInboxSyncService` | ✅ correct | server-authored |

## Why there are no duplicates between the two paths

- **Accounts / planning parents:** both the outbox push and the backfill key on
  `(user_id, local_id)` → the second writer upserts the same row.
- **Transactions:** the outbox keys on `client_request_id = local_id`; the
  backfill keys on `backfill_transaction_<localId>`. To prevent two server rows,
  `TransactionsBackfillService` now **skips any transaction already on the
  ledger outbox** (`WHERE id NOT IN (SELECT transaction_id FROM
  ledger_sync_outbox)`), and the reconcile guard excludes queued rows. The
  outbox owns queued rows; the backfill owns the rest.
- **Planning children** (goal_contributions, bill_payments) are intentionally
  **not** direct-pushed by the reconcile — their write paths already enqueue, so
  they flow through the child outbox only (no `client_request_id` collision).

## Sequence the user asked for

```
Local Drift ─► Backfill (reconcile, idempotent) ─► Supabase ─► rows marked
synced (server_id set, backlog cleared) ─► normal outbox Push/Pull thereafter
```

The reconcile runs at the **start** of the `app_shell` sync cycle, before the
normal push/pull, so back-filled rows are already `sync_status='synced'` when the
pull runs (it won't re-import them) and the outbox push has nothing duplicate to
send. One-shot per session (`_didReconcile`), re-armed on any session change,
and internally guarded to do zero network work once everything is synced/queued.

## Guest / auth safety

Every enqueue and the reconcile are auth-gated (`getAuthUserId() == null →
skip`). A signed-out user's data stays 100% local and never uploads. The
backfill services additionally assert local-data ownership, refusing to upload
if the local rows belong to a different Supabase identity (cross-account leak
guard).

## Residual notes (not blocking)

- Legacy **planning** rows created before the outbox existed (rare; UI-created
  with session) are not direct-pushed by the reconcile to avoid colliding with
  the live child outbox; they sync via their outbox on next edit. A dedicated
  planning enqueue-reconcile is a clean follow-up if a population of such rows is
  found.
- Legacy **cards** without `server_id` are re-derived idempotently from
  transactions and enqueue on the next bootstrap card-backfill.
- If the Edge Function `capture_direct_supabase_write` is ever enabled, align its
  server `client_request_id` with the local id so the outbox push dedupes
  against it (currently OFF, so the outbox is the sole writer).
