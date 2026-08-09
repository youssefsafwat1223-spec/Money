# Phase 7 · MALI-040 — Test database / executor ownership & isolation

**Finding (FULL_APP_AUDIT MALI-040):** test-suite isolation concerns —
`dontWarnAboutMultipleDatabases` suppression, executor ownership, and the lack of
randomized ordering. The notification-timing sub-finding was closed earlier
(`94571f4b`); this closes the remaining historical finding.

## §1 Inventory (complete, before any patching)

- **111** test files construct an `AppDatabase`.
- **0** leave a database unclosed — every one closes deterministically via
  `addTearDown(db.close)` or `tearDown`.
- **0** share a `QueryExecutor`/`DatabaseConnection` across two wrappers — every
  `open()` receives a **fresh inline** `NativeDatabase.memory()`/`File()`; no
  executor is assigned to a variable and reused. So the *actual* hazard the Drift
  warning names ("two databases use the same QueryExecutor") exists **nowhere**.
- **4** files used `driftRuntimeOptions.dontWarnAboutMultipleDatabases` (prod: 0).
- **632** "created the database class AppDatabase multiple times" warnings across
  103/111 files — ~one per test after the first, firing even in isolation.

## Root cause — a production close() lifecycle bug (not a test defect)

Test ownership was already deterministic. The warnings came from production:
`AppDatabase.close()` overrode `GeneratedDatabase.close()` and, in `_close()`,
called `await executor.close()` directly but **never `super.close()`**. Drift's
own teardown lives only in the super chain:

```dart
// drift GeneratedDatabase.close():
await super.close();            // DatabaseConnectionUser.close → streamQueries.close() + executor.close()
devtools.handleClosed(this);
assert(() { _openedDbCount[type]--; }());   // the counter that drives the warning
```

Skipping it meant (a) Drift's stream-query manager was never disposed on close —
a real teardown leak, since `.watch*` is used in **60 lib files** and the DB is
closed+reopened on sign-out / account-switch / restore (the MALI-069n
owner-lifecycle paths); (b) the open-db counter never decremented, so it climbed
monotonically and every later `open()` warned; (c) `devtools.handleClosed` never
fired.

**Fix (`fix(db): close Drift database lifecycle correctly`):** in `_close()`,
replace the bare `executor.close()` with `super.close()`. Each `AppDatabase`
owns its own executor (main, each secondary, and every test open independent
connections; the file-level lease is not an executor share), so `super.close()`
closes this instance's executor exactly once — no double close — while disposing
streamQueries, decrementing the counter, and notifying devtools. The Phase-6
lease release, lifecycle-state transitions, custom controller closes, and the
idempotent `_closeFuture` guard are unchanged.

**Regression** (`test/data/db/database_close_lifecycle_test.dart`, fails on the
old code, no suppression): watch a query → close → reopen ⇒ no multi-db warning;
watch stream is terminated on close (streamQueries disposed); close() idempotent.

## §5 Ownership classification of residual concurrent instances

After the fix the warnings drop **632 → 57**, all in tests that hold **≥2
concurrent** `AppDatabase` instances **by design**, each with its **own**
executor and deterministic close:

- backup ↔ restore (`restore_recovery`, `restore_pipeline`, `restore_fk_safety`,
  `restore_compatibility`, `backup_completeness`) — source + restored target.
- key hygiene / isolation / egress / device-transfer — source + target device.
- data portability / importer — export source + import target.
- cross-device sync (`card_/settings_/category_sync_service`) — `db` + `dbB`.
- migration ownership (`migration_version_ownership`) — `dbProd` + `dbFramework`.
- query-count harnesses (`transaction_page_filter`, `ledger_sync_service`) —
  main + an intercepting-executor counting DB.

These are §5 "multiple wrappers genuinely required" (case B/E): independent
executors, explicit ownership, deterministic close. **No shared-executor
duplicate-ownership defect exists** to fix.

