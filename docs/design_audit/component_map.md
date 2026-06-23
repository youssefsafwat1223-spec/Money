# Mali — Component Map

> Read-only audit of repeated UI components. "Verdict" = reuse / redesign / merge / remove.
> Paths relative to `app/`. Shared library lives in `lib/features/common/`.

---

## Headers (CRITICAL inconsistency)

There is **no single header component**. Three coexisting patterns:

| Pattern | File | Used by | Problem |
|---|---|---|---|
| `SectionHeroHeader` (gradient, `AppGradients.heroHeader`, optional metrics + back button) | `lib/features/common/section_hero_header.dart` | Goals (`goals_screen.dart`), and via `AppScreenScaffold` | Only used in 1–2 places despite being the "canonical" hero |
| Bespoke dashboard header (`_header`/`_accountRow`/`_monthSelector`) | `lib/features/dashboard/dashboard_screen.dart` | Dashboard only | Unique greeting + account chips + month selector; not reusable |
| Plain text header | `reports_screen.dart` (`Text('الرؤى')`), `settings_screen.dart` (`_SettingsHeader`), screens using `Scaffold`+`AppBarTheme` | Reports, Settings, detail screens | No gradient, different paddings, different title sizes |

- **Verdict: REDESIGN + MERGE** into one configurable `AppHeader` (title, subtitle, optional metrics, optional actions, optional gradient/flat variant, back button). Migrate Dashboard, Reports, Settings, Goals, Budgets onto it.

---

## App bar / Scaffold wrappers

- `AppScreenScaffold` — `lib/features/common/app_screen_scaffold.dart` — wraps header + scrollable body + `bottomNavPadding`. Used by Reports (and intended as the standard).
- Global `AppBarTheme` is defined in `app_theme.dart` but **most primary screens don't use a Material `AppBar`** (shell has `appBar: null`); only detail/secondary screens (`Scaffold`) pick it up.
- **Verdict: REUSE `AppScreenScaffold`**, expand it to host the unified `AppHeader`; standardize all 5 tabs on it.

---

## Bottom navigation

