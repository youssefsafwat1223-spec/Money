# Mali — Forensic Engineering Audit

**Reviewer role:** external principal engineer, production-readiness review.
**Scope:** offline-first sync architecture, runtime data paths, integrity, sync
correctness, performance, security, UX, production readiness.
**Method:** static code trace of the sync spine end-to-end, cross-checked
against the live production Supabase (read-only, service_role) for user
`970c7f60-7be1-49d4-aee3-55baa1cf257d`.
**Date:** 2026-07-23

---

## Headline

The offline-first migration built a complete outbox → push → pull → Drift
pipeline, but the application's **primary data source — SMS capture — writes
around it.** Combined with the absence of any startup backfill, the result is
that **Supabase is empty (verified: 0 rows in every `user_*` table, for this
user and across all users), and effectively nothing a real user creates ever
leaves the device.** The sync layer is wired, gated on, and dormant.

The architecture is not "Supabase = source of truth, Drift = cache." In
practice it is "Drift = only truth, Supabase = empty," with a correct-looking
sync engine that has no inputs. Backup/restore, multi-device, and reinstall
therefore mean **total data loss** for real users today.

Confidence in the headline: **97%** (code-certain on the mechanism; the empty
server is directly observed).

---

## Coverage & honesty note

I traced the sync spine exhaustively (bootstrap, DI wiring, outbox queues, push
services, pull services, sync engines, app-shell orchestration, capture path,
wipe). I **sampled** data integrity, performance, security, and UX rather than
exhaustively auditing every migration, every screen, every RLS policy, and the
edge functions. Findings below carry per-item confidence. Absence of a finding
in a sampled area is not proof of correctness there.

---

# 🔴 CRITICAL

## C1 — SMS-captured transactions never enter the outbox → never reach Supabase

**Root cause.** The capture ingestion services are constructed with an
**outbox-less** repository:

- `lib/core/di/app_providers.dart:737-749` — `captureSyncServiceProvider` builds
  `CaptureSyncService(transactionRepository: DriftTransactionRepository(db), …
  isSupabasePrimaryEnabled: () => false)`. No `outboxQueue`, and **no**
  `directTransactionRepository` is passed.
- `lib/features/capture/services/capture_sync_service.dart:354-360` — with
  `supabasePrimaryMode == false` and `_directTransactionRepository == null`,
  every capture is saved via `_transactionRepository.saveTransaction(...)` on
  the outbox-less repo → row lands in Drift with **no `ledger_sync_outbox`
  row**.
- `lib/features/capture/services/captured_message_processor.dart:72,108,270` —
  same bare `DriftTransactionRepository(db)`.
- `LedgerPushService.push()` drains `ledger_sync_outbox`
  (`ledger_push_service.dart:61`). Empty queue → pushes nothing.

The code comments actively assert the opposite of what happens:
`ledger_outbox_queue.dart:184-187` and `capture_sync_service.dart:746-747` both
claim relay captures "land in Drift first, then the normal ledger outbox
publishes them in the background." They never enqueue, so the background publish
never occurs. Both intended push paths (client outbox, and the edge-function
`capture_direct_supabase_write` direct-write referenced at
`capture_sync_service.dart:118-120`) are inactive.

**Affected files:** `capture_sync_service.dart`, `captured_message_processor.dart`,
`app_providers.dart` (DI), `ledger_outbox_queue.dart` (misleading comment).
**Affected entities:** Transactions (and everything derived: dashboard, reports,
budgets, goals progress, plans).
**Impact:** No cloud copy of the user's transactions. No multi-device. Reinstall
/ device loss = permanent data loss. Backup captures only what a *manual* add
produced.
**Reproducibility:** 100% — deterministic; observed empty server.
**Confidence:** 98%.
**Proposed fix:** Wire `ledgerOutboxQueueProvider` into the `DriftTransactionRepository`
used by `captureSyncServiceProvider` (and the processor path), so captures
enqueue like manual adds. Verify a captured txn produces a `ledger_sync_outbox`
row and pushes. Delete/repair the misleading comments.
**Complexity:** Low for the DI wiring (a few lines); Medium to test the full
capture→push→pull round-trip and confirm no double-write with the edge path.

## C2 — No startup/first-sign-in backfill; pre-existing local data is stranded