## §3 Suppression removed

All **4** `dontWarnAboutMultipleDatabases` suppressions removed (with their now-unused
`driftRuntimeOptions` imports). Prod = 0, tests = 0. Each formerly-suppressed file
runs green with **0** warnings unsuppressed — proof the suppression was masking the
production close() bug, not a test-ownership issue.

## §8 CI warning policy

`tools/check_arch_guard.sh` (a mandatory `ci_gates.sh` stage) now forbids
`dontWarnAboutMultipleDatabases` anywhere in lib or test (self-tested to fail on
reintroduction). Global *fail-on-warning* is **not** practical: the 57 residual
warnings come from legitimate concurrent independent-executor tests, and Drift's
by-type heuristic cannot distinguish them from the (non-existent) shared-executor
case. Per §8 we therefore rely on: **zero suppression + deterministic single-owner
close + the static guard**, with the production fix making any *future* warning a
meaningful signal of a genuine concurrent instance.

## §9 Randomized ordering

Supported and honored: `flutter test --test-randomize-ordering-seed=<seed>` emits
`Shuffling test order with --test-randomize-ordering-seed=<seed>` and shuffles
test order within each suite. The isolation-sensitive suites (`test/data/db/`,
`test/features/planning_sync/`, `test/features/capture/`, `test/core/backup/` —
**615 tests**) pass under shuffle (seed `20260809`), confirming no hidden
inter-test ordering dependencies in the DB-heavy paths (consistent with the
inventory: every test opens its own DB in `setUp`/`test` and closes it in
teardown, sharing no state).

**Decision:** prefer a **deterministic fixed-seed** strategy (reproducible /
debuggable) over per-run random — this satisfies the constraint against opaque
shell-level random execution. It is **not** wired into the mandatory closure gate
in this commit, to keep that gate deterministic and first-attempt-green;
recommended as a dedicated CI lane (a fixed-seed shuffled run) once a full-suite
shuffle audit is green. Per the finding, this is secondary to the ownership fix,
which is complete.

## §7 Isolation proofs

- `database_close_lifecycle_test.dart` — test-A DB fully closed before test-B open
  (counter balanced), no use-after-close (stream terminated), idempotent close.
- Existing Phase-6 coverage retained green: `database_lease_test`,
  `database_lifecycle_test`, `database_closure_test`, `database_gate_test`,
  `database_key_state_test`, migration + restore suites, owner/sign-out lifecycle.

## Closure gate

Canonical `tools/ci_gates.sh` run **once** from the committed clean tree
`54e53a60`, **first attempt green**:

```
mandatory gates passed : 11
mandatory gates failed : 0
tools unavailable      : 0
skip/ignore manifest   : satisfied
ALL LOCAL GATES PASSED
```

- flutter test bulk (crypto excluded): **1582 passed** — residual Drift multi-db
  warnings **57** (all legitimate concurrent independent-executor tests).
- flutter test crypto (serialized Argon2, `--concurrency=1`): **24 passed**.
- arch guard **6/6** — including the new MALI-040 check "no Drift multi-db
  warning suppression".

**Closure conditions met:** production close lifecycle correct; warning
suppressions = 0; unclosed test databases = 0; no shared-executor duplicate
ownership (residual concurrency is legitimate, independent-executor, closed);
canonical gate first-attempt green. **MALI-040 is closed** on
`feat/phase1-data-integrity` (not pushed).

**Status:** MALI-040 — Code complete — locally verified; test database/executor
ownership is deterministic, all test databases close explicitly, and Drift
multiple-database warning suppression has been removed. The underlying
production `close()` lifecycle defect (skipped `super.close()`) is fixed in
`f33d6e58`.

## Invariants preserved

Schema **v29**, `kServerRevisionCas=false`, migration 0070 inactive, 0068–0076
undeployed, backup envelope **v3**. No schema/flag/migration/wire change.
