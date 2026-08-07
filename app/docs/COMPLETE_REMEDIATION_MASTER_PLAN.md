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

**STATUS: Code complete · Locally verified** (commits `374560ff` lifecycle, `89db9f09`
consent; full suite 1015, analyze 0, Deno 54, migration lint + iOS packaging PASS).
Native device execution (residue purge on device, 2-user smoke) remains external
(gates 6/9). **Bug found & fixed during implementation** (not a new finding):
`userSettingsFromRow` hard-coded consent to `true`, making revocation a no-op —
fixed under MALI-001. Approved MALI-059n decision implemented in full.

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

> **Status (2026-08-04): Phase 3 LOCALLY COMPLETE — all 6 batches delivered;
> live-backend + two-device verification pending.** B6 closure: full finding
> reconciliation, gamification single-authority overlap proof (no overlap — Edge
> path active, RPC path dormant), entity contract matrix, migration/capability
> ledger, and external verification checklist are in `PHASE_3_SYNC_CLOSURE.md`.
> `kServerRevisionCas` remains false; migrations 0068–0070 authored + lint-clean
> but NOT deployed. B5 sender-mapping sync
> durability (072n/008 — keyset + tombstones + typed errors, `96993c5e`) +
> gamification single-authority (024 — server-authoritative idempotent
> engagement events via migration 0070 + locked-down RPC; client aggregate-total
> upload removed, `74a77398`). See the Batch-5 delivered-contracts section in
> `REMEDIATION_STATUS_LEDGER.md`. Only batch 6 (docs closure) remains.
> Earlier: batches 1–4 —
> (051n, `acf9ca99`); B2 outbox coalescing + typed dead-letter/retry (052n/023,
> `d6820285`); B3 server revision CAS migration 0068 + universal conflict
> policy/resolver (all 12 entities) + dormant client CAS plumbing gated OFF
> (022/057n/052n, `4a2da692`/`de672bc0`/`0e52da68` — **live CAS activation is
> external-pending; `kServerRevisionCas` stays false**); B4 dedicated
> default-account command + versioned canonical ledger payload
> (055n/056n/009/010, `58614ad4`/`124fd83b`). See the delivered-contracts section
> at the end of `REMEDIATION_STATUS_LEDGER.md` for the default-command contract,
> ledger payload version, enum mapping table, and compatibility rules. Batches
> 5–6 (072n/008/024; docs) remain.

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

> **Status (2026-08-04): PHASE 4 CLOSED — locally verified (code + automated);
> device/PDF/UI spot-checks external-pending.** All six batches landed. The
> authoritative canonical spec is `PHASE_4_FINANCIAL_SEMANTICS.md`; the
> per-finding reconciliation and closure verdict are in `REMEDIATION_STATUS_LEDGER.md`
> ("Phase 4 closure reconciliation"). 018/028/062n Closed · LV; 047n/048n/049n/
> 050n/063n/064n/074n Code complete · LV (documented device spot-checks remain).
> Full suite 1179; analyze 0; `kServerRevisionCas` false; migrations 0068–0070
> undeployed. Batch 6 was documentation/verification only (no production code).
>
> Earlier (batch history):
> **Batches 1–5 Code complete · Locally verified.**
> Batch 5 (`a25a75c7`/`0f86fb7c`/`1fc89450`): exact account ownership (an
> unassigned row is never attributed to an account by currency — MALI-074n
> NULL-account contract), per-currency net-spend card summaries (refund-netted,
> income-only, exponent formatter), an authoritative installment paid-count from
> the `bill_payments` ledger (distinct settled installments, not
> `MAX(installment_index)`), a remaining-fold sweep (dead `totalDue` removed;
> list/dashboard boundaries made half-open; distinct-metric folds left labelled),
> and the final cross-surface invariant now spanning repo/header/Home/budget-ring/
> budget-detail/plan/report/card. The approved empty-plan-scope decision
> (`allExpenses`, no `unconfigured` state) is recorded. Full suite 1179; analyze
> 0; `kServerRevisionCas` false; migrations 0068–0070 undeployed.
>
> Earlier:
> **Batches 1–4 Code complete · Locally verified.**
> Batch 4 (`b702669c`/`989f6614`/`d5d1605b`/`174ed4c3`): the budget-history
> transaction list now nets to its total (MALI-062n tail); the PDF report donut/
> slices/appendix are scoped to the primary currency — never a cross-currency
> sum — with 0/2/3-decimal formatting (MALI-063n/074n-report); ONE bill-payment
> attribution contract (`bill_payments` authoritative, one payment counts once,
> fuzzy match demoted to a link suggestion) + ONE subscription monthly/annual
> metric replacing three divergent formulas (MALI-064n); and the dormant
> migration-0030 / Supabase-summary switches are retired (no flag left to
> reintroduce pre-canonical totals). Batch 5 (MALI-074n card gross/NULL-account)
> + Batch 6 (the `PHASE_4_FINANCIAL_SEMANTICS.md` closure doc) remain.
>
> Earlier:
> **Batches 1–3 Code complete · Locally verified.**
> Batch 1 (`71dc2534`): the domain semantics/period/currency contract. Batch 2
> (`c4b6df97` + `2052687d`): canonical repo aggregates made half-open `[from, to)`
> (MALI-028) and the **Transactions header** (MALI-047n) + **Home category totals**
> (MALI-050n) routed through it. Batch 3 (`4fa413a9` + `4dc0d190`): **plan spending**
> (MALI-048n — currency isolation, refund netting, half-open window, explicit
> scope model, UNION membership, fail-closed currency) and **dashboard budget
> rings** (MALI-049n — the ring uses the budget's own stored period via one
> canonical resolver shared with budget detail/reports/alerts, never the
> dashboard filter; genuine Saturday-week half-open periods, unifying the three
> divergent resolvers — MALI-028/062n budget-period portion). New callers obey a
> strict genuine-`toExclusive` boundary rule (no epsilon ends). No signature/
> schema change; dormant Supabase summary tier untouched (MALI-063n). Full suite
> 1150; analyze 0; `kServerRevisionCas` false; migrations 0068–0070 undeployed.
> Batches 4–5 remaining: MALI-064n bill double-count, MALI-063n PDF multi-currency
> + 0030 RPCs, MALI-074n card gross/decimals. See the Batch-2 and Batch-3
> delivered-contracts sections in `REMEDIATION_STATUS_LEDGER.md`.

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

