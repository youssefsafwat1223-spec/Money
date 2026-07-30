# Mali — Complete Remediation Master Plan

Authoritative execution plan for resolving every actionable finding from
`FULL_APP_AUDIT.md` (MALI-001…044) and `FINAL_FULL_PRODUCTION_AUDIT.md`
(MALI-045n…077n). Live status lives in `REMEDIATION_STATUS_LEDGER.md`. Full
evidence for each finding lives in the two audit documents (preserved as history).

- **Baseline HEAD:** `e2679d0e` (feat/phase1-data-integrity)
- **Rule:** finding → implementation → test → commit → verification, traceable end to end.
- **Rule:** one shared domain contract, never per-screen patches, where a finding is systemic.
- **Rule:** never weaken security/privacy/migration/backup/ownership/financial guarantees to pass gates.
- **Decision-required (never invented):** MALI-059n (consent default), MALI-043 (brand name).

## Scope normalization — classification of every actionable finding

| Class | Findings |
|---|---|
| Code remediation | 008(periph),009,010,011,014,017,018,019,021,022,023,024,025,026,027,028,029,030,031,032,033,034,036(CI),037,038,039,044, 045n–058n,060n–069n,070n–077n |
| Test remediation | 018(invariants),032,038,040,041,042,067n |
| Documentation | 035, parts of 077n |
| Product/policy decision | 059n (consent default), 043 (brand) |
| External verification only | 002,003,004,005,006,012,013,020,036(hosted) |
| Duplicate/subsumed | 027→046n, 014→045n, 009/010→056n, 040/041/042→067n/066n, 057n→052n, 019→061n |
| Already fixed (fresh evidence, Closed) | 007,015,016 (+ core of 008/011/018/002/003/012/020) |

Findings already Verified-Closed by the independent re-audit (MALI-007, 015, 016,
and the verified cores of others) are NOT reopened; only their explicitly-listed
residual gaps are actioned under the owning `n`-finding.

---

## PHASE 1 — Migration & restore regressions (IMPLEMENTING NOW)

Two regressions that live *inside* the prior remediation. Both are local, code-only,
and fully testable without any external environment.

### MALI-046n (subsumes historical MALI-027) — migration pipeline must own `user_version`

- **Root cause:** Drift's `NativeDatabase` installs a `_SqliteVersionDelegate`
  (a `DynamicVersionDelegate`) which, during `openInternal`, stamps
  `PRAGMA user_version = schemaVersion` (27) *before* `_runInitialize` reads it
  (`drift .../engines.dart:559-562`; `sqlite3/database.dart:112`). So
  `_currentUserVersion()` always returns 27; the downgrade guard, the versioned-
  migration registry, and the v8/v9-gated compatibility repairs are all inert in
  production. Empirically proven: on-disk v10→observed 27, v999→observed 27.
- **Required remediation:** open the production database with `enableMigrations: false`,
  which installs a `NoVersionDelegate` — Drift then runs no migrator and **never
  calls `setSchemaVersion`**, leaving `user_version` exactly as on disk. The
  existing `_runInitialize` state machine (discovery → downgrade-guard → atomic
  txn → `user_version` bump last) then becomes real: it reads the true on-disk
  version and is the sole writer of `user_version`.
- **Expected files:** `lib/data/db/app_database.dart` (`_openEncryptedConnection`
  → add `enableMigrations: false` to `NativeDatabase.createBackgroundConnection`);
  new test `test/data/db/migration_version_ownership_test.dart`.
- **DB/backend/native impact:** local DB only. No schema change, no data change.
  Existing production DBs already carry `user_version = 27` (stamped by prior
  builds) → observed as 27 → downgrade-guard passes → no behavior change for them.
  New installs now correctly observe 0; genuine legacy versions are observed;
  future higher versions fail closed.
- **Backward compatibility:** fully compatible. The one behavioral change is that
  version-gated compatibility repairs now fire for DBs whose on-disk version is
  below the gate (previously skipped) — all such steps are idempotent
  `ADD COLUMN IF NOT EXISTS`/`CREATE TABLE IF NOT EXISTS`, so re-running on a
  fresh (v0) DB is a no-op over what `_createSchema` already built.
- **Required tests (file-based, `enableMigrations: false`, mirroring production):**
  (1) fresh DB observed as `user_version = 0` (no framework stamp) then upgraded to 27;
  (2) legacy DB (v8, `transactions` missing `foreign_amount`) → the `version < 9`
  gate fires and adds the column, reaches 27, marker row preserved
  (proves real version observed + version-gated step executes exactly once);
  (3) reopen the same file → `user_version` persists 27, no re-migration, data intact;
  (4) newer DB (v999) → `UnsupportedDatabaseVersionException`, `user_version`
  stays 999 (framework did NOT stamp it to 27 — the exact regression);
  (5) full existing 19-test migration suite still green.
