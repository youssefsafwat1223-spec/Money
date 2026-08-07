# Phase 7 — Performance Contract (Batch 2)

Structural, machine-measurable performance budgets for query/provider/startup/
rendering/reporting/background work. Batch 2 targets MALI-029, MALI-030, MALI-073n
and the perf/startup portion of MALI-038. **No financial semantics, precision,
currency, refund, half-open-period, or restore behavior changes in this batch.**

Budgets are **structural** (query counts, rebuild counts, rows retained, packaged
bytes, algorithmic shape) — NOT wall-clock. Wall-clock/profile numbers are device
verification and stay external (they must not gate CI from a busy dev machine).

## 0. Baseline harness

`test/performance/perf_harness.dart` — deterministic NON-FINANCIAL fixtures at
100/1k/10k rows, a Drift `QueryInterceptor` (`StatementCounter`) counting SQL by
kind (a batched write = ONE round-trip regardless of row count), and an
`EXPLAIN QUERY PLAN` helper. No real user data is ever used.

## 1. MALI-073n — hot-path indexes (DONE ✓)

Evidence-backed by real `EXPLAIN QUERY PLAN` (`test/performance/query_plan_test.dart`):

| query | plan BEFORE | plan AFTER |
|---|---|---|
| `account_id = ? ORDER BY occurred_at DESC` | `SCAN transactions USING INDEX idx_transactions_occurred_at` (full index scan, filter in scan) | `SEARCH transactions USING INDEX idx_transactions_account_occurred (account_id=?)` |
| `... occurred_at >= ? < ? AND account_id = ?` | `SEARCH ... idx_transactions_occurred_at (range)` | `SEARCH ... idx_transactions_account_occurred (account_id=? AND occurred_at>? <?)` |
| `category_id = ?` | `SCAN transactions` (full table) | `SEARCH transactions USING INDEX idx_transactions_category_id (category_id=?)` |

**Indexes added** (in `_runCompatibilityMigrations`, after `account_id` is ensured):
- `idx_transactions_account_occurred (account_id, occurred_at)` — **composite;
  subsumes** a single-column `account_id` index AND serves `WHERE account_id = ?
  ORDER BY occurred_at DESC` (account detail / latest-balance / recent list) without
  a temp-B-tree sort;
- `idx_transactions_category_id (category_id)` — `WHERE category_id = ?` + `GROUP BY
  category_id`.

Additive read accelerators only. **Schema `_targetSchemaVersion` 28 → 29**, version-
owned: created inside the migration transaction; postflight `_verifyMigrationIntegrity`
asserts both exist before the `user_version` bump commits.
`test/performance/schema_v29_migration_test.dart` proves clean install, realistic
v28→v29 upgrade, idempotent reopen (no duplicate), and rollback preserves the previous
schema. No Supabase migration; migrations 0068–0076 remain undeployed.

## 2. MALI-029 — domain-scoped provider invalidation (DONE ✓)

Root cause: `dbRevisionProvider` ticked a single global counter on EVERY write to ANY
table (raw-SQL writes route through a table-less `manualRevisionStream`), rebuilding
all ~30 watcher providers — sync/notification bookkeeping rebuilt the whole financial
UI (the documented "flicker").

**Mechanism** — `AppDatabase.tableWriteStream` emits the TARGET table of each data
write (`targetTableOf`: the identifier after INTO/UPDATE/FROM — the one table a single-
table DML unambiguously targets). Two revision providers filter it, coalesced
(300ms quiet / 2s max, matching the global provider):

| provider | domain | consumers |
|---|---|---|
| `scopedRevisionProvider(kReportsRevisionTables)` | `categories, transactions` | reports |
| `scopedRevisionProvider(kBudgetsRevisionTables)` | `budgets, categories, transactions` | budgets |
| `scopedRevisionProvider(kTransactionsRevisionTables)` | `accounts, categories, transactions` | transaction list |
| `financialRevisionProvider` | **any table EXCEPT** `kOperationalOnlyTables` | dashboard |

Domain sets **include display dependencies** (e.g. `categories` so a category rename
still refreshes transaction rows) — providers never go stale. `financialRevisionProvider`
uses **exclusion, not enumeration**: a new financial table is auto-included; only
confirmed-operational writes (notification_log_events, ledger/planning outboxes, sync
cursors, engagement outbox, remote catalog mirrors, dedup/restore journals,
sender-mappings, smart-inbox, suspected-duplicates) are filtered out. Gamification
DISPLAY aggregates (achievements/streaks/xp_levels) are intentionally NOT excluded.

**Budgets proven** (`test/performance/scoped_invalidation_test.dart`):
- unrelated-table write → **0** rebuilds of a scoped provider;
- relevant / display-dependency write → **exactly 1**;
- 100-write burst → **≤ 2** (coalesced), never 100;
- purely-operational writes → **0** financial rebuilds.

Non-migrated providers keep the global `dbRevisionProvider` (unchanged; the safe
default). The cross-connection reconcile path (background notification actions) is
untouched.

## 3. MALI-029 — pull batching (PARTIAL)

**Done ✓** — `CaptureSyncService` reloaded the ENTIRE accounts table
(`repository.getAll()`) for EVERY captured row. Now prefetched ONCE per run into a
first-match-per-currency map (create-on-miss preserves exact `isDefault`/`sortOrder`);
run-scoped, cleared on completion; single-flight guarded. Proven: 8 captures across 2
currencies read the accounts table **once**
(`test/features/capture/capture_sync_service_test.dart`).

