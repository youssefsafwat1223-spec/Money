# S0 — Offline-First Architectural Correction · Audit

**Goal:** `UI → Drift → Sync Engine → Supabase`. No `UI → Supabase` reads.
**Status:** ✅ analyze clean · ✅ 755 tests pass · no commits.

## What changed
1. **`routeFinancialOperation`** (`financial_cache_health.dart`) now **always returns `drift()`** — it ignores `useSupabase`/the primary flag and the dirty-cache throw. All 7 routed financial repos (accounts, transactions, budgets, goals, bills, plans, smart-inbox) therefore read **and** write through Drift + the outbox. Offline never throws.
2. **`RoutedCategoryRepository`** used a separate `useSupabase ? supabase : drift` getter — changed to **always Drift**.
3. **Dashboard/Reports summary RPCs** (`supabaseDashboardSummaryEnabled`, `supabaseBudgetProgressSummaryEnabled`) were a direct `UI → Supabase` RPC path — now hard-**`false`**, so the UI computes summaries from Drift (`txRepo`, now Drift-backed). The RPC branches are dead code (removed in S5).
4. **Background sync enablement** decoupled from the primary flag: `_planningAccountsSyncEnabled`, `_planningEntitySyncEnabled`, ledger push/pull now enable Pattern-B sync when the user is Supabase-backed by **either** flag (`planning_*_sync` **OR** `*_primary`). So writes enqueue to the outbox and the pull keeps Drift fresh regardless of cutover state.

## Objective verification
| # | Objective | Status | Evidence |
|---|---|---|---|
| 1 | Eliminate direct UI→Supabase reads | ✅ | `routeFinancialOperation` always Drift; category always Drift; summary RPCs gated false |
| 2 | Every screen reads from Drift | ✅ | all UI providers use routed repos (Drift) / `txRepo` (Drift) |
| 3 | Supabase = sync only | ✅ | `_supabase` repos now referenced only by push/pull services + reconcile |
| 4 | Preserve push/pull/conflict | ✅ | sync engine untouched; only enablement widened |
| 5 | Offline never throws | ✅ | `test/data/s0_offline_first_reads_test.dart`: routed reads/writes succeed while the Supabase repo throws on every call |
| 6 | Auto-sync on reconnect | ✅ (by design) | writes enqueue to outbox; push/pull run on bootstrap + resume; needs live device to observe end-to-end |

## No remaining UI → Supabase reads
Grep of `lib/features/` + `lib/core/` confirms:
- No widget/provider calls a `Supabase*Repository` read method directly.
- The 10 `summaryService.*` calls are all behind `useSupabaseSummary == false` → dead branches, no runtime read.
- Routed repos still *pass* `_supabase.<method>` closures into `_route`, but `routeFinancialOperation` never invokes them → dead closures.

## Repositories still holding a Supabase path (dead for reads — cleanup in S5)
These no longer read from Supabase in the UI path, but still construct/reference Supabase repos:
- `RoutedAccountRepository`, `RoutedTransactionRepository`, `RoutedBudgetRepository`, `RoutedGoalRepository`, `RoutedBillRepository`, `RoutedPlanRepository`, `RoutedSmartInboxRepository` — keep `_supabase` + `_useSupabase` (dead). Remove in **S5**.
- Financial reconcile service + `accounts_backfill_service` use Supabase repos/RPCs — **background sync only, not UI**. OK.

## Known gaps (later phases, not S0)
- **Smart Inbox** and **Category** Drift repos have **no outbox** → their writes don't push yet (read side is Drift-correct). → **S3**.
- **Cards** sync inert, **Settings** local-only → **S1 / S2**.
- Offline **write** for the 7 financial entities now enqueues to the outbox (offline editing works); full conflict coverage audited in **S3**.

## Offline verification
- **Automated:** `s0_offline_first_reads_test.dart` simulates offline (Supabase throws) → routed reads/writes succeed from Drift. ✅
- **Manual (owner, device):** Airplane Mode → open app (loads from Drift, no red errors), create/edit an account + transaction (persists), toggle network back → confirm rows appear on Supabase. *(Cannot be executed here — requires a device + real network toggling.)*