- **External acceptance:** none (fully local).
- **Rollback strategy:** single-line revert of the `enableMigrations: false`
  argument returns to prior behavior. No migration or data change to undo.
- **Definition of done:** all 5 test groups pass; existing migration suite green;
  analyze clean; full suite green; committed.

### MALI-045n (subsumes historical MALI-014) — restore FK strategy

- **Root cause (two parts):** (a) `restore_backup_usecase.dart:76` issues
  `PRAGMA foreign_keys = OFF` *inside* `_db.transaction()`, where SQLite treats it
  as a no-op (documented in `app_database.dart:228-229`) — so every restore runs
  with FK enforcement ON. (b) the snapshot filters parent tables `subscriptions`,
  `goals`, `plans` active-only (`deleted_at IS NULL`) while their FK children
  (`bill_payments`, `goal_contributions`, `plan_transaction_links`) are also
  active-only — so a soft-deleted parent with a retained (active) child produces an
  orphan whose insert throws FK 787 under enforcement → whole restore rolls back →
  **permanently unrestorable.** Also: v2 backups (no `categories` key) restored on a
  fresh install carry cross-catalog dangling category refs.
- **Required remediation (FK-safe first, disable-correctly where unavoidable):**
  1. **Snapshot (Part A):** back up `subscriptions`, `goals`, `plans` FULL
     (include soft-deleted, add `deleted_at` to their column lists) — matching the
     existing full-fidelity treatment of `cards`/`categories`. This makes v3
     snapshots FK-self-consistent so restore succeeds with the *existing correct
     parent-before-child ordering* and no reliance on disabling FKs.
  2. **Restore (Part B):** move `PRAGMA foreign_keys = OFF` OUTSIDE the transaction
     (so it genuinely suspends enforcement for the bulk insert — required for v2/
     legacy graceful restore); after inserts, run an idempotent FK-safe sanitize
     (null `SET NULL` dangling refs on `transactions`; drop `NOT NULL` child rows
     whose parent is genuinely absent, in cascade-safe order); then run
     `PRAGMA foreign_key_check` INSIDE the txn — any residual violation throws and
     rolls the whole restore back. `finally` re-enables `PRAGMA foreign_keys = ON`;
     the call then asserts enforcement is back on (returns 1).
- **Expected files:** `lib/core/backup/backup_snapshot_builder.dart` (Part A),
  `lib/core/backup/restore_backup_usecase.dart` (Part B); new test
  `test/core/backup/restore_fk_safety_test.dart`; possible update to
  `test/core/backup/backup_completeness_test.dart` if it asserts exact column sets.
- **DB/backend/native impact:** local DB + backup format (within v3, additive:
  adds `deleted_at` to three tables and includes soft-deleted parent rows). No
  Supabase/native impact. `currentSchemaVersion` stays 3 (the restore inserts
  whatever columns a row carries, so new→old and old→new remain compatible).
- **Backward compatibility:** a v3 backup from the OLD builder (no `deleted_at` on
  subscriptions/goals/plans, parents active-only) restored by the NEW build →
  sanitize drops any orphaned children (same graceful outcome, now FK-clean). A
  NEW-builder backup restored by an OLD build → the OLD restore inserts the extra
  `deleted_at` column (which exists in the schema) — works. v2 backups → graceful
  sanitized restore.
- **Required tests:** (1) v3 backup built from a DB with a **soft-deleted
  subscription that has an active bill_payment** → restore succeeds, both rows
  present, `foreign_key_check` empty, `foreign_keys = 1` after; (2) hand-crafted
  snapshot with an orphaned active child whose parent is absent → restore
  sanitizes (drops orphan) and succeeds FK-clean (proves FKs genuinely suspended +
  sanitize + validate); (3) v2-style snapshot (no categories) with a transaction
  referencing a dangling category → restore succeeds, transaction present with
  `category_id` nulled; (4) malformed snapshot → rejected in preflight, original
  data untouched, no DELETE ran; (5) failure mid-restore (unrepairable violation)
  → transaction rolled back, original DB byte-for-value intact, `foreign_keys = 1`
  after.
- **External acceptance:** on-device backup→restore round-trip = gate 6 (Phase 9).
- **Rollback strategy:** revert both files; the backup format change is additive
  and forward/backward compatible, so no persisted backup is invalidated.
- **Definition of done:** all 5 test groups pass; backup completeness/coverage
  test green; analyze clean; full suite green; committed.

**Phase 1 commit plan:** production + tests in one commit
(`fix(db,backup): migration version ownership + FK-safe restore`), docs
(this plan, ledger, and audit-status touch) in a separate commit. Then run all
gates, report, and STOP for approval.

