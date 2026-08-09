# Mali — Remediation Status Ledger

Single source of truth for the state of every finding from `FULL_APP_AUDIT.md`
(MALI-001…044) and `FINAL_FULL_PRODUCTION_AUDIT.md` (MALI-045n…077n). **No finding
is ever removed from this ledger.** Updated at the end of every phase.

- **Baseline HEAD:** `e2679d0e` (feat/phase1-data-integrity)
- **Last updated:** **Phase 7 Batch 3 — MALI-034: Supabase-primary financial
  authority RETIRED (Option A) — 2026-08-09.** In-slot legacy-cache
  reconciliation replaces the recurring repair cycle; the `*_supabase_primary`
  flags, `FinancialCacheRepairService`, the 8 repair-only Supabase financial
  repositories, the server/mixed data-portability import path, and the vestigial
  `Routed*` wrappers are deleted; data portability is single Drift-authoritative;
  a code-signal architecture guard (`tools/check_arch_guard.sh`) is wired into
  `ci_gates.sh` to keep it retired. Schema stays v29; no flag-runtime/migration/
  wire change. See the MALI-034 row and `PHASE_7_MALI_034_CLOSURE.md`. Final
  status gated on a first-attempt-green `ci_gates.sh` from the committed tree.
  _Prior:_ **Phase 7 Batch 2 — CLOSURE: Argon2 KDF gate determinism
  (test/harness reliability) — 2026-08-08.** The Batch-2 canonical gate was not
  deterministic: two backup/database-key tests intermittently failed with
  `Bad state: Segment processing timeout`, passing only in isolation / on a rerun.
  **Root cause (from source):** `package:cryptography` 2.9.0
  `DartArgon2StateImplFfi._sendSegmentsToIsolate` guards each Argon2 segment with a
  **hardcoded 10s per-segment isolate timeout** that is internal to the package and
  **immune to `@Timeout`**; under `flutter test`'s default core-count parallelism the
  memory-hard 64 MiB derivation's worker isolate is CPU-starved and a segment can exceed
  10s (measured derive inflation ~3s→~8s@2×→~11s@4× oversubscription). The prior fix
  `f469b69c` bumped the **outer framework** `@Timeout` — the wrong layer — so the flake
  recurred in a different file. **Fix (no production crypto/wire/param change):** a
  `crypto-prod` tag (`app/dart_test.yaml`) routes the production-cost crypto contract set
  (`backup_envelope_v3_test.dart`, `backup_payload_limit_test.dart`) into a **serialized**
  gate stage (`flutter test --tags crypto-prod --concurrency=1`) run uncontended, and
  **excludes** it from the parallel bulk stage (`--exclude-tags crypto-prod`) — both
  mandatory in `tools/ci_gates.sh` (gate 4a/4b), disjoint, union = whole suite. The two
  previously-flaky **semantic** tests in `database_key_state_test.dart` now inject a cheap
  Argon2 via the existing `BackupCrypto(kdf:)` seam (envelope-semantics assertions are
  KDF-cost-independent; genuine production-cost wrong-passphrase/round-trip coverage is
  retained in the serialized set — nothing faked). **Production DB-key KDF wiring
  (audited):** the SQLCipher DB key is a RANDOM secure-storage value (NOT Argon2-derived);
  `db_encryption_key_ref` is a deprecated column excluded from backups; the production
  Argon2id KDF is the backup key-protection boundary (`BackupCrypto`/`EncryptedBackupService`).
  New mandatory `production_kdf_contract_test.dart` (3rd `crypto-prod` file, serialized)
  pins all four production params (64 MiB/3/2/32), proves the real KDF is selected +
  deterministic + salt-sensitive + consumed through the production v3 boundary, and that
  the missing-DB-key state stays a DISTINCT typed exception. `database_lease_test.dart`
  isolate spawns hardened with defensive `addTearDown` kills (no core-burning isolate leak).
  **Rerun-normalization removed** (the closure rule forbids failed→isolated-pass→rerun as
  evidence); a clean gate no longer depends on any rerun. Consecutive first-attempt green
  evidence + full root-cause write-up: `PHASE_7_TEST_AND_CI_CONTRACT.md §9`. Argon2
  production parameters (64 MiB/3/2/32B), v3 envelope wire format, AES-GCM, and all
  security limits UNCHANGED; schema v29; CAS false; 0070 inactive; 0068–0076 undeployed;
  not pushed. Prior — **Phase 7 Batch 2-B — report/export/backup memory (MALI-030)
  — 2026-08-07.** Removed/capped every avoidable full-dataset materialization: SQL
  top-N for report largest-transactions; keyset-paged + 5000-capped report appendix;
  keyset-paged CSV export + chunked encode; paged full-export transactions + no
  re-decode-to-count; paged backup snapshot + dropped a full `Map.from` copy; typed
  `payloadTooLarge` (48 MiB plaintext cap) enforced BEFORE v3 encryption. v3 one-shot
  AEAD residual characterized as a bounded crypto-library constraint (not device-
  external); no plaintext to disk; v3 auth + export/import + backup/restore round-trips
  unchanged. 6 focused commits, structural tests at 10k. No financial-semantics change;
  CAS false; 0070 inactive; 0068–0076 undeployed; not pushed. Prior — **Phase 7 Batch 2
  (in progress) — performance: query/provider/startup/rendering/reporting/background —
  2026-08-07.** Established a structural (not
  wall-clock) perf baseline harness (`test/performance/perf_harness.dart`: fixtures +
  statement-counter + EXPLAIN helper). **MALI-073n DONE:** evidence-backed hot-path
  indexes (composite `(account_id, occurred_at)` + `category_id`), schema **v29**,
  version-owned + postflight-verified. **MALI-029 partial:** domain-scoped provider
  invalidation (tableWriteStream + scoped/financial revisions; unrelated→0, relevant→1,
  burst→coalesced, operational→0) + CaptureSyncService account prefetch (getAll()/row →
  1/run). **MALI-038 partial:** removed 8.1 MB unreferenced assets + asset-size budget
  (font portion pending a product decision). **MALI-030 audited, not yet fixed.** No
  financial semantics/precision/currency/refund/period/restore behavior changed. CAS
  false; migration 0070 inactive; migrations 0068–0076 undeployed; not pushed. See
  `app/docs/PHASE_7_PERFORMANCE_CONTRACT.md`. Prior — **Phase 7 Batch 1 CLOSURE —
  CI/test-harness/skip/lint/known-failure truthfulness — 2026-08-06.** Made
  `tools/ci_gates.sh` the SINGLE truthful canonical
  gate (local == CI, no CI-only subset or extra step): added the previously CI-invisible
  Deno lint + Node contract + admin auth suites, a machine-readable **skip/ignore
  manifest** gate, and **l10n** generated-code freshness (`.g.dart` is gitignored → a
  git-diff on it was a false-green; the committed `app/lib/l10n` output is the real
  staleness surface). Strict exit propagation (`PIPESTATUS`, `fail=1` latch, banner
  guarded by `fail==0`), a truthful **nested summary** (passed/failed/unavailable/
  node-skipped/deno-ignored/manifest/lint-exceptions kept SEPARATE — skips never rolled
  into passed) + a secret-free `CI_GATES_JSON` line, and `--self-test` /
  `CI_GATES_INJECT_FAILURE` self-checks (a failed gate provably exits non-zero). Enforced
  skip policy via `tools/test_skip_manifest.json` + `tools/check_test_skips.mjs`
  (unexpected/disappeared skip, changed reason, ignored-without-entry, and
  partial/present-credential violations all FAIL). Removed load-based skipping from the
  locally-testable `Process.start` kill test (generous 60s readiness + bounded setup
  retry; rollback ASSERTED; only genuine `dart`/native-sqlite absence skips) — 3/3, 0
  skips under full CPU load. Documented the exact **7** retained `deno-lint-ignore
  no-explicit-any` exceptions + an allowlist contract. **MALI-041** reconciled to its
  authoritative identity (admin test-quality: double-quote assertion vs single-quote
  source, `FULL_APP_AUDIT.md:622` / `FINAL_FULL_PRODUCTION_AUDIT.md:122`), baseline
  reproduced (old match → index -1), quote-independent contract + **regression** added →
  admin **8/0**; distinct from **MALI-066n** (CI-visibility). Fixed the 4 Deno-lint
  findings (0 now, no semantic change). No production feature behavior changed. Phase-6
  contracts preserved; migrations 0068–0076 undeployed; CAS false; 0070 inactive.
  See `app/docs/PHASE_7_TEST_AND_CI_CONTRACT.md`. Prior — **Phase 6 Batch 6 FINAL
  reconciliation — confirmation capability + post-commit usability — 2026-08-06.** Closed two production-integration
  ambiguities: (1) removed the combined `restoreFromBackup`/`restore` bypass —
  destructive mutation now requires an unforgeable single-use `RestoreConfirmation`
  (private-constructor capability minted only by the controller, tied to op
  id/fingerprint/admission, consumed once, destroyed on cancel), enforced by a
  production-call-site contract test; (2) `completed` is emitted only after commit →
  verifying → reestablishingDatabase (a real usable-state proof: production query +
  admission still current) → durable acknowledgement — a failed reopen/admission →
  `recoveryRequired`, not completed, not acknowledged (data stays committed; startup
  recovery re-establishes). +19 tests. Roll-up → **Code complete — locally verified;
  physical-device, native SQLCipher/process timing, live Supabase, multi-device, and
  device restore-UI verification pending.** Prior — **Phase 6 Batch 6 — integration
  reconciliation, documentation, external-verification matrix, formal LOCAL closure — 2026-08-06.** Fixed one real
  integration defect: the `RestoreController` existed but was unwired — the
  production restore screen bypassed it, so there was NO explicit confirmation gate
  before destructive mutation. `EncryptedBackupService` now exposes prepareRestore
  (no mutation) + commitRestore; `RestorePromptScreen` drives the controller with an
  explicit confirmation dialog (widget-tested: preparation never mutates, cancel = no
  mutation, confirm = mutation + navigate). Verified the v28 journal schema is
  version-pipeline-owned (clean install + realistic v27→v28 upgrade + idempotent
  reopen + PK). Added `PHASE_6_DATABASE_BACKUP_RESTORE.md` (closure doc) +
  `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`. **Phase-6 local roll-up: Code
  complete — locally verified; physical-device, native SQLCipher/process timing, live
  Supabase, and multi-device verification pending.** No new Supabase migration; CAS
  false; 0070 inactive. Prior — **Phase 6 Batch 5 closure — durable replay journal (local
  schema v28), preparation-time compatibility adapters, full rollback evidence,
  crash/replay recovery, truthful UI controller — 2026-08-06.** The in-memory replay
  guard is replaced by a durable `restore_operations` journal whose `committed`
  transition is atomic with the restored data (so a crash / ack-loss can never
  replay a destructive restore); explicit per-version snapshot adapters normalize
  legacy backups before mutation; 9-point fault injection proves a full-DB digest is
  unchanged on rollback; file-backed crash-before-commit + commit-before-ack restart
  + a real `Process.start` native-sqlite kill test cover the durable logic; and a
  `RestoreController` state machine enforces a confirmation gate + truthful phases.
  MALI-014 + MALI-076n restore-side → Code complete · Locally verified; native
  process-kill timing, SQLCipher hardware round-trip, device UI verification pending.
  Local Drift schema **v27 → v28** (additive `restore_operations`; no Supabase
  migration). +34 tests. Batch 6 (formal closure) NOT started. Prior —
  **Phase 6 Batch 5 — restore compatibility, atomic rollback,
  crash recovery, and user-data recovery matrix — 2026-08-06.** Restore is now a
  two-phase pipeline: PREPARATION (envelope decode/decrypt/limits → validate →
  build an IMMUTABLE `RestorePlan`) runs entirely before the maintenance gate and
  mutates nothing; MUTATION consumes only the plan, runs through the accepted
  Batch-4 file-exclusive maintenance primitive with admission revalidation, and
  executes one transaction with in-transaction verification (counts, canonical
  financial totals, no-key/no-remote/no-duplicate/singleton invariants) that throws
  BEFORE commit so any failure rolls the whole restore back and preserves the
  original DB. Typed `RestoreOutcome` taxonomy, operation-ID replay guard
  (idempotent commit, mismatched-source rejection), and the verified
  committed-generation download + v1/v2/v3 legacy readers are preserved. MALI-014 +
  MALI-076n restore-side → Code complete · Locally verified; real process-kill
  timing remains device-external. +19 tests. Batch 6 (formal closure) NOT started.
  Prior — **Phase 6 Batch 4 closure #4 — Contract B (single-process)
  proven + heartbeat/mtime REMOVED as reaping authority — 2026-08-06.** A process-
  access inventory (docs/PROCESS_ACCESS_INVENTORY.md) proves exactly one OS process
  (the Flutter host app) ever opens the DB; every separate-process target (iOS Share
  extension, App Intents, Android receivers) is pure-native and stages to the App
  Group/SharedPreferences. The unsafe heartbeat/mtime stale-recovery authority is
  removed: authoritative records are immutable + atomic (temp+rename); RUNTIME
  maintenance never reaps (waits for release → typed bounded timeout, so a live-but-
  paused isolate is never false-reaped); the only reaping is process-start recovery
  gated by a process-lifetime OS advisory lock (`DatabaseProcessLiveness`), clearing
  only leftovers from ENDED instances (different owner pid). Proven with a REAL
  `Process.start` test + a Contract-B enforcement source scan. MALI-069n + MALI-027
  lifecycle tail → Code complete — locally verified; native SQLite contention timing
  and platform-specific lifecycle behavior pending. +10 more tests. Prior —
  **closure #3** (admission generation + the renewable lease that this pass replaced
  with the process-liveness authority). Fixed two correctness gaps in
  the closure-2 protocol. (1) Ownership is no longer UID-only: Phase-2 admission
  now stores a `Random.secure()` GENERATION nonce beside the owner UID, minted on
  every genuine (re-)admission and invalidated BEFORE any sign-out purge / wipe /
  ownership change — so a previous session of the SAME user (`A→signout→A`,
  `A→B→A`) is rejected. `OwnershipGuard` binds a job to `{ownerUid, generation}`
  and re-validates at all 5 boundaries (lease, open, commit, native-ack, notify);
  a mismatch aborts with typed `StaleOwnershipException`. (2) Leases + intent are
  RENEWABLE: a fencing token + heartbeat (sub-second mtime via file rewrite);
  liveness measured from the last heartbeat, stale recovery only after a
  re-verification, token-matched cleanup — a long restore / paused device / clock
  jump never false-reaps live work, a killed isolate is recoverable after ttl. The
  shared-acquire vs intent race is closed (two-phase acquire + stable-zero settle),
  proven with deterministic real-isolate tests incl. a 14-round cross-isolate
  zero-overlap hammer. `runFileExclusiveMaintenance` is the single Batch-5
  primitive. MALI-069n + MALI-027 lifecycle tail → Code complete — locally
  verified; native process timing and real-device SQLite contention pending.
  +30 more closure tests (superseding closure-2's +15). Prior — **closure #2** (the
  cross-isolate filesystem lease that this pass hardened).
  analyze 0, full suite 1391, deno 76/0/2-ignored, node 29/0 (+27 skips), migration
  lint PASS. No Drift schema bump; no Supabase migration. Prior — **Phase 6 Batch 4
  closure (enforceable maintenance gate, secondary admission, typed busy taxonomy,
  stream ownership) — 2026-08-06.** The
  flag-only maintenance boundary is now an ENFORCEABLE borrow/lease gate (reject/
  queue borrows during maintenance, bounded drain, recoverable-restore vs typed
  `recoveryRequired`); secondary admission via `admitsSecondary`/`openSecondary`;
  `mapDatabaseBusy` + `runWithBusyRetry` typed retryable busy taxonomy; and
  stream/provider ownership proven (the DB provider is an override holder — a
  non-owning container disposal never closes the DB; a live watcher survives
  close). MALI-069n + MALI-027 lifecycle tail → Code complete · Locally verified;
  native-isolate + real-device file-lock timing pending. +15 closure tests.
  analyze 0, full suite 1354, deno 76/0/2-ignored, node 29/0 (+27 skips), migration
  lint PASS. No Drift schema bump; no Supabase migration. Prior — **Phase 6 Batch 4
  (database connection lifecycle, failed-init cleanup, concurrent same-file
  access — MALI-069n) — 2026-08-06.** Fixed the
  init-failure connection/isolate leak (close on failure, original error
  preserved), added the missing `busy_timeout=5000` to the centralized PRAGMA
  contract, routed the two same-file second connections (background capture-import
  + notification-action isolate) through `openSecondary()` (no concurrent
  migrations), and added a typed `DatabaseLifecycleState` + idempotent `close()`
  (waits for init to settle) + a `runExclusiveMaintenance` primitive for Batch-5.
  8 real-Drift lifecycle tests. No Drift schema bump; no Supabase migration.
  analyze 0, full suite 1339, deno 76/0/2-ignored, node 29/0 (+27 skips), migration
  lint PASS. Prior — **Phase 6 Batch 3 closure (remote-backup UI truthfulness,
  server-atomic CAS, trigger coordination, retention) — 2026-08-06.** The four
  approved tails are implemented: (1) truthful `RemoteBackupController` wired to
  the screen (Protected only on a committed+verified generation); (2) migration
  0076 `commit_backup_generation` server-atomic CAS RPC (locked-down, owner from
  auth, object size verified, row-locked, stale/conflict typed, idempotent replay,
  one txn); (3) trigger coordination (no auto-triggers exist — manual/enable
  serialised through the coordinator + consent gate); (4) retention (current + one
  previous + orphan prune). Credential-gated live Supabase harness added (skips
  honestly). MALI-076n remote portion → Code complete · Locally verified; live
  Supabase Storage/RLS + multi-device pending. MALI-069n untouched (Batch 4).
  analyze 0, full suite 1331, deno 76/0/2-ignored, node 29/0 (+27 skips),
  migration lint PASS. Prior — **Phase 6 Batch 3 (remote-backup state, safe
  publication, verified download) — 2026-08-06.** MALI-076n remote-backup portion + MALI-014
  remote reliability: a typed remote-backup state machine + error taxonomy +
  bounded retry policy; generation-based safe publication (unique per-generation
  object path → size-verify → CAS pointer commit → retire old, so an interrupted
  upload never replaces the last valid backup); integrity-verified download
  (size + hash before decrypt); lost-response idempotency; disable/delete
  separated; migration 0075 (generation pointer columns, additive, undeployed);
  Supabase adapter wired into backupNow/restore. 28 new tests. **Remaining tails
  (external/follow-up): truthful UI states, automatic triggers, multi-generation
  retention/pruning, server-atomic CAS RPC, credential-gated live Supabase.**
  MALI-069n remains untouched (Batch 4). analyze 0, full suite 1322, deno
  76/0/2-ignored, node 26/0 (+23 skips), migration lint PASS. Prior — **Phase 6
  Batch 2 (versioned authenticated backup envelope) — 2026-08-06.** MALI-076n backup-envelope portion + MALI-014 format-compat: new v3
  envelope with a magic identifier and an AES-GCM-AAD-authenticated header (magic,
  versions, cipher, KDF id + Argon2id params, compression) bound to the payload
  and every key slot; untrusted params/lengths resource-limited before the KDF;
  explicit UTF-8 passphrase bytes (no trim/normalize, v3); typed
  BackupEnvelopeException taxonomy; validate→authenticate→whitelist→preflight
  restore ordering; writes v3, reads v1/v2/v3. **MALI-069n was named in the
  Batch-2 finding list in error and is NOT addressed here — deferred to Batch 4
  (DB connection lifecycle).** analyze 0, full suite 1299, deno 76/0/2-ignored,
  node 21/0 (+23 skips), migration lint PASS; no schema/migration change. Prior —
  **Phase 6 Batch 1 closure reconciliation (MALI-058n) — 2026-08-05.** Added the typed `LocalDatabaseKeyUnavailableException` +
  `classifyDatabaseKeyState` gate (existing DB + missing key → typed state, never
  a silently-minted key or delete; distinct from wrong-passphrase / corrupt-DB /
  fresh-install) and end-to-end key-isolation evidence (restore makes zero
  key-store calls; missing key never falls back to backup; upload/export/telemetry
  key-canary tests). MALI-058n → Code complete · Locally verified;
  physical-device secure-storage + real encrypted backup round-trip pending.
  Prior — **Phase 6 Batch 1 (encryption-key & backup-schema hygiene,
  MALI-058n) — 2026-08-05.** The DB seed had copied the RAW SQLCipher key into
  `user_settings.db_encryption_key_ref`, which was also in the backup allowlist —
  so the raw local-DB key was serialized into every backup snapshot. Fixed: the
  key stays in platform secure storage only; the column is deprecated + forced
  empty; excluded from backup/restore/sync/export; restore filters to a central
  column whitelist and fails closed on unknown key/secret fields before any
  destructive step; idempotent legacy cleanup. analyze 0, full suite 1264, deno
  76/0/2-ignored, node 21/0 (+23 skips), migration lint PASS. No local
  schema-version bump; no Supabase migration. Prior — **Phase 5 Batch 6 closure
  correction — 2026-08-05.** The Batch-6
  documentation surfaced four production-code defects INSIDE Phase-5 scope; they
  were fixed (not deferred): (1) MALI-019 — `evaluate-gamification` push now
  policy/quiet-hours/privacy gated; (2) MALI-061n — goals/achievements coordinated,
  streak/bill server cron retired, text-derived captureLight/budget ids removed;
  (3) MALI-060n — `process-ios-sms` server-consent + bounded-body hardened. analyze
  0, full suite 1258, deno 76/0/2-ignored, node 21/0 (+23 credential-gated skips),
  migration lint PASS, ci_gates PASS. Prior Batch-6 was **documentation, reconciliation,
  external-gate inventory, formal closure** — documentation & verification only; no
  production code changed. Authoritative Phase-5 contract spec created:
  `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md` (native storage, Android, telemetry,
  exports, AI-endpoint matrix, notification authority/terminology/scheduling,
  backend security, gamification 8-layer authority + the 0074 atomic-award
  contract). Verdict: **Phase 5 code complete — locally verified; signed-device,
  Android, APNs, store-policy, and live-PostgreSQL verification pending.**
  Migrations 0068–0074 undeployed; `kServerRevisionCas=false`; migration 0070
  authority inactive. Prior — **Phase 5 Batch 5 (backend, RLS, SECURITY DEFINER,
  metrics, purge, gamification, endpoint hardening) Code complete · Locally
  verified — 2026-08-05.** MALI-075n (SD search_path — dead handle_new_user dropped, prune
  fixed; owner-bound rate-limited `record_metric` RPC replacing `with check
  (true)`; purge coverage extended to AI-idempotency/engagement/metrics-quota),
  MALI-044 (dead merchant-feedback retired — auth + 410), MALI-024 backend
  confirmation (dormant record_engagement_event hardening asserted; activation
  gate documented). Migration 0072 (additive, undeployed, lint PASS).
  `4e927db5`/`6ddd5aaa`/`975af849`. analyze 0, flutter suite green, deno 68/0
  (+2 ignored), 9 backend contract tests. Live RLS/RPC/purge under real Postgres
  external. **Batch-5 closure reconciliation (2026-08-05):** gamification gap
  found & fixed — 0062 owner aggregate-writes let clients forge their own
  XP/streak/achievements; **0073** makes the aggregates read-only to clients
  (server-only authoritative writer). **Idempotency closure (2026-08-05):** the
  first fix claimed the ledger row and mutated XP in SEPARATE Edge calls (separate
  transactions) — a crash between them LOST the award. **0074** folds the claim +
  XP/level/achievement/eligibility into ONE Postgres transaction (SECURITY DEFINER
  `award_gamification_for_transaction`, server-role only, ownership-checked) →
  exactly-once AUTHORITATIVE mutation; APNs delivery is after commit with a stable
  collapse id (idempotent, retryable). Client verified pull-only; engagement
  submission already bounded. `9fdd30e7`/`c4f2aea0`. Batch 6 not started.
  Prior — **Phase 5 Batch 4 (notification authority, policy,
  deduplication, lock-screen privacy, scheduling limits, Android receiver tail)
  Code complete · Locally verified — 2026-08-05.** MALI-061n (stable event
  identity off display text; budget local-primary/server-fallback coordination),
  MALI-019 (lock-screen privacy contract + log-leak fix; honest delivery states),
  MALI-025 (iOS pending-capacity + rolling-window scheduler), MALI-068n (Android
  receiver native-epoch timestamp authority + inexact alarms + durable clear),
  and the Batch-3 Android consent-propagation tail. `1e2d88f4`/`1e217ce3`/
  `224394fd`/`9128589e`/`8337202e`/`5b2c771b`. analyze 0, flutter suite green,
  deno 68/0 (+2 ignored). Native Android compile/receiver/alarm/device external.
  **Batch-4 closure reconciliation (2026-08-05):** three contracts proven with
  behavioral tests + two gaps fixed — the silent-`now` timestamp default
  (`d72e5785`), the sign-out reminder-cancel gap (`f7cbe727`), plus the explicit
  capture-notification authority (`c3ffc673`). See the `[B4-closure]` notes on
  MALI-019/061n/068n. Batches 5–6 not started.
  Prior — **Phase 5 Batch 3 (AI endpoint authentication, verified
  identity, consent, rate limiting, abuse controls) — 2026-08-05.** MALI-060n: parse-sms/bank-discovery/enrich-merchant
  now require a server-verified identity (device secret or user JWT, never
  caller install_id), enforce consent server-side (fail-closed), rate-limit +
  idempotency on the verified identity, bounded payloads, upstream timeouts, and
  a typed error envelope; migration 0071 (consent cols + idempotency RPCs, NOT
  deployed) + set-device-consent + client wiring. Endpoint matrix in the master
  plan. deno 67/0 (+2 credential-gated real-backend ignored), migration-lint
  PASS. Live migration apply + RPC concurrency + Android consent-push external.
  Batches 4–6 not started.
  Prior — **Phase 5 Batch 2 (telemetry, logging, temp files, export
  privacy, merchant logos) — 2026-08-05.**
  MALI-032 (allowlist telemetry boundary `bff0f1d8`), MALI-065n (managed
  temp-export lifecycle `2d1072f6`, iOS simulator build), MALI-071n (merchant-
  logo consent gate `08e7ca0d`), and the logging/privacy portions of MALI-039 +
  MALI-075n (central redacting `debugPrint` sink + `Diag` `0010b037`; merchant
  edge functions reviewed — no sensitive logging). analyze 0, targeted suites
  green. Batches 3–6 of Phase 5 not started.
  Prior — **Phase 5 Batch 1 (native storage + Android backup) — 2026-08-04:**
  MALI-033/031 + the native-storage portion of MALI-068n: Android Auto Backup
  disabled + durable capture-queue writes (`5c88417c`); iOS shared-Keychain
  secrets + AES-encrypted capture queue + aux-queue locking (`30b4f3fc`, iOS
  simulator build + `xcodebuild test` 6/6).
  **Phase 4 CLOSED (locally verified)** — spec `PHASE_4_FINANCIAL_SEMANTICS.md`
  (analyze 0, full suite 1181). Phase 3: `PHASE_3_SYNC_CLOSURE.md`.

