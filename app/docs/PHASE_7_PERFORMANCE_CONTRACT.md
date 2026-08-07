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

## 3. MALI-029 — pull batching (PARTIAL — 2 services measured + fixed)

Only **production-reachable** services (invoked by `_runLedgerSyncBody` or bootstrap)
are in scope; dormant/legacy paths are deferred to Batch-3/MALI-034, not optimized.

**Done ✓ (measured):**
- `CaptureSyncService` — reloaded the ENTIRE accounts table per captured row; now
  prefetched ONCE per run (first-match-per-currency, create-on-miss preserves
  `isDefault`/`sortOrder`). Proven: 8 captures / 2 currencies → **1** accounts read.
- `LedgerSyncService.pull()` — resolved local account (`server_id→id` + existence) and
  category (`key→id`) with a SELECT PER ROW; now primed ONCE per pull into snapshot maps
  (a ledger pull only writes transactions and runs single-flight after the accounts
  pull, so the snapshot is valid for every page; null-cache fallback preserved). Proven:
  25 rows sharing one account → accounts read **once** (was ~25). All CAS/tombstone/
  conflict/flicker-guard semantics preserved (17 existing tests green).

**Known repo-layer redundancy (documented, not yet fixed):** the shared
`DriftTransactionRepository.saveTransaction` re-resolves the category key per insert
(`_categoryIdByKey`, with type-based normalization). LedgerSync passes the resolved
ACCOUNT id (so accounts are bounded) but the KEY for categories; bounding this needs a
repo API change (shared by many callers) — deferred, not changed at the service layer.

**Remaining production-reachable (audited, not yet done):** SenderBankMapping
one-row-at-a-time upsert (sink already takes a List; per-row error isolation is a
tradeoff to preserve), PlanningPull `_ensureMerchant`/category per row, accounts/planning
pull per-row lookups, planning-child pulls. Each to be measured + fixed with query-count
tests at 100/1k/mixed/idempotent before claiming done.

## 4. Background-work cadence (DONE ✓)

The fixed 30s `Timer.periodic` is replaced by a self-rescheduling **adaptive** poll:
`SyncCadence` (pure, unit-tested — `lib/features/app/sync_cadence.dart`) widens the
interval on consecutive idle polls (30s → ×2 → up to a 5-min cap) and resets to base on
local activity (`SyncWakeup`), app resume, or a user trigger — so an idle/offline app
stops polling (and burning per-item outbox retries) every 30s. `SyncCoalescer` turns
overlapping run requests into at most ONE pending follow-up (the old re-entry guard
DROPPED them). 7 deterministic tests (`sync_cadence_test.dart`). Sync AUTHORITY,
ordering and conflict semantics unchanged; server revision CAS stays OFF. **Remaining:**
true reachability-based offline detection (would need a connectivity source) and skipping
the full fan-out when no cursor/domain changed — the adaptive backoff approximates both.

## 5. MALI-030 — report / export / backup memory (DONE ✓, v3 residual characterized)

Every avoidable full-dataset materialization is removed or hard-capped; the only
remaining one-shot buffer is the v3 AEAD residual, characterized below.

| path | before | after |
|---|---|---|
| report `_largestTransactions` | `getAll()` whole table → Dart sort → take 10 | `largestExpenses(...)` SQL `ORDER BY amount DESC LIMIT N` — only N rows enter Dart |
| report `_appendixFor` | `getAll()` whole table → Dart filter/sort | keyset pages (`confirmedInRangePage`, 500/page) + hard cap `_appendixMaxRows`=5000 |
| report headline / category / merchant / daily | already canonical SQL aggregates | unchanged |
| CSV `exportTransactionsCsv` | `.get()` whole table → one row list | keyset pages (1000/page), per-page CSV chunk appended + released |
| full export `exportFinancialPackage` | `.get()` every table; codec RE-DECODES each CSV to count | transactions table paged; precomputed `rowCounts` passed (no re-decode) |
| `backup_snapshot_builder.build()` | `.get()` every table + `Map.from(row.data)` (2 full copies) | transactions paged (2000/page) + `row.data` taken directly (1 copy) |

**Structural results (10k synthetic):** top-N returns exactly N (not 10k); appendix/
CSV/backup transactions read in bounded pages (≤ page size each), every row emitted
exactly once, stable order preserved; export/import + backup/restore round-trips
unchanged. Retained transaction DOMAIN objects are bounded per page; the final CSV/zip/
snapshot bytes are each artefact's own output contract, not extra retained models.