> **Status (2026-08-05): Batch 6 closure correction.** The Batch-6 documentation's
> own honesty surfaced four production-code defects INSIDE Phase-5 scope, which
> were FIXED (not deferred): **MALI-019** — `evaluate-gamification` post-award push
> now passes the server-authoritative notification policy (per-type + quiet hours
> via `isPushAllowed`, `hideLockScreenContent` redaction, device eligibility,
> coordinated fallback), eligibility staying exactly-once in the 0074 RPC;
> **MALI-061n** — goals + achievements are local-primary/server-fallback
> (`anyDeviceRecentlyActive`), the redundant streak/bill server cron push is
> RETIRED (scheduled-local is the sole authority), and the two text-derived
> notification ids (captureLight, budget) are replaced with generated-before-notify
> stable keys; **MALI-060n** — `process-ios-sms` is brought onto the Batch-3
> boundary (server-owned consent with `allowAi` compat-only, `readBoundedJsonBody`
> cap, schema/length limits, gate ordering before any Gemini call). Gates: analyze
> 0, full suite 1258, deno 76/0/2-ignored, node 21/0 (+23 credential-gated skips),
> migration lint PASS, ci_gates PASS; 4 pre-existing `_shared` deno-lint findings
> unchanged. Migrations 0068–0074 undeployed; `kServerRevisionCas=false`; 0070
> inactive. No type remains documented as "may duplicate".
>
> **Prior — Batch 6 — documentation, reconciliation, external-gate
> inventory, formal closure (documentation & verification only; no production code
> changed).** The authoritative Phase-5 contract spec is
> `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md` — it documents the FINAL implemented
> contracts (native storage, Android persistence/backup/alarms, telemetry/
> diagnostics, temp exports, the AI-endpoint security matrix, the notification
> authority/terminology/scheduling contracts, the backend security model, and the
> gamification 8-layer authority incl. the 0074 single-transaction atomic-award
> RPC), the per-finding reconciliation, the 0068–0074 migration/activation
> inventory, the environment-grouped external checklist, and the permanent
> architectural guardrails with their enforcing tests. **Verdict: Phase 5 code
> complete — locally verified; signed-device, Android, APNs, store-policy, and
> live-PostgreSQL verification pending.** Migrations 0068–0074 undeployed;
> `kServerRevisionCas=false`; migration 0070 authority inactive. The whole
> remediation program is NOT complete (Phases 6–9, MALI-026, external validation
> remain).
>
> **Prior — Batch 5 (backend, RLS, SECURITY DEFINER, metrics, purge,
> gamification, endpoint hardening) Code complete · Locally verified.** MALI-075n
> / MALI-044 / MALI-024-backend. Migration 0072 (additive, undeployed, lint PASS);
> Batch-5 closures added 0073 (aggregate read-only) + 0074 (atomic award).
>
> - **SECURITY DEFINER inventory:** a precise per-function audit found exactly two
>   SD functions lacking a fixed search_path. `handle_new_user` (0001) is DEAD
>   (0005 dropped its trigger + superseded it with `create_profile_on_signup`,
>   which sets search_path) → dropped. `prune_processed_captures` (0012) recreated
>   with `SET search_path = public` + re-locked. All other SD functions
>   (0005/0033/0035/0065/0070/0071) already have one.
> - **Metrics (MALI-075n):** the `with check (true)` free-for-all authenticated
>   INSERT is removed + revoked. `record_metric(key, dimension)` RPC gates
>   ingestion — authenticated-only (owner from auth.uid()), event allowlist
>   ({app_open}), bounded lengths, atomic per-user daily quota (deny-all
>   `metrics_rate_limits`), server timestamp, NO PII stored. Client → RPC.
> - **Gamification (MALI-024):** `record_engagement_event` (0070) hardening
>   asserted (auth.uid() owner, reject unauth/unknown-type/unsupported-version,
>   server-fixed CASE award, ON CONFLICT idempotent). **Batch-5 closure — gap
>   found & fixed:** the earlier report wrongly accepted 0062's owner
>   aggregate-writes; a normal authenticated client could forge its OWN
>   XP/level/streak/achievement totals (owner-scoped write is NOT security).
>   **Migration 0073** supersedes those policies (drops owner insert/update +
>   revokes INSERT/UPDATE/DELETE from authenticated) → aggregates READ-ONLY to
>   clients; the server (service_role) is the sole authoritative writer; the
>   client is pull-only (verified). **Legacy idempotency (§5) — crash-safety
>   correction:** the first fix (`9fdd30e7`) claimed the ledger row and mutated
>   XP in SEPARATE Edge calls (separate transactions); a crash after the claim
>   committed but before the XP update LOST the award permanently (the claim then
>   blocked every retry). **Migration 0074** folds the claim + XP / level /
>   achievement / notification-eligibility into ONE Postgres transaction
>   (`award_gamification_for_transaction`: SECURITY DEFINER, fixed search_path,
>   ownership-verified, service_role-only) → **exactly-once AUTHORITATIVE
>   mutation** (crash rolls the claim back with the award; a lost-response /
>   duplicate / concurrent retry reconstructs the stored canonical result; no
>   partial state). APNs delivery happens AFTER commit, keyed by a stable
>   per-transaction collapse id (best-effort, idempotent, retryable — a send
>   failure never rolls back or re-awards). Ledger purge-covered. Client
>   engagement submission already bounded (retry→dead-letter, projection
>   preserves progress, pull reconciles). **Effective dormancy —
>   corrected characterization:** the client DOES enqueue + submit engagement
>   events (`_syncEngagement` → the RPC), but because 0070 is UNDEPLOYED the RPC
>   does not exist, so every submission 404s (best-effort, caught) and produces
>   NO award; the legacy transaction-triggered path (evaluate-gamification) is the
>   sole active award authority. **Activation gate (critical):** deploying 0070
>   while the legacy path is still active would DOUBLE-AWARD, so activation
>   requires — in the SAME release — 0070 deployed + real concurrency/idempotency
>   tests green + the legacy transaction-triggered authority disabled. This batch
>   keeps 0070 undeployed. Client aggregate-write policies (0062) are the accepted
>   offline-first Phase-3 design (per-user, non-financial); left intact.
> - **Purge/retention:** `purge_user_data` extended to AI-idempotency (owner_key),
>   engagement, and metrics-quota rows in FK-safe order (before capture_devices).
>   Idempotency rows also self-expire (0071 TTL); metrics counters self-prune.
> - **Dead endpoints (MALI-044):** merchant-feedback retired (auth + 410 →
>   enrich-merchant); its unwired client noted. Other Edge functions carry real
>   contracts (Batch 3 verified identity / catalog reads / service-role workers).
> - **Admin auth (MALI-041):** unchanged — the known admin-test failure is a
>   test-harness brittleness (Phase-7 scope per prior approval); production admin
>   authorization (0035 get_user_stats service-role lockdown) is intact.
>   *(Phase-7 B1 update: MALI-041 is now RESOLVED — the brittle assertion was replaced
>   by a quote-independent contract + regression; admin suite 8/0. See the Phase-7
>   status block.)*
>
> `4e927db5`/`6ddd5aaa`/`975af849`. Live RLS/RPC/purge/quota under real Postgres +
> the credential-gated node/deno tests remain external where no local Supabase
> exists.
>
> **Prior — Batch 4 (notification authority, policy, dedup,
> lock-screen privacy, scheduling limits, Android receiver tail) Code complete ·
> Locally verified.** MALI-061n / MALI-019 / MALI-025 / MALI-068n + the Batch-3
> Android consent tail.
>
> - **Android consent tail:** a platform dispatcher `syncBackendState()` registers
>   the Android device (only after cloud/AI opt-in) and pushes consent via
>   `set-device-consent`, fail-closed; iOS unchanged. `1e2d88f4`.
> - **Event identity (§3):** `notificationEventId`/`achievementNotificationId` —
>   stable business key, never display text/hashCode (achievement + review ids
>   fixed). `1e217ce3`.
> - **Lock-screen privacy (§6/§9):** `hideLockScreenContent` pref + generic
>   `redactedContentFor` per type; in-app inbox keeps real content; title-logging
>   leak removed; delivery states already honest (no 'delivered'). `224394fd`.
> - **iOS capacity (§8):** `NotificationCapacityPlanner` (cap < 64, immediate
>   reserve, importance-then-due, rolling window, verify actual pending set).
>   `9128589e`.
> - **Android tail (§9/§11):** SMS native-epoch timestamp authority
>   (`resolveCapturedReceivedAt`: epoch→ISO-legacy→null, never `now`); durable
>   corruption clear; inexact alarms + Play-restricted exact-alarm permissions
>   removed. `8337202e`. Android compile/receiver/alarm/device EXTERNAL.
> - **Authority coordination (§12):** budget local-primary; evaluate-budgets
>   pushes only as a fallback when no device is recently active
>   (`anyDeviceRecentlyActive`). `5b2c771b`.
>
> ### Batch-4 notification-authority matrix
>
> | Type | Authority | Fallback | Logical event id | Privacy | Quiet hours | Dedup |
> |---|---|---|---|---|---|---|
> | capture review/light | local (`_show`) | — | `review:<txnId>` / capture payload id | redacted-aware | bypass (time-sensitive) | id + notification_logs |
> | budget warning/over | **local (immediate)** | server (`evaluate-budgets`, when inactive) | `budget:<id>:<period>:<bucket>` + spend watermark | redacted-aware / server policy | enforced both tiers | watermark + recency guard |
> | achievement / streak | local (gamification→`_show`) | — | `achievement:<key>` | generic | enforced | stable id |
> | bill/subscription, weekly report, goal | local scheduler | — | `notificationEventId(type,key)` | redacted-aware | enforced (defer) | capacity-planned ids |
> | (Phase-3) gamification award authority | legacy transaction-triggered ONLY | — | — | — | — | 0070 engagement authority stays DORMANT |
>
> Preserved: Phase-3 gamification transition (0070 engagement authority not
> activated), install_id non-authoritative, server consent authoritative. Native
> Android receiver/alarm/device verification remains external.
>
> **Prior — Batch 3 (AI endpoint authentication, verified identity,
> consent, rate limiting, abuse controls) Code complete · Locally verified.**
> MALI-060n. The three client-callable paid endpoints — parse-sms (Gemini),
> bank-discovery (Gemini), enrich-merchant (Google Places) — no longer trust a
> caller-supplied install_id. Shared `_shared/ai_endpoint.ts` enforces:
> server-verified identity (device secret via `verifyDevice`, else real user JWT;
> install_id alone → authentication_required), fail-closed server-side consent
> (AI for parse/discovery, cloud for enrich), an atomic rate limit keyed on the
> verified identity, a typed 13-code error envelope (never a raw message/upstream
> body), bounded bodies + text-length caps, upstream timeouts + classified
> errors, and request idempotency (0071 `claim_ai_idempotency`, payload hash
> only) so a retry never double-pays. Migration 0071 (consent columns +
> revoked_at + idempotency ledger + locked-down RPCs, migration-lint PASS, NOT
> deployed) + `set-device-consent` write path + client wiring (device_secret +
> request_id + schema_version, consent push via iOS syncNativeState). deno 67/0
> (+2 credential-gated real-backend ignored). `b6c990f8`/`9bf26554`/`2aa29d60`/
> `3316c154`/`8dd5f1b1`.
>
> ### Batch-3 endpoint matrix (MALI-060n)
>
> | Endpoint | Paid upstream | Authoritative identity | Consent | Quota (per identity/day) | Idempotency | Notes |
> |---|---|---|---|---|---|---|
> | `parse-sms` | Gemini | device secret / user JWT | AI (fail-closed) | 500 | request_id → claim RPC | primary; local-parse fallback |
> | `bank-discovery` | Gemini | device secret / user JWT | AI (fail-closed) | 50 | n/a (200-on-fail, rare) | safeLog only |
> | `enrich-merchant` | Google Places | device secret / user JWT | cloud (fail-closed) | 200 | request_id → claim RPC | leak removed; idempotent upsert |
> | `set-device-consent` | — | device secret (only) | writes consent | 200 | — | consent write path (new) |
> | `process-ios-sms` | Gemini (internal) | device secret (existing) | existing capture flow | 300 | payload_id (existing) | already verified; unchanged |
> | `register-device` | — | bootstraps secret | — | 20 | — | issues/rotates device secret |
> | `catalog-*` (delta/flags/…) | none (no paid upstream) | anon read | — | — | — | cheap cached content; out of scope |
> | worker/cron (`evaluate-*`, purge, retries) | none | service-role / bearer secret | — | — | — | not client-callable; out of scope |
> | `merchant-feedback` | none | anon | — | — | — | keyword list only; no console.* (Batch-2 verified) |
>
> Compatibility: an old client sending only install_id gets a typed
> authentication_required and falls back to local parsing; a new client's extra
> fields are ignored by the old server. Rollout = migration 0071 + functions,
> then client. Live migration apply, RPC concurrency, and the Android
> consent-push path remain external/follow-up.
>
> **Prior — Batch 2 (telemetry, logging, temp files, export
> privacy, merchant logos) Code complete · Locally verified.** MALI-032
> (allowlist Sentry boundary — beforeSend + beforeBreadcrumb, drop all
> free-form text, structured `TelemetryCodes`, behavioral canary tests
> `bff0f1d8`), MALI-039 + the MALI-075n logging portion (central redacting
> `debugPrint` sink + `Diag`; SQL already parameterized `0010b037`), MALI-065n
> (one `ManagedExportStore` — opaque names, iOS file-protection + backup-
> exclusion channel, delete on success/cancel/failure, startup + resume sweeps,
> no clipboard fallback; 9 fs tests + iOS build `2d1072f6`), MALI-071n
> (merchant logos gated on cloud-processing consent, fail-closed, ladder
> bundled→consented remote→placeholder `08e7ca0d`). Merchant edge functions
> reviewed — no sensitive logging. analyze 0.
>
> **Prior — Batch 1 (shared native storage + Android backup) — 2026-08-04:**
> MALI-033 (Android Auto Backup disabled), MALI-031 (iOS shared-Keychain
> secrets + AES-encrypted capture queue + secret invalidation), native-storage
> portion of MALI-068n. iOS simulator build + `xcodebuild test` 6/6.
> `5c88417c`/`30b4f3fc`. Batches 3–6 (AI auth, notifications, backend/RLS,
> closure) not started. The full `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md`
> spec is written at Phase-5 closure.

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

