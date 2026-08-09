# Phase 7 · Batch 3 — Final cleanup & closure

Batch-3 reconciled the financial-authority architecture (MALI-034) and the test
database/executor ownership + a production close() defect (MALI-040), then swept
for residual escape hatches, verified retained backfill ownership, and locked the
invariants behind a static guard. Nothing pushed; schema stays v29.

See also: `PHASE_7_MALI_034_CLOSURE.md`, `PHASE_7_MALI_040_CLOSURE.md`.

## Final finding status

- **MALI-034 — CLOSED.** Drift is the sole normal financial CRUD authority;
  Supabase is reached only through explicit sync transport / import-export /
  auth / catalog / backend / storage / RPC. Legacy Supabase-primary repos,
  `FinancialCacheRepairService`, `*_supabase_primary` (and `dashboard_supabase_summary`
  / `budget_progress_supabase_rpc` / `capture_direct_supabase_write`) flags,
  and the `Routed*` wrappers are retired. Historical dirty-state recovery is the
  in-slot `LegacyFinancialCacheReconciler`. Data portability is Option-A local
  Drift authority. Executable closure `a72f1b11`; docs-only record `0db06c48` +
  `0b165d88`.
- **MALI-040 — CLOSED.** Root cause was a production `AppDatabase.close()`
  lifecycle defect (skipped `super.close()` → Drift `streamQueries` never
  disposed + open-db counter never decremented). Fixed `f33d6e58`; the full Drift
  close lifecycle is restored. Test ownership inventory: 111 DB-owning files, 0
  unclosed, 0 shared-executor. Suppressions 4 → 0. Executable closure `54e53a60`;
  docs-only record `f86f1629`.

## Discrepancy with the historical audit (unclosed test databases)

The original audit statically flagged some DB-opening tests as leaving databases
unclosed. The full §1 ownership inventory **disproves** that as a literal leak:
every one of the 111 DB-owning test files closes its database **deterministically**,
but the close is frequently registered **indirectly** and so is invisible to a
shallow "does this test body call `.close()`?" scan:

- a shared factory helper (`Future<AppDatabase> _openDb() => AppDatabase.open(...)`)
  whose callers each register `addTearDown(db.close)` at the call site, or
- a group-level `setUp`/`tearDown` pair (`db = await _openDb()` … `tearDown(() => db.close())`).

