# Phase 7 · MALI-034 — Retirement of the Supabase-primary financial authority

**Finding (FULL_APP_AUDIT MALI-034):** a legacy "Supabase-primary" financial
architecture ran alongside the offline-first Drift store — per-entity
`*_supabase_primary` feature flags could make the UI read/write Supabase
directly, a recurring `FinancialCacheRepairService` re-mirrored Supabase into the
local Drift cache, and data-portability import had a server/mixed RPC path. This
duplicated the source of truth, added a background repair cycle, and left a
crash/restart window where a server-authoritative import could not self-heal.

**Decision (Option A):** *retire* the Supabase-primary authority and every path
that existed only to serve it, rather than harden a second authority. Drift is
the single financial source of truth; the server is reached only by the
background outbox/push/pull sync.

## What changed (commit stack on `feat/phase1-data-integrity`)

| Commit | Scope |
|--------|-------|
| `476474b8` | Add the **in-slot** `LegacyFinancialCacheReconciler`: at each domain's post-push pull SLOT, a dirty legacy cache marker is reconciled by an epoch full-pull under a synchronous exact-generation admission guard (preserves PUSH→PULL order; atomic marker clear; explicit cancellation). Replaces the recurring repair cycle's runtime role. |
| `8ee1bd4c` | Retire the 10 `*_supabase_primary` / `*_supabase_summary` / `*_supabase_rpc` authority flags; collapse data portability to a single Drift-authoritative export/import (remove the server/mixed import RPC + `repairAll` rebuild + the `flags`/`getSupabase`/`invokeRpc`/`repairFinancialCache` service wiring); remove the post-restore primary backfill. |
| `a988e830` | Delete `FinancialCacheRepairService` + its provider, the 8 repair-only Supabase financial repositories, and the dead `markFinancialCacheDirty`/`mirrorFinancialCacheSafely`. Extract the transaction enum→wire mappers **verbatim** into `data/sync/transaction_server_mappers.dart` (authority-neutral transport for the ledger outbox + backfill). Retire the CaptureSync Supabase-primary relay path. |
| `f5b07e62` | Collapse the 8 vestigial `Routed*Repository` pass-through wrappers — the providers now return their `Drift*Repository` directly. |
| _(this)_ | Docs + the narrow CI architecture guard + data-portability regression tests. |

`476474b8` (the in-slot transition) is preserved intact and is **not** reverted.

## Crash/restart window (the reason Option A was chosen)

The retired server-import RPC preserved the *original* server timestamps on
imported rows, so a crash between "server import committed" and "local cache
rebuilt" left a state that an incremental pull could **not** heal (the pulled
rows were not newer than what the device already had), and the client never
consumed the durable server `financial_import_runs` ledger for recovery. Rather
than build a client-side recovery reader for a path we were retiring, the path
itself is removed: local import is a single Drift transaction, recorded in the
**local** `financial_import_runs` table for idempotency, with no server
round-trip and therefore no such window.

## Historical dirty-marker compatibility (§7)

A device upgraded from the old architecture may still hold `financial_cache_health`
rows marked dirty. The typed `kFinancialCacheMarkers` map (`financial_cache_reconcile_map.dart`)
maps every historical marker to exactly one reconcile domain; unrecognized
markers map to `null` and are surfaced for diagnostics, never guessed or
silently cleared. Covered by `financial_cache_reconcile_map_test.dart`.

## Zero runtime reachability (§9)

Proven against `app/lib` (production code only) — all zero except intentional
history comments:

- imports of `repositories/supabase_*_repository.dart` — **0**
- imports of `financial_cache_repair_service.dart` — **0**
- `FinancialCacheRepairService(` / `SupabaseXxxRepository(` constructors — **0**
- quoted `*_supabase_primary` flag selectors (`getBool('..._supabase_primary')`) — **0**
- `Routed*Repository` classes / imports / constructors — **0**
- DB schema version — **29** (unchanged)

These invariants are enforced going forward by **`tools/check_arch_guard.sh`**,
wired as a mandatory stage in `tools/ci_gates.sh`. The guard matches code
signals only (imports, quoted flag keys, constructor calls, the schema
constant), so the history comments that name the retired classes do not trip it;
a self-test proves it fails when any signal is reintroduced.

## Test coverage

- **Data portability (10)** — `app_data_portability_service_test.dart`: local-first
  CSV + rerun dedup, qirsh local-only import recorded in `financial_import_runs`,
  local export, lossless round-trip, replace soft-hide, idempotency (same package
  once), mode-conflict rejection, CSV-cannot-replace, `canReplace` ungated,
  merge non-destructive.
- **Reconciliation (33)** — `legacy_financial_cache_reconciler_test.dart`,
  `financial_cache_reconcile_map_test.dart`, `ledger_sync_engine_reconcile_test.dart`,
  per-puller `SyncPullStatus` contracts.
- **Offline-first / DI** — `s0_offline_first_reads_test.dart` (Drift repo offline
  read/write), `accounts_sync_service_test.dart` (provider returns the Drift repo).

## Invariants preserved (unchanged by MALI-034)

Schema **v29**; `kServerRevisionCas=false`; migration 0070 authority inactive;
migrations 0068–0076 undeployed; backup envelope **v3**; Argon2 production
parameters. No schema, flag-runtime, migration, or wire-format change.

## Closure gate

Canonical `tools/ci_gates.sh` run **once** from the committed clean tree
`a72f1b11`, **first attempt green**:

```
mandatory gates passed : 11
mandatory gates failed : 0
tools unavailable      : 0
node tests skipped     : 27  (credentials absent — see manifest)
deno tests ignored     : 2   (live-Postgres — see manifest)
skip/ignore manifest   : satisfied
ALL LOCAL GATES PASSED
```

- flutter test bulk (production-cost crypto excluded): **1579 passed**
- flutter test crypto (serialized production-cost Argon2, `--concurrency=1`): **24 passed**
- MALI-034 architecture guard: **5/5** (schema 29, no `*_supabase_primary`
  selectors, no `FinancialCacheRepairService` wiring, no legacy Supabase repo
  wiring, no `Routed*` wrappers)

Zero-runtime-reachability is proven and enforced, and the committed-tree gate is
first-attempt green. **MALI-034 is closed** on branch `feat/phase1-data-integrity`
(not pushed). The broader MALI-040 DB/executor test-ownership work remains open
and was intentionally kept out of this stack.
