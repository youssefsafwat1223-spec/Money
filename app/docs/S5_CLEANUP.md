# S5 — Dead Pattern-A Cleanup

Strictly cleanup — no behavior change, no business logic changed, no features.
**Gates:** ✅ `flutter analyze` clean · ✅ **774 tests pass** (−3 obsolete) · no commits.

## 1. Dead-code report (what was verified dead, and how)
| Dead item | Why it was dead | Verified by |
|---|---|---|
| `routeFinancialOperation<T>()` | S0 reduced it to `return drift()`; the `useSupabase`/`supabase` args were ignored | grep: only callers were the routed repos (all now delegate to Drift) |
| Routed repos' `_supabase` field + `_route` + `_useSupabase` | after S0 the Supabase branch was never taken (always Drift) | grep: `_supabase.*` closures passed to `_route`, never invoked |
| `RoutedTransactionRepository` `accounts_primary_required` guard | Pattern-A rule (txn-primary requires accounts-primary); dead + could misfire under S0 | code read: only reachable in the removed routing path |
| 2 × `routeFinancialOperation` unit tests + 1 × `accounts_primary_required` test | tested removed behavior | test read |
| `_ThrowingSupabaseAccounts` test stub + 5 unused imports | orphaned by the above | analyzer |

**Verification before deletion:** each item was (a) grep'd for references, (b) confirmed
unreachable after S0's always-Drift change, (c) covered by the surviving repository/sync
tests (774 green).

## 2. Removed files / classes / functions
**No files deleted** (the routed wrapper classes are retained — see below).
Removed **symbols/logic**:
- `routeFinancialOperation<T>()` — `data/db/financial_cache_health.dart`.
- From all 8 routed repos (`routed_{account,transaction,budget,goal,bill,plan,smart_inbox,category}_repository.dart`): the `_supabase`, `_flags`, `_db` fields, `_useSupabase` getter, `_route<T>` helper, the transaction `accounts_primary_required` guard, and every `_supabase.<method>` closure. Constructors reduced to `{required <T> drift}`.
- `app_providers.dart`: removed the `supabase:` / `flags:` / `db:` args and the
  `Supabase<X>Repository(db: db)` constructions in the 8 routed-repo providers.
- Tests: 3 obsolete tests + `_ThrowingSupabaseAccounts` + 5 unused imports.

## 3. Retained on purpose (verified NOT dead)
| Kept | Still referenced by |
|---|---|
| `Supabase*Repository` classes | `financial_cache_repair_service`, `capture_sync_service`, `transactions_backfill_service` |
| `*_supabase_primary` feature flags | sync enablement (`planning_*_sync \|\| *_primary`) — flags still gate background sync |
| Routed wrapper classes (now thin Drift delegates) | the DI providers; a stable seam. Collapsing them into direct Drift usage is a *refactor of working reachable code*, not dead-code removal → deliberately out of S5 scope |
| `financial_cache_health` (mark/clear/mirror/repair) | Supabase repos' cache mirroring |

## 4. Identified dead, retained (optional follow-up — not removed to avoid churn)
- **Dashboard/Reports summary-RPC branches** (`dashboard_providers.dart`,
  `reports_providers.dart`): the `useSupabaseSummary ? summaryService.X : driftPath`
  ternaries. `supabaseDashboardSummaryEnabled()`/`supabaseBudgetProgressSummaryEnabled()`
  return **hardcoded `false`**, so the `summaryService` branches are unreachable.
  **Retained** because removing them means editing the large, complex dashboard/reports
  providers — a refactor of working code, which S5's rules say not to do unnecessarily.
  Recommended as a small dedicated follow-up: delete the ternaries + the two
  `*Enabled()` functions + `supabaseFinancialSummaryServiceProvider`.

## 5. Final architecture (one supported synchronization architecture)
```
                 ┌──────────────────────────── the ONLY path ────────────────────────────┐
   User ──▶ UI ──▶ Riverpod providers ──▶ Drift repos (local, source of truth for reads)
                                              │  writes also enqueue ▼
                                     planning_sync_outbox (persisted Drift table)
                                              │            ▲
                              (background) Push│            │Pull (background)
                                              ▼            │
                                    PlanningPush/PullService, AccountsPush/Pull,
                                    LedgerSync, SmartInboxSyncService
                                              │            ▲
                                              ▼            │
                                          Supabase  (source of truth for the cloud)

   Never:  UI ──▶ Supabase   (removed in S0; routing dead code removed in S5)
```
- **UI reads:** exclusively Drift.
- **UI writes:** Drift + enqueue; background push drains; background pull refreshes Drift.
- **Supabase:** touched only by the background sync services (+ cache-repair/backfill).

## 6. Final synchronization coverage (unchanged from S4 — still complete)
Accounts, Transactions, Budgets, Goals, Subscriptions, Plans, Cards, Settings,
Categories, Smart Inbox, Gamification — all offline read+write, push, pull, conflict,
multi-device. (Detail in `S4_OFFLINE_FIRST_CERTIFICATION.md`.)

## 7. Confirmation
**There is exactly one supported synchronization architecture:**
`UI → Drift → Sync Engine → Supabase` (offline-first, outbox-based). The competing
Pattern-A routing (`UI → Supabase` direct reads via `routeFinancialOperation` + the
routed repos' Supabase branches) is **fully removed**. The only residual dead code is the
gated-`false` dashboard summary branches (Section 4), documented for an optional
follow-up. No second sync engine, no second read path, remains.