**Root cause.** The three backfill services that enqueue existing local rows —
`AccountsBackfillService`, `TransactionsBackfillService`,
`PlanningPrimaryBackfillService` — are invoked **only** from
`lib/core/backup/backup_service.dart:135-146`. Nothing calls them at bootstrap
or on sign-in (`bootstrap_runner.dart` has no such step; `app_shell` sync only
drains the outbox). The outbox is populated **only** by new writes going through
a queue-wired repo. Therefore any row created:
- before the outbox wiring existed, or
- outside a repo (e.g. the **default account**, created by a SQL migration
  backfill, not through `DriftAccountRepository`),

never gets an outbox row and never syncs. This is why `user_accounts = 0` even
though accounts sync is enabled and always-on.

**Affected files:** `bootstrap_runner.dart` (missing step), `backup_service.dart`
(only caller), the three backfill services.
**Affected entities:** All (accounts, transactions, budgets, goals, plans,
subscriptions, cards, categories, settings).
**Impact:** Existing installs never converge to the server even after C1 is
fixed — the fix only captures *future* writes. A one-time enqueue of the current
local state is required for real users to ever back up.
**Reproducibility:** 100%.
**Confidence:** 95%.
**Proposed fix:** Run the backfill/enqueue pass once per install after a valid
session is established (idempotent; guarded by a persisted "backfilled" flag),
not only inside backup. Reuse the existing services.
**Complexity:** Medium (ordering: accounts before transactions before children;
must be idempotent and not block startup).

## C3 — Transaction pull drops category and several fields

**Root cause.** `lib/features/capture/services/ledger_sync_service.dart:274-296`
(`_rowToEntity`) constructs the imported `TransactionEntity` with **no category**
(and the subsequent `saveTransaction(..., categoryKey: null)` at line 201/…),
and omits `direction`, `balance_after`, `note/description`, `card_last4`, and any
foreign amount/currency present on the server row.

**Affected files:** `ledger_sync_service.dart`.
**Affected entities:** Transactions (category, and derived budgets/reports).
**Impact:** On any real multi-device pull, imported transactions arrive
uncategorized ("غير مصنف") and lossy → wrong category reports and budget math on
the second device. Latent today only because nothing is on the server to pull
(C1/C2); becomes user-visible the moment sync works.
**Reproducibility:** 100% once server has rows.
**Confidence:** 95%.
**Proposed fix:** Map `category_id` → local category (by server id/key), plus
`direction`, note, and card fields, in `_rowToEntity` and the save call.
**Complexity:** Low–Medium (needs server→local category id resolution).

---

# 🟠 HIGH

## H1 — Plan↔transaction explicit links are never pulled