A static scan that only matched an in-body `.close()` (or a per-file "has a close
somewhere" heuristic) mis-classified these as unclosed. Dynamically, Drift's own
open-db accounting confirms the closes happen: once the production `close()` bug
was fixed (`f33d6e58`), the multi-database warnings collapsed 632 → 57, and the
57 residual are all **legitimate concurrent independent-executor** tests (each DB
closed) — not leaks. So the historical finding was a **false positive of static
classification**; the real defect it was pointing at was the production close()
lifecycle bug, now fixed.

## §1 Dependency inventory — nothing removable

The MALI-034/040 cleanup deleted 8 Supabase financial repos, `FinancialCacheRepairService`,
8 `Routed*` wrappers, and fixed `close()`. No pubspec dependency became dead:

| Dependency | Historical consumer | Remaining consumers | Disposition |
|------------|--------------------|--------------------|-------------|
| `supabase_flutter` | deleted repos | 40 lib + 16 test (sync/backend/auth) | **retain** |
| `postgrest` | deleted repos | `domain/errors/repo_exceptions.dart` (`mapSupabaseError`) + sync | **retain** |
| all others | — | ≥1 live lib consumer each | **retain** |

No upgrades, no constraint changes — pruning only, and there was nothing to prune.

## §2 Residual Supabase-financial-authority sweep — clean

Production (`app/lib`) code references (comments excluded): `FinancialCacheRepairService`
0, retired Supabase financial repo import/ctor 0, `*_supabase_primary` /
`dashboard_supabase_summary` / `budget_progress_supabase_rpc` /
`capture_direct_supabase_write` selectors 0, `Routed*` 0, legacy mirror/mark
helpers 0. Remaining textual matches are history comments only. Canonical flow:
UI/use case → Drift repository → local transaction/outbox → explicit sync → Supabase.

## §3 Retained backfill ownership — mid-run safety

`StartupSyncReconcileService.run()` (invoked inside `_runLedgerSyncBody(gen)`
after an entry `_syncGate.admits(gen)` check) runs Accounts → Transactions →
PlanningPrimary backfills. Each captures the uid once and asserts local-data
ownership at **preflight** (`_assertLocalDataOwnership`: `ownerUid != null &&
ownerUid != uid` → refuse; null legacy owner intentionally allowed).

**Mid-run account/generation change is safe through an existing contract — not a
hole:**

1. **Entry admission** — `_runLedgerSyncBody` refuses to start the body under a
   stale generation.
2. **Preflight ownership** — a conflicting local owner blocks BEFORE any remote
   mutation (tested for all three backfills).
3. **Server RLS** — every target table (`user_transactions`, `accounts`,
   budgets/goals/subscriptions/plans, financial children, portability, settings,
   cards) enforces `WITH CHECK (user_id = auth.uid())`. A push whose `user_id` no
   longer matches the auth token (after a mid-run sign-out / switch) is **rejected**.
4. **Fail-closed** — a rejected write throws a typed `RepoException` (via
   `mapSupabaseError`); the local `server_id` is never stamped, so the row stays a
   backfill candidate and `StartupSyncReconcile` returns `failed` → retried next
   cycle under the then-current owner.

The backfill loop does **not** re-check the SyncGate generation per row (a design
choice): cross-account writes are made impossible by server RLS and no local state
is half-committed, so the mid-run window cannot leak or corrupt. Tested:
per-backfill preflight refusal + "never contacts Supabase when refused" +
null/matching owner (transactions/accounts/planning ownership tests), and a new
`mid-run server rejection … fails closed` test (server 42501 → throws, `server_id`
stays NULL).

## §4 SyncGate consistency (Batch-3-touched flows)

The in-slot `LegacyFinancialCacheReconciler` captures the exact generation and
re-validates it synchronously (`_admitted() = _isAdmitted(_generation)`) at every
page boundary; a sign-out (generation bump) makes it false even for the same user
re-authenticating under a later generation. `cancelled` (generation invalidated)
is a distinct outcome from `failed` (transport). The durable dirty marker is
cleared ONLY on true-EOF completion under a still-valid generation
(`clearFinancialCacheDirtyIfAdmitted`, atomic admit-check + UPDATE in one txn); a
stale run leaves the marker set so the next valid generation re-reconciles from
epoch — a stale run can never clear durable recovery state. All pull services
(accounts/ledger/planning/smart-inbox) thread `isAdmitted` through and check it
per page. No mechanical retrofit was applied elsewhere.

## §5 financial_cache_health final role

Schema v29; table retained (`CREATE TABLE IF NOT EXISTS`, not dropped).

- **Writers:** only `clearFinancialCacheDirty` / `clearFinancialCacheDirtyIfAdmitted`
  — both write `dirty = 0`. **No code path sets `dirty = 1`** (the mark-dirty
  helper was deleted in MALI-034).
- **Readers:** `isFinancialCacheDirty` + `readDirtyFinancialCacheMarkers`,
  consumed only by the in-slot reconciler (reconcile → clear) and the reconcile
  map (surface UNSUPPORTED historical markers, never guessed).
- **New markers:** normal CRUD **cannot** create dirty markers; data portability
  (Option A, local Drift) **cannot** create them either.

Role = historical durable dirty-state recovery / compatibility only. No new
Supabase-primary cache-repair cycle exists. No migration is introduced merely to
remove historical state.

## §6 Architecture guard

`tools/check_arch_guard.sh` (mandatory `ci_gates.sh` stage) — 6 code-signal-only
checks (schema=29; no `*_supabase_primary` selectors; no `FinancialCacheRepairService`;
no legacy Supabase financial repo; no `Routed*` wrapper; no
`dontWarnAboutMultipleDatabases`). Matches imports / quoted flag keys /
constructor calls / the schema constant, so history comments naming retired
classes do not trip it. Each of the 5 signal checks is negative-self-tested to
fail on reintroduction; clean tree passes.

## §9 Randomized ordering

Supported/honored (`--test-randomize-ordering-seed`); the isolation-sensitive
suites (615 tests) pass shuffled (seed 20260809). Deterministic fixed-seed lane
recommended; not wired into the mandatory gate (kept first-attempt-green).

## Batch-3 closure gate

<!-- filled after the authoritative Batch-3 gate run -->

## Invariants preserved

schema **v29**, `kServerRevisionCas=false`, migration 0070 inactive, 0068–0076
undeployed, backup envelope **v3**. No schema/flag/migration/wire change.