**Budget (target for remaining services):** for an N-row pull/import, query count
grows by BATCHES, not linearly (`WHERE id IN (...)` chunked prefetch, batched upserts
in bounded transactions, one revision emission per committed batch), preserving every
Phase-3 invariant (cursor-in-txn, per-row CAS, conflict marking, tombstones,
idempotency keys, dead-letter/backoff, parked rows, ownership, flicker guards).

**Remaining (not yet done):** LedgerSyncService (~5–6 SQL/row), SenderBankMapping
one-row-at-a-time upsert (the sink already takes a List), PlanningPull `_ensureMerchant`
per subscription row, the backfills, accounts/planning pull per-row lookups. Query-count
tests at 100/1k/mixed/child/idempotent sizes to be added with each.

## 4. Background-work cadence (NOT yet done)

Current: fixed 30s `Timer.periodic`; a 750ms event debounce; a re-entry guard exists.
No offline pause, no adaptive backoff after empty syncs, ~15–18 "anything-new?" round-
trips per idle tick, and offline burns per-item retry budget toward dead-letter.
**Target:** pause honestly when offline (do not consume retry attempts), bounded
adaptive delay after empty syncs, skip a full snapshot when no cursor/domain changed,
coarse secret-free instrumentation (trigger reason / batch count / duration bucket /
retry class). Sync AUTHORITY is not redesigned.

## 5. MALI-030 — report / export / backup memory (NOT yet done)

Audited hotspots (all materialize the entire transaction set in Dart):
`report_snapshot_builder.dart` `_largestTransactions` (loads the whole table to take
the top 10 — should be `ORDER BY amount DESC LIMIT 10` in SQL) and `_appendixFor`
(details-on); both CSV exporters (`drift_financial_exporter.dart`, no streaming; the
package exporter even re-decodes each CSV to count rows); `backup_snapshot_builder.dart`
(all tables/rows into one nested map). Headline totals are ALREADY canonical SQL
aggregates (safe).

**v3 crypto residual (classification):** `encryptEnvelopeV3` is one-shot
`AesGcm.encrypt(utf8.encode(jsonEncode(json)))` — the `cryptography` package's AES-GCM
takes the whole plaintext at once; it cannot stream without a NEW envelope format
(forbidden this batch — no v4). So a bounded but real one-shot plaintext + ciphertext
residual is **unavoidable within v3**, capped by the existing 64 MiB ciphertext /
96 MiB blob limits. This residual is honestly a **crypto-library constraint**, NOT a
device-only concern. **Target:** page the pre/post-encryption reads and eliminate the
duplicate full copies (snapshot map → JSON string → bytes → ciphertext → envelope
bytes = 4–5 copies today) so peak memory is bounded independent of row count APART from
the single unavoidable one-shot crypto buffer; typed `payloadTooLarge` before OOM; never
stage plaintext to disk; never weaken v3 auth.

## 6. Transaction-list / dashboard rendering (NOT yet done)

Audited: the list is virtualized at day-group granularity but grouping + brand-mark
resolution (~228-entry scans/row) run in `build()`; search has no debounce (every
keystroke re-fetches page 1 + re-filters + re-groups); `getPage` ignores the active
filter (500-row all-time paging + Dart filtering); two dashboard providers fold
`getAll()`. Formatting IS already memoized. **Target:** move grouping/brand-resolution
out of `build()` (cached per-tx), debounce search, push the date/account filter into
`getPage` (uses the new `idx_transactions_account_occurred`), replace the `getAll()`
folds with bounded/SQL queries; rebuild-count + pagination tests. No visual redesign;
Phase-4 totals unchanged.

## 7. Startup / resume (NOT yet done)

Stage inventory captured (`bootstrap_runner.dart`): DB open + migrations + repairs +
ownership admission + liveness reaping are REQUIRED (stay on the critical path).
Deferrable-after-first-frame: metrics `app_open`, export-temp sweep, key-ref cleanup,
goal autosaves, card backfill, brand-logo asset scan. `SeedLoader.seedIfEmpty` and
`initFeatureFlagService` run 2–3× on the critical path (coalesce). **Target:** defer the
clearly-non-critical stages and coalesce the duplicates WITHOUT moving any required
safety work after data display; no financial data before ownership admission.

## 8. Font & asset contract

**Assets (DONE ✓):** removed 8.1 MB of unreferenced assets (assets/ 16.7 MB → 8.6 MB);
`test/performance/asset_budget_test.dart` enforces ≤ 1 MiB/file and ~11 MiB total.

**Fonts (PENDING a product decision):** production typography uses
`GoogleFonts.alexandria()` + `GoogleFonts.ibmPlexSans()` with runtime network fetching
ON — so an offline cold start does NOT get the intended fonts (platform fallback). The
bundled TTFs are IBM Plex Sans Arabic (used only by the PDF path); Alexandria is not
bundled and cannot be fetched offline. Options: (A) bundle & switch to the already-
vendored IBM Plex Sans Arabic family + disable runtime fetching — offline-correct but a
visible typeface change; (B) obtain & bundle Alexandria TTFs (files not available in
the repo); (C) defer. `test/core/theme/app_typography_test.dart` pins the current
`GoogleFonts.*` source and will need updating with the chosen option.

## 9. Performance budgets (enforced today)

- no full-table SCAN for the audited account/category hot-path queries (§1);
- scoped-provider rebuilds: unrelated → 0, relevant → exactly 1, 100-write burst → ≤ 2 (§2);
- CaptureSyncService: 1 accounts read per sync run, not per row (§3);
- no single packaged asset > 1 MiB; assets/ total ≤ ~11 MiB (§8).

## 10. Remaining external / device verification

Wall-clock cold/warm startup, dashboard first-usable, list scroll jank, report/export
peak memory, packaged IPA size — all device/profile measurements, external. See
`PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.
