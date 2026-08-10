# Phase 7 — Local closure record (final reconciliation)

Batch 5 is a reconciliation-and-closure pass, not a feature batch. It reconciled
every locally completed remediation layer, attacked cross-phase assumptions, and
ran the authoritative final local validation. **No production code change was
warranted** — the reconciliation found no regression or contradiction. Nothing
deployed, nothing pushed; MALI-026 remains deferred to Phase 8.

Invariants held throughout: schema **v29**, `kServerRevisionCas=false`, migration
0070 inactive, migrations 0068–0076 undeployed, backup envelope **v3**,
canonical brand **Qirsh/قِرش**, bundle id `com.youssefsafwat.mali` unchanged.

## A. Phase-7 status (batches + earlier phases)

| Layer | Status |
|---|---|
| Phase 1–6 remediation | Code complete · Locally verified (device/live-backend external per each closure record) |
| P7 Batch 1 (CI truthfulness / canonical gate) | Closed · LV |
| P7 Batch 2 (performance + Argon2 gate determinism + fonts) | Closed · LV (approved 2026-08-08) |
| P7 Batch 3 (MALI-034 financial authority + MALI-040 DB/close lifecycle) | Closed · LV (approved 2026-08-10) |
| P7 Batch 4 (privacy/CI-coverage/deps/test-integrity/ops/docs + iOS provenance) | Closed · LV (approved 2026-08-10) |
| P7 Batch 5 (this — final reconciliation) | Code complete · LV |

## B. Finding ledger — final local status (rollup; per-finding rows in REMEDIATION_STATUS_LEDGER.md)

- **Closed · Locally verified / Code complete · LV (local):** the bulk of
  MALI-001…077n (architecture, ownership, sync, backup, privacy, native-contract,
  tooling). No P7 finding remains "Not started."
- **Source remediated — deployment pending (undeployed migration/backend):**
  MALI-044 (metrics RLS, `0072`), MALI-024 (engagement/gamification server
  authority, `0070`/`0073`/`0074`), MALI-076n/014 remote-backup generations
  (`0075`/`0076`), MALI-022/052n/057n live revision-CAS (`0068`, `kServerRevisionCas=false`).
- **Code complete — external verification pending:** device/APNs/live-Supabase/
  signed-archive items (002–006, 012, 013, 017, 019, 020, 025, 031, 033, 058n,
  060n, 065n, 068n, 069n, 075n; MALI-036 hosted CI).
- **Superseded:** MALI-021 (folded into 076n/065n/077n).
- **Deferred to Phase 8:** MALI-026 (fixed-precision money).

No duplicate ownership; CODE closure is distinguished from DEPLOYMENT closure
(the "source remediated — deployment pending" class is never marked CLOSED).

## C. Cross-phase reconciliation results (§3 scenarios → proving evidence)