**Resource caps (typed, fail-safe — no OOM, no partial write, no DB mutation, no temp
files):** appendix ≤ 5000 rows; snapshot/CSV/export paged; **`BackupEnvelopeLimits.
maxPlaintextBytes` = 48 MiB enforced BEFORE encryption** → typed
`BackupEnvelopeErrorKind.payloadTooLarge`; existing 64 MiB ciphertext / 96 MiB envelope
caps retained.

### B2-B closure — corrected memory-lifetime accounting

The earlier "1 copy" note was about avoiding a `Map.from` double-copy INSIDE `build()`;
it did NOT bound total generation memory, because the production path was
`build()` (whole snapshot Map) → `jsonEncode` (whole JSON String) → `utf8.encode`
(plaintext) → encrypt — **all four coexisting** for a 10k backup. Corrected:

**Production backup path (streaming — `buildEncryptedPlaintext` → encrypt-from-bytes):**

```
DB page (≤2000 rows)          ← released after each page is serialized
  → jsonEncode per row/table  ← small, transient
  → utf8 bytes appended to BytesBuilder (size-capped as it grows)
  → [whole plaintext bytes]   ← the ONE unavoidable full buffer (AES-GCM is one-shot)
  → AesGcm.encrypt            ← plaintext + ciphertext (+16B MAC) coexist here only
  → ciphertext → v3 envelope base64/JSON → toBytes() (once)
  → publish(immutable blob)   ← sha256/size over existing bytes, no clone
```

**Simultaneously alive for a 10,000-row backup (after closure):** one DB page + the
growing/whole plaintext byte buffer + (at the encrypt call) its ciphertext. There is
**NO** longer a complete snapshot object graph AND a whole JSON String alive alongside
the plaintext — proven byte-identical to `utf8.encode(jsonEncode(build()))` yet built
without them. The plaintext cap is enforced **during** accumulation (before a large
buffer exists) → typed `payloadTooLarge`, never OOM. Pure in-memory (no plaintext to
disk); v3 wire/auth unchanged; the legacy pre-v3 path still builds the object snapshot
lazily (old installs only).

**v3 one-shot residual (irreducible, NOT device-external):** exactly ONE full plaintext
buffer + its ciphertext (+16-byte MAC) at the single `AesGcm.encrypt` call —
`package:cryptography` has no streaming API (streaming needs a new envelope = out of
scope: no v4). Bounded by 48 MiB plaintext / 64 MiB ciphertext caps.

**Full-data export (Blocker 4):** the transactions table is CSV-paged (bounded row
objects); other tables are small bounded catalogs. The zip archive inherently needs all
per-table CSV byte arrays present to encode the final package — that multi-CSV + archive
+ zip coexistence is a **zip-format constraint** on the final artefact, not extra
retained domain objects. Enforced total bound: the envelope/blob caps.

**Remote upload handoff (Blocker 5 — audited, application code clean):** `publish` takes
the immutable `Uint8List`; `sha256Hex(blob)` hashes the existing bytes (no clone);
byte-count uses `.length`; `putObject(blob)` passes by reference; retry reuses the same
blob (no per-attempt clone); `toBytes()` runs once. Only Supabase's client may copy
internally — a library boundary, not application-controlled.

**Status:** *MALI-030 code complete — locally verified for bounded report/export/
snapshot database processing; the v3 authenticated encryption remains a bounded one-shot
in-memory operation under enforced payload caps.* The only dataset-sized application
buffers are those inherent to the serialized v3 plaintext/ciphertext and the final
export zip — no complete snapshot object graph + whole JSON String remain alongside the
plaintext. Native heap/profile numbers stay external.

## 6. Transaction-list / dashboard rendering (NOT yet done)

**Done ✓:** search is now **debounced** (250ms) — a keystroke burst no longer re-fetches
page 1 + re-filters + re-groups on every character (compile-verified; a widget-level
rapid-search test is an outstanding follow-up as the field is private).

**Remaining (audited, not yet done):** move day-grouping + brand-mark resolution
(~228-entry scans/row) out of `build()` (cached per-tx); push the date/account filter
into `getPage` (uses the new `idx_transactions_account_occurred`) so a narrow filter
stops paging the whole table client-side; replace the two dashboard `getAll()` folds
with bounded/SQL queries; rebuild-count + pagination tests. Formatting is already
memoized. No visual redesign; Phase-4 totals unchanged.

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