- `_FloatingBottomBar` / `_NavTab` / `_NavSlot` — `lib/features/app/app_shell.dart`.
- Floating pill (radius 32, `AppShadows.nav`), 5 tabs, hides on scroll, RTL-forced. Icons mix `AppLucideIcons` and Material (`Icons.bar_chart_rounded`).
- **Problem:** icon set is mixed (lucide + material); no center action (add-txn lives in dashboard header instead); selected state styling is custom.
- **Verdict: REDESIGN (light)** — unify icons to one family; consider a center "+" capture action (the app's core loop is capture).

---

## Cards

| Component | File | Used by | Problem | Verdict |
|---|---|---|---|---|
| `AppCard` | `common/app_card.dart` | dashboard, reports | Good baseline (surface+radius+`AppShadows.card`) | REUSE |
| `AppMetricCard` | `common/app_metric_card.dart` | budgets, reports | Solid; `AppMetricStyle` enum semantic colors | REUSE |
| `AppInsightCard` | `common/app_insight_card.dart` | dashboard smart-inbox, transactions bulk, reports | `AppInsightType.ai` comment says "amber tint" but maps to `c.accent` (blue) — stale comment | REUSE (fix doc/intent) |
| Bills hero card | `transactions_screen.dart` `_BillsHero` | bills tab | **Hardcoded blue gradient** not tokens | REDESIGN → tokenized gradient |
| Wallet/financial card | `dashboard_screen.dart` `_financialCard` | dashboard | Bespoke; overlaps `AppGradients.walletCard` | REDESIGN → shared wallet card |
| `_BudgetCard` / `_GoalCard` / `_GoalPlannerCard` / `_BillCard` | budgets/goals/transactions | each feature | 4 separate "item with progress" cards | MERGE → one `ProgressItemCard` |
| `bento_card.dart` | onboarding | onboarding visuals | Niche | REUSE (onboarding only) |
| `GlassCard` | `onboarding/widgets/premium_ui.dart` | onboarding/method | Blur card, onboarding-only | REUSE (scope to onboarding) |

---

## Buttons

| Component | File | Notes | Verdict |
|---|---|---|---|
| `AppPrimaryButton` / `AppButton` | `common/app_button.dart` | Primary CTA; has loading state | REUSE |
| Theme `FilledButton`/`ElevatedButton`/`OutlinedButton` | `app_theme.dart` | Default to `c.cta`, 56px, radius 16 | REUSE |
| Ad-hoc `FilledButton.styleFrom(backgroundColor: c.primary)` | settings sheets, sms-permission, foundation, change-category, force-update, app-lock, confirm sheet | **BUG class:** `c.primary` = white in dark mode → invisible white buttons (several already fixed to `c.cta`) | REDESIGN — purge `c.primary` as button bg everywhere; lint/guard |
| `_HeroCircle` (round icon button) | `transactions_screen.dart` | now functional (add) | REUSE/merge into an `IconCircleButton` |
| `_quickHeaderButton` | `dashboard_screen.dart` | dashboard header actions | MERGE into `IconCircleButton` |

- **Verdict overall:** one `IconCircleButton`; ban `c.primary` backgrounds.

---

## Transaction rows

- `AppTransactionRow` — `common/app_transaction_row.dart` — canonical row (category avatar, title, subtitle, pending/AI badges, amount color by debit/credit, privacy mode, min-height 44, a11y semantics). Used by Transactions list + Dashboard recent.
- **Problem:** Dashboard `_recentCard` re-derives `isDebit`/title/subtitle logic inline instead of a single mapper; `TransactionRow` (legacy) still referenced in `common/widgets.dart`.
- **Verdict: REUSE `AppTransactionRow`**; remove/retire the legacy `TransactionRow`; centralize the entity→row mapping.

---

## Charts

- `spending_charts.dart` — `lib/features/common/charts/` (fl_chart). Used by Dashboard `_analyticsCard` and Reports.
- **Problem:** charts are static (no tap/scrub interaction); style (colors/grid) defined inside the chart file, partly hardcoded.
- **Verdict: REDESIGN** — tokenize chart colors, add interaction (tap day/segment to filter), consistent legend.

---

## Empty states

- `AppEmptyState` — `common/app_empty_state.dart` (icon + title + subtitle + optional primary/secondary buttons, RTL-safe). Used by dashboard, transactions, budgets, subscriptions.
- **Problem:** Some screens build empty UI inline instead of using it (bills `_BillExample` is a richer custom empty state); positioning differs (budgets was centered via `SliverFillRemaining`, now inline).
- **Verdict: REUSE + standardize** placement; fold `_BillExample` into an "example/empty" variant.

---

## Dialogs / Bottom sheets

- ~20 files use `showModalBottomSheet`; almost all wrap content in `Directionality(rtl)` + a drag handle, but with **inconsistent** chrome: some `ClipRRect`+`BackdropFilter` blur (`change_category_sheet`, method country picker, confirm sheet), some plain `Container`, varying radii (28 vs `AppRadius.card`).
- **Problem:** no shared sheet scaffold; repeated overflow bugs (several sheets needed `SingleChildScrollView` added — account form, change-category, goal form).
- **Verdict: REDESIGN → one `AppBottomSheet` scaffold** (drag handle, RTL, max-height, scrollable body, optional blur) that all sheets adopt.

---

## Forms

- `manual_transaction_sheet.dart`, `bill_form_sheet.dart`, `budget_form_screen.dart`, `goal_form_screen.dart`, `_AccountForm` (accounts), `change_category_sheet`, settings category form.
- **Problem:** each re-implements `InputDecoration`, dropdown chrome, and currency suffix logic separately, despite a global `inputDecorationTheme`. Currency selection exists in some (bills, goals, manual txn, accounts) but not others (budget inherits account). `DropdownButtonFormField` value/item mismatches caused a crash (manual sheet) — fragile.
- **Verdict: REDESIGN → shared `AppFormField` / `AppCurrencyDropdown` / `AppAmountField`**; one currency-picker component used everywhere a price is entered.

---

## Tabs

- `AppPillTabBar` — `common/app_pill_tab_bar.dart` (fixed-height 44 pill, `c.cta` active, `caption` text, RTL-safe). Used by Transactions (status), Reports, Budgets, Bills (`_BillsTypeSegmented` wraps it).
- **Problem:** Transactions stacks an outer transactions/bills tab + inner status tabs (two `AppPillTabBar`s) → heavy.
- **Verdict: REUSE**; reduce nesting in Transactions.

---

## Chips

- `ChoiceChip` (Material) for date-range presets (`_DateRangeChips`, `_ReportDateRangeChips`) and kind/account filters (`_KindFilterChips`, `_AccountFilterChips`). Account switcher uses custom `_accountChipLight`.
- **Problem:** mix of Material `ChoiceChip` and bespoke chips; date-range chips were a wrapping pile (now horizontal scroll, height scales with textScaler).
- **Verdict: MERGE → one `AppFilterChip` + one `AppChipRow`** (horizontal scroll, scale-aware).

---

## Badges

- Pending/AI badges in `AppTransactionRow` (`_Badge`); `_Tag` in bills; `card_network_badge.dart` (Visa/Mastercard); streak chip in dashboard header; due-date pill in `_BillCard`.
- **Problem:** 4+ separate small "pill" implementations.
- **Verdict: MERGE → one `AppBadge`/`AppPill`** with semantic color variants.

---

## Notification / banner widgets

- `AnnouncementBanner` — `common/widgets/announcement_banner.dart` (remote announcements, top of shell).
- `_CelebrationBanner` — `app_shell.dart` (badge/streak toast).
- `LocalNotificationService` — OS notifications (capture/budget/streak/achievement).
- **Problem:** announcement + celebration banners are separate one-off widgets stacked in the shell.
- **Verdict: REDESIGN (light)** — a single in-app banner/toast system with types (announcement, celebration, error).

---

## Misc shared

| Component | File | Verdict |
|---|---|---|
| `MaliLogo` | `common/mali_logo.dart` | REUSE |
| `VaultWidget` | `common/vault_widget.dart` | REDESIGN — art style off-brand vs flat cards |
| `motion.dart` (`AnimatedAmountText`, `PremiumMotion`) | `common/motion.dart` | REUSE — standardize on these for all animations |
| `premium_loading.dart` (`PremiumSkeletonPage`) | `common/premium_loading.dart` | REUSE — adopt everywhere instead of raw spinners |
| `BrandMark` | `cards/brand_mark.dart` | REUSE |
| `category_catalog.dart` (`CategoryView`, `CategoryAvatar`) | `common/category_catalog.dart` | REUSE |
| `foundation_home_screen.dart` | `foundation/` | **REMOVE** (unrouted/dead — verify first) |

---

## Summary of verdicts

- **Build/merge:** `AppHeader`, `AppBottomSheet`, `ProgressItemCard`, `IconCircleButton`, `AppBadge/AppPill`, `AppFilterChip`+`AppChipRow`, `AppCurrencyDropdown`/`AppAmountField`, unified in-app banner.
- **Reuse & enforce:** `AppCard`, `AppMetricCard`, `AppInsightCard`, `AppTransactionRow`, `AppEmptyState`, `AppPillTabBar`, `AppButton`, `PremiumSkeletonPage`, `motion.dart`.
- **Redesign:** charts (interaction + tokens), bottom-sheet chrome, bills/wallet cards (tokenized gradients), `VaultWidget`, bottom bar icons.
- **Remove:** `foundation_home_screen.dart` (after confirming unused); legacy `TransactionRow`.
- **Ban:** `c.primary` as a button background (dark-mode invisibility bug class).