> **Status (2026-08-06): Batch 6 final reconciliation — confirmation capability +
> post-commit usability.** Two remaining production-integration ambiguities closed:
>
> - **No confirmation bypass.** The combined `restoreFromBackup`/`restore` entry
>   points are REMOVED. Destructive mutation is reachable only through
>   `prepareRestore` → explicit user confirmation → `commitRestore`, and
>   `commitRestore` REQUIRES an unforgeable single-use `RestoreConfirmation`
>   capability whose constructor is private to the controller's library — no
>   service/provider/onboarding/recovery/background path can fabricate one. It is
>   tied to the operation id + source fingerprint (a changed source → rejected), the
>   admission is captured at preparation and re-validated at commit (same-UID
>   re-login / ownership change → aborted), it is consumed exactly once, and
>   cancellation destroys the pending confirmation. A production-call-site contract
>   test proves no direct destructive call exists outside the canonical boundary.
> - **Success is post-commit-usable, not merely committed.** The controller now
>   sequences `restoring → verifying → reestablishingDatabase → completed`. After the
>   transaction commits (data + durable journal marker atomically), the service runs
>   a **usable-state proof** (`verifyRestoredDatabaseUsable`: a real production query
>   + the restore's admission still current); only then is the restore durably
>   **acknowledged** and `completed` shown. A failed reopen/admission →
>   `recoveryRequired`, NEVER completed, and NOT acknowledged — the data stays
>   committed and startup recovery re-establishes (never re-restores).
>
> **Prior — Status (2026-08-06): Batch 6 — integration reconciliation, documentation,
> external-verification matrix, formal LOCAL closure.** One integration defect
> fixed: the `RestoreController` was unwired — the production restore screen bypassed
> it, so no explicit confirmation gate existed before destructive mutation.
> `EncryptedBackupService` now splits `prepareRestore` (download/decrypt/validate, no
> mutation) from `commitRestore` (mutation via the maintenance gate), and
> `RestorePromptScreen` drives `RestoreController` with an explicit confirmation
> dialog — widget-tested to prove preparation never mutates, cancellation runs no
> mutation, and the mutation runs only after confirmation. Verified schema v28 is
> owned by the versioned migration pipeline (clean install + realistic v27→v28 upgrade
> + idempotent reopen + PK constraint). Added the Phase-6 closure document and the
> external-verification checklist.
>
> **Final local status roll-up — `Code complete — locally verified; physical-device,
> native SQLCipher/process timing, live Supabase, multi-device, and device restore-UI
> verification pending.`** Per finding: **MALI-014** (restore/rollback/recovery) — durable replay
> journal, prep/mutation split, in-txn verification + atomic rollback, crash/replay,
> truthful UI; **MALI-027 lifecycle tail** — one migration owner, once-per-open,
> failed-init cleanup, cross-isolate admission generation; **MALI-058n** — SQLCipher
> key isolation (key in secure storage only; no key in backup/restore/export);
> **MALI-069n** — Contract-B single-process invariant, process-liveness OS-lock
> authority (no heartbeat reaping), file-exclusive maintenance; **MALI-076n** —
> authenticated v3 envelope + v1/v2 readers, generation CAS + verified download,
> restore-side pipeline. All external gates are enumerated in
> `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`. No new Supabase migration;
> `kServerRevisionCas = false`; migration 0070 inactive; 0068–0076 undeployed.
>
> **Prior — Status (2026-08-06): Batch 5 closure — durable replay journal, preparation-time
> compatibility adapters, complete rollback evidence, crash/replay recovery, and a
> truthful UI controller.** Five gaps flagged after Batch-5's core were closed:
>
> 1. **Durable replay journal (§Blocker-1).** The in-memory guard is replaced by a
>    `restore_operations` Drift table (local schema **v27 → v28**, additive, created
>    idempotently on fresh install + upgrade, excluded from backup/restore/sync/
>    export, bounded retention). Its `committed` transition is written INSIDE the
>    restore transaction, so it commits atomically with the restored data and rolls
>    back with it. A crash / acknowledgement loss is recovered at restart:
>    the committed operation is discovered (`committedPendingAcknowledgement`) and
>    NEVER destructively replayed; acknowledgement is idempotent; a same-op-id /
>    different-source is rejected.
> 2. **Preparation-time compatibility adapters (§Blocker-2).** An explicit
>    `SnapshotSchemaAdapter` per snapshot version (v1/v2/v3) normalizes the source to
>    the current plan shape BEFORE the maintenance/mutation phase (version-specific
>    required tables + column defaults + safe warnings; a future version is rejected
>    before mutation). Synthetic v1/v2/v3 fixtures exercise the adapters end-to-end.
> 3. **Complete rollback evidence (§Blocker-3).** Deterministic fault injection at 9
>    transaction-boundary points (after first/several deletes, first/partial insert,
>    relationship reconstruction, before/during/after verification, journal commit),
>    each proving a full-DB digest (all user-data tables) + per-currency financial
>    totals are unchanged and no committed marker survives. In-transaction
>    verification strengthened (per-currency canonical totals, default-account +
>    singleton, no duplicate/key/remote).
> 4. **Local crash/replay (§Blocker-4).** File-backed crash-before-commit (reopen =
>    complete old state, no committed marker, FK-clean); commit-before-ack restart
>    (a fresh service discovers the committed op via the durable journal, does not
>    replay, then acknowledges idempotently); and a REAL `Process.start` native-sqlite
>    kill proving SQLite rolls back the uncommitted transaction (native SQLCipher
>    timing is the only external part — skip-safe under load).
> 5. **Truthful UI controller (§Blocker-5).** A `RestoreController` state machine
>    (selecting → downloading → decrypting → validating → readyForConfirmation →
>    waitingForDatabase → restoring → completed / cancelled / failedWithoutChanges /
>    recoveryRequired) ENFORCES an explicit confirmation gate before any mutation,
>    guarantees cancellation-before-mutation changes nothing, shows success only
>    after commit/verify/reopen, maps typed outcomes to safe phases, and
>    acknowledges idempotently. Broad screen redesign intentionally avoided.
>
> MALI-014 + MALI-076n restore-side → Code complete · Locally verified; native
> process-kill timing, SQLCipher hardware round-trip, and device UI verification
> pending. No Supabase migration; the only schema change is the additive local
> `restore_operations` table (v28). Batch 6 (formal closure) is NOT started.
>
> **Prior — Status (2026-08-06): Batch 5 — restore compatibility, atomic rollback, crash
> recovery, and user-data recovery matrix.** Restore is refactored into two explicit
> phases and wired onto the accepted Batch-4 maintenance primitive.
>
> **Preparation (before the gate, no mutation):** the existing envelope reader
> decodes/decrypts/limits (typed errors preserved), then `RestorePreparation`
> validates schema support, the Batch-1 column whitelist, sensitive-field rejection,
> required tables, and rejects any unknown/excluded table — and builds an IMMUTABLE
> `RestorePlan` (opaque operationId, envelope+schema version, opaque source
> fingerprint, whitelisted table payloads, expected row counts, privacy-safe
> warnings). The plan holds no passphrase, key, path, token, or raw JSON.
>
> **Mutation (consumes only the plan):** `RestoreService` revalidates the admission
> generation before the gate and again immediately before the transaction, then runs
> the destructive delete/insert/sanitize through `runFileExclusiveMaintenance` in one
> Drift transaction. Before commit it VERIFIES the result against the plan — required
> singleton row, transaction count == plan, no duplicate ids, sanitize-safe tables ≤
> plan, the canonical net-expense confirmed total (Phase-4 `FinancialSql`) == the
> plan's total, no SQLCipher key ref, no intentionally-excluded/remote/pending table
> — and throws BEFORE commit on any mismatch, so the whole restore rolls back and the
> original database is preserved (proven with a duplicate-id rollback test asserting
> the destination is unchanged).
>
> **Result taxonomy + replay + ownership:** every failure maps to a typed
> `RestoreOutcome` (success/cancelled/authenticationFailed/malformedBackup/
> unsupportedEnvelope/incompatibleSnapshot/payloadTooLarge/ownershipChanged/
> maintenanceTimeout/databaseBusy/validationFailed/rollbackCompleted/rollbackFailed/
> reopenFailed/recoveryRequired/localFileUnavailable/remoteObjectUnavailable/
> remoteIntegrityFailed/internalFailure) with a safe user message — never a raw
> error. An in-memory operation-ID guard makes a committed restore idempotent (no
> destructive replay on acknowledgement loss) and rejects the same op id carrying a
> different source. An admission change (sign-out / wipe / ownership change /
> same-UID re-login) before commit aborts without mutation.
>
> **Preserved contracts:** the verified committed-generation download, the v1/v2/v3
> legacy envelope readers, Batch-1 key isolation, Batch-4 admission + file-exclusive
> maintenance, Phase-1 FK-safe restore, Phase-2 ownership isolation, and Phase-4
> financial semantics all stand. No Drift schema bump; no Supabase migration.
> **Remaining external (device-only):** real process-kill-mid-transaction timing —
> covered locally by SQLite transactional rollback + the operation-ID replay guard.
> Batch 6 (formal closure) is NOT started.
>
> **Prior — Status (2026-08-06): Batch 4 closure #4 — Contract B (single-process) proven;
> heartbeat/mtime removed as the reaping authority.** Closure #3's renewable
> heartbeat/mtime lease made a stopped heartbeat authorize reaping — unsafe, because
> a live isolate blocked in a long SQLite call (or a paused/suspended isolate) stops
> heartbeating without closing its connection, so destructive maintenance could
> begin over a still-open connection. This pass replaces that authority.
>
> **Step 1 — process-access inventory (docs/PROCESS_ACCESS_INVENTORY.md).** Every
> executable that could touch the DB was audited against the actual manifests,
> entitlements, and Xcode targets. Result: **Contract B — exactly one OS process
> (the Flutter host app) can ever open the Drift/SQLCipher database.** Evidence: no
> Swift/Kotlin code references sqlite/sqlcipher/sqlite3mc; the iOS `ShareBankMessage`
> extension and `BankMessageShortcuts` App Intents are pure-native and stage to the
> App Group (`UserDefaults(suiteName:)` + shared Keychain) — no `FlutterEngine`, so
> the `sqlite3mc`/Drift Dart plugin can never load in them; the Android manifest
> declares no `android:process`, so the notification `ActionBroadcastReceiver` and
> all receivers run as same-process background isolates; the only three Dart open
> sites are bootstrap (`open`) + the two `openSecondary` background isolates.
>
> **Step 2 — Contract B enforcement + safe authority.** (a) A source-scan gate fails
> if any extension/receiver imports Drift / embeds a Flutter engine / references the
> DB, if `android:process` appears, or if a new Dart open site is added. (b) The
> authoritative lease/intent record is IMMUTABLE and written atomically (temp-file +
> rename), carrying only a fencing token, owner pid, and instance token — a reader
> never observes partial content, and liveness = record EXISTENCE, never age.
>
> **Step 3 — heartbeat is no longer an authority.** RUNTIME maintenance NEVER reaps:
> it waits for every shared lease to be RELEASED by its holder with a typed BOUNDED
> TIMEOUT. A live-but-blocked/paused isolate keeps its lease → maintenance times out
> (safe), never corrupts; uncertain liveness never authorizes deletion. No
> wall-clock/mtime decision exists, so forward/backward clock jumps and suspension
> can never authorize deletion.
>
> **Step 4/5 — process-liveness recovery + maintenance entry.** The ONLY reaping is
> stale-file recovery at process start (`DatabaseProcessLiveness`): a starting
> process takes a process-lifetime OS advisory lock (POSIX fcntl, released by the OS
> on death — even SIGKILL); acquiring the exclusive lock is proof that prior
> instances ended, so it clears leftovers tagged with a DIFFERENT owner pid (pids
> are unique among live processes); a current-pid live lease is never cleared.
> `runFileExclusiveMaintenance` enters its callback only after: admission generation
> valid → new borrows blocked → intent fenced → main borrows drained → new
> secondaries blocked → every shared lease RELEASED (or, only at startup, its owner
> proven ended) → uncertain holders yield a typed timeout → stable-zero verified.
> Proven with a REAL `Process.start` test (a live external holder is not reaped;
> after SIGKILL its leftover is recovered and a new instance token minted) plus the
> deterministic isolate/race/timeout suite. Restore/reset itself is NOT started.
>
> **Prior — Status (2026-08-06): Batch 4 closure #3 — ADMISSION GENERATION + RENEWABLE
> (heartbeat/fencing) lease.** Closure #2 shipped the cross-isolate filesystem
> lease; closure #3 fixed two correctness gaps the reviewer flagged in it.
>
> **(1) Ownership is an admission GENERATION, not UID-only.** A UID alone cannot
> invalidate work from a PREVIOUS session of the SAME user (`A→sign-out→A`, or
> `A→B→A` — a stale job still carrying UID A would be accepted). Phase-2 admission
> (`AppSession`) now stores a cryptographically-random generation nonce
> (`local_data_owner_generation`, `Random.secure()`) beside the owner UID: minted
> on every genuine (re-)admission (idempotent within a live session so its own
> in-flight jobs stay valid) and invalidated BEFORE any sign-out purge / wipe /
> ownership change — so it rotates even when the same UID signs in again.
> `OwnershipGuard` binds a background job to an `AdmissionToken {ownerUid,
> generation}` (no secret/financial content) and re-validates it at ALL FIVE
> boundaries: before the lease and before the secondary open (both inside
> `openSecondary`, typed `StaleOwnershipException`), immediately before the Drift
> commit, immediately before the native acknowledgement, and before any
> notification. Both production isolates (background capture-import + the
> notification-action isolate) capture the token and abort a superseded session
> WITHOUT committing, acknowledging, or notifying. This REUSES and extends the
> Phase-2 admission system — no second identity.
>
> **(2) Leases and the maintenance intent are RENEWABLE, not fixed-age.** A
> fixed-age file could be false-reaped while its holder is still alive (a long
> restore, a paused/suspended device, a forward clock jump). Each lease and the
> intent now carries a unique fencing token and a HEARTBEAT — a bounded periodic
> mtime bump done by REWRITING the file (a plain `setLastModified` truncates to
> whole seconds on macOS, too coarse for a bounded ttl). Liveness/expiry is
> measured from the LAST heartbeat, so long-running valid work stays protected
> indefinitely; stale recovery happens only after the heartbeat stops past the ttl
> AND a re-verification (unchanged token+mtime); cleanup is token-matched (an older
> holder's cleanup can never remove a newer lease/intent); a killed isolate simply
> stops beating and becomes recoverable after the ttl — never a permanent lock. The
> files hold ONLY a random token — no UID, path, key, or financial data.
>
> **(3) The shared-acquire vs maintenance-intent race is provably closed.** Shared
> acquisition is TWO-PHASE (create the lease, THEN re-read the intent and back off
> if it appeared/changed); the maintenance side publishes its fenced intent, drains
> every pre-existing live lease, then requires a STABLE-ZERO settle so a lease
> created concurrently with the last drain check (which self-deletes on its own
> intent re-read) is waited out before any destructive work. Verified with
> deterministic REAL-isolate tests: both race windows, "maintenance never enters
> while a live shared lease exists", a 14-round cross-isolate zero-overlap hammer,
> long-op-survives-heartbeat, crashed-holder recovery, fencing, typed bounded
> timeout, and no-leaked-timer/file. `runFileExclusiveMaintenance` is the single
> explicit Batch-5 primitive (admission-validated → drain borrows → fence intent →
> drain every shared lease → callback quiesces/reopens → recoverable restores /
> unrecoverable → `recoveryRequired`). No Drift schema bump; no Supabase migration.
> Restore/reset itself is NOT started.
>
> **Prior — Status (2026-08-06): Batch 4 closure #2 — CROSS-ISOLATE lease + ownership
> generation.** The in-memory borrow/maintenance gate could not coordinate the two
> production secondary paths, which run as background isolates (Dart's
> RandomAccessFile.lock is POSIX-fcntl = per-PROCESS, so it cannot coordinate
> isolates within one process). Replaced with a FILESYSTEM lease every
> isolate/process sees: an ATOMIC maintenance-intent marker
> (File.create(exclusive:true), stale-recovered by bounded age) plus a REGISTRY of
> per-secondary lease files (created on acquire, deleted in `finally`).
> `openSecondary({leaseManager})` acquires a cross-isolate SHARED lease (held for
> the connection's lifetime, released on close) and is REFUSED (typed
> DatabaseLeaseUnavailable) while intent is active; `runExclusiveMaintenance(mode:
> fileExclusive, leaseManager)` publishes intent (refusing new secondaries),
> drains in-memory borrows AND every secondary lease with a bounded timeout, then
> runs — the file-exclusive contract the Batch-5 restore/reset will use; no
> deletion/replacement may begin while any shared lease exists. The two production
> secondary paths (background capture-import + notification-action isolate) now
> pass AppDatabase.appSupportLeaseManager(). Proven with a REAL Isolate.spawn test
> (a shared lease held in another isolate blocks exclusive maintenance in the
> main). Cross-isolate ownership generation: OwnershipGuard reuses the Phase-2
> admission owner UID (secure storage → visible to every isolate); a background
> job captures the owner at creation and re-checks before commit/native-ack, so a
> sign-out / wipe / ownership change aborts the old-user job WITHOUT committing
> (no leaked previous-owner rows — tested). +15 more closure tests (7 lease + 8
> integration/ownership/watcher). No Drift schema bump; no Supabase migration.
> MALI-069n + the MALI-027 lifecycle tail → Code complete · locally verified;
> native process timing + real-device SQLite contention pending.
>
> **Prior — Status (2026-08-06): Batch 4 closure — the maintenance boundary is now
> ENFORCEABLE, plus secondary admission, a typed busy taxonomy, and stream
> ownership.** The flag-only `runExclusiveMaintenance` became a real borrow/lease
> gate: `borrow<T>()` is REJECTED (typed `DatabaseLifecycleException`) after
> close/failed/recovery and QUEUED while maintenance holds the gate;
> `runExclusiveMaintenance` transitions to `maintenanceRequested` so new
> borrows/secondaries are refused/queued, DRAINS active borrows with a bounded
> `drainTimeout` (→ typed `maintenanceTimeout`), runs the action, returns to
> `open` on success, restores the prior usable state on a recoverable failure,
> and exposes the typed `recoveryRequired` state on an unrecoverable one (never
> publishing a partial database); cleanup is idempotent and never masks the
> original error. Secondary admission: `admitsSecondary` (open && not under
> maintenance) + `openSecondary({owner})` refused (typed) unless the owner is
> usable — the two production second-connection paths run where no owner is
> in-memory-accessible (a background isolate / no main connection), so their
> admission is file-level (the Batch-1 key-state gate + the shared PRAGMA +
> busy_timeout contract + the no-concurrent-migration rule), documented. Typed
> busy taxonomy: `mapDatabaseBusy` maps SQLITE_BUSY(5)/LOCKED(6) (+ the 261/262
> extended codes) to a retryable `DatabaseBusyException` using only the numeric
> result code — never the raw text, non-busy never misclassified — and
> `runWithBusyRetry` retries bounded then throws the typed error, never inside a
> transaction, with no reset/rotate. Stream/provider ownership: `appDatabaseProvider`
> is an OVERRIDE HOLDER (main/bootstrap owns the DB; no provider closes it), so a
> non-owning `ProviderContainer` disposal leaves the database open, and closing
> with a live Drift watcher completes cleanly (no use-after-close). +15 closure
> tests. No Drift schema bump; no Supabase migration. MALI-069n + the MALI-027
> lifecycle tail → Code complete · locally verified; native-isolate + real-device
> file-lock timing pending.
>
> **Prior — Status (2026-08-06): Batch 4 — database connection lifecycle, failed-init
> cleanup, concurrent same-file access (MALI-069n + MALI-027 lifecycle tail) —
> Code complete · Locally verified (device-external).** Three defects fixed: (1)
> **connection/isolate leak on failed init** — `open()` awaited the migration
> pipeline and, on failure, left the native `createBackgroundConnection` + its
> background isolate alive; `_finishOpen` now closes the connection on ANY init
> failure (best-effort — never masking the original typed error, verified the
> original error propagates), marks the lifecycle `failed`, and rethrows, with no
> key rotation and no file deletion (the Batch-1 missing-key / corrupt-DB / wrong-
> passphrase / fresh-install distinctions are preserved). (2) **missing
> busy_timeout** — the single centralized connection-configuration contract in
> `_openEncryptedConnection` (SQLCipher-correct order: cipher → verify extension →
> key → prove key → foreign_keys) now also sets `busy_timeout = 5000` on EVERY
> production connection, so the background second connection racing the main one
> waits a bounded time instead of failing immediately with SQLITE_BUSY. (3)
> **uncontrolled second connections** — the two same-file second connections (the
> background capture-import in `captured_message_processor` and the
> notification-action background isolate in `local_notification_service`) called
> `AppDatabase.open()`, which ran the full migration pipeline; they now use
> `AppDatabase.openSecondary()` (`runMigrations:false`) — same authoritative key +
> the same PRAGMA contract, but the migration pipeline is NEVER run concurrently
> from two connections, and each is closed in a `try/finally`. Added a typed
> `DatabaseLifecycleState` (opening/open/closing/closed/failed), an idempotent
> `close()` that waits for any in-flight init to SETTLE before teardown (a
> concurrent close shares one teardown), and a `runExclusiveMaintenance` lifecycle
> primitive (§10) that serialises + marks maintenance and always clears the flag —
> the abstraction the Batch-5 restore/reset matrix will build on (Batch 4 does not
> rewrite restore). No Drift schema-version bump; no Supabase migration. 8
> real-Drift lifecycle tests. External: on-device native-isolate leak audit + real
> file-lock contention. **Migrations 0068–0076 remain undeployed; kServerRevisionCas
> false; migration 0070 inactive.**
>
> **Prior — Status (2026-08-06): Batch 3 closure — the four approved remote-backup
> tails implemented.** (1) **Truthful UI/provider state:** `RemoteBackupController`
> (StateNotifier) is wired into the backup screen; the label + icon derive from
> the typed `RemoteBackupState`, so "محمي/Protected" renders ONLY for
> `enabledIdle` (a committed + verified generation) — never on local encryption,
> a staging upload, or metadata creation alone. `refresh()` reconstructs from
> remote truth on startup/resume, sign-out resets, and one operation coordinator
> (busy-mutex) serialises manual/automatic backups so they can never independently
> upload duplicate generations; a consent gate blocks uploads when cloud consent
> is OFF. (2) **Server-atomic generation CAS:** migration **0076**
> `commit_backup_generation` (SECURITY DEFINER, fixed search_path, PUBLIC/anon
> revoked, authenticated-only) derives the owner from auth, verifies the
> owner-scoped object path + byte size from `storage.objects`, takes a `FOR
> UPDATE` row lock, rejects a stale expected generation, guards operation
> conflicts, replays the winning operation idempotently, moves the pointer in ONE
> transaction, and retains the previous generation — the adapter now commits via
> this RPC (backup-specific; `kServerRevisionCas` stays false). (3) **Trigger
> coordination:** an audit found the app has NO automatic background backup
> triggers (backup runs only on manual action + enable); both route through the
> coordinator with the consent gate + serialization + sign-out invalidation (no
> new background-execution framework introduced). (4) **Retention:** the publisher
> keeps the current + one previous known-good generation, prunes the 2-back only
> after the replacement commits, and `pruneOrphans` clears abandoned staging
> objects; `deleteRemoteBackups` is the explicit destructive path. A
> credential-gated real-Supabase Storage/RLS/CAS harness is added (skips honestly;
> the fake store does not prove live RLS or PostgreSQL concurrency). +18 closure
> tests. MALI-076n remote portion + MALI-014 → Code complete · locally verified;
> live Supabase Storage/RLS + two-device verification pending. **MALI-069n
> untouched (Batch 4).**
>
> **Prior — Status (2026-08-06): Batch 3 — remote-backup state, safe publication,
> verified download (MALI-076n remote portion + MALI-014 remote reliability) —
> Code complete · Locally verified (live-backend + UI + retention tails
> external).** The remote-backup flow used a boolean (`backupEnabled`/`hasBackup`)
> and uploaded with `upsert=true` to a single fixed `backup.enc` object — so an
> interrupted upload could REPLACE the only valid backup, and the UI could claim
> protection before a verified commit. New: a typed `RemoteBackupState` machine
> (16 states; only `enabledIdle` = Protected), a `RemoteBackupErrorKind` taxonomy
> (distinct from the envelope + DB-key errors), and a bounded exponential-backoff
> retry policy (offline pauses without consuming an attempt; terminal ≠
> retryable). **Safe generation publication** — `RemoteBackupPublisher` over an
> injectable `RemoteBackupStore`: each backup uploads to a UNIQUE per-generation
> object path, the size is verified, the pointer is committed with a
> compare-and-set on the previous generation, and the old object is retired ONLY
> after the new pointer commits, so an interrupted upload can only orphan a new
> object and never replaces the last valid backup. **Verified download** — size +
> encrypted-blob SHA-256 checked before any decryption (a transport check, never a
> substitute for the v3 AEAD authentication). **Lost-response idempotency** — a
> retry of the same generation returns the committed result with no duplicate
> upload. **disable() is now stop-only**; deleting remote data is a separate
> explicit `deleteRemoteBackups()`. Migration **0075** (additive, undeployed) adds
> the generation/hash/operation/status pointer columns; ownership stays
> server-enforced (owner RLS on `backups` + the storage `<uid>/` folder RLS — a
> caller-supplied owner id is never authoritative, a leaked path alone grants no
> access). The `SupabaseRemoteBackupStore` adapter is wired into
> `backupNow`/`restore`. 28 new tests (state/retry 11 + publication/download 12 +
> contract 5), proven with an injected fake store. **Remaining tails (NOT this
> batch, external/follow-up):** truthful UI-state rendering (§16), automatic-
> trigger changes (§14), multi-generation retention/pruning (§15), a server-atomic
> CAS RPC, and credential-gated live Supabase Storage/RLS tests. **MALI-069n stays
> untouched (Batch 4).** External: live Supabase round-trip + two-device conflict +
> device.
>
> **Prior — Status (2026-08-06): Batch 2 — versioned authenticated backup envelope
> (MALI-076n backup-envelope portion + MALI-014 format-compat) — Code complete ·
> Locally verified (device/cross-platform external).** The legacy v1/v2 blob
> header (version/kdf/cipher/salt/nonce) was UNAUTHENTICATED and the algorithm
> fields were DECORATIVE (decrypt hardcoded AES-GCM/Argon2id and ignored them);
> there was no magic identifier, no resource limits on blob-declared lengths, and
> `enable()` silently trimmed the passphrase. **New v3 envelope:** magic
> `MALIBAK`, `envelopeVersion:3`, `schemaVersion`, `cipher:aes-256-gcm`,
> `kdf:argon2id` + `kdfParams{memory:65536 KiB, iterations:3, parallelism:2,
> hashLength:32}`, `compression:none`, all cryptographically bound as AES-256-GCM
> **additional authenticated data** to the payload AND every key slot — a modified
> header field, algorithm id, or KDF parameter fails authentication before any
> restore mutation. The content-key + password/recovery-slot model is preserved
> (slot AAD excludes schemaVersion so stored slots survive a snapshot schema
> bump). **Untrusted parameters and lengths are resource-limited BEFORE the
> expensive KDF** (memory 8–256 MiB, iterations 1–10, parallelism 1–4, salt
> 16–64 B, nonce = 12 B, ciphertext ≤ 64 MiB, ≤ 8 slots, blob ≤ 96 MiB),
> preventing memory/CPU DoS and allocation overflow. **Passphrase (v3):** exact
> UTF-8, no trimming, no Unicode normalization, case + whitespace significant
> (legacy v1/v2 keep their historical trim for old-backup recovery). **Typed
> `BackupEnvelopeException`** taxonomy, distinct from
> `LocalDatabaseKeyUnavailableException`; a wrong passphrase, tampering, and
> corruption are cryptographically indistinguishable and share one safe message.
> Restore order: `fromBytesChecked` (validate + limit) → decrypt/authenticate →
> Batch-1 column whitelist → preflight → destructive delete, so any failure leaves
> the current DB untouched. Writer emits **v3 only**; reader accepts v1/v2/v3 by
> the in-blob version marker (no exception-driven format guessing). Backups are
> uploaded as opaque encrypted bytes (no local staging file to make atomic; the
> Phase-5 managed-export lifecycle is unchanged). Remote metadata stays advisory —
> the envelope version lives inside the authenticated blob. 22 crypto/compat/
> resource/privacy tests; no schema or migration change. **MALI-069n was listed in
> the Batch-2 finding set in error; it is DB connection-lifecycle work and is
> DEFERRED to Batch 4 — no connection ownership/isolate/busy_timeout/second-
> connection/cleanup behavior was touched in Batch 2.** External: physical-device
> secure-storage + real encrypted round-trip + cross-platform KDF vectors.
>
> **Prior — Status (2026-08-05): Batch 1 — encryption-key & backup-schema hygiene
> (MALI-058n) — Code complete · Locally verified (device-external).** Root defect:
> the DB seed copied the RAW SQLCipher key (`keyStore.readStoredKey()`) into
> `user_settings.db_encryption_key_ref`, which was ALSO in the backup column
> allowlist — so the raw local-database key was serialized into every backup
> snapshot (recoverable from any blob decrypted with the user passphrase). The
> final contract is STRICTER than the original plan (which proposed storing a
> fingerprint): the column stores NOTHING — the raw key lives only in
> platform secure storage (`money_companion.db_key`), device-scoped, and is never
> in Drift, a backup, a sync payload, an export, a log, or telemetry. Restore
> writes through the destination's already-open encrypted connection and never
> mutates its key; the backup passphrase-derived key and the DB key are distinct
> and never interchangeable. Implementation: seed + repo writer write ''; the repo
> read never surfaces the column into the entity; excluded from the backup
> allowlist; restore filters every row to a CENTRAL column whitelist
> (`BackupSnapshotBuilder.restorableColumns`) so no arbitrary snapshot key reaches
> SQL, writes '' to the NOT NULL column, drops a legacy `db_encryption_key_ref`
> value, and FAILS CLOSED on any other key/secret-like field BEFORE the
> destructive delete; an idempotent post-admission repair (`clearDeprecatedDbKeyRef`)
> clears legacy values without reading them. Key-loss behavior is documented (no
> silent delete — explicit recovery UX; `readOrCreateKey` never consults a
> backup). No local schema-version bump (idempotent data repair, not a rebuild);
> no Supabase migration. 6 real-Drift behavioral tests. Gates green. Batches 2–6
> (passphrase envelope, remote-backup reliability, DB connection lifecycle,
> restore/recovery matrix, closure) not started. **External:** on-device
> secure-storage + real encrypted backup round-trip.
>
> **Batch-1 closure reconciliation.** Two gaps closed: (1) the approved contract's
> **typed missing-key state** — `open()` now resolves `classifyDatabaseKeyState`
> (keyPresent / freshInstall / keyUnavailable) BEFORE creating or using a key, and
> throws the typed `LocalDatabaseKeyUnavailableException` when an encrypted DB
> exists but its secure-storage key is gone (never mints a new key, never opens
> with a new key, never reads a key from Drift/backup, never deletes; the existing
> explicit recovery/reset UX is preserved). The four conditions are programmatically
> distinct: **DB-key missing** (typed state) · **wrong backup passphrase**
> (`SecretBoxAuthenticationError`) · **corrupt DB with a key** (a present key always
> classifies keyPresent) · **fresh install** (no DB + no key → normal key creation).
> (2) The egress checks previously "held by construction" are now **behavioral**:
> restore makes zero key-store calls (destination key unchanged, foreign key never
> written), a missing key never falls back to backup data, and the key canary is
> absent from the upload metadata, the CSV/full-package exports, and telemetry.
> 15 closure tests. MALI-058n → Code complete · locally verified; physical-device
> secure-storage + real encrypted backup round-trip pending.

- MALI-058n: **DONE (Batch 1 + closure)** — stop storing the SQLCipher key in `user_settings`/backups (store NOTHING; the key stays in secure storage; restore writes '' + whitelists columns + fails closed on unknown key-like fields); typed missing-key state + end-to-end isolation evidence.
- MALI-076n: validate backup `version`/`kdf`; normalize passphrase trim; distinguish network-error from no-backup; whitelist restore columns against `_tables`; delete the dead `data_export.dart` clipboard helper.
- MALI-069n: close the connection/isolate on failed init; set `busy_timeout`; define safe second-connection behavior for the background notification path.
- MALI-073n: add `transactions(account_id)`/`(category_id)` indexes (measure query plans; address the NULL-account OR-subquery that defeats them).

## PHASE 7 — CI, tests, architecture, performance, docs

> **Status (2026-08-06): Batch 1 CLOSURE — CI/test-harness/skip/lint/known-failure
> truthfulness (Code complete · Locally verified).** `tools/ci_gates.sh` is the SINGLE
> truthful canonical gate (local == CI, no CI-only subset or extra step): it runs the
> previously CI-invisible Deno lint + Node contract + admin auth suites, a
> machine-readable **skip/ignore manifest** gate, and **l10n** freshness (`.g.dart` is
> gitignored — a git-diff on it was a false-green; committed `app/lib/l10n` is the real
> staleness surface, checked inside the gate). It latches failures (`PIPESTATUS`,
> `fail=1`, banner guarded by `fail==0`), reports UNAVAILABLE toolchains separately, a
> truthful **nested summary** keeps passed/failed/unavailable/node-skipped/deno-ignored/
> lint-exceptions SEPARATE (+ secret-free `CI_GATES_JSON`), and self-tests its own
> failure propagation (`--self-test` / `CI_GATES_INJECT_FAILURE`). Skip policy is
> enforced by `tools/test_skip_manifest.json` + `tools/check_test_skips.mjs` (unexpected/
> disappeared skip, changed reason, ignored-without-entry, partial/present-credential all
> FAIL). The locally-testable `Process.start` kill test no longer skips under load
> (generous readiness + bounded retry; rollback asserted; only genuine dart/native-sqlite
> absence skips) — 3/3, 0 skips under full load. Exactly **7** retained `deno-lint-ignore
> no-explicit-any` exceptions, documented + allowlist-contracted. **MALI-041** reconciled
> to its authoritative identity (double-quote assertion vs single-quote source;
> `FULL_APP_AUDIT.md:622` / `FINAL_FULL_PRODUCTION_AUDIT.md:122`), baseline reproduced,
> quote-independent contract + **regression** added → admin **8/0**; distinct from
> **MALI-066n** (partially addressed — the wired suites are now mandatory + contract-
> proven; per-function test dirs + `verify_ios_packaging.sh` remain). All 4 Deno-lint
> findings fixed, no semantic change. No production feature behavior changed. See
> `app/docs/PHASE_7_TEST_AND_CI_CONTRACT.md`. Batch 1 approved + closed.
>
> **Status (2026-08-07): Batch 2 (IN PROGRESS) — performance (query/provider/startup/
> rendering/reporting/background).** Structural budgets (query/rebuild counts, rows,
> bytes — never wall-clock). **MALI-073n DONE:** evidence-backed hot-path indexes
> (composite `(account_id, occurred_at)` subsuming single-column account_id + serves
> `account_id=? ORDER BY occurred_at` without a temp sort; `category_id`), schema v29,
> version-owned + postflight-verified (EXPLAIN before/after). **MALI-029 B2-A DONE:**
> domain-scoped provider invalidation (`tableWriteStream` → `scopedRevisionProvider` /
> `financialRevisionProvider`; unrelated→0 rebuilds, relevant/display-dep→1, burst→≤2,
> operational→0) + **pull-batching complete for every production-reachable path** via a
> central bounded-ID chunk primitive (`bounded_lookup.dart`, chunk=500, bound-vars only):
> AccountsPull 3/5, PlanningPull subs 4/6 + budgets 5/7, PlanningChildSync 6/10 SELECTs
> @100/@1,000 rows (O(distinct+chunks), not O(rows)); shared `saveTransaction`
> `resolvedCategoryId` fast path (0 category SELECTs, fail-closed via FK, type-forcing
> kept); prior accepted CaptureSync/LedgerSync/SenderBankMapping. Cadence: adaptive backoff
> + coalescing + offline/ownership `SyncGate` (outbox-derived reachability, admission
> generation). No unexplained active O(rows) FK-resolution loop remains (push=network-bound
> per-item; smart-inbox pull self-lookup + import fuzzy dedup = intentional non-FK;
> backfills=migration-only; financial_cache_repair=MALI-034 dormant). **MALI-038
> partial:** removed 8.1 MB unreferenced assets + asset-size budget; **font portion
> pending a product decision** (offline Alexandria not bundleable; switch to vendored
> IBM Plex Sans Arabic is a visible typeface change). MALI-030 CODE COMPLETE (B2-B + closure): streaming backup plaintext (no full object graph/JSON String), truthful appendix omission rendered in the PDF (ar/en), enforced 100 MiB export cap, 48 MiB plaintext cap; irreducible bounded buffers = v3 plaintext/ciphertext + export ZIP (none device-only). **B2-B DONE (MALI-030):** report largest→SQL top-N, appendix keyset-paged+capped, CSV/full-export paged, backup snapshot paged + copy dropped, pre-encryption 48 MiB plaintext cap; v3 one-shot residual is a bounded crypto-library constraint (not device-external). **Remaining in B2:** the other
> ~14 pull/backfill batchings + sync cadence; MALI-030 memory; rendering; startup; the
> font decision. No financial semantics/precision/currency/refund/period/restore behavior
> changed. CAS false; 0070 inactive; 0068–0076 undeployed; not pushed. See
> `app/docs/PHASE_7_PERFORMANCE_CONTRACT.md`. Batches 3–5 not started.

- MALI-066n: **P7-B1 partial** — admin auth suite, Deno `_shared` tests + lint, Node contract, skip manifest, migration lint, l10n freshness are now mandatory in the ONE canonical gate (`tools/ci_gates.sh`), contract-proven wired. **Remaining:** wire `verify_ios_packaging.sh` into the gate; run per-Edge-function test dirs beyond `_shared/`.
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