| Scenario | Proven by | 
|---|---|
| A. A→sign-out→B isolation (no A rows/capture/notif-action/stale-generation leaks to B; owner marker correct) | `transactions_backfill_service_test` (end-to-end sign-out wipe + owner-conflict refusal + mid-run fail-closed), `accounts_backfill_service_test`, AppSession sign-out/wipe + `OwnershipGuard`/admission tests, notification-action ownership (MALI-069n) |
| B. Local edit + sync + account switch (atomic write/outbox; stale generation can't push/apply/clear) | in-slot `legacy_financial_cache_reconciler_test` (exact-generation admission, cancellation ≠ transport failure), SyncGate admission tests, `revision_cas_test` |
| C. Dirty historical cache + pending local edit (push-first, epoch-pull second, no overwrite, atomic admitted clear) | `legacy_financial_cache_reconciler_test`, `ledger_sync_engine_reconcile_test`, per-puller `*_pull_status_contract_test`, `financial_cache_reconcile_map_test` |
| D. Backup/restore + DB lifecycle (ownership preserved; failure leaves DB valid; leases close; no stale Drift stream state) | `test/core/backup/` (161), `database_close_lifecycle_test`, `database_lease_test`, `database_lifecycle_test`, restore-pipeline/journal tests |
| E. Capture→transaction→notification (stable payload id; one txn; one notif; no replay duplicate; retention) | `capture_sync_service_test`, `local_notification_service_tracking_test`, `notification_privacy_test`, dedup/idempotency tests |
| F. Reporting consistency (one canonical txn/currency/refund semantics across dashboard/report/export) | `financial_totals_invariant_test` ("canonical totals stay equal across headline, views, budget, and report"), `financial_cross_surface_invariant_test` |
| G. Data portability (Drift-authoritative; idempotent import; no legacy repair/repo path; no dirty-marker writer) | `app_data_portability_service_test` (10), `drift_financial_importer_test` (incl. hostile-id SQL), arch guard |

All run within the canonical gate's bulk lane. Adding duplicate integrated
"umbrella" tests was declined (per the simplicity guideline and to avoid flakiness
risk to the first-attempt-green closure gate); each cross-boundary property is
already proven by a dedicated suite above.

## D. Architecture negative-proof counts (production `app/lib`, code-only)

`FinancialCacheRepairService` **0** · retired Supabase financial CRUD repos **0**
· `Routed*` financial wrappers **0** · quoted `*_supabase_primary` selectors **0**
· `dontWarnAboutMultipleDatabases` (lib+test) **0** · runtime `google_fonts`
(dep/path; only history comments remain, absent from `pubspec.lock`) **0** ·
embedded `BankMessageShortcuts.appex` obsolete extension **0** · external Dart
callers of the deleted `consumePendingSharedMessages` **0** ·
`markFinancialCacheDirty`/`mirrorFinancialCacheSafely` **0**. Enforced by
`tools/check_arch_guard.sh` (6 checks, negative-self-tested).

## E. Migration 0068–0076 compatibility (undeployed; client forward-compatible)

| Mig | Purpose | Client dependency while UNDEPLOYED |
|---|---|---|
| 0068 entity_revision_cas | server optimistic concurrency | none — `kServerRevisionCas=false`; client sends `updated_at`, not `revision` |
| 0069 sender_mapping_sync_durability | durable sender-mapping sync | additive server-side; client sync uses existing behavior |
| 0070 engagement_events | server-authoritative engagement | **inactive**; client records to a local outbox + shows a LOCAL projection (`projectedXp`); a failed `record_engagement_event` just leaves events pending |
| 0071 ai_endpoint_hardening | AI consent + idempotency | AI capture is optional; old endpoint behavior; graceful |
| 0072 backend_security_hardening | metrics RLS + `record_metric` RPC (MALI-044/075n) | `record_metric` is best-effort `try/catch(_)` (swallowed, never blocks bootstrap) |
| 0073 gamification_aggregate_readonly | remove client-authoritative XP write | server-side hardening; client local projection carries UI |
| 0074 gamification_atomic_award | atomic award ledger | additive; runs after 0073 |
| 0075 remote_backup_generations | remote-backup generation pointer | remote backup is optional cloud feature |
| 0076 backup_generation_cas | server-atomic backup commit (`commit_backup_generation`) | typed `RemoteBackupException(storageUnavailable)` on absence; core (local) backup/restore unaffected |

**No core-function client behavior requires an undeployed migration** — every
dependency degrades gracefully (swallowed / typed-error / local-projection).
Reconfirmed: 0070 inactive; `kServerRevisionCas=false`; 0072 source-remediates
metrics but is undeployed; backup migrations undeployed; client does not assume
any of them live.

## F. Wire-format compatibility

| Format | Versioning | Compatibility |
|---|---|---|
| Ledger push payload | `kLedgerPayloadVersion=2` + legacy `type`/`source`/`direction` kept for downgrade | writer↔reader current; older builds read the legacy fields |
| Backup envelope | v3 (`envelopeVersion`; magic + header-AAD) | v1/v2/v3 read, v3-only write (unchanged) |
| Data-portability package | `qirshPackageVersion` (reader rejects `> current` and `< 1`) | forward/back guarded |
| Sync cursor / revision | `(updated_at, id)` keyset; `server_revision` sent but server-ignored while 0068 undeployed | no unversioned incompatible payload introduced this phase |

No new wire format introduced in Batch 5.

## G. Test / gate counts

Authoritative `tools/ci_gates.sh` run once from committed clean tree `b8289aa5`,
**first attempt green**:

```
mandatory gates passed : 13
mandatory gates failed : 0
tools unavailable      : 0
node tests skipped     : 27  (credentials absent — see manifest)
deno tests ignored     : 2   (live-Postgres — see manifest)
skip/ignore manifest   : satisfied
ALL LOCAL GATES PASSED
```

- flutter test bulk (crypto excluded): **1589**; crypto serialized: **24**.
- deno (ALL functions): pass, 2 live self-skip; deno lint pass.
- migration lint, node contract, admin auth, l10n freshness: pass.
- architecture guard **6/6**; dependency policy **3/3** (offline).
- iOS packaging: **CURRENT artifact — provenance-verified** (source contract in
  `flutter test`; signed archive external).

## H. Executable verified commit

`b8289aa5` (executable-identical to the Batch-4 closure `82cd7e6f`; no production
change in Batch 5).

## I. Documentation-only closure commit

The commit that adds this record (docs-only; the executable-verified HEAD is
`b8289aa5`).

## J. External-evidence ledger (consolidated — remains pending)

- Live migrations/RLS/functions/cron/Vault (0068–0076 deploy + verify).
- APNs push delivery; signed **App Store** archive + privacy report/questionnaire.
- Physical iPhone behavior (notifications capacity/priority, biometrics, App-Group
  Keychain cross-process, background/exact-alarm).
- Android SDK/release AAB + merged manifest; **Play** SMS-permission policy review.
- Multi-device live conflict / 2-device CAS tests; hosted-CI compatibility matrix.
- Rollback rehearsal; store/privacy questionnaires.
- CVE/advisory feed (the offline deps-policy gate is the local half of MALI-037).
- Real battery/background/performance/jank profiling on device.

No local substitute was manufactured for any of these.

## K. Phase-8 handoff — MALI-026 (fixed-precision money) prerequisites

- **Schema version ownership:** `_targetSchemaVersion` in `app_database.dart` (29);
  a money-representation change bumps it + adds a migration case.
- **Migration transaction model:** the pipeline is the sole `PRAGMA user_version`
  owner (`enableMigrations:false` + `NoVersionDelegate`); MALI-026 migration must
  follow it.
- **Backup versioning:** changing stored money fields changes snapshot content →
  a backup-envelope compatibility decision (v3 read path must still parse old
  money fields, or a v4 with a documented read matrix).
- **Money fields (Drift / Supabase / wire):** `amount`, `balance_after`,
  `foreign_amount`, budget/goal/subscription amounts, and their server columns +
  ledger/portability payloads — all currently `double`. Fixed-precision means a
  coordinated Drift + server + wire change.
- **Currency scales:** per-currency minor-unit scale (the `Currency` helper) must
  drive precision.
- **Rollback/compatibility:** a build reading old double money and a build reading
  fixed-precision must not corrupt each other's local/backup/synced state.

MALI-026 is **not** implemented; these are the inherited constraints only.

## L. Git state

Clean working tree; nothing pushed; feature branch `feat/phase1-data-integrity`.

---

**Allowed Phase-7 closure statement (on green reconciliation):**

> Phase 7: Code complete — locally verified across architecture, ownership, sync,
> backup, privacy, native-contract, and tooling boundaries. Remaining release
> evidence is explicitly external; MALI-026 fixed-precision money remains deferred
> to Phase 8.

This is **not** a declaration of production-readiness.