---

## PHASE 2 — Cross-user lifecycle, sign-out, consent

- **MALI-054n (High):** native App Group / SharedPreferences capture queue survives
  sign-out → A's captures import under B. *Remediation:* add `purgeAll()` to the
  native capture bridge (iOS `SharedCaptureStore` + Android `DurableCaptureQueue`);
  call it from `DataWipeService`/`AppSession.signOut` and every owner-change/reset/
  account-deletion path. *Files:* `native_capture_bridge.dart`, `SharedCaptureStore.swift`,
  `DurableCaptureQueue.kt`, `MainActivity.kt`, `AppDelegate.swift`, `data_wipe_service.dart`,
  `app_session.dart`. *Tests:* Dart bridge purge + wipe-calls-purge; native tests are external.
  *DoD:* enqueue→wipe→queue empty (Dart-level), documented device gate.
- **MALI-053n (High):** sign-out flush omits child outboxes. *Remediation:* add child
  sync to the pre-wipe flush set (`app_shell.dart` flush + `app_session.signOut`).
  *Tests:* pending child rows flushed before wipe.
- **MALI-011 remaining / MALI-070n (Low):** delete `pending_notification_actions.json`
  on wipe; correct the closure-ledger claim; handle legacy-null-owner window
  (MALI-002 residual) and cross-user announcement-dismissal residue.
- **MALI-017 remaining (High-ish):** extend the unsynced-card data-loss guard to ALL
  destructive paths (server-driven signOut/userDeleted, account deletion, reset-all,
  cross-UID wipe), not just interactive sign-out; add honest local-only card badging.
- **MALI-001 / MALI-059n (Decision required):** consent currently opt-out. *Action:*
  surface an explicit onboarding consent step decision to the owner; implement the
  approved default. Ensure queued cloud/AI work halts on revocation (verify the gates
  drain in-flight work). *Do not invent the default.*

## PHASE 3 — Sync & multi-device correctness (one shared sync-semantics contract)

- **MALI-052n (High):** no outbox re-base/coalescing → consecutive offline edits
  self-conflict; conflict resolution covers 4 of ~12 entities → terminal freezes.
  *Remediation:* after a successful push, re-base the queued follow-up items to the
  returned server token (or coalesce same-entity pending updates); extend conflict
  resolution — or an explicitly documented deterministic LWW — to EVERY synced
  entity so no row stays permanently `sync_status='conflict'`.
- **MALI-051n (High):** child pull advances cursor past skipped (missing-parent) rows.
  *Remediation:* park unresolved children in a retry set; never advance the cursor past them.
- **MALI-055n (Med):** accounts have no conflict detection; `setDefault` mass-rolls-back.
  *Remediation:* base-token snapshot for account pushes; `setDefault` must not enqueue
  full-field updates for every account.
- **MALI-056n (Med, subsumes 009/010):** withdrawal/unknown round-trip; null-base blind
  overwrite; add an outbox payload `version` field.
- **MALI-057n (folds into 052n):** pull base-compare for accounts/settings/children.
- **MALI-022 (server):** add a real atomic server-side conditional update (version column
  / `WHERE server_updated_at = base` RPC) — requires a Supabase migration (staged, additive).
- **MALI-008 periphery / MALI-072n:** sender-mapping keyset + delete propagation;
  `_isConflict` must not string-match `'duplicate'`/`'409'`.
- **MALI-023 / MALI-024:** dead-letter + bounded retry; stop the child-StateError storm;
  idempotent gamification events (or single authority).
- **Tests:** two-device edit/edit, edit/delete, offline replay, crash windows, equal timestamps.

## PHASE 4 — Canonical financial correctness (one contract, all surfaces)

- **Shared contract:** extend the MALI-018 canonical predicate (`_financialAggregateSql`)
  into a single domain-level financial-semantics module covering income/expense/transfer/
  refund/withdrawal, status, excluded accounts, account/currency/category scope, half-open
  date/period boundaries, budget periods, bill-payment attribution.
- **Remediation:** route MALI-047n (transactions header), MALI-048n (plan spend),
  MALI-049n (dashboard budget rings), MALI-050n (Home category totals), MALI-064n
  (bill paid double-count, monthly formula), MALI-074n (card gross/decimals/NULL-account),
  MALI-062n (week anchor + budget scope), MALI-063n (PDF multi-currency + latent 0030 RPCs)
  through the shared contract. **UI providers must not fold raw amounts.** Never sum
  mixed currencies under one label. Standardize half-open UTC intervals + business
  week (MALI-028) in one place.
- **Tests:** provider-tier cross-surface invariant tests (transactions==dashboard==Home==
  plans==budgets==reports==export) across all types/refunds/excluded/multi-currency/periods.
