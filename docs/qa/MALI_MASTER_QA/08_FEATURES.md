# 08 — Features

Related: [02_PROJECT_DISCOVERY.md](02_PROJECT_DISCOVERY.md), [09_DATA_FLOW.md](09_DATA_FLOW.md), [11_TEST_MATRIX.md](11_TEST_MATRIX.md).

Each feature below maps to a `lib/features/<name>/` folder and, where relevant, to test-matrix ID prefixes in [11_TEST_MATRIX.md](11_TEST_MATRIX.md).

## 1. Onboarding (`features/onboarding/`) — test prefix `ONB`

First-run flow: welcome/cinematic intro pages → base currency/country selection → capture setup (Android: SMS permission request; iOS: Shortcuts guide walkthrough, see `ios_shortcut_guide.dart`) → optional biometric lock setup → optional AI-consent toggle. A "complete setup" nudge is shown post-onboarding if capture setup wasn't finished, snoozable for 30 days.

## 2. Accounts (`features/accounts/`) — test prefix `ACC`

Multi-currency account management: create/edit/delete accounts, set a default account, per-account currency. Backed by `AccountRepository` → `RoutedAccountRepository` (flag: `accounts_supabase_primary`). The dashboard's account/currency switcher chip row reads from here. See [09_DATA_FLOW.md](09_DATA_FLOW.md) for the create/set-default/delete flows in detail.

## 3. Transactions (`features/transactions/`) — test prefix `TXN`

Transaction list (chronological, filterable), transaction details screen, manual-add sheet, confirm-transaction sheet (for pending/low-confidence captures). Backed by `TransactionRepository` → `RoutedTransactionRepository` (flag: `transactions_supabase_primary`, which additionally requires `accounts_supabase_primary` to also be on — see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4, since transaction rows reference server account UUIDs). Supports: edit amount/category/account/card, delete, confirm (pending → confirmed), duplicate-of linking.

## 4. Dashboard (`features/dashboard/`) — test prefix `DASH`

Home screen: account/currency switcher, per-currency totals, recent transactions, budget-progress teaser. Currently reads from Drift-backed aggregation queries directly (`dashboard_providers.dart`); migrating to Supabase RPC-backed summaries is an active roadmap item — see [30_ROADMAP.md](30_ROADMAP.md).

## 5. Reports (`features/reports/`) — test prefix `RPT`

Spend charts (`fl_chart`-based): category breakdown, daily/monthly trend, merchant breakdown, currency totals. All aggregation queries must respect half-open date ranges (see [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 5) and the transfer-accounting rule (internal transfers excluded from income/expense totals).

## 6. Budgets (`features/budgets/`) — test prefix `BUD`

Per-category or all-expenses monthly budgets. Alerts fire at 75%/90%/100%+ thresholds via `LocalNotificationService.showBudgetAlert`, computed in `AppShell._checkBudgetAlert`/`_syncEngagement`. Backed by flag `budgets_supabase_primary`.

## 7. Goals (`features/goals/`) — test prefix `GOAL`

Savings goals with a target amount and manual/auto contributions. Milestone celebrations trigger `CelebrationRuntime` events and a local notification. Backed by flag `goals_supabase_primary`; contributions are a distinct child entity (`user_goal_contributions` server-side).

## 8. Subscriptions/Bills (`features/subscriptions/`) — test prefix `SUB`

Recurring payment tracking (subscriptions, installments) with due-date reminders. "My Cards" screen shows big-brand card visuals for linked recurring payments. Backed by flag `subscriptions_supabase_primary`; bill payments are a distinct child entity (`user_bill_payments` server-side).

## 9. Plans (`features/plans/`) — test prefix `PLAN`

A higher-level budgeting/planning construct linking specific transactions to a plan (e.g., "Ramadan spending plan"). Backed by flag `plans_supabase_primary`; plan-transaction links are a distinct child entity (`user_plan_transaction_links` server-side).

## 10. Smart Inbox — test prefix `INBOX`

Not a standalone `features/` folder but a cross-cutting review queue: low-confidence parses (`needs_review`) and suspected duplicates land here for user confirmation/rejection rather than being silently auto-confirmed or silently auto-rejected. Backed by flag `smart_inbox_supabase_primary`.

## 11. Capture (`features/capture/`) — test prefix `CAP`

The SMS-to-transaction pipeline itself. See the dedicated deep-dive documents: [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) and [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md).

## 12. Achievements / Gamification (`features/achievements/`) — test prefix `ACHV`

Badges and a daily-activity streak counter, driven by `RecordEngagementUseCase`. Passive badges are evaluated on every app resume/capture cycle; unlocking one triggers a `CelebrationRuntime` event and a local notification.

## 13. Backup (`features/backup/`) — test prefix `BKUP`

User-initiated encrypted export/import of the local Drift database to/from the Supabase `backups` Storage bucket. See [26_BACKUP_STRATEGY.md](26_BACKUP_STRATEGY.md).

## 14. Settings (`features/settings/`) — test prefix `SET`

App-wide preferences (notification toggles, quiet hours, AI consent, biometric lock, base currency), the account manager (`/accounts` route), and category catalog management.

## 15. Cross-cutting: notifications

Every feature above can produce a notification (capture result, budget alert, achievement, goal milestone, streak reminder, weekly report, bill reminder, marketing/growth message). All notification scheduling funnels through `LocalNotificationService`, which enforces quiet hours (except for time-sensitive capture notifications), per-type user preferences, and in-app history recording. See [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) for the full pipeline including the iOS-specific APNs path.

## 16. Feature-flag inventory (current)

| Flag | Gates | Default |
|---|---|---|
| `accounts_supabase_primary` | Accounts feature reads/writes | OFF (rollout 0%) |
| `transactions_supabase_primary` | Transactions feature reads/writes (requires accounts flag also on) | OFF |
| `budgets_supabase_primary` | Budgets feature reads/writes | OFF |
| `goals_supabase_primary` | Goals feature reads/writes | OFF |
| `subscriptions_supabase_primary` | Subscriptions/bills feature reads/writes | OFF |
| `plans_supabase_primary` | Plans feature reads/writes | OFF |
| `smart_inbox_supabase_primary` | Smart Inbox reads/writes | OFF |
| `capture_direct_supabase_write` | iOS capture relay writes directly to `user_transactions` (requires `transactions_supabase_primary` also on) | OFF |
| `ledger_dual_write` | Legacy dual-write path during an earlier migration phase, independent of the direct-write flag | OFF |

Every flag above defaults to **OFF globally**; enabling any of them for the general population is a production cutover decision requiring the process in [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) and [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) Rule 1.