**Root cause.** `planning_pull_service.dart` `_insertPlan`/`_updatePlan`
(around 627-664) map a plan's `account_ids` and `card_last4s` (implicit
matching) but never pull `user_plan_transaction_links` into the local
`plan_transaction_links` table. The push side backfills them
(`planning_primary_backfill_service.dart:_backfillPlanLinks`), so it is a
pull-only gap.
**Affected entities:** Plans.
**Impact:** A plan's explicitly linked transactions do not appear on another
device / after restore. (This is the user's reported bug #2.)
**Reproducibility:** 100% once plans+links exist server-side.
**Confidence:** 90%.
**Proposed fix:** Add a `user_plan_transaction_links` pull that repopulates
`plan_transaction_links` keyed by resolved local plan id + transaction id.
**Complexity:** Medium.

## H2 — Unconditional 30-second full-sync timer (battery / data / server load / flicker)

**Root cause.** `app_shell.dart:130-133` `Timer.periodic(30s)` calls
`_runLedgerSync`, which runs planning push+pull, ledger push+pull, smart-inbox
push+pull, planning children, and gamification sync **every 30 seconds while
foregrounded**, regardless of whether anything changed. `fetchActiveRows()`
(pull) appears to fetch all active rows each cycle (no incremental cursor seen).
Each cycle writes to Drift → ticks `dbRevisionProvider` → rebuild churn (the
user's reported "flicker" bug #3).
**Affected entities:** All; performance-wide.
**Impact:** At 100k users this is continuous background pull traffic and device
battery drain even when idle; locally it causes periodic UI rebuilds.
**Reproducibility:** 100%.
**Confidence:** 88%.
**Proposed fix:** Drive sync from the `SyncWakeup` debounce (already present for
writes) plus a much longer safety poll (e.g. 5–15 min) and/or an incremental
`updated_at` cursor for pulls; skip pull when nothing is pending and no
inbound-change signal exists.
**Complexity:** Medium.

## H3 — `type='unknown'` transactions are silently excluded from all totals

**Root cause.** `drift_transaction_repository.dart` `expenseTotalBetween` /
`incomeTotalBetween` filter on specific `type` values (`payment`,`withdrawal` /
`income`). Any row with `type='unknown'` (parser could not classify) is dropped
from dashboard and budget aggregates with no indication.
**Affected entities:** Transactions → Dashboard, Budgets, Reports.
**Impact:** The dashboard "doesn't sum" some transactions (user's reported bug
#4). Silent under-counting of spend.
**Reproducibility:** Deterministic for any unknown-type row.
**Confidence:** 88%.
**Proposed fix:** Decide policy for `unknown` (surface as "uncategorized spend"
or force classification at capture) and make aggregation explicit about it.
**Complexity:** Low–Medium.

---

# 🟡 MEDIUM

## M1 — Card auto-backfill bypasses the outbox
`bootstrap_runner.dart:176` runs `DriftCardRepository(database).backfillFromTransactions()`
with a bare repo (no outbox). Auto-created cards never enqueue → never sync
(same class of defect as C1/C2, smaller blast radius). Card creation via the UI
provider was **not** verified in this pass. **Confidence:** 75%. Fix: pass the
planning outbox queue; verify the card UI provider wires it too. Complexity: Low.

## M2 — Misleading comments assert behavior the code does not perform
`ledger_outbox_queue.dart:184-187` and `capture_sync_service.dart:746-747`
document a background outbox publish for captures that never happens. This is a
maintenance trap: a future engineer will "confirm" sync works by reading the
comment. **Confidence:** 100%. Fix: correct or delete. Complexity: trivial.

## M3 — Per-item server round-trip on ledger update (N+1)
`ledger_push_service.dart:237-249` (`_findServerId`) and the update conflict
check issue one Supabase query per outbox item when `server_id` is unknown.
Fine at low volume; grows linearly with a large backlog (e.g. first backfill of
an existing install — see C2). **Confidence:** 85%. Fix: batch by
`client_request_id`, or rely on the idempotent upsert and skip the pre-check.
Complexity: Medium.

## M4 — Pull has no pagination / incremental cursor
`fetchActiveRows()` / `fetchTombstones()` appear to fetch the full active set
each cycle. Combined with H2's 30s cadence, a heavy user re-pulls their entire
ledger every 30s. **Confidence:** 75% (did not read the fetch SQL in full). Fix:
`updated_at > cursor` incremental pull + page size. Complexity: Medium.

---

# 🟢 LOW / POSITIVE

- **L1 (flicker mechanism).** `dbRevisionProvider` debounces (300ms quiet / 2s
  max) but the 30s sync re-writes "synced" metadata each cycle, ticking the
  revision even when nothing user-visible changed → periodic rebuilds. Downstream
  of H2. Confidence 80%.
- **L2 (payload-import markers).** Capture import markers appear to live in
  `dedup_hashes` (wiped on logout). Worth confirming there is no separate
  un-wiped `payload_imports` table. Confidence 60%.

**Verified-good (challenge passed):**
- **Logout/multi-user isolation is solid** — `DataWipeService._tables`
  (`data_wipe_service.dart:21-46`) clears both outboxes, dedup, capture markers,
  and all financial tables, plus custom/synced categories; reseeds singletons.
  No cross-user leakage on shared device.
- **No `service_role` key anywhere in `lib/`** (grep clean). Client uses anon key
  only; RLS is the boundary.
- **Pull idempotency is correct** — `_findLocalId` matches by `server_id` then
  payload hash before inserting, and sets `server_id` on import, so repeated
  pulls do not duplicate. (My initial "repeated pull duplicates" hypothesis was
  tested and **rejected**.)
- **Conflict guard exists** — `sync_status='conflict'` blocks the server from
  overwriting a locally-pending edit on both ledger and accounts paths.

---

## Priority order for remediation

1. **C1** — make captures enqueue (restores the entire premise of the app).
2. **C2** — one-time backfill/enqueue of existing local state (so current users
   converge, not just future writes).
3. **C3 + H1** — fix pull mapping (category/fields) and plan-link pull *before*
   turning on real multi-device, or the first cross-device sync corrupts data.
4. **H2/M4** — replace the 30s full-sync with wakeup-driven + incremental pull
   (fixes flicker, battery, and 100k-scale server load together).
5. **H3, M1, M2, M3** — hardening.

C1+C2 are the difference between "offline-first app with cloud backup" and
"local-only app with a dormant sync engine." Everything else is downstream.
