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

## 3. MALI-029 — pull batching (B2-A DONE ✓ — every production-reachable path)

Only **production-reachable** services (invoked by `_runLedgerSyncBody` or bootstrap)
are in scope; dormant/legacy paths are deferred to Batch-3/MALI-034, not optimized.

### Central bounded-ID chunk primitive
`lib/data/db/bounded_lookup.dart` is the single owner of the safe IN-list chunk size
and the chunk/bind contract. **`kSqliteMaxLookupChunk = 500`** — conservative under the
lowest `SQLITE_MAX_VARIABLE_NUMBER` we target (999; no assumption of the raised 32766
limit), >49% headroom for the caller's own owner/cursor bindings, and above the 200-row
page size (so production pages resolve in one chunk while migration/backfill paths that
pass more still chunk safely). `chunkForLookup` (deterministic, dedup-before-chunk,
empty→no query) + `selectByIdChunks`/`lookupRowsById` (one bounded SELECT per chunk,
**bound variables only** — never an interpolated ID list, explicit owner scoping via
trailing bound vars). 15 tests: empty / 1 / 2 / exact boundary / boundary+1 / 1,000+ /
1,001 / duplicates / owner-scoping / no-query-on-empty / chunk-size invariant.

### Query-count evidence (measured; a batched write is one `customStatement`, so the
### SELECT count is the lookup surface)

| Path (single page) | Distinct keys | Before (per row) | After @100 | After @1,000 | Property |
|---|---|---:|---:|---:|---|
| AccountsPull | — (identity) | `_findLocalId` (1–2) + meta (1) ⇒ ~2–3/row | **3** | **5** | O(chunks) |
| PlanningPull subscriptions | 5 merchants | `_findLocalId`+meta+`_ensureMerchant` ⇒ ~4–7/row | **4** | **6** | O(distinct+chunks) |
| PlanningPull budgets | 6 categories | `_findLocalId`+meta+`_localBudgetCategoryId` ⇒ ~3–5/row | **5** | **7** | O(distinct+chunks) |
| PlanningChildSync goal-contribs | 4 goals | `_localId`+`_childLocalId`+`_preservePending` ⇒ ~3/row | **6** | **10** | O(distinct+chunks) |
| saveTransaction category (fast path) | K categories | `_categoryIdByKey` ⇒ 1/row | **0** cat-SELECTs | **0** cat-SELECTs | O(1) — caller pre-resolves |
| CaptureSync accounts (accepted) | per currency | full accounts table/row | 1 read/run | 1 read/run | O(1)/run |
| LedgerSync account/category (accepted) | 1 account | SELECT/row | 1 read/pull | 1 read/pull | O(1)/pull |
| SenderBankMapping (accepted) | — | 1 upsert/row | 1 batched upsert | 1 batched upsert | O(1) + per-row fallback |

10× the rows adds only the extra chunk per bounded lookup (1,000 distinct ids = 2 chunks
at size 500) — never O(rows). Tests: `accounts_pull_query_count_test`,
`planning_pull_query_count_test`, `planning_child_query_count_test`,
`save_transaction_category_boundary_test`.

### Per-service resolution model (all page/batch-scoped — never an instance/static field,
### so a same-UID relogin under a new admission generation can't reuse stale map state)
- **AccountsPull** — two bounded lookups (`server_id IN …`, `id IN …`) build a
  `_AccountIdentityIndex` (server-id-first → local-id, exactly like `_findLocalId`)
  carrying id + sync_status + server_updated_at, kept live on write for duplicate
  local_id safety. `_ensureOneDefaultAccount` runs once per page (was per-tombstone).
- **PlanningPull** — a `_PlanningPageContext` with: identity index (as above);
  merchant resolver (existing-by-id + existing-by-normalized-name prefetched, new
  merchant created once and memoised by normalized name); category resolver
  (key→id + server_id→id maps + one shared 'other' fallback; prefers the canonical
  key — the old `key OR server_id` had undefined precedence). Settings singleton path
  keeps its own lookup (no identity map).