> **Phase 2 note — bug found & fixed during implementation (not a new finding):**
> `drift_repository_support.dart` `userSettingsFromRow` hard-coded both consent
> flags to `true`, so runtime consent was ALWAYS ON and revocation was a no-op
> (the re-audit's MALI-001 verdict under-counted this). Fixed as part of the
> MALI-001/059n remediation (the read now reflects the persisted versioned state).

### Approved product decisions
- **MALI-059n (consent default) — APPROVED 2026-07-30:** Cloud processing and AI
  processing both **default OFF**; they are **separate explicit opt-ins**; the
  local/offline app is fully usable without either; consent is **never inferred**
  from onboarding completion, authentication, restore, migration, or previous
  default values; existing installs that never made an explicit choice **migrate
  to OFF**; revocation takes effect **immediately and fails closed**. A versioned
  consent schema distinguishes unset / explicitly-accepted / explicitly-declined
  (not a default-true boolean).
- **Plan scope (MALI-048n) — APPROVED 2026-08-04:** an empty stored plan scope
  permanently means the documented `allExpenses` mode. There is deliberately NO
  separate `unconfigured` state, NO `scope_mode` column, and NO new UI for the
  distinction — this **preserves the existing approved product contract**, it is
  not deferred work. (Supersedes the Batch-3 "deferred product decision" note.)
- **MALI-046n — CLOSED (locally verified):** on-device production-path
  confirmation remains part of external gate 6 (per Phase-1 approval).
- **MALI-045n — Code complete · Locally verified:** final closure requires the
  on-device backup→restore round-trip in external gate 6.

**Status vocabulary:** Not started · In progress · Code complete · Locally verified ·
External verification pending · Closed · Decision required · Blocked.

**Classification (actionable scope):** C=Code · T=Test · D=Docs · P=Product/policy ·
X=External-only · DUP=Duplicate · AF=Already-fixed (fresh evidence). VC findings from
the re-audit are recorded Closed (local) with any external tail tracked separately.

## Legend for "Phase"
P1 migrations/restore · P2 lifecycle/consent · P3 sync · P4 financial · P5 security/notif/native ·
P6 backup/DB/reliability · P7 CI/test/arch/docs · P8 MALI-026 · P9 external validation · — none.

## Master ledger

| Finding | Sev | Class | Phase | Status | Subsumed-by / Notes |
|---|---|---|---|---|---|
| MALI-001 | Crit | C+P | P2 | Code complete · Locally verified | explicit versioned default-OFF consent; read-clamp bug fixed; `89db9f09` |
| MALI-002 | Crit | X | P9 | Locally verified | on-device 2-user smoke = gate 6; legacy-null-owner window = MALI-070n |
| MALI-003 | Crit | X | P9 | Locally verified | release-binary fail-closed proof = gate 3/10 |
| MALI-004 | Crit | X | P9 | Locally verified | live Edge adversarial = gate 12 |
| MALI-005 | Crit | X | P9 | Locally verified | live purge time-travel = gates 1/2/12; purge coverage lows = MALI-075n |
| MALI-006 | High | X | P9 | Code complete (device pending) | merged-manifest+smoke = gate 3 |
| MALI-007 | High | — | — | Closed | atomic write+outbox re-verified |
| MALI-008 | High | C | P3 | Code complete · Locally verified | periphery closed via MALI-072n durable sender-mapping sync (keyset + tombstones + typed errors); `96993c5e` (batch 5) |
| MALI-009 | High | C | P3 | Code complete · Locally verified | versioned canonical payload preserves type/direction/status/source; base-token round-trip; `124fd83b` (batch 4); live 2-device = external |
| MALI-010 | High | C | P3 | Code complete · Locally verified | withdrawal/refund/unknown/source round-trip via canonical metadata (no lossy debit/credit collapse); `124fd83b` (batch 4) |
| MALI-011 | High | C | P2 | Code complete · Locally verified | atomic wipe + unsynced inventory (flush→re-check→discard); `374560ff` |
| MALI-012 | High | X | P9 | Locally verified | on-device kill = gate 6/9 |
| MALI-013 | High | C+X | P5/P9 | Code complete (device pending) | apply()-in-receiver = MALI-068n; gates 9/10/11 |
| MALI-014 | High | C | **P1** | Code complete · Locally verified | closed by MALI-045n fix; on-device round-trip = gate 6. **P6-B2:** remaining backup-format compatibility addressed — the versioned envelope reader accepts v1/v2/v3 explicitly by the in-blob version marker (no exception-driven format guessing), preserving legacy passphrase/KDF behavior for old-backup restore; new writer emits v3 only. **[P6-B5] restore compatibility/rollback/recovery matrix.** Restore is now a two-phase pipeline — PREPARATION (envelope decode/decrypt/limits → validate schema/whitelist/sensitive-field/required-table → build an IMMUTABLE `RestorePlan`: opaque operationId, envelope+schema version, source fingerprint, whitelisted table payloads, expected counts, privacy-safe warnings; no secret/key/path) then MUTATION which consumes ONLY the plan. Mutation runs through the accepted Batch-4 file-exclusive maintenance primitive (`RestoreService` → `runFileExclusiveMaintenance`), revalidates admission before the gate and again immediately before the transaction, and executes the destructive delete/insert/sanitize in one transaction with IN-TRANSACTION verification (required singleton, transaction row-count == plan, no duplicate ids, sanitize-safe tables ≤ plan, canonical net-expense financial total == plan total via Phase-4 `FinancialSql`, no SQLCipher key ref, no intentionally-excluded/remote/pending table) — any mismatch throws BEFORE commit so the whole restore rolls back and the original DB is preserved. Typed `RestoreResult`/`RestoreOutcome` taxonomy (success/cancelled/authenticationFailed/malformedBackup/unsupportedEnvelope/incompatibleSnapshot/payloadTooLarge/ownershipChanged/maintenanceTimeout/databaseBusy/validationFailed/rollbackCompleted/rollbackFailed/reopenFailed/recoveryRequired/localFileUnavailable/remoteObjectUnavailable/remoteIntegrityFailed/internalFailure) maps every internal exception to a safe message. Operation-ID replay guard (in-memory, no schema table): a committed operation is never destructively replayed (idempotent), the same op id with a different source fingerprint is rejected. `EncryptedBackupService.restore` wired to the pipeline; the existing verified committed-generation download + v1/v2/v3 legacy readers are preserved. 9 pipeline tests (success+verify, duplicate-id rollback with the destination unchanged, unknown-table/sensitive-field/future-schema preflight, ownership-changed abort, replay idempotency+mismatch, maintenance-timeout, privacy canaries) + the existing FK-safety/completeness suites. **[P6-B5-closure] five gaps closed.** (1) **Durable replay journal** — the in-memory guard is replaced by a `restore_operations` Drift table (local schema **v28**, created idempotently by `_createSchema` on fresh install + upgrade, excluded from backup/restore/sync/export, bounded retention); the `committed` transition is written INSIDE the restore transaction so it is atomic with the data (rolls back with it), and a committed operation is discovered at restart (`committedPendingAcknowledgement`) and never destructively replayed; acknowledgement is idempotent. (2) **Preparation-time compatibility adapters** — an explicit per-version `SnapshotSchemaAdapter` (v1/v2/v3) normalizes the source to the current plan BEFORE mutation (version-specific required tables + defaults + warnings; future version rejected before mutation), tested with synthetic v1/v2/v3 fixtures. (3) **Complete rollback evidence** — deterministic fault injection at 9 transaction-boundary points, each proving a full-DB digest (all user-data tables + per-currency totals) is unchanged and no committed marker survives; strengthened in-transaction verification (per-currency canonical totals, default-account, singleton, no-duplicate/key/remote). (4) **Local crash/replay** — file-backed crash-before-commit (reopen = complete old state, no marker) + commit-before-ack restart (discovered, not replayed, then acknowledged) + a REAL `Process.start` native-sqlite kill proving SQLite rolls back the uncommitted work (native SQLCipher timing external, skip-safe). (5) **Truthful UI controller** — a `RestoreController` state machine with an explicit confirmation gate before mutation, cancellation-changes-nothing, success only after commit/verify/reopen, typed-outcome→phase mapping, and idempotent acknowledgement (9 controller tests; broad screen redesign intentionally avoided). External (device-only): native process-kill timing, SQLCipher hardware round-trip, device UI verification |
| MALI-015 | High | — | — | Closed | RPC path re-verified (client+server) |
| MALI-016 | High | — | — | Closed | atomic per-relation deletion re-verified |
| MALI-017 | High | C | P2 | Code complete · Locally verified | local-only cards in the inventory guard (interactive path); delete/reset gate behind explicit confirmation; remote/cross-UID wipe for isolation; `374560ff` |
| MALI-018 | High | C+T | P4 | **Closed · locally verified** | provider tier complete across repository/header/Home/plan/budget-ring/budget-detail/budget-history/report/bill/subscription/card/account-detail/installment; dormant Supabase aggregate tier retired; locked by the cross-surface invariant suite. Spec: `PHASE_4_FINANCIAL_SEMANTICS.md`. Live two-device/device = external |
| MALI-019 | High | C | P5 | Code complete · Locally verified (device external) | server-side preference enforcement (edge `notification_policy.ts`, per-type + quiet hours) already present; Batch-4 added the lock-screen privacy contract (hideLockScreenContent pref, `redactedContentFor` generic content per type, in-app inbox keeps real content), removed a title-logging leak (§9), and honest delivery states confirmed (notification_logs has NO 'delivered'). `224394fd` (P5-B4). [B4-closure] Closure: sign-out reminder-cancel gap FIXED (`cancelScheduledReminders` wired to the residue purge; `f7cbe727`); reconciliation (edit keeps stable id→OS-replace, disable/delete plan nothing) + quiet-hours boundary/midnight-crossing + managed-reminder-id tests. **[B6-closure]** gamification push gap FIXED: `evaluate-gamification` now routes the post-award push through `loadNotificationPolicy`/`isPushAllowed('achievement')` (per-type + quiet hours) + `hideLockScreenContent` redaction + valid-token/ownership + coordinated fallback; eligibility stays exactly-once in the 0074 RPC, delivery best-effort after commit. deno gamification-policy tests + static contract. Device lock-screen render external |
| MALI-020 | High | X | P9 | Locally verified | archive privacy report = gate 5 |
| MALI-021 | High | C | P6/P7 | Not started (scope Closed) | dead file + PDF sweep = MALI-076n/065n |
| MALI-022 | High | C | P3 | Code complete · Locally verified · **live CAS external-pending** | server revision CAS migration 0068 `4a2da692` + universal resolver all 12 `de672bc0` + client CAS plumbing gated OFF `0e52da68` (batch 3); activation blocked on 0068 staging verification |
| MALI-023 | Med | C | P3 | Code complete · Locally verified | typed failure classes + dead-letter + bounded backoff + re-arm; `d6820285` (batch 2) |
| MALI-024 | Med | C | P3 | Code complete · Locally verified | server-authoritative idempotent engagement events (migration 0070 + locked-down record_engagement_event RPC); client aggregate-total upload removed (tamper vector gone); durable event outbox + exactly-once + projection; `bc0e0ddb` (batch 5). **P5-B5 confirmation:** contract tests assert record_engagement_event derives owner from auth.uid(), rejects unauthenticated/unknown-type/unsupported-version, server-fixed CASE award (no client XP), idempotent (ON CONFLICT DO NOTHING), SD + fixed search_path; the path is EFFECTIVELY DORMANT via 0070 undeployed (client enqueues+submits but the RPC 404s → no award; the legacy transaction-triggered authority is the sole active award path). **Batch-5 closure — gap found & fixed:** the earlier report wrongly accepted 0062's owner aggregate-writes; a normal client could forge its own XP/level/streak/achievements. **0073** removes the owner insert/update policies + revokes write grants (aggregates read-only to clients; server service-role is the sole authoritative writer); the client is pull-only (verified). Legacy award made **exactly-once as a single-transaction authoritative mutation**: the first fix (`9fdd30e7`) claimed the ledger row and mutated XP in SEPARATE Edge calls (separate transactions) — a crash after the claim committed but before the XP update LOST the award permanently; **0074** (`c4f2aea0`) folds the claim + XP/level/achievement/notification-eligibility into ONE Postgres transaction (`award_gamification_for_transaction`, SECURITY DEFINER, fixed search_path, ownership-verified, service_role-only), so a crash rolls the claim back with the award, a lost-response/duplicate/concurrent retry reconstructs the stored canonical result, and no partial state is possible. APNs delivery happens AFTER commit, keyed by a stable per-transaction collapse id (best-effort, idempotent, retryable — a send failure never rolls back or re-awards). Ledger purge-covered. Client engagement submission already bounded (retry→dead-letter, projection preserves progress, pull reconciles). Activation gate (deploy 0070 + disable legacy in the SAME release, else double-award) documented. Live RLS/concurrency = external |
| MALI-025 | Med | C | P5 | Code complete · Locally verified (device external) | NotificationCapacityPlanner (pure): internal cap below iOS's ~64 max, immediate-alert reserve, importance-then-nearest-due, past-due drop, rolling window over app-managed ids only; schedulePlannedNotifications reads the live pending set, applies {schedule,cancel}, and verifies the actual pending set (safe count only). 5 planner tests. `9128589e` (P5-B4). On-device 64-limit behavior external |
| MALI-026 | Med | C | **P8** | Not started | separate financial-storage project |
| MALI-027 | Med | C | **P1** | Code complete · Locally verified | closed by MALI-046n fix. **P6-B4 database-lifecycle tail:** the migration pipeline stays the sole `user_version` owner AND now runs exactly once per opened lifecycle — a failed open closes the connection/isolate (no partial-owner leak), close is idempotent + waits for init to settle, and second connections never run migrations concurrently (`openSecondary`). **[B4-closure-3] cross-isolate admission generation** — the lifecycle tail is no longer UID-only: a rotating `{ownerUid, generation}` admission token invalidates a previous session's background job (same-UID re-login included) before it can commit, acknowledge, or notify. **[B4-closure-4]** destructive maintenance no longer relies on heartbeat/mtime to prove a lease owner is gone: it never reaps at runtime (waits for release → typed bounded timeout), and the only reaping is process-start recovery gated by a process-lifetime OS advisory lock (proven with a real `Process.start` test). Lifecycle tail status → **Code complete — locally verified; native SQLite contention timing and platform-specific lifecycle behavior pending** |
| MALI-028 | Med | C | P4 | **Closed · locally verified** | half-open `[from, to)` for every Phase-4 interval (repo aggregates, budget/plan/report periods, transactions/dashboard lists, appendix, comparison); no epsilon/`23:59:59`/inclusive-last-instant anywhere; boundary rule enforced for every new/changed caller. Spec §F. Live device = external |
| MALI-029 | Med | C | P7 | **Code complete · Locally verified** (device battery/background timing + real-network cadence profiling external) | **P7-B2-A APPROVED (2026-08-08).** Accepted permanent contracts: every production-active pull/import FK-resolution path uses bounded batch-scoped lookup; SQLite lookup chunks use the central safe bound + bound parameters; no static/cross-admission lookup cache; account/category/merchant/parent resolution scales by chunks/distinct keys not remote row count; `saveTransaction` may use a pre-validated `resolvedCategoryId` without re-querying; invalid category stays fail-closed; overlapping sync requests coalesce; old-owner scheduled work invalidated on admission change; offline/background work never burns retry budget; provider invalidation stays domain-scoped + batch-bounded; CAS stays disabled. Do NOT reopen B2-A unless B2-C exposes a direct regression. Scoped invalidation DONE (unchanged, still green: unrelated→0, relevant→1, 100-burst→≤2 — `scoped_invalidation_test.dart`). **Pull-batching COMPLETE for every production-reachable path** via a central bounded-ID chunk primitive (`lib/data/db/bounded_lookup.dart`, `kSqliteMaxLookupChunk=500`, bound-vars only, 15 tests). Measured SELECTs @100/@1,000 rows: AccountsPull **3/5** (identity index); PlanningPull subscriptions **4/6** (merchant batch), budgets **5/7** (category batch); PlanningChildSync goal-contribs **6/10** (parent+child+pending scope); saveTransaction fast path **0** category SELECTs (resolvedCategoryId, fail-closed via FK, type-forcing preserved). All O(distinct keys+chunks), not O(rows) (`accounts_pull_/planning_pull_/planning_child_query_count_test`, `save_transaction_category_boundary_test`). Prior accepted: CaptureSync (8→1), LedgerSync (25→1), SenderBankMapping (25→1 upsert). Cadence DONE: adaptive backoff + coalescing + **offline/ownership `SyncGate`** (outbox-derived reachability — no connectivity source; offline coalesces one intent, no retry burn; sign-out/relogin invalidates old-owner work via admission generation; 8 SyncGate tests). **Final inventory** (pump=_runLedgerSyncBody+bootstrap): 4 named paths + 3 accepted = fixed; push services = intentional network-bound per-item; smart-inbox pull self-lookup + import fuzzy dedup = intentional non-FK per-item; gamification/catalog = bounded catalogs; backfills = migration-only (StartupSyncReconcile); financial_cache_repair = MALI-034 dormant. **No unexplained active O(rows) FK-resolution loop remains.** **B2-C (rendering/pagination/search/startup/resume) DONE** (locally verified; real-device frame/battery/memory profiling external): keyset pagination + full SQL filter push-down in `getTransactionPage` (10k → first page 50 rows in 1 SELECT, no full-history load, filter-change cursor reset + stale-page guard); 250ms search debounce proven at the widget level; date-grouping moved to the provider layer; brand-mark O(rows×catalog) → O(distinct) memoised index; transaction/dashboard financial providers domain-scoped (operational write → 0 recompute); home "today" full-table load → bounded date query; startup defers the network feature-flag override + export sweep off the first frame + `localFinancialUiUsable` milestone; resume coalesces non-critical refreshes (`ResumeCoalescer`). **B2-C closure reconciliation DONE**: (1) NO whole-ledger `getAll()` remains on any rendering/provider path — budgets history line-items (period-window keyset drain, canonical filter unchanged), dashboard bootstrap (`distinctCurrencies`+null-account drain+bounded pending), cards/plan pickers + bill-details (bounded pages), capture-health (`latestBankCaptureAt`) all fixed; bills/accounts getAll = bounded catalogs; export = non-render (MALI-030). (2) startup local/remote boundary proven — `app_open` remote metric deferred; `localFinancialUiUsable` waits on no remote HTTP except local owner-conflict; offline local-critical-path (key+DB+migrations+owner query) test green. (3) search fold made consistent (SQLite LOWER both sides; ASCII case-insensitive both ways, Arabic exact, %/_ escaped) + parity matrix. Status → **Code complete · LV** (real-device frame timing/startup timing/jank/memory/battery profiling external). Tests: `transaction_page_filter_/search_debounce_/day_grouping_/brand_mark_index_/startup_deferral_/provider_large_ledger_test` + `scoped_invalidation`/`sync_cadence` extensions. See `PHASE_7_PERFORMANCE_CONTRACT.md §3–4, 6–7`. |
| MALI-030 | Med | C | P7 | **Code complete · Locally verified** | **P7-B2-B.** Every avoidable full-dataset materialization removed/capped: `_largestTransactions`→SQL top-N (`largestExpenses`); appendix→keyset pages + 5000-row cap; CSV export→keyset pages + chunked encode; full-export→paged transactions + no re-decode-to-count; backup snapshot→paged transactions + dropped the `Map.from` double-copy. Typed `payloadTooLarge` enforced BEFORE encryption (48 MiB plaintext cap). v3 one-shot AEAD residual characterized honestly as a bounded crypto-library constraint (NOT device-external); no plaintext staged to disk; v3 auth unchanged; export/import + backup/restore round-trips preserved. Status: *bounded report/export/snapshot DB processing; v3 encryption a bounded one-shot under enforced caps.* See `PHASE_7_PERFORMANCE_CONTRACT.md` §5. **B2-B closure:** production backup path now STREAMS the snapshot to capped plaintext bytes (byte-identical to jsonEncode(build)) — no full object graph + whole JSON String coexist with the plaintext (Blocker 1/2); appendix >5000 rows OMITTED with an explicit flag, never silent truncation (Blocker 3); full-export multi-CSV/zip coexistence is a zip-format constraint (Blocker 4); upload handoff audited clean — no application blob clone (Blocker 5). **Closure final:** appendix omission now RENDERED in the PDF with a localized ar/en notice (Blocker 1); full-export has its OWN enforced 100 MiB cap checked incrementally → typed error + no partial (Blocker 2). Irreducible whole buffers (all bounded, none device-only): v3 plaintext ≤48 MiB, ciphertext ≤64 MiB, export ZIP ≤100 MiB. **Remaining:** native heap/profile (external). |
| MALI-031 | Med | C | P5 | Code complete · Locally verified (device-external) | secret material (device secret + capture-queue key) moved to a shared Keychain access group; capture queue AES-GCM encrypted at rest (legacy-plaintext migration, corrupt fail-closed no-delete); device secret invalidated on wipe; flutter_secure_storage default group preserved. `30b4f3fc` (P5-B1). iOS simulator: build + `xcodebuild test` 6/6 incl. behavioral encryption/secret/purge tests. External: shared-Keychain cross-process app↔extension under a real provisioning profile + `keychain-access-groups` entitlement |
| MALI-032 | Med | C+T | P5 | Code complete · Locally verified | allowlist telemetry boundary — beforeSend AND beforeBreadcrumb drop all free-form text (exception messages, breadcrumbs, threads, request, user), keeping only allowlisted tags/extra/contexts + exception class name + stack frames (vars stripped) + structured `TelemetryCodes`; native auto-breadcrumbs disabled (the Dart boundary cannot scrub native-SDK crashes — documented residual); behavioral canary tests inject every sensitive class through message/cause/stack-vars/breadcrumb/tag/context/extra/URL/db-error and assert none survive the serialized event. `bff0f1d8` (P5-B2). Native-SDK scrubbing parity external |
| MALI-033 | Med | C | P5 | Code complete · Locally verified (device-external) | Android Auto Backup + device-transfer disabled (`allowBackup="false"`, `fullBackupContent="false"`) — the Keystore-bound DB + raw-SMS queue + secrets would restore incoherent; recovery is via the app's own encrypted backup. `5c88417c` (P5-B1); manifest static-verified (`android_backup_policy_test`). External: on-device restore attempt confirms exclusion |
| MALI-034 | Med | C | P7 | **Closed · gate green (committed tree `a72f1b11`)** | **P7-B3 (2026-08-09) — Supabase-primary financial authority RETIRED (Option A).** The legacy dual-authority architecture is gone: (1) in-slot `LegacyFinancialCacheReconciler` (`476474b8`) reconciles a dirty legacy cache marker at each domain's post-push pull SLOT via an epoch full-pull under a synchronous exact-generation admission guard (PUSH→PULL order preserved; atomic marker clear; explicit cancellation) — replaces the recurring repair cycle's runtime role; (2) the 10 `*_supabase_primary`/`_supabase_summary`/`_supabase_rpc` authority flags + the server/mixed data-portability import RPC + `repairAll` rebuild + post-restore primary backfill retired, data portability collapsed to one **Drift-authoritative** export/import recorded in the LOCAL `financial_import_runs` for idempotency (`8ee1bd4c`); (3) `FinancialCacheRepairService` + provider + the 8 repair-only Supabase financial repositories deleted, the transaction enum→wire mappers extracted **verbatim** to `data/sync/transaction_server_mappers.dart` (authority-neutral transport), CaptureSync Supabase-primary relay removed, dead `markFinancialCacheDirty`/`mirrorFinancialCacheSafely` dropped (`a988e830`); (4) the 8 vestigial `Routed*Repository` pass-through wrappers collapsed to direct `Drift*Repository` providers (`f5b07e62`). **Crash-window (§6):** the retired server-import preserved original timestamps so an incremental pull couldn't heal a crash between server-commit and cache-rebuild; Option A removes the path (local import is one Drift txn, no server round-trip, no window). **Zero runtime reachability (§9):** 0 imports/constructors of the retired repos + repair service, 0 quoted `*_supabase_primary` selectors, 0 `Routed*` wrappers in `app/lib` (remaining refs are history comments only); schema stays **v29**. Enforced by `tools/check_arch_guard.sh` (code-signal-only; self-tested to fail on reintroduction), wired as a mandatory `ci_gates.sh` stage. **Historical dirty-marker compat (§7):** `kFinancialCacheMarkers` maps every legacy marker to one domain, unknown→null never guessed. **Tests:** data-portability regression ×10 (`app_data_portability_service_test.dart`), reconciliation ×33, offline-first/DI repointed. Invariants preserved: `kServerRevisionCas=false`, 0070 inactive, 0068–0076 undeployed, envelope v3, Argon2 params. Full narrative: `PHASE_7_MALI_034_CLOSURE.md`. **Closure gate:** `ci_gates.sh` ran once from committed clean tree `a72f1b11`, **first attempt green** — 11/11 mandatory gates passed, 0 failed, 0 unavailable (bulk 1579 + serialized Argon2 crypto 24; arch guard 5/5; skip manifest satisfied). Not pushed. |
| MALI-035 | Med | D | P7 | Not started | CLAUDE.md drift (incl. dangerous "all optional") |
| MALI-036 | Med | X+C | P7/P9 | Code complete (limits) | CI wiring = MALI-066n; hosted run = gate 8 |
| MALI-037 | Med | C | P7 | Not started | CVE/license gate |
| MALI-038 | Low | C+T | P7 | **Code complete · Locally verified** (packaged IPA/APK size + real-device typography/layout external) | **P7-B2-D DONE.** Asset portion: removed 8.1 MB unreferenced assets, `asset_budget_test.dart` enforces ≤1 MiB/file + ≤11 MiB total (assets/ 7.81→~8.47 MiB with bundled fonts; margin ~2.5 MiB). **Font portion DONE:** user-supplied SIL-OFL-1.1 Alexandria TTFs bundled (verified family='Alexandria', usWeightClass 400/500/600/700, valid TrueType) + registered as ONE `Alexandria` family (400/500/600/700) with a bundled `IBMPlexSansArabic` fallback; `AppTypography.custom()` → plain `TextStyle(fontFamily:'Alexandria')` (all metrics unchanged); **`google_fonts` dependency removed** → no runtime font fetch, offline-correct. FontManifest verified; behavioral font tests (`app_typography_test`) replace the brittle source-text test; `asset_budget_test` asserts all 4 weights packaged. PDF font path unchanged. See `PHASE_7_PERFORMANCE_CONTRACT.md §8`. |
| MALI-039 | Low | C | P5/P7 | Code complete · Locally verified | central redacting diagnostic sink — `main()` rewires the global `debugPrint` to redact (shared `PrivacyRedactor`) + length-bound every line (all call sites, plugins, future code) in debug AND release; `Diag.error`/`Diag.log` sanctioned structured API; SQL already parameterized (custom SQL interpolates only fixed table identifiers, never values). `0010b037` (P5-B2) |
| MALI-040 | Low | T | P7 | Not started (one contention-surface item hardened) | test isolation (subsumed by MALI-067n). **P7-B2 (Argon2 gate determinism):** the two `database_lease_test.dart` `Isolate.spawn` sites now carry a defensive `addTearDown` kill so a core-burning hammer isolate cannot leak on the throw-path and starve a co-located Argon2 derivation. This is confined to the CPU-contention surface behind the gate flake; the broader test-isolation sweep (global static state, executor ownership, temp-dir teardown across the suite) remains scoped here for a later batch. |
| MALI-041 | Low | T | P7 | **Code complete · Locally verified** | **P7-B1 (authoritative-identity reconciled).** MALI-041 = admin **test-quality** defect: the assertion matched the parser-test source with a double-quote literal `.from("admin_users")` while the source uses single quotes — a false failure despite correct auth→admin→parser ordering (`FULL_APP_AUDIT.md:622`; `FINAL_FULL_PRODUCTION_AUDIT.md:122`). **Baseline reproduced:** the old double-quote match returns index -1 on the real single-quote source. **Fix:** a quote/whitespace-independent structural contract (`enforcesAuthThenAdminThenRead`: `auth.getUser → admin_users allowlist → sms_parsers read`, no caller-supplied admin identity) + 3 negative self-tests + a **MALI-041 regression** proving quote-style invariance (single- AND double-quote inputs both pass and are equal; the live source passes). Admin suite **8 pass / 0 fail**, wired into the canonical gate + CI. Distinct from **MALI-066n** (the CI-visibility gap). No longer a known failure. |
| MALI-042 | Low | T | P7 | Not started | Edge unit isolation (MALI-066n) |
| MALI-043 | Low | P+D | P7 | Decision required | canonical brand name (Mali vs Qirsh) |
| MALI-044 | Low | C | P5 | Code complete · Locally verified (live-backend external) | dead/no-op endpoint retired: merchant-feedback (never-implemented `TODO`, anonymous, fake-success) now requires a bearer token and returns an explicit 410 `retired` → `enrich-merchant`, with a reuse guard; its unwired client (`flushIfReady` never called) noted. The metrics `with check (true)` policy is removed under MALI-075n (0072). `6ddd5aaa` (P5-B5) |
| MALI-045n | High | C | **P1** | Code complete · Locally verified | FK-safe restore (full parents + suspend-correctly + sanitize + verify); 5 regression tests; on-device round-trip = gate 6 |
| MALI-046n | High | C | **P1** | Closed · locally verified | `enableMigrations:false` → pipeline owns user_version; 5 regression tests; on-device path = gate 6 |
| MALI-047n | High | C | P4 | Code complete · Locally verified | header total now canonical net expense over the complete dataset (`transactionsPeriodTotalProvider`), pagination-independent, confirmed-only, refund-netted, single-currency; bespoke `TransactionsView` folds removed; `2052687d` (Batch 2). Device UI spot-check external |
| MALI-048n | High | C | P4 | Code complete · Locally verified | canonical plan spending: half-open window, plan-currency isolation (no cross-currency sum, incl. linked rows), refund netting (no raw SUM), confirmed-only, excluded-account policy for all-expenses scope, UNION account/card membership, blank-currency fail-closed, list==total; empty scope preserved as documented all-expenses; `4fa413a9` (Batch 3). Device UI spot-check + unconfigured-scope product decision external |
| MALI-049n | High | C | P4 | Code complete · Locally verified | dashboard ring uses the budget's OWN stored period (not the dashboard filter) via one canonical resolver shared with budget detail/reports/alerts; genuine half-open Saturday week; ring == detail == repo consumption; refund/excluded/currency identical; `4dc0d190` (Batch 3). Device UI spot-check external |
| MALI-050n | High | C | P4 | Code complete · Locally verified | Home category totals sourced from canonical `categoryBreakdown` (refund netting, status, excluded-account, half-open month); cannot disagree with the adjacent budget chip for the same scope; bespoke `getAll()` fold removed; `2052687d` (Batch 2). Provider is not currently UI-wired (dropped by the Calm-Capital redesign) — closed at the provider tier to hold the invariant. Device UI spot-check external |
| MALI-051n | High | C | P3 | Code complete · Locally verified | durable parked_child_rows + drain; cursor never skips; `acf9ca99` (batch 1) |
| MALI-052n | High | C | P3 | Code complete · Locally verified | outbox coalescing/re-basing `d6820285` (batch 2) + universal conflict policy/resolver for all 12 entities `de672bc0` (batch 3); live 2-device = external |
| MALI-053n | High | C | P2 | Code complete · Locally verified | flush now covers child + smart-inbox + notif-log + sender-mapping outboxes; `374560ff` |
| MALI-054n | High | C | P2 | Code complete · Locally verified | native+file residue purge on every destructive path; fail-closed admission; `374560ff`. Device execution = gate 6/9 (external) |
| MALI-055n | Med | C | P3 | Code complete · Locally verified | dedicated default-account command (no broad rewrite; stale device can't roll back fields) + guarded accounts update (base token now carried); `58614ad4` (batch 4) |
| MALI-056n | Med | C | P3 | Code complete · Locally verified | versioned canonical payload (v2) + documented compatibility + future-version dead-letter; `124fd83b` (batch 4) |
| MALI-057n | Med | C | P3 | Code complete · Locally verified · **live CAS external-pending** | pull/push base compare + universal per-entity policy; `de672bc0`/`0e52da68` (batch 3) |
| MALI-058n | Med | C | P6 | Code complete · Locally verified (device-external) | **P6-B1.** Root defect: the DB seed copied the RAW SQLCipher key (`keyStore.readStoredKey()`) into `user_settings.db_encryption_key_ref`, which was ALSO in the backup allowlist → the raw local-DB key was serialized into every backup snapshot (recoverable from any blob decrypted with the passphrase). **Key inventory:** raw key = platform secure storage only (`money_companion.db_key`); `db_encryption_key_ref` = deprecated column (was raw key, now forced ''); Drift/backup/sync/export/telemetry/logs = no key material (sync already excluded it; exporter never touches user_settings). **Contract:** raw key device-scoped, secure-storage-only, never in Drift/backup/sync/export/logs; restore never mutates the destination key (writes through the already-open connection); backup passphrase-key ≠ DB key. **Fix:** seed + repo writer write ''; repo read never surfaces the column into the entity; excluded from the backup column allowlist; restore now filters every row to a CENTRAL column whitelist (`BackupSnapshotBuilder.restorableColumns`) — no arbitrary snapshot key reaches SQL — writes '' to the NOT NULL column, drops a legacy `db_encryption_key_ref`, and FAILS CLOSED on any other key/secret-like field BEFORE the destructive delete; idempotent post-admission cleanup (`clearDeprecatedDbKeyRef`) clears legacy values without reading them. Entity field + SQL column marked deprecated. Key-loss behavior documented (no silent delete; explicit recovery UX; `readOrCreateKey` never consults a backup). 6 real-Drift behavioral tests (seed-empty, cleanup idempotent/retryable, snapshot omits + no-canary-plaintext, legacy restores-others-not-key, unknown-key fails-closed-before-delete, cross-user isolation) + existing sync-exclusion test. No schema-version bump (idempotent repair, not a rebuild). **[B1-closure]** typed missing-key state + end-to-end isolation evidence added: `classifyDatabaseKeyState` (keyPresent / freshInstall / keyUnavailable) + typed `LocalDatabaseKeyUnavailableException`; `open()` now resolves the key state BEFORE creating/using a key — an existing encrypted DB with a MISSING secure-storage key fails with the typed state (never mints a new key, never opens with a new key, never reads a key from Drift/backup, never deletes; explicit recovery UX preserved). Four-way distinction: **missing DB key** (typed state) vs **wrong backup passphrase** (`SecretBoxAuthenticationError`, distinct) vs **corrupt DB with a key** (a present key always classifies keyPresent, never key-unavailable) vs **fresh install** (no DB + no key → normal key creation). Behavioral proofs (real Drift + spy key store): restore makes ZERO key-store calls (destination key A unchanged; foreign key B never written); missing key never falls back to backup; upload metadata fixed-schema no-canary; CSV + full-package exports no-canary; restore fail-closed error names the table not the value; telemetry sanitization drops a key canary. 15 closure tests. External: physical-device secure-storage + real encrypted backup round-trip |
| MALI-059n | Med | P+C | P2 | Code complete · Locally verified | decision implemented (default OFF, separate opt-ins, migrate-to-OFF, versioned state, device-local, restore resets); `89db9f09` |
| MALI-060n | Med | C | P5 | Code complete · Locally verified (live-backend external) | AI/paid endpoints (parse-sms, bank-discovery, enrich-merchant) no longer trust a caller-supplied install_id. Shared `_shared/ai_endpoint.ts`: server-verified identity (device secret via `verifyDevice`, else real user JWT; install_id alone → `authentication_required`), fail-closed server-side consent (AI for parse/discovery, cloud for enrich), atomic rate limit keyed on the verified identity (`bump_capture_rate_limit`), typed 13-code error envelope (no raw message/upstream body), bounded bodies + text-length caps, upstream timeouts (AbortController) + classified upstream errors, and request idempotency (0071 `claim_ai_idempotency`, payload HASH only) so a retry never double-pays. enrich-merchant merchant-name leak removed; bank-discovery logs via `safeLog`. Migration 0071 (consent cols + revoked_at + idempotency ledger + locked-down RPCs) + `set-device-consent` write path. Client sends device_secret + stable request_id + schema_version and pushes consent (iOS syncNativeState); degrades to local parse on failure. `b6c990f8`/`9bf26554`/`2aa29d60`/`3316c154`/`8dd5f1b1` (P5-B3). deno 67/0/2-ignored; migration lint PASS. **[B6-closure]** `process-ios-sms` (the legacy iOS path that predated the boundary) brought onto it: AI now gated by the SERVER-owned `ai_consent_granted` (fail-closed; `allowAi` compat-only, never overrides OFF; revoked blocks AI); body via `readBoundedJsonBody` (16KB, ignores Content-Length, UTF-8-byte-aware) + SMS/sender/schema-version limits; gate ordering (body→schema→auth→ownership→consent→quota→idempotency) before any Gemini call; metadata-only logs. `readBoundedJsonBody` deno tests + static ordering + credential-gated real-backend gates. External: live migration apply + RPC concurrency + Android consent-push + live process-ios-sms consent under 0071 |
| MALI-061n | Med | C | P5 | Code complete · Locally verified | notification identity now derives from a stable business key (`notificationEventId`/`achievementNotificationId`), not mutable display text/hashCode (achievement + review ids fixed); gamification/capture already route through `_show` (the local policy gate: per-type enabled + quiet hours). Budget dual-authority coordinated: local app is primary; evaluate-budgets advances the notified watermark but pushes only as a fallback when no device is recently active (`anyDeviceRecentlyActive`). Phase-3 gamification authority preserved; 0070 engagement authority stays dormant. `1e217ce3`/`5b2c771b` (P5-B4). [B4-closure] Closure: explicit `CaptureNotificationAuthority.shouldShowLocalReview` (payload-id identity; APNs-sent suppresses local; lost APNs response never suppresses both; replay/owner-invalid blocked) wired into the drain + 5 behavioral tests (`c3ffc673`). **[B6-closure]** authority matrix completed: goals + achievements now local-primary/server-fallback (server pushes only via `anyDeviceRecentlyActive`); streak + bill server cron push RETIRED (scheduled-local is the sole authority — `anyDeviceRecentlyActive` can't coordinate a scheduled notification); captureLight id now from a generated-before-notify stable key (txn id or immutable content fingerprint) via `notificationEventId`; budget `showBudgetAlert` `notifId` now REQUIRED (text-hash fallback removed); `_safeId` orphan removed. No type is "may duplicate". 6 stable-id tests + coordinated-fallback contracts. Live two-path device delivery + two-device fallback timing external |
| MALI-062n | Med | C | P4 | **Closed · locally verified** | Saturday-week fixed (B1); the three divergent weekly/budget-period resolvers unified into one canonical resolver + Saturday-anchored history (B3); the per-period history transaction LIST nets to its total (B4). Week definitions, budget periods, and history list-vs-total parity all verified. Device UI spot-check external |
| MALI-063n | Med | C | P4 | Code complete · Locally verified | PDF donut center/slices/appendix scoped to the primary currency (per-currency `categoryBreakdown`), never a cross-currency sum; exponent formatter (0/2/3); dormant 0030 RPCs + Supabase-summary flags retired (no switch to re-enable pre-canonical totals); `989f6614`/`174ed4c3` (Batch 4). Live PDF render spot-check external |
| MALI-064n | Med | C | P4 | Code complete · Locally verified | one attribution contract — `bill_payments` authoritative, a linked payment counts once (double-count gone), fuzzy match demoted to a non-authoritative link suggestion; one canonical `monthlyEquivalent`/`annualEquivalent`/`subscriptionMonthlyTotal` unifying the three divergent formulas; `d5d1605b` (Batch 4). Device UI spot-check external |
| MALI-065n | Med | C | P5 | Code complete · Locally verified (device-external) | one `ManagedExportStore` for every export temp file (report PDF / CSV / full-data package): opaque, data-free on-disk names; iOS `NSFileProtectionComplete` + backup-exclusion via a new `mali/export_protection` channel (Android no-op — FBE + `allowBackup=false`); delete on success/cancel/failure (idempotent + retry); startup delete-all + resume bounded-lease sweep (corrupt-metadata / orphan-sidecar tolerant); NO clipboard fallback for full ledger/package (dead `data_export.dart` removed); 9 behavioral filesystem tests + iOS simulator build. `2d1072f6` (P5-B2). Device file-protection/backup-exclusion attributes external |
| MALI-066n | Med | C | P7 | **Partially addressed · Locally verified** | **P7-B1.** The CI-visibility gap for the suites now IN the canonical gate is closed and proven mandatory by a static contract (`ci_gates_contract_node_test.mjs` asserts each is wired; it would fail if a step were dropped): admin authorization tests (gate 7), Deno `_shared` tests + Deno lint (gate 2), Node contract tests (gate 5), skip/ignore manifest (gate 6), migration lint (gate 1), l10n freshness (gate 8) — all run identically local + CI, no CI-only subset. **Still open:** per-Edge-function test dirs beyond `_shared/` and `verify_ios_packaging.sh` are not yet gate steps. |
| MALI-067n | Med | T | P7 | Not started | source-text tests, no-close, warning suppression |
| MALI-068n | Med | C | P5 | Code complete · Locally verified (device external) | native-storage portion done (P5-B1): Android durable-queue writes synchronous (`commit()`, enqueue/ack durable before return) `5c88417c`; iOS aux notification-route/log queues now under the shared `withQueueLock` cross-process lock `30b4f3fc`. Batch-4 native tail (P5-B4 `8337202e`): SMS receiver stamps the SMS's native `timestampMillis` (not receiver-run time), Item carries authoritative `receivedAtEpochMs`, corruption clear now `commit()`; Dart `resolveCapturedReceivedAt` prefers epoch, ISO string legacy-only, unknown→null (never `now`); exact-alarm permissions removed (reminders use inexact). Static-reviewed + Dart/manifest-contract tests. EXTERNAL: Android compile, receiver process-death replay, alarm delivery, on-device timestampMillis + reboot | [B4-closure] Closure: silent-`now` gap FIXED — `CapturedMessage.receivedAt` nullable, drain no longer stamps `now`; behavioral tests (real Drift occurredAt: SMS-date authority, real receivedAt used, null→documented fallback) + file-backed native-queue LEASE test (peek≠ack, failed-handle-retries-after-restart, crash-after-commit idempotent) (`d72e5785`). Ack-failure idempotent-replay already in capture_sync_service_test |
| MALI-069n | Med | C | P6 | Code complete — locally verified; native SQLite contention timing and platform-specific lifecycle behavior pending | **P6-B4 — DB connection lifecycle, failed-init cleanup, concurrent same-file access.** Three root defects fixed: (1) **connection leak** — `open()` awaited `initialize()` and, on failure, left the native `createBackgroundConnection` + its background isolate ALIVE (leak); now `_finishOpen` closes the connection/isolate on ANY init failure (best-effort, NEVER masking the original typed error — verified: the original StateError propagates), marks `failed`, and rethrows. No key rotation, no file deletion (preserves Batch-1 key-state distinctions). (2) **no busy_timeout** — the centralized `_openEncryptedConnection` PRAGMA contract (cipher→verify→key→prove→foreign_keys) now also sets `busy_timeout=5000` on EVERY production connection, so a background second connection racing the main one waits (bounded) instead of failing immediately with SQLITE_BUSY. (3) **second-connection concurrency** — the two same-file second connections (background capture-import `captured_message_processor` + the notification-action background isolate `local_notification_service`) called `AppDatabase.open()` which ran the FULL migration pipeline; they now use `AppDatabase.openSecondary()` (`runMigrations:false`): same key + PRAGMA contract, NO concurrent migrations, bounded try/finally close. Added: typed `DatabaseLifecycleState` (opening/open/closing/closed/failed), an **idempotent `close()`** that waits for in-flight init to settle before teardown (concurrent close shares one teardown), and a `runExclusiveMaintenance` lifecycle primitive (§10, for Batch-5 restore) that serialises + marks maintenance + clears the flag on failure. 8 real-Drift lifecycle tests. **[B4-closure] the flag-only maintenance boundary is now an ENFORCEABLE gate:** (1) a borrow/lease model — `borrow<T>()` is REJECTED (typed `DatabaseLifecycleException`) after close/failed/recovery and QUEUED while maintenance holds the gate; `runExclusiveMaintenance` transitions to `maintenanceRequested`, DRAINS active borrows with a bounded `drainTimeout` (→ typed `maintenanceTimeout`), runs the action, restores `open` on success, restores the prior usable state on a recoverable failure, and exposes the typed `recoveryRequired` state on an unrecoverable one (never publishing a partial DB); serialised; cleanup never masks the original error. (2) secondary admission — `admitsSecondary` (open && !maintenance); `openSecondary({owner})` is refused (typed) unless the owner is usable (the two production paths run where no owner is in-memory-accessible, so their admission is file-level: key-state gate + shared PRAGMA/busy_timeout + no-concurrent-migration — documented). (3) typed busy taxonomy — `mapDatabaseBusy` maps SQLITE_BUSY(5)/LOCKED(6) (+261/262) to a retryable `DatabaseBusyException` (never the raw text; non-busy never misclassified); `runWithBusyRetry` retries bounded then throws the typed error, never inside a transaction, no reset/rotate. (4) stream/provider ownership — `appDatabaseProvider` is an OVERRIDE HOLDER (no provider closes the DB; main/bootstrap owns it), so a non-owning `ProviderContainer` disposal leaves the DB open (tested), and closing with a live Drift watcher completes cleanly (no use-after-close, tested). +15 closure tests. **[B4-closure-2] the in-memory gate is now CROSS-ISOLATE.** Dart's `RandomAccessFile.lock` is POSIX-fcntl (per-PROCESS) so it can't coordinate same-process background isolates; replaced with a filesystem lease: an ATOMIC maintenance-intent marker (`File.create(exclusive:true)`, stale-recovered by age) + a REGISTRY of per-secondary lease files (created on acquire, deleted in `finally`). `openSecondary({leaseManager})` acquires a SHARED lease (held for the connection's lifetime, released on close) and is REFUSED while intent is active; `runExclusiveMaintenance(mode: fileExclusive, leaseManager)` publishes intent (refusing new secondaries), drains in-memory borrows AND every secondary lease (bounded → typed timeout), then runs — the file-exclusive contract Batch-5 restore/reset uses. The two production secondary paths (`captured_message_processor` background import + `local_notification_service` notification isolate) now pass `AppDatabase.appSupportLeaseManager()`. Proven with a REAL `Isolate.spawn` test (a shared lease in another isolate blocks exclusive maintenance). Cross-isolate ownership generation (`OwnershipGuard`, reusing the Phase-2 secure-storage owner UID): a background job captures the owner at creation + re-checks before commit; sign-out/wipe/ownership-change aborts the old-user job (no leaked previous-owner rows, tested). +15 more closure tests (7 lease + 8 integration/ownership/watcher). **[B4-closure-3] two correctness fixes.** (a) **Ownership is now an ADMISSION GENERATION, not UID-only.** A UID alone cannot reject a previous session of the SAME user (`A→signout→A`, or `A→B→A`). Phase-2 admission (`AppSession`) now also stores a cryptographically-random generation nonce (`local_data_owner_generation`, `Random.secure()`): minted on every genuine (re-)admission, invalidated BEFORE the sign-out purge / wipe / ownership change — so it rotates even when the same UID signs in again. `OwnershipGuard` binds a background job to `{ownerUid, generation}` (an `AdmissionToken`, no secret/financial content) and re-validates at all 5 boundaries — before the lease, before the secondary open (both inside `openSecondary`, typed `StaleOwnershipException`), before the Drift commit, before the native acknowledgement, and before any notification. Both production isolates capture the token and abort a superseded session without committing/acknowledging/notifying. (b) **Leases/intent are RENEWABLE (heartbeat + fencing), not fixed-age.** Each lease and the intent carries a unique fencing token and a heartbeat (a periodic sub-second mtime bump via file rewrite — `setLastModified` truncates to whole seconds on macOS, too coarse); liveness/expiry is measured from the LAST heartbeat, so a long restore / paused device / forward clock jump can never false-reap live work. Stale recovery only after the heartbeat stops past the ttl AND a re-verification (unchanged token+mtime); cleanup is token-matched (an older holder's cleanup can't remove a newer lease/intent); a killed isolate just stops beating → recoverable after ttl, never a permanent lock. (c) **The shared-acquire vs maintenance-intent race is closed:** shared acquisition is TWO-PHASE (create lease → re-read intent → back off if it appeared), and maintenance publishes its fenced intent then requires a STABLE-ZERO settle so a lease created concurrently with the last drain check (which self-deletes on its own intent re-read) is waited out before destructive work. `runFileExclusiveMaintenance` is the single Batch-5 primitive (admission-validated → drain borrows → fence intent → drain every shared lease → callback quiesces/reopens → recoverable restores / unrecoverable → recoveryRequired). Deterministic real-isolate tests: both race windows, "maintenance never enters while a live shared lease exists", 14-round cross-isolate zero-overlap hammer, long-op-survives-heartbeat, crashed-holder recovery, fencing, typed bounded timeout, no leaked timer/file. +30 more closure tests (12 lease + 15 integration/admission/watcher + AppSession rotation, superseding the closure-2 count). **[B4-closure-4] heartbeat/mtime REMOVED as the stale-recovery authority; Contract B (single-process) proven and enforced.** A process-access inventory (docs/PROCESS_ACCESS_INVENTORY.md) proves exactly ONE OS process (the Flutter host app) ever opens the DB: no native code references sqlite/sqlcipher/sqlite3mc; the iOS Share extension + App Intents are pure-native and stage to the App Group/UserDefaults+Keychain (no Flutter engine → the `sqlite3mc`/Drift Dart plugin can't load there); Android declares no `android:process`; the two secondary paths are same-process background isolates. New authority model: (a) the authoritative lease/intent record is IMMUTABLE + written atomically (temp-file + rename → readers never see partial content) and carries only a fencing token, owner pid, and instance token; liveness = record EXISTENCE, never age. (b) RUNTIME maintenance NEVER reaps — it waits for holders to release with a typed BOUNDED TIMEOUT; a live-but-blocked/paused isolate keeps its lease → timeout (safe), never corruption; uncertain liveness never authorizes deletion; no wall-clock/mtime decision exists so clock jumps/suspension are irrelevant. (c) the ONLY reaping is STALE-FILE RECOVERY at process start, gated by a process-lifetime OS advisory lock (`DatabaseProcessLiveness`): a starting process that acquires the exclusive lock has proof prior instances ended, so it clears leftovers tagged with a DIFFERENT owner pid (pids unique among live processes); current-pid live leases are never cleared. Enforcement + Process.start tests: a Contract-B source scan (no extension/native Drift import, no `android:process`, DB opens confined to the 3 approved Dart sites) + a REAL `Process.start` proof (a live external process holding the OS lock is NOT reaped; after SIGKILL its leftover is recovered and a new instance token minted). +10 more tests (5 liveness incl. Process.start + 5 Contract-B enforcement). External (device-only): native SQLite contention timing + platform-specific lifecycle |
| MALI-070n | Low | C | P2 | Code complete · Locally verified | pending-actions file purged on destructive paths; `374560ff`. Announcement-dismissal residue = minor, remains backlog |
| MALI-071n | Low | C | P5 | Code complete · Locally verified | merchant logos gated on cloud-processing consent (fail-closed while loading/errored/unset) — OFF/revoked = ZERO outbound requests (bundled SVG or letter placeholder only); data-minimization ladder made explicit: bundled SVG → (consented) catalog `logoUrl` → logo.dev by verified PUBLIC DOMAIN (never raw merchant text) → placeholder; no prefetch path (`registerBrandLogos` is asset-only); `BrandMark`→`ConsumerWidget`; 4 widget tests assert no `Image` widget with consent OFF even given a `logoUrl`. `08e7ca0d` (P5-B2) |
| MALI-072n | Low | C | P3 | Code complete · Locally verified | durable sender-mapping sync: keyset pagination + server-authoritative updated_at + durable cursor + tombstone deletion propagation + LWW (pending-safe) + typed error classification (no string-match); soft-delete replaces hard delete; `96993c5e` (batch 5). Live two-device = external |
| MALI-073n | Low | C | P7 | **Code complete · Locally verified** | **P7-B2.** Evidence-backed (`EXPLAIN QUERY PLAN` before/after) hot-path indexes: composite `idx_transactions_account_occurred (account_id, occurred_at)` (subsumes single-column account_id + serves `account_id=? ORDER BY occurred_at` without a temp sort) + single `idx_transactions_category_id`. Baseline account/category queries full-scanned; both now SEARCH via index. Additive read accelerators only; version-owned (schema v29, postflight-verified). `query_plan_test.dart` + `schema_v29_migration_test.dart`. |
| MALI-074n | Low | C | P4 | Code complete · Locally verified | report decimals (B4); exact account ownership (no null-account-by-currency), per-currency net-spend card summaries (refund-netted, income-only, exponent formatter), authoritative installment paid-count from the ledger (B5 `a25a75c7`/`0f86fb7c`/`1fc89450`). Device UI spot-check external |
| MALI-075n | Low | C | P5 | Code complete · Locally verified (live-backend external) | logging/privacy portion (P5-B2 `0010b037`) + backend lows (P5-B5, migration 0072, undeployed): (a) SD search_path — the only two functions lacking a fixed path fixed (dead `handle_new_user` dropped; `prune_processed_captures` recreated with search_path + re-locked); a precise per-function audit confirms all others already had one. (b) Metrics ingestion — `with check (true)` free-for-all authenticated insert removed + INSERT revoked; owner-bound (auth.uid()) `record_metric` RPC with event allowlist, length bounds, atomic per-user daily quota (deny-all `metrics_rate_limits`), no PII stored; client routes through the RPC. (c) Purge coverage — `purge_user_data` extended to AI idempotency (owner_key), engagement, and metrics-quota rows in FK-safe order. `4e927db5`/`975af849` (P5-B5). Live RLS/RPC/purge under real Postgres external |
| MALI-076n | Low | C | P6 | **Backup-envelope portion Code complete · Locally verified** (device-external); other lows not started | **P6-B2 — versioned authenticated backup envelope.** Root gaps: the v1/v2 blob header (version/kdf/cipher/salt/nonce) was UNAUTHENTICATED and the algorithm fields DECORATIVE (decrypt hardcoded AES-GCM/Argon2id, ignoring them); no magic; no resource limits on blob-declared lengths; `enable()` silently `.trim()`-ed the passphrase. **New v3 envelope:** magic `MALIBAK`, `envelopeVersion:3`, `schemaVersion`, `cipher:aes-256-gcm`, `kdf:argon2id` + `kdfParams{memory:65536KiB,iterations:3,parallelism:2,hashLength:32}`, `compression:none` — all bound as AES-GCM **AAD** to the payload AND every slot (a modified header/param/id fails auth before any restore mutation). Content-key + password/recovery slots preserved (slot AAD excludes schemaVersion so stored slots survive a schema bump). **Resource limits** (memory 8–256 MiB, iters 1–10, parallelism 1–4, salt 16–64B, nonce=12B, ciphertext ≤64 MiB, ≤8 slots, blob ≤96 MiB) enforced BEFORE the KDF. **Passphrase:** exact UTF-8, no trim, no normalization, case/whitespace significant (v3; legacy keeps historical trim). **Typed `BackupEnvelopeException`** taxonomy (unsupportedVersion/malformed/unsupportedAlgorithm/unsafeKdfParams/payloadTooLarge/authenticationFailed/incompatibleSchema/decodeFailed) — distinct from `LocalDatabaseKeyUnavailableException`; wrong passphrase/tamper/corruption share one message (indistinguishable). Restore: `fromBytesChecked` (validate+limit) → decrypt/authenticate → Batch-1 whitelist/preflight → destructive. Writes v3 only; reads v1/v2/v3. 22 crypto/compat/limit/privacy tests. **P6-B3 — remote-backup state/publication portion Code complete · Locally verified (live-backend external):** typed `RemoteBackupState` machine (16 states; only `enabledIdle`=Protected, so the UI can't claim protection before a verified commit) + `RemoteBackupErrorKind` taxonomy + bounded exp-backoff retry policy (offline pauses without burning an attempt; terminal≠retryable). **Safe generation publication** (`RemoteBackupPublisher` over an injectable `RemoteBackupStore`): each backup writes to a UNIQUE per-generation object path, size-verified, then a compare-and-set pointer commit, then the previous object is retired ONLY after commit — so an interrupted upload can NEVER replace the last valid backup (was: `upsert=true` overwrite of a single `backup.enc`). **Verified download** (size + encrypted-blob SHA-256 before decryption; hash is transport-only, not a substitute for v3 AEAD auth). **Lost-response idempotency** (same generation id → no duplicate upload). **disable() is now stop-only**; remote deletion is a separate explicit `deleteRemoteBackups()` (§3 no longer silently combined). Migration **0075** (additive, undeployed): generation_id/blob_sha256/operation_id/status/committed_at on `backups`; ownership already server-enforced (owner RLS + storage `<uid>/` folder RLS). `SupabaseRemoteBackupStore` adapter wired into `backupNow`/`restore`. 28 new tests (domain 11 + publisher 12 + contract 5). **[B3-closure] the four remaining production contracts are now implemented:** (1) **truthful UI/provider state** — `RemoteBackupController` (StateNotifier) drives the backup screen; the label/icon derive from the typed state so "محمي/Protected" shows ONLY for `enabledIdle` (a committed+verified generation), never on local-encryption/upload-only; refresh reconstructs from remote truth; sign-out resets; one operation coordinator (busy-mutex) serialises manual/auto so no duplicate generation; consent-gated. (2) **server-atomic generation CAS** — migration **0076** `commit_backup_generation` (SECURITY DEFINER, fixed search_path, PUBLIC/anon revoked, authenticated only): derives owner from auth, verifies owner-scoped object path + byte size from storage.objects, FOR UPDATE row lock, rejects stale expected-generation, idempotent-replay of the winning operation, one transaction, retains previous generation — the adapter now commits via this RPC and maps server errors to the typed taxonomy. (3) **trigger coordination** — audit found NO automatic background triggers (backup is manual + enable only); both route through the coordinator with a consent gate + serialization + sign-out reset (documented: no unsupported background framework added). (4) **retention/pruning** — publisher keeps current + one previous known-good, prunes the 2-back only after the replacement commits, and `pruneOrphans` clears abandoned staging; `deleteRemoteBackups` is the explicit delete; account purge covered. +18 closure tests (controller 8, retention/prune 2, contract 3, live-harness 4 skip, +1). **Credential-gated live Supabase Storage/RLS/CAS harness exists** (`remote_backup_live_node_test.mjs`, skips honestly). External: live Supabase round-trip + two-device conflict + device. (`hasRemoteBackup`/dead-export/other lows remain.) **[P6-B5] restore-side portion Code complete · Locally verified:** the verified committed-generation download (`downloadVerified`: size + encrypted-blob SHA-256 before decryption) now feeds the two-phase restore pipeline (see MALI-014 [P6-B5]) — preparation validates + builds the immutable plan before the maintenance gate; mutation runs through the file-exclusive primitive with in-transaction verification + atomic rollback + typed outcomes + operation-ID replay. Remote integrity re-verification and committed-vs-staging rules are unchanged (Batch-3). **[P6-B5-closure]** the operation-ID replay is now DURABLE (a `restore_operations` journal committed atomically with the restored data; a crash/ack-loss cannot replay a destructive restore), preparation-time per-version snapshot adapters (v1/v2/v3) run before mutation, complete rollback fault-injection + full-DB digest, local crash/replay tests, and a truthful restore UI state machine. → **Code complete · Locally verified; native process-kill timing, SQLCipher hardware round-trip, and device UI verification pending.** |
| MALI-077n | Low | C+P | P7 | Not started | ops lows (keystore name, email, dead API, package path) |

## Phase roll-up

| Phase | Findings | Status |
|---|---|---|
| P1 migrations/restore | MALI-046n/027, MALI-045n/014 | **Code complete · Locally verified** (full suite 1003; awaiting approval) |
| P2 lifecycle/consent | 053n,054n,070n,011,017,001,059n | **Code complete · Locally verified** (full suite 1015; commits 374560ff + 89db9f09; awaiting approval) |
| P3 sync | 051n,052n,055n,056n,057n,008,009,010,022,023,024,072n | **LOCALLY COMPLETE** (live/2-device pending) — all 6 batches committed: B1 051n (acf9ca99), B2 052n/023 (d6820285), B3 022/057n/052n revision-CAS+resolver (4a2da692/de672bc0/0e52da68, **live CAS external-pending**), B4 055n/056n/009/010 (58614ad4/124fd83b), B5 072n/008 + 024 (96993c5e/74a77398), B6 closure docs. MALI-023 Closed-LV; all others CC-LV (external tail). Gamification single-authority overlap proof: no overlap (Edge active, RPC dormant) — see `PHASE_3_SYNC_CLOSURE.md` §2. |
| P4 financial | 047n,048n,049n,050n,062n,063n,064n,074n,018,028 | **CLOSED · locally verified** — B1–B6 complete. 018/028/062n Closed · LV; 047n/048n/049n/050n/063n/064n/074n Code complete · LV (documented device spot-checks remain). Spec `PHASE_4_FINANCIAL_SEMANTICS.md`. Full suite 1179; analyze 0. Verdict: code+automated closed locally, device/PDF/UI external-pending |
| P5 security/notif/native | 031,032,033,060n,061n,065n,068n,071n,075n,019,025,044,039 | **Phase 5 code complete — locally verified; external verification pending.** All 6 batches committed: B1 native storage (031/033/068n `5c88417c`/`30b4f3fc`), B2 telemetry/logging/exports/logos (032/065n/071n/039/075n-logging `bff0f1d8`/`2d1072f6`/`08e7ca0d`/`0010b037`), B3 AI endpoint auth (060n `b6c990f8`+), B4 notification authority (061n/019/025/068n-tail `1e217ce3`/`224394fd`/`9128589e`/`8337202e` + closure `f7cbe727`/`c3ffc673`/`d72e5785`), B5 backend/RLS/metrics/purge/gamification (075n/044/024 `4e927db5`/`6ddd5aaa`/`975af849` + closures `9fdd30e7`/`c4f2aea0`/`ae1f967b`), B6 closure docs. MALI-071n Closed·LV; all others Code complete·LV (external tail). Authoritative spec: `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md`. Migrations 0068–0074 undeployed; `kServerRevisionCas=false`; 0070 authority inactive. External: signed-device, Android, APNs, store-policy, live-Postgres |
| P6 backup/DB/reliability | 058n,069n,073n,076n | **Batches 1–2 in progress.** B1 MALI-058n (SQLCipher key + backup-schema hygiene) Code complete · Locally verified. B2 MALI-076n backup-envelope portion + MALI-014 format-compat (versioned authenticated v3 envelope: magic, header-AAD, Argon2id params + resource limits, explicit passphrase bytes, typed errors, v1/v2/v3 read, v3-only write) Code complete · Locally verified (device/cross-platform external). B3 MALI-076n remote-backup portion + MALI-014 remote reliability Code complete · Locally verified. B4 **MALI-069n (DB connection lifecycle + failed-init cleanup + concurrent same-file access) Code complete · Locally verified**: failed-init closes the connection/isolate (no leak, original error preserved); centralized busy_timeout=5000 PRAGMA; second connections use openSecondary (no concurrent migrations); typed lifecycle state + idempotent close + maintenance primitive. B5 **MALI-014 restore + MALI-076n restore-side + MALI-069n/027 lifecycle integration Code complete · Locally verified**: two-phase preparation/mutation restore pipeline (immutable plan, in-transaction verification + atomic rollback, admission-validated file-exclusive maintenance, typed result taxonomy, operation-ID replay guard). Batch 6 (formal closure) not started. 073n not started |
| P7 CI/test/arch/docs | 066n,067n,029,030,034,035,037,038,040,041,042,043,077n,036-limits,021-deadfile | Not started |
| P8 MALI-026 | 026 | Not started (blocked on P1) |
| P9 external validation | 12 gates (002,003,004,005,006,012,013,017,019,020,022,036) | Not started |

Decision-required (await explicit product approval): **MALI-059n** (consent default),
**MALI-043** (canonical brand name). These are surfaced, never silently decided.

## Batch 4 delivered contracts (MALI-055n / 056n / 009 / 010)

### Account default-command contract (MALI-055n)
- Changing the default is ONE dedicated command — `account_default_command`
  (outbox entity type), payload `{target_local_id, operation_id}`, NO account
  field payload — resolved on push to the atomic `set_default_account` RPC
  (demote old + promote new in one server transaction).
- A default switch queues **zero** account field rows, so a stale device can
  never roll back an unrelated remote rename/type/currency edit.
- Successive switches coalesce to one command (singleton key `__current__`);
  latest target wins. Create-as-default and delete-successor route through the
  same command. Create/update no longer apply the default via `is_default`.
- Delete additionally queues a **guarded** update of the successor only (so it
  exists server-side for the command to resolve); guarded (Batch 3C) → conflicts
  instead of clobbering.
- Push order: field syncs before commands (target established first); an unsynced
  target defers (`missingDependency`). RPC is idempotent → replay/crash-after-
  acceptance safe; concurrent switches = deterministic last-RPC-wins; exactly one
  active default after every path; capability OFF and ON both resolve via the RPC.

### Versioned canonical ledger payload (MALI-056n / 009 / 010)
- `payload_version = 2` (`lib/features/capture/services/ledger_payload.dart`).
- Outbox payload carries `payload_version` + `canonical_type/source/direction`
  (legacy `type` retained for downgrade safety).
- Push writes the coarse server columns AND round-trips the exact client
  type/source/direction through the server `metadata` JSONB.
- Pull recovers the exact meaning from canonical metadata (authoritative);
  older rows use the documented compatibility rule below.

**Enum mapping table**

| client type | server transaction_type | server direction (derived) | pull recovery (v2 canonical / v1 coarse) |
|---|---|---|---|
| payment    | expense  | debit   | canonical→payment / expense→payment |
| withdrawal | expense  | debit   | canonical→withdrawal / (v1 indistinguishable → payment) |
| income     | income   | credit  | income→income |
| refund     | refund   | credit  | refund→refund |
| transfer   | transfer | unknown | transfer→transfer |
| unknown    | unknown  | unknown | canonical→unknown / adjustment·unknown·future→unknown (**never payment**) |

- **Historical compatibility:** a payload with no `payload_version` is treated as
  v1 and pushes via the legacy `type` mapping. A pulled server row without
  canonical metadata uses the coarse rule above — legacy `expense`→payment, and
  any unmapped/future category → `unknown`, never silently payment/expense.
- **Future safety:** a payload written by a newer app (`payload_version` beyond
  this build) dead-letters as `unsupportedSchema` (re-armable after upgrade); an
  unrecognised canonical enum NAME falls back to the coarse column, never trusted
  verbatim.

### Local verification (Batch 4)
`flutter analyze` clean; new tests: account_default_command_test (10),
ledger_payload_test (21), ledger_roundtrip_test (18). Full suite green (see
Batch-4 report). No schema/backend change in Batch 4; capability `kServerRevisionCas`
stays **false**.

## Batch 5 delivered contracts (MALI-072n / 008 / 024)

### Sender-mapping sync contract (MALI-072n / 008)
- **Pagination:** stable keyset by `(updated_at, id)` with a durable cursor
  advanced atomically per page; `updated_at` is server-authoritative (0069
  trigger) so it is monotonic across devices and the keyset never skips a row.
- **Tombstones:** `deleted_at` (local + server, migration 0069) propagates
  deletions both ways; a hard delete is replaced by a soft-delete; re-suggesting
  a sender un-tombstones it (explicit recreate).
- **Conflict policy:** server-authoritative-timestamp LWW that never overwrites a
  locally pending change (it is pushed and wins) and never applies an older
  remote snapshot.
- **Typed errors:** `classifyOutboxError` replaces string-matching. A natural-key
  duplicate is resolved by the upsert; any error reaching the handler (unrelated
  unique-constraint, validation, auth, server, unsupported schema, network) marks
  the item failed for bounded retry and never falsely resolves it.

### Gamification single-authority contract (MALI-024)
- **Server authority:** migration 0070 adds `user_engagement_events`
  (owner-bound idempotency: `UNIQUE(user_id, event_id)` + partial unique
  `(user_id, business_key)`) and the locked-down `record_engagement_event` RPC
  (SECURITY DEFINER, fixed search_path, revoked from PUBLIC / granted
  authenticated, `user_id` from `auth.uid()`). The server validates the event
  type + version and decides the award; the client cannot submit an XP total.
- **Idempotency:** duplicate `event_id`/`business_key` awards nothing; the
  aggregate UPSERT is row-locked so concurrent events cannot lose an increment.
- **Client:** durable `engagement_events` outbox (event_id idempotency, bounded
  retry/dead-letter, business-key dedup); exactly-once submit; the client
  aggregate-total upload is REMOVED (tamper vector gone) — `GamificationSyncService`
  is pull-only. Displayed state = acknowledged server aggregate + projection of
  pending events (unknown types project 0 — no invented award).
- **Event schema:** `{event_id, event_type, occurred_at, business_key?,
  event_version}`; supported types → award: transaction_confirmed 10,
  goal_contribution 15, budget_action 5, bill_payment 5, streak_activity 2;
  unknown/future type or version → rejected (dead-letter), never awarded.
- **Compatibility:** additive migration; transaction-driven awards continue via
  the existing evaluate-gamification Edge Function; per-domain-action event
  enqueue is added as each action migrates off that path (avoids double-award).

### Batch 5 local verification
`flutter analyze` clean; new tests: sender_bank_mapping_sync_service (11),
engagement_event_service (12), gamification_sync_service (rewritten, pull-only);
migration lint PASS (70 files, 14 SECURITY DEFINER); node contract 5 pass / 13
skip / 0 fail. Full suite green.

### Batch 5 external / two-device acceptance (still pending)
- Live two-device sender-mapping keyset/tombstone round-trip on a real backend.
- Live `record_engagement_event` RPC verification: idempotency, ownership
  (`auth.uid()`), atomic concurrent increments, unknown-type/version rejection,
  unauthenticated rejection (credential-gated node contract test).

## Batch 4 external / two-device acceptance criteria (still pending)
- Live `set_default_account` RPC round-trip on a real backend; two-device
  concurrent default switch converges to one default with no field rollback.
- Two-device ledger round-trip on a real backend confirming withdrawal/refund/
  unknown/source/status survive without conversion.
- Live revision-CAS activation (MALI-022) remains blocked on migration 0068
  staging apply + real Postgres concurrency tests before `kServerRevisionCas` may
  be flipped.

## Phase 4 Batch 2 delivered contracts (MALI-047n / 050n / 018-provider / 028-boundary)

### Canonical aggregate APIs
- No new repository methods or signatures. The two surfaces route through the
  existing canonical aggregates (`expenseTotalBetween`, `incomeTotalBetween`,
  `categoryBreakdown`, `currencyTotalsBetween`) — production UI always reads the
  Drift-routed repository.
- **Date boundary (MALI-028):** all seven canonical aggregate methods now use
  half-open `[from, to)` (`occurred_at >= from AND occurred_at < to`) instead of
  inclusive `BETWEEN`, applied once in the shared aggregate SQL. The boundary
  instant belongs to the next window, never both. Boundary-safe for every
  existing caller (dashboard/reports/budgets pass an inclusive last-instant `to`
  — `now`, `end − 1ms/1s/1μs` — where no real row sits, so no live number
  changes); the fix only bites for callers passing a clean period boundary. The
  dormant Supabase summary tier keeps inclusive `BETWEEN` (flag-off, tracked
  under MALI-063n) and is out of Batch-2 scope.
- **Currency scope:** expressed through account scope (each account carries one
  currency). The all-accounts case uses per-currency `currencyTotalsBetween` and
  is never a cross-currency sum.

### Transactions-header metric contract (MALI-047n)
- `transactionsPeriodTotalProvider` → canonical **net expense**
  (payment + withdrawal − refund), **confirmed-only**, over the COMPLETE dataset
  for the visible **period × active-account** scope. Pagination-independent
  (set-based Drift, not a page fold). Transfer/unknown excluded; refund never
  counted as income; excluded-account policy applies only in the all-accounts
  case. Single-currency (the active account fixes the currency); no active
  account → base currency's own total via per-currency grouping. Free-text
  search and the list kind/category filters do **not** change it — the header
  claims the *period* expense, not the filtered subset. The amount is labelled
  with the scope's own currency.
- Not covered by this contract (unchanged, visible-list affordances, documented):
  `pendingCount` and `transactionsCount` reflect the loaded/visible list, and the
  confirm-all action operates on that list.

### Home-category metric contract (MALI-050n)
- `monthlyExpenseGroupsProvider` group totals come from canonical
  `categoryBreakdown` over the half-open current month — same refund netting,
  status contract, excluded-account policy and account/currency scope as the
  budget chip beside them (which reuses the same canonical budget math), so a
  category amount and its adjacent budget metric cannot disagree for the same
  scope. Uncategorized rows are not shown as a group (consistent with the
  Reports category ranking, which uses the same aggregate). `MonthlyCategoryGroup`
  drops the unused per-group transactions list and carries the canonical `count`.
- **UI-wiring status:** the provider is not currently rendered by any screen
  (the Calm-Capital redesign, `88475da8`, dropped its consumer). It is closed at
  the provider tier to hold the cross-surface invariant; re-wiring it to a Home
  section is a UI decision outside Batch-2 scope.

### Currency behaviour
- Grouped by currency (via account scope or `currencyTotalsBetween`); a single
  currency label is never attached to a multi-currency sum. No exchange-rate
  conversion in this batch. Batch-1 `formatMoneyAmount` remains available for
  exponent-correct display (the two headers still use `Formatters.amount`; the
  scope currency is single so this is presentation-consistent).

### Local verification (Batch 2)
- `flutter analyze` clean (0 issues); full Flutter suite **1131** (baseline 1121
  + 10 new). New tests: `financial_aggregate_boundary_test` (3 — half-open at
  exact from/before-to/exactly-to, category half-open, currency isolation);
  `financial_cross_surface_invariant_test` (7 — one-fixture agreement across
  repo/header/breakdown/Home/budget; excluded account; multi-currency isolation;
  501-row completeness; type matrix; empty; alias→stable key). Existing
  `home_sections_providers_test`/`financial_totals_invariant_test`/
  `exclude_from_totals_test`/`repository_test` remain green.
- No schema, migration, backend, or capability change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 remain undeployed.

### Batch 2 external / device acceptance (still pending)
- On-device spot-check that the Transactions header and (once/if re-wired) the
  Home category groups render the canonical values with the scope currency.

## Phase 4 Batch 3 delivered contracts (MALI-048n / 049n / 018-provider / 028-062n budget-period)

### Plan scope model (MALI-048n)
- Two explicit modes (`lib/domain/finance/plan_scope.dart`, `PlanScopeMode`):
  **allExpenses** (no account/card selected) and **selected** (one or more
  accounts/cards). All-expenses is the DOCUMENTED plan-form contract shown to
  the user ("if you don't choose an account or card, the plan counts all
  expenses in the period"), named in one place instead of scattered `isEmpty`
  checks — not an accidental empty-means-all.
- **Empty vs all-expenses:** the current data model has NO separate stored
  "unconfigured/zero" state; an empty selection has always meant all-expenses.
  This meaning is preserved exactly — no user data is reinterpreted. A distinct
  unconfigured state (empty → zero + configuration prompt) would change every
  existing empty-scope plan and requires an additive `scope_mode` column + UI;
  it is surfaced as a **deferred product decision**, not invented.
- **Membership: UNION.** A transaction counts if it matches the plan's window +
  currency + status + net-expense type AND (its account ∈ selected accounts OR
  its card ∈ selected cards OR it is manually linked). The same membership backs
  `spentForPlan` and `transactionsForPlan`, so the displayed list nets to the
  displayed total. Applies to plan progress, the plan transaction list, and any
  future notification.
- **Plan currency policy:** every candidate row (including manually-linked ones)
  must match the plan's currency — a SAR plan never sums an EGP/USD/KWD amount;
  no exchange-rate conversion. A blank currency is an invalid configuration and
  **fails closed to zero** consumption / an empty list.
- **Semantics:** net expense (payment + withdrawal − refund) via the shared
  `FinancialSql` signed sum (no raw `SUM(amount)`), confirmed-only, genuine
  half-open `[startDate, endExclusive)` window where `endExclusive` is the start
  of the day after the plan's last day (derived from the legacy `23:59:59`
  endDate with no epsilon), and the excluded-from-totals account policy for the
  all-expenses scope (an explicitly-selected account overrides it).

### Budget period + scope contract (MALI-049n / 028 / 062n)
- **One resolver:** `resolveBudgetPeriod(budget, now)` (`budget_period.dart`)
  returns a genuine half-open `[from, to)` window via `FinancialPeriod` —
  Saturday-anchored week, calendar month/year, NO epsilon end. Used by the
  dashboard ring, budget detail (`budgetsViewProvider`), the reports/alerts
  use-case (`BudgetProgressUseCase`), and the Saturday-anchored budgets-screen
  history. The yearly `−1ms` and the three previously-divergent weekly
  definitions are gone.
- **One consumption:** `budgetSpent(repo, budget, period, {fallbackAccountId})`
  — all-expenses budgets net across categories, category budgets scope to their
  category, both through the canonical aggregate (refund netting, confirmed-only,
  excluded-account policy). A budget with its own account stays account-scoped; a
  global budget falls back to the surface's active account, so the dashboard ring
  and budget detail agree for the same scope.
- **No filter leakage:** the dashboard transaction filter no longer feeds any
  budget-consumption query. A monthly budget stays monthly under a "last 90 days"
  filter; the ring equals budget detail equals the repository aggregate.
- **Boundary rule:** all new/changed budget/plan callers pass a genuine
  `toExclusive` boundary; no `end − 1ms/1μs`, `23:59:59`, or inclusive last
  instant is introduced or relied upon. The dormant Supabase summary batch-fetch
  path (flag-off) is left untouched (MALI-063n).

### Local verification (Batch 3)
- `flutter analyze` clean (0 issues); full Flutter suite **1150** (baseline 1131
  + 19 new). New tests: `plan_spending_canonical_test` (11), 
  `budget_consumption_canonical_test` (7 — resolver genuine half-open incl. leap
  day; budget detail == canonical repo and filter-invariant; excluded account);
  `financial_cross_surface_invariant_test` extended (+1 — repo == header ==
  budget detail == plan progress on one all-expenses month fixture, all 400 after
  a refund). Existing plan/budget/report/alert tests remain green.
- No schema, migration, backend, or capability change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 remain undeployed.

### Batch 3 external / product tail (still pending)
- On-device spot-check of plan progress and dashboard rings.
- **Product decision — RESOLVED 2026-08-04 (Batch 5):** empty plan scope stays
  `allExpenses`; no `unconfigured` state / `scope_mode` column / UI is added.
  Recorded under Approved product decisions above.
- Budget-history per-period transaction LIST vs net-total refund reconciliation
  (MALI-062n tail — delivered in Batch 4) and bill/subscription/PDF surfaces
  (Batch 4).

## Phase 4 Batch 4 delivered contracts (MALI-063n / 064n / 062n-tail / 074n-report / 018 / 028 + legacy retirement)

### Report currency + interval policy (MALI-063n / 074n / 028)
- The PDF report picks a **primary currency**; every currency-scoped figure — the
  donut center, slices, slice-percentage denominator, summary tiles, cash-flow,
  comparison — uses only that currency's own data. `categoryBreakdown` gained an
  optional `currency` scope; the snapshot carries `categoryBreakdownByCurrency`
  (one query per currency present), and the composer feeds the donut the primary
  currency's breakdown + `currencyTotals[primary].expense`. A single currency
  label is **never** attached to a cross-currency sum; no FX conversion.
- The appendix applies the excluded-from-totals account policy in the combined
  view, so appendix rows net to the displayed per-currency totals.
- Intervals are genuine half-open `[fromInclusive, toExclusive)`; a transaction
  at `toExclusive` is in neither totals nor appendix, one before it is in both.
  The reports-screen + dashboard previous-period bounds are genuine exclusive
  (no `−1s`/`+1µs` epsilon).
- Report money uses the Batch-1 `currencyDecimalDigits` (0/2/3 fraction digits).

### Bill-payment attribution contract (MALI-064n)
- `bill_payments` is the authoritative settled-payment ledger: **one real
  payment counts exactly once**, no matter how many representations exist
  (transaction, relation row, manual amount). `billPaidTotal` = Σ recorded
  payments + the legacy-manual residual (`max(0, manual − recorded)`). Fuzzy
  merchant-name matched transactions are **never** summed authoritatively — they
  are shown only as "suggested to link"; `linkedTransactionIds` keeps an
  already-linked transaction out of that list. The bill-details `totalPaid`
  double-count (fuzzy transactions + recorded payments) is gone.
- Refunds: reconciled by removing/reducing the corresponding `bill_payments`
  row (the ledger is authoritative); a fuzzy refund transaction is not
  auto-netted (documented).

### Subscription monthly-metric definitions (MALI-064n)
- **`monthlyEquivalent(bill)`** = the projected MONTHLY recurring obligation,
  frequency-normalized; **`annualEquivalent(bill)`** = monthlyEquivalent × 12
  exactly (weekly ×52, monthly ×12, yearly ×1, custom ×365/days). One
  normalization ended the three divergent "monthly total" formulas
  (frequency-normalized-30-day vs raw un-normalized sum) and the two annual
  conventions. **`subscriptionMonthlyTotal`** = Σ monthlyEquivalent over ACTIVE
  subscriptions, single-currency (paused/cancelled/installment excluded). The
  transactions screen and subscriptions screen now agree on this metric. The
  dashboard's auto-detected "recurring candidates" total is a **different**
  metric (heuristic detection, not saved subscriptions) and is left as-is.

### Budget-history list vs total (MALI-062n tail)
- The per-period budget transaction list mirrors the canonical consumption
  exactly (confirmed-only, net-expense types with refunds INCLUDED, half-open,
  account/category scope, excluded-account policy for global budgets), so its
  signed sum equals the net total shown beside it; refund rows are visible.

### Legacy aggregation retirement (Outcome B)
- The two hardcoded-false summary flags, the `supabaseFinancialSummaryService`
  provider, and every `useSupabaseSummary` branch (dashboard, reports,
  budget-progress) were removed — all financial surfaces compute from the
  canonical Drift aggregates; no switch remains to re-enable the pre-canonical
  0030 tier. `SupabaseFinancialSummaryService` + `SupabaseTransactionRepository`
  aggregates are documented RETIRED/DORMANT (the latter kept live only for
  `repairLocalCache()` + credential-gated contract tests). Migration 0030 is
  marked HISTORICAL (not deleted — deployed); its flag stays OFF.

### Local verification (Batch 4)
- `flutter analyze` clean; full Flutter suite (see report) with new tests:
  `budget_history_reconciliation_test` (2), `report_multicurrency_test` (3),
  `bill_metrics_test` (7), cross-surface invariant extended (+1: report snapshot/composer
  tie-in on the shared fixture). No schema/migration/backend change beyond the 0030
  historical comment; `kServerRevisionCas` stays **false**; migrations 0068–0070
  undeployed.

### Batch 4 external / device acceptance (still pending)
- Live PDF render spot-check of a multi-currency report (donut labelled per
  currency; 0/2/3-decimal). On-device bill-details paid total + subscription
  monthly metric. No live-backend dependency (the retired path is gone).

## Phase 4 Batch 5 delivered contracts (MALI-074n / 018-provider / 028-list)

### NULL-account attribution contract (MALI-074n)
- A specific account's scope is EXACT ownership (`account_id = ?`). An
  unassigned (`account_id IS NULL`) transaction belongs to no account and is
  never attributed to one because its currency matches — it appears only in the
  all-accounts scope (`accountId == null`). Fixed at the source (`_accountClause`
  → every Drift aggregate) plus the transactions list scoping and the report
  "largest transactions" builder. Assigning an orphan to an account (incl. the
  dashboard's one-time currency reconciliation) moves it exactly once; it then
  appears there because it is assigned, not by a read-time currency match. Both
  lists and totals share the exact-ownership rule so they cannot disagree.

### Account-detail contract (MALI-018)
- Account detail reads the same canonical account-scoped aggregates as the
  dashboard/transactions/reports (exact ownership, confirmed-only, refund-netted,
  excluded-account policy affects only combined totals, half-open, full-dataset
  set-based, exponent formatter). No separate account-detail fold exists.

### Card financial-metric contract (MALI-074n)
- Per (last4, currency): `totalOut` = **net spend** (payment + withdrawal −
  refund), `totalIn` = **income only** (a refund is netted into spend, never
  ordinary income), confirmed-only, transfers excluded, set-based
  (pagination-independent). `CardSummary`/`CardAccountBreakdownRow` carry
  `currency`; the grouper keys by (last4, currency) so two currencies on one card
  never merge. The card UI shows the summary's own currency with the exponent
  formatter (0/2/3 digits). Card net-spend equals the account's net expense for
  the same scope (cross-surface invariant).

### Installment paid-count contract (MALI-074n)
- The authoritative paid count is the number of DISTINCT settled installments in
  the `bill_payments` ledger for the bill's own currency
  (`COUNT(DISTINCT installment_index)` for indexed rows + one per null-indexed
  row, non-deleted, capped at totalInstallments), recomputed after every settle
  and delete — never `MAX(installment_index)` and never a monotonic counter.
  Duplicate-index rows collapse to one; deleted / foreign-currency payments never
  count; paying installment 5 alone = 1; out-of-order is safe; a payment linked
  to a transaction is one ledger row = one count.

### Remaining-fold disposition (MALI-018)
- Removed: dead `BillsView.totalDue` (raw cross-frequency/currency fold, no
  consumer). Made half-open: transactions list + dashboard recent-list date
  filters. Left as intentionally-different metrics with distinct labels: the
  dashboard "قيد المراجعة" gross pending sum (pending-review affordance), the
  dashboard auto-detected recurring-candidates total (heuristic, not saved
  subscriptions), the subscriptions "إجمالي مديونية الأقساط" remaining-debt
  projection (built on the corrected paid-count). No mixed-currency raw sum, no
  page-dependent total, and no direction-inferred expense remains on a
  user-facing Phase-4 financial total.

### Approved plan-scope decision (recorded)
- Empty plan scope permanently means `allExpenses`; no `unconfigured` state /
  `scope_mode` column / UI (Approved product decisions, above).

### Local verification (Batch 5)
- `flutter analyze` clean; full Flutter suite **1179** (B4 1163 + 16 new). New
  tests: `null_account_attribution_test` (4), `card_summary_canonical_test` (4),
  `installment_paid_count_test` (7), cross-surface invariant +1 (card tie-in);
  `repository_test` updated to the exact-ownership contract; card constructors
  carry currency. No schema/migration/backend change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 undeployed.

### Batch 5 external / device acceptance (still pending)
- On-device spot-check of account detail (unassigned rows only under
  all-accounts), card in/out/net per currency, and installment "X of N".

## Phase 4 closure reconciliation (Batch 6)

Canonical spec: `PHASE_4_FINANCIAL_SEMANTICS.md`. Phase-4 commits (17):
`71dc2534` `c4b6df97` `2052687d` `161f669f` `4fa413a9` `4dc0d190` `76423f1b`
`b702669c` `989f6614` `d5d1605b` `174ed4c3` `9e819ee0` `d2b911da` `a25a75c7`
`0f86fb7c` `1fc89450` `acb079a3` (+ this Batch-6 closure commit).

Per-finding reconciliation (defect → root cause → remediation → commits → tests →
status). "External" = a device/PDF/UI spot-check with no automated proxy; never
marked done without captured evidence.

- **MALI-047n — Code complete · Locally verified.** Defect: Transactions header
  folded loaded pages (counted pending, refund-as-income, page-dependent). Root
  cause: a second Dart aggregation tier. Remediation: `transactionsPeriodTotalProvider`
  → canonical `expenseTotalBetween`, confirmed-only, refund-netted, single-currency,
  pagination-independent. Commits `2052687d`. Tests: cross-surface invariant (501-row,
  types, statuses, boundaries). External: header render spot-check.
- **MALI-048n — Code complete · Locally verified.** Defect: plan `SUM(amount)` with
  no refund/currency/half-open. Remediation: canonical membership (half-open window,
  plan currency isolation incl. linked rows, net-expense signed sum, UNION account/card,
  fail-closed currency, list==total). Commit `4fa413a9`. Tests: `plan_spending_canonical_test`
  (11). External: plan progress spot-check. Empty scope = `allExpenses` (approved).
- **MALI-049n — Code complete · Locally verified.** Defect: dashboard ring used the
  screen filter as the budget window; ring ≠ detail. Remediation: `resolveBudgetPeriod`
  + `budgetSpent` shared by ring/detail/reports/alerts; genuine Saturday-week half-open.
  Commit `4dc0d190`. Tests: `budget_consumption_canonical_test` (filter-invariant),
  cross-surface. External: ring render spot-check.
- **MALI-050n — Code complete · Locally verified.** Defect: Home category fold, no
  refund netting, disagreed with the budget chip. Remediation: `categoryBreakdown`
  (canonical). Commit `2052687d`. Tests: cross-surface (Home==breakdown==budget).
  Provider not UI-wired (Calm-Capital redesign) — closed at the provider tier.
  External: n/a until re-wired.
- **MALI-062n — Closed · locally verified.** Defect: three weekly definitions; history
  list ≠ total. Remediation: Saturday-week (`71dc2534`); one resolver + Saturday history
  (`4dc0d190`); history list nets to total (`b702669c`). Tests: `budget_history_reconciliation_test`,
  `budget_consumption_canonical_test`.
- **MALI-063n — Code complete · Locally verified.** Defect: PDF donut cross-currency sum;
  dormant 0030 tier. Remediation: per-currency `categoryBreakdown` + primary-currency
  donut/slices/appendix; exponent formatter; retired the 0030/Supabase-summary switches.
  Commits `989f6614`/`174ed4c3`. Tests: `report_multicurrency_test`. External: on-device
  PDF render.
- **MALI-064n — Code complete · Locally verified.** Defect: bill paid double-count
  (fuzzy + recorded + manual); three monthly formulas. Remediation: `bill_payments`
  authoritative `billPaidTotal` (fuzzy = suggestion); one `monthlyEquivalent`/`annualEquivalent`/
  `subscriptionMonthlyTotal`. Commit `d5d1605b`. Tests: `bill_metrics_test`. External:
  bill-details + subscription metric spot-check.
- **MALI-074n — Code complete · Locally verified.** Defect: card gross/refund-as-income,
  cross-currency card sums, null-account-by-currency, `MAX(installment_index)`. Remediation:
  exact account ownership; per-currency net card summaries; ledger-based distinct
  installment count; report decimals. Commits `989f6614`/`a25a75c7`/`0f86fb7c`. Tests:
  `null_account_attribution_test`, `card_summary_canonical_test`, `installment_paid_count_test`.
  External: card/account/installment device spot-check.
- **MALI-018 — Closed · locally verified.** Defect: a second Dart aggregation tier
  contradicted the canonical repo predicate on multiple surfaces. Remediation: every
  provider/report/bill/card/account tier routed through the canonical aggregate/helper;
  dormant Supabase tier retired; locked by the cross-surface invariant suite (B2–B5).
- **MALI-028 — Closed · locally verified.** Defect: inclusive `BETWEEN` / epsilon ends.
  Remediation: half-open `[from, to)` for every Phase-4 interval; boundary rule enforced.
  Tests: `financial_aggregate_boundary_test` + every canonical test.

**Phase-4 closure verdict: Code complete — external verification pending.**
Phase-4 production code and all automated (Drift/provider/domain) invariants are
**closed locally**; the only remaining acceptance is device/PDF/UI spot-checks
(listed per finding above, and per batch). This item is closed; the wider program
(Phases 5–9, MALI-026, live revision-CAS activation, external validation) remains
open. `kServerRevisionCas` stays **false**; migrations 0068–0070 remain
undeployed; engagement-event authority not activated.