- **Note:** fix-or-delete the 0030 summary RPCs before their flags can ever flip.

## PHASE 5 — Security, privacy, notifications, native hardening

- MALI-061n/019: apply notification policy + quiet hours to gamification pushes; one
  authority per notification type; stable (non-random) collapse ids.
- MALI-031: App Group encryption + shared-Keychain secret + rotation on unlink.
- MALI-032: scrub all Sentry event surfaces (breadcrumbs/contexts/extras/tags/messages) + tests.
- MALI-033: Android `dataExtractionRules`/`fullBackupContent` excluding the capture queue + secrets.
- MALI-068n: Android receiver persistence `commit()` (kill-safe); lock the iOS auxiliary queues; fix re-enqueue timestamp parsing.
- MALI-065n: deterministic PDF/temp cleanup (startup sweep + delete on preview close).
- MALI-071n: gate logo.dev merchant-logo fetches behind cloud/consent.
- MALI-060n: rate-limit AI endpoints on server-verifiable identity (device secret), not client-supplied install id.
- MALI-075n: `SET search_path` on `handle_new_user`/`prune_processed_captures`; lock client-writable gamification tables; purge coverage for endpoint-namespaced/ai rate-limit rows.
- MALI-044: rate-limited/owner-bound metrics ingest (replace `WITH CHECK (true)`).
- MALI-025: iOS 64-pending management + exact-alarm capability + full lock-screen redaction.
- MALI-039: opt-in/redacted debug diagnostics + parameterized SQL.

## PHASE 6 — Backup, DB, reliability hardening

- MALI-058n: stop storing the SQLCipher key in `user_settings`/backups (store a fingerprint; null on restore).
- MALI-076n: validate backup `version`/`kdf`; normalize passphrase trim; distinguish network-error from no-backup; whitelist restore columns against `_tables`; delete the dead `data_export.dart` clipboard helper.
- MALI-069n: close the connection/isolate on failed init; set `busy_timeout`; define safe second-connection behavior for the background notification path.
- MALI-073n: add `transactions(account_id)`/`(category_id)` indexes (measure query plans; address the NULL-account OR-subquery that defeats them).

## PHASE 7 — CI, tests, architecture, performance, docs

- MALI-066n: wire `verify_ios_packaging.sh` into CI; run ALL Deno function tests (not just `_shared`); enable the admin auth suite; one authoritative CI config.
- MALI-067n/040/041/042/038: replace source-text tests with behavioral/AST tests; close every test DB; remove Drift warning suppression; randomized/repeated ordering; correct font bundling.
- MALI-034: break the app_shell↔dashboard import cycle; retire/isolate the legacy Supabase-primary repair architecture.
- MALI-029/030: table-scoped invalidation; streamed/paged reports + memory budgets + large-dataset tests.
- MALI-035: fix `CLAUDE.md` drift (schema v27, test counts, 4 workflows, and remove the dangerous "all optional / stub mode" claim).
- MALI-037: dependency CVE/license/outdated gate.
- MALI-077n: keystore env-var name, notification email, remove obsolete `consumePendingSharedMessages`, Kotlin package path.
- MALI-043 (Decision required): confirm canonical brand (Mali vs Qirsh), then align identifiers/copy/store metadata; remove the unused iOS location string.

## PHASE 8 — MALI-026 fixed-precision financial storage (isolated major project)

Starts ONLY after: MALI-046n closed (pipeline owns version), backup/restore verified,
sync semantics stable, all financial-surface contradictions closed, and a rollback/
compat strategy approved. Integer minor units (or approved exact decimal); currency
exponents 0/2/3; covers Drift+Supabase+RPCs+Edge+sync payloads+backup+import/export+
reports+UI; additive staged migration with dual-read/write + backfill verification;
add relational integrity constraints safely; test every upgrade path + old/new client×
server; no in-place destructive conversion without a proven recovery path.

## PHASE 9 — External validation & closure

Execute `RELEASE_VALIDATION_RUNBOOK.md` gates 1-12 with captured evidence (staging
Supabase apply, RLS/Edge adversarial, Vault/secret, cron/purge, signed Android +
device durable capture, Play policy, physical iPhone APNs/App Group/App Intent, App
Store privacy archive, backup/restore + A→B lifecycle, two-device conflict, old/new
client compat, internal beta, staged rollout, monitoring + rollback rehearsal).
External findings cannot be marked Closed without captured evidence.

## Global rollback posture

Every phase commits behind the feature branch; nothing is pushed without explicit
request. Schema/backend changes (Phase 3 server conditional-update, Phase 8) use
additive staged migrations with documented reversals. Financial-surface refactors
(Phase 4) are behind the shared contract with invariant tests as the safety net.