- **PlanningChildSync** — a per-batch `_ChildResolveScope`: parent local ids per parent
  table (`server_id IN …`), child identity + sync_status (`_ChildIndex`), and plan-link
  pending status keyed by the resolved (plan_id, transaction_id) pair. Built in BOTH
  `_pullTable` (page) and `_drainParked` (batch); each parked row still applied in its
  own transaction (isolation). Missing-parent → durable park, terminal after
  `_kParkedChildMaxAttempts` — unchanged.
- **saveTransaction category boundary** — an optional `resolvedCategoryId` on the
  repository interface (Option B: a validated id from a caller that already batch-resolved
  the category). Used directly ONLY when the type does not override the key (income/
  transfer/withdrawal still force their category); fail-closed via the enforced FK
  (`transactions.category_id` → `categories(id)`, PRAGMA foreign_keys=ON — a bogus id
  throws, storing nothing); unknown key still → null category. Bulk callers wired:
  ledger pull (primed key→id snapshot) and CSV import (once-fetched category list).

### Final production-reachable inventory & remaining per-row SQL (classified)
| Service | Reachable | Old lookup | Final lookup | Class |
|---|---|---|---|---|
| AccountsPull | ✓ pull | per-row identity | bounded identity index | **fixed** |
| PlanningPull | ✓ pull | per-row identity + merchant + category | page context | **fixed** |
| PlanningChildSync | ✓ pull | per-row parent + child + pending | batch scope | **fixed** |
| saveTransaction | ✓ import/ledger | `_categoryIdByKey`/insert | resolved id fast path | **fixed** |
| CaptureSync / LedgerSync / SenderBankMapping | ✓ | (accepted earlier) | prefetch/prime/batch | **fixed** |
| accounts_push / planning_push / ledger_push / notification_log / smart_inbox push | ✓ push | 1 local SELECT/item + RPC | unchanged | **intentional — network-bound per-item** (SELECT dwarfed by the RPC round-trip) |
| smart_inbox **pull** self-lookup | ✓ pull | 1 self-row SELECT by server_id/row | unchanged | **intentional — self-row merge** (same accepted pattern as LedgerSync's retained `_findLocalId`; not FK resolution) |
| CSV import `findSuspiciousDuplicate` | ✓ import | 1 fuzzy-dedup SELECT/row | unchanged | **intentional — content-based dedup** (amount/currency/merchant/time window; not FK resolution) |
| gamification / catalog per-row loops | ✓ | 1 SELECT/item | unchanged | **false positive — bounded to fixed catalogs** (O(1)) |
| accounts_backfill / planning_primary_backfill | one-shot | per-row `_serverId` + network | unchanged | **migration-only** (StartupSyncReconcile chain; documented separately) |
| financial_cache_repair | dormant | — | unchanged | **MALI-034** (Supabase-primary/cache-repair architecture; inactive in Drift-only S5) |

**No unexplained active O(rows) FK-resolution lookup loop remains** in any
production-reachable pull/import path. The two remaining active per-row SELECTs
(smart-inbox self-row merge; import fuzzy dedup) are non-FK and intentionally per-item.

## 4. Background-work cadence (DONE ✓)

The fixed 30s `Timer.periodic` is replaced by a self-rescheduling **adaptive** poll:
`SyncCadence` (pure, unit-tested — `lib/features/app/sync_cadence.dart`) widens the
interval on consecutive idle polls (30s → ×2 → up to a 5-min cap) and resets to base on
local activity (`SyncWakeup`), app resume, or a user trigger — so an idle/offline app
stops polling (and burning per-item outbox retries) every 30s. `SyncCoalescer` turns
overlapping run requests into at most ONE pending follow-up (the old re-entry guard
DROPPED them).

**Offline- and ownership-aware gate (B2-A DONE ✓) — `SyncGate` (pure, unit-tested).**
The app has NO platform connectivity source, so offline is inferred from the outbox's own
network-stall signal — `_networkStalledOutbox()` reads whether a financial outbox
(`ledger_sync_outbox`/`planning_sync_outbox`) still holds `status='pending'` rows whose
last `failure_class='transientNetwork'` (a cheap, no-network read the push services
already populate; server 5xx / auth / rate-limit are deliberately NOT treated as offline).
Contract:
- **Offline:** a background/local-activity trigger does NOT run (no doomed remote work, no
  burned outbox retry) and coalesces exactly ONE pending intent; repeated triggers never
  stack. Manual and recovery probes always run.
- **Recovery:** the periodic poll is the sole auto-recovery probe (runs even while
  offline); the first attempt to reach the network flips online — exactly one recovery,
  never one-per-missed-timer. Cold-start/resume are recovery probes; local activity is a
  gated background trigger.
- **Sign-out / ownership:** `invalidate()` bumps the admission generation and drops the
  pending intent; `_handleSessionStatusChange` cancels the old owner's poll timer; a run
  captures its generation and aborts if the owner changed mid-run; a same-UID relogin gets
  a fresh generation, so old scheduled work can never execute under the new owner.

15 deterministic tests (`sync_cadence_test.dart` — cadence, coalescer, and 8 SyncGate
cases). Sync AUTHORITY, ordering, revision and conflict semantics unchanged; server
revision CAS stays OFF. **Residual (out of B2-A scope):** while offline the periodic
recovery probe still runs the full push body (bounded by per-item exponential backoff);
a pull-only probe that fully suppresses offline push retries is a future refinement gated
on a real connectivity source.

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

### Final closure — the two remaining production contracts

**Appendix policy (exact):** ≤ 5000 confirmed in-period rows → complete detailed
appendix. > 5000 → the detailed appendix is OMITTED (never a silent `take(5000)`):
`ReportDataSnapshot.appendixOmittedForSize=true`, `appendixTransactions` empty, and the
rendered PDF emits an explicit **omission page** with a localized notice (Arabic +
English, `ReportStrings.appendixOmittedNotice`) stating the appendix was omitted for
exceeding the 5000-row limit and that summaries/totals still cover the full period. No
transaction values / account / merchant / private IDs in the notice. Accumulation while
detecting overflow is bounded (≤ cap + one page). Proven: 4999/5000 → present;
5001/8000 → omitted; ar + en notice rendered end-to-end.

**Full-data export — its OWN enforced cap (separate lifetime from the backup path):**

```
DB page (≤1000 rows)  ← released per page
  → CSV chunk bytes appended to a BytesBuilder, running total checked vs
    maxExportPackageBytes (100 MiB) AS it grows  → typed DataPortabilityException
    mid-build if exceeded (no partial ExportedFile returned)
  → per-table CSV byte arrays  → Archive → [final ZIP bytes]  ← the zip library's
    one irreducible whole artefact
```

The ZIP export does NOT invoke the backup-envelope caps — it now has its own
`maxExportPackageBytes` = 100 MiB, enforced incrementally in `_pagedSpecCsv` (per page)
and across tables in `exportFinancialPackage`. Over-cap → typed resource-limit error,
no partial file, no DB mutation, no financial content in the message. Proven: 10k
succeeds page-bounded (every row once); over-cap aborts mid-build and returns nothing.

**Irreducible whole buffers (documented separately, none device-only):**
1. bounded v3 plaintext bytes (≤ 48 MiB, one-shot AES-GCM input);
2. bounded AES-GCM ciphertext (≤ 64 MiB);
3. the bounded final ZIP/export artefact (≤ 100 MiB) where the zip library requires it.

**Status:** *MALI-030 code complete — locally verified for bounded report/export/
snapshot database processing; v3 authenticated encryption remains a bounded one-shot
in-memory operation under enforced payload caps.* No complete snapshot object graph +
whole JSON String remain alongside the plaintext; the export has its own enforced cap.
Native heap/profile numbers stay external.

## 6. Transaction-list / dashboard rendering + search (B2-C DONE ✓)

### Keyset pagination + SQL filter push-down
The list previously loaded 500 UNFILTERED rows per page (OFFSET) and applied
account/date/kind/category/search filters in Dart over the accumulated list —
load-then-discard, hasMore reflecting the unfiltered page. Now
`getTransactionPage({limit, after, filter})` pushes EVERY supported filter into SQL
(account · half-open date · kind · category · pending · per-field escaped-LIKE search
over merchant/currency/2-dp-amount/joined category name_ar+key/note) and keyset-pages by
`occurred_at DESC, id DESC` (stable for equal timestamps, uses the v29
`(account_id, occurred_at)` index when an account is active). No OFFSET, no full-history
preload, no Dart discard. The notifier resolves the filter + display context ONCE per
build (all dimensions watched → the keyset cursor resets on any change) and drops an
in-flight `loadMore` page whose generation was superseded (a page for the old filter can
never append to a newer result). The dormant Supabase repo throws (list is Drift-only in
S5). Documented refinement: search matches PER FIELD (was a naive whole-haystack
`String.contains`); SQLite `LOWER` is ASCII-only.
Evidence (`transaction_page_filter_test`): unfiltered/equal-timestamp keyset stability,
each filter + combined, pending-only, ignored-excluded, per-field+escaped search,
empty/partial page, and **10k rows → first page = 50 rows in ONE SELECT** with a
no-overlap next page (never loads the full history).

### Search debounce (production/widget-level)
250ms debounce (accepted core) now proven at the widget level (`TransactionSearchField`
made public): rapid `a→ab→abc` settles to ONE trigger; clear cancels the pending search;
dispose-before-fire writes nothing; slow typing yields each settled term; the notifier
drops a stale in-flight page after a filter change. (`search_debounce_test`).

### Build-time work removed
- **Date-section grouping** moved OUT of `build()`: `TransactionsView` precomputes ordered
  day sections (by local calendar day) once in the provider layer; `build()` formats each
  section's today/yesterday/per-day label once (O(sections)) — was a full O(rows) re-group
  on every rebuild. (`day_grouping_test`.)
- **Brand-mark lookup** was O(rows × catalog): `_resolveSlug`/`logoDevUrlFor`/`hasBrand`/
  `BrandMark.build` scanned the ~200-entry `_merchantDomains` + `_brandSvgs` + asset slugs
  by substring `.contains`, 2–3× per row, recompiling a RegExp each call. The catalogs are
  fixed after startup but matched by substring, so the WHOLE stable resolution is memoised
  per merchant name (`_StableBrand`): first occurrence scans once, every later row is an
  O(1) map hit → **O(distinct merchants × catalog)**; regex precompiled; cache cleared on
  `registerAssetSlugs`. Semantics identical. (`brand_mark_index_test`: repeats → 1 scan,
  distinct → O(distinct), semantics-identical, catalog-refresh invalidation.)

### Rebuild scope
Transaction-screen header total + single-transaction detail now watch
`scopedRevisionProvider(kTransactionsRevisionTables)` and the bills tab watches
`financialRevisionProvider` (exclude-operational) — an operational (sync/notification/
outbox) write no longer recomputes them (the list already was scoped). The dashboard
already used `financialRevisionProvider`. (`scoped_invalidation_test` extended: transactions
domain — operational → 0, transactions/accounts → 1, 100-burst coalesced.)

### getAll() policy + residual classification (B2-C closure)
**Policy:** `getAll()` on the transaction repository may remain ONLY where the result is
naturally bounded by entity cardinality (never ledger-size). **No active whole-ledger
`getAll()` remains on a rendering/provider path.** Bounded primitives added:
`distinctCurrencies()`, `transactionsWithoutAccount({keyset})`, `latestBankCaptureAt()`.

| Path | Was | Now | Class |
|---|---|---|---|
| home "today's expenses" | getAll + sort | bounded `getTransactionPage` (account + half-open today + expense kind) | fixed |
| budgets history line-items | getAll folded per (budget × period) | keyset drain bounded to the UNION of the period windows; per-period canonical filter unchanged | fixed |
| dashboard currency/account bootstrap | getAll (currencies + backfill + 3 pending) | `distinctCurrencies()` + null-account keyset drain (empty post-backfill) + bounded pending query | fixed |
| cards link picker | getAll + Dart search | bounded, debounced, SQL-search page (`pickTransactionsProvider`) | fixed |
| plan-link picker | getAll + `.take(40)` | bounded recent-expenses page (kind in SQL) + Dart filter | fixed |
| bill-details transactions | getAll + `_matchesBill` | bounded recent-expenses page (account+kind) + exact Dart match | fixed |
| capture-health latest capture | getAll + Dart max | `latestBankCaptureAt()` aggregate | fixed |
| `billRepo.getAll()`, `accountRepo.getAll()` | — | unchanged | bounded user catalog (bills/accounts) — kept |
| `AppDataPortabilityService.exportTransactionsCsv` | getAll | unchanged | **export operation**, not a rendering path — loading all IS the payload; memory is MALI-030's (closed) |

Evidence (`provider_large_ledger_test` + the `selectRows` harness): with 10k unrelated old
rows, budgets/dashboard/cards providers return < 2000 ROWS (never ~10k); budgets
current-period list = the in-window rows only.

## 7. Startup / resume (B2-C DONE ✓)

**Startup stage classification** (`bootstrap_runner.dart`).
*Safety-critical — stay blocking:* runtime-config gate, `supabase_init` (SDK),
`session_restore` (identity), `notifications_init` (harvests the cold-start tap),
`database_process_liveness` (advisory lock + reap), `database_open`, `has_local_data`,
`seed_catalog` (first-run seed), LOCAL `feature_flags_init` (the `featureFlags` getter
throws if never initialised), `capture_registration` incl. owner-conflict resolution;
and the owner-sensitive DB mutations (`db_key_ref_cleanup`, `goal_autosaves`,
`card_backfill`, `sender_bank_sync`) stay on the critical path where the owner is already
resolved and no sign-out can interleave.
*Deferred off the first-frame path:* the feature-flag **network override refresh**
(`applyUserOverrides` — the post-frame `syncCatalog` already re-runs it, so the first
frame never blocks on a remote flag fetch), and `export_temp_sweep` (crash-orphan
housekeeping, owner-independent, already deferred on resume). Deferred work is unawaited,
best-effort, and outside the 30s bootstrap timeout — a failure can never fault a usable
local DB.
**`localFinancialUiUsable` milestone** (`app_boot_loader.dart`): flips true the moment the
safety-critical phase completes (DB key/open, liveness, admission/owner-conflict, seed,
local flags) — it does NOT wait for network/backup-metadata/analytics; previous-user
cached data is never shown (the `appDataRestoring` gate). (`startup_deferral_test`.)

**Startup local/remote boundary matrix (B2-C closure).** `localFinancialUiUsable` waits on
NO remote HTTP call except the local owner-conflict check (which prevents cross-owner
exposure — the one kind §12 allows to block):

| Stage | Local / remote | Blocks milestone? | Owner-sensitive? | Failure behaviour |
|---|---|---|---|---|
| runtime-config gate | local | yes | no | throws → startup error |
| `supabase_init` | SDK init: local session restore + **background** refresh (no blocking round-trip) | yes | yes (identity) | throws → startup error |
| `app_open` metric | **remote RPC** | **no — deferred (unawaited)** | no | swallowed (best-effort) |
| `session_restore` | local (secure storage + auth listener) | yes | yes | throws → startup error |
| `notifications_init` | local native channel | yes | no | throws → startup error |
| `database_process_liveness` | local (OS lock + local reap) | yes | yes | throws → startup error |
| `database_open` | local SQLite (SQLCipher) | yes | yes | throws → reset/retry |
| `seed_catalog` | local (seed + asset scan) | yes | no | throws → startup error |
| LOCAL `feature_flags_init` | local (cached flags) | yes | no | throws → startup error |
| owner-conflict resolution | **local** (stored owner vs locally-cached session) | yes | **yes** | throws → startup error |
| feature-flag remote override | remote | **no — post-frame `syncCatalog`** | no | retried post-frame |
| device registration / sender-bank sync | remote | **no — unawaited** | no | retried in background |
| `export_temp_sweep` | local housekeeping | **no — deferred** | no | swallowed |

A genuine safety-critical failure blocks the milestone: the flip is the LAST statement after
the critical phase, so any thrown critical step is surfaced as a startup error and the
milestone is never reached. (`startup_deferral_test`: app_open no-op offline; secure key +
encrypted DB + migrations (`user_version`=29) + owner-scoped query all succeed with NO
network. Full native-channel bootstrap cold-start offline run remains device/external.)

### Search semantic contract (B2-C closure)
Search is per-field escaped `LIKE` with SQLite `LOWER` on BOTH the column and the query
(consistent ASCII fold): ASCII case-insensitive in both directions; Arabic matches exactly
(no case); `%`/`_` are literal (escaped); the term is trimmed. Fields: raw_merchant,
currency, 2-dp amount (`printf`), joined category name_ar + key, note. Documented limit:
`LOWER` is ASCII-only, so a non-ASCII-Latin letter (é/ñ/…) must be typed in its own case
(rare in an Arabic-first app; no FTS/schema change). (`transaction_page_filter_test` parity
matrix.)

**Resume** (`_onResume`). Non-critical idempotent refreshes (catalog, native-capture-state,
export sweep) are coalesced by a pure `ResumeCoalescer` (20s window) so rapid repeated
resumes don't re-run them; sign-out resets it so the new owner's first resume fully
refreshes. Never coalesced: auth revalidation, data reconcile, `_consumeSharedInput` (a
capture may have arrived while backgrounded), the SyncGate-coalesced sync, notification
drain, engagement (each already in-flight-guarded). Migration/DB/admission are
bootstrap-only and do not re-run on resume. (`sync_cadence_test` — ResumeCoalescer.)
**Lifecycle cancellation (§14):** app_shell `dispose` cancels every timer/subscription/
native handler; the search field cancels its debounce on dispose/submit/clear; the cadence
primitives (SyncGate/ResumeCoalescer) hold no timers. No `setState`-after-dispose, no stale
page/search result (generation guard), no duplicate recurring timer.

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
- pull-batching lookups scale O(distinct keys + chunks), not O(rows) (§3, MALI-029);
- **B2-C list/render (structural, never wall-clock):**
  - transaction first page ≤ `transactionsPageSize` (500) rows; first page = ONE keyset
    SELECT; next page = one SELECT, no overlap (proven at 10k);
  - filters (account/date/kind/category/pending/search) applied in SQL — never
    load-then-discard in Dart;
  - rapid typing → ≤ 1 DB search per SETTLED term (debounce), not per keystroke;
  - brand-mark: repeated merchant names → 0 additional catalog scans (memoised); large row
    counts never trigger O(rows × catalog);
  - date-section grouping computed once per page in the provider, not per widget build;
  - operational (sync/notification/outbox) write → 0 transaction-screen/dashboard financial
    recompute;
- **B2-C startup/resume:** the network feature-flag override + export sweep do NOT gate the
  first financial frame; non-critical resume refreshes coalesce within a 20s window;
- no single packaged asset > 1 MiB; assets/ total ≤ ~11 MiB (§8).

## 10. Remaining external / device verification

Wall-clock cold/warm startup, dashboard first-usable, list scroll jank, report/export
peak memory, packaged IPA size — all device/profile measurements, external. See
`PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.
