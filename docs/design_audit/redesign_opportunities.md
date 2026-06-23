# Mali — Redesign Opportunities (Prioritized)

> Read-only audit output. Prioritized backlog for the redesign phase. Nothing implemented.
> Each item names exact files/widgets. P0 = highest impact / lowest regret.

---

## P0 — High-impact UX fixes (do first)

1. **Make the app live (no manual refresh).**
   - Today all data is one-shot `FutureProvider`s; `AppShell._refreshAll()` only fires on resume and **omits `reportsProvider`**. Captures while foregrounded don't appear.
   - Fix: Drift `.watch()` streams (or a global `dataRevision` `StateProvider` watched by `dashboardDataProvider`, `transactionsListProvider`, `reportsProvider`, budgets/goals). Files: `lib/features/*/**_providers.dart`, `app_shell.dart`.

2. **Unify the header system.**
   - 3 header styles (`SectionHeroHeader`, dashboard bespoke, plain `Text`). Build one `AppHeader` + standardize all 5 tabs on `AppScreenScaffold`. Files: `common/section_hero_header.dart`, `common/app_screen_scaffold.dart`, dashboard/reports/settings/budgets/goals.

3. **Consolidate the Smart Inbox.**
   - Pending review is split across dashboard `_smartInbox`, Transactions "معلقة" tab, and `confirm_transaction_sheet`. Create one inbox surface (swipe-to-confirm / swipe-to-fix) with inline category+account edit (no nested sheets). Files: `dashboard_screen.dart`, `transactions_screen.dart`, `widgets/confirm_transaction_sheet.dart`, `widgets/change_category_sheet.dart`.

4. **Fix the dark-mode button bug class for good.**
   - Ban `FilledButton(backgroundColor: c.primary)` (white in dark). Several fixed; sweep the rest + add a guard. Files: settings sheets, `sms_permission_screen.dart`, `foundation_home_screen.dart`, `change_category_sheet.dart`, `force_update_screen.dart`, `app_lock_gate.dart`.

5. **Standardize bottom sheets.**
   - Recurring overflow bugs (account form, change-category, goal form all needed `SingleChildScrollView` retrofits). Build one `AppBottomSheet` (drag handle, RTL, max-height, scrollable, optional blur). Files: all ~20 `showModalBottomSheet` call sites.

6. **Simplify the dashboard month/range + add controls.**
   - `_monthSelector` crams 5 controls into one row; account-swipe is hidden. Separate time-nav from the primary "add" action (consider center "+" in the bottom bar). Files: `dashboard_screen.dart`, `app_shell.dart`.

---

## P1 — Flow simplification

7. **Lighten onboarding/method screen.**
   - `OnboardingMethodScreen` stacks auto-opening country picker + mandatory DOB + AI consent + 8-step iOS guide. Split into steps with progress; justify or soften DOB; defer Shortcut guide. Files: `onboarding/method_screen.dart`, `onboarding/ios_shortcut_*`.

8. **Merge the two add-transaction surfaces.**
   - `capture_entry_sheet` → (paste vs manual) is an extra hop. One add sheet with a "paste SMS" affordance at top. Files: `capture/capture_entry_sheet.dart`, `capture/manual_paste_screen.dart`, `transactions/manual_transaction_sheet.dart`.

9. **Reduce tab nesting in Transactions.**
   - Outer transactions/bills tabs + inner status tabs = two `AppPillTabBar`s. Consider moving Bills to its own destination or a segmented filter. Files: `transactions_screen.dart`.

10. **Separate Budgets vs Goals.**
    - They share a tab but use different scroll mechanics (`Sliver*` vs `ListView`) and different card languages. Give them a shared layout or distinct destinations. Files: `budgets_screen.dart`, `goals_screen.dart` (+ duplicate `/goals` routes).

11. **iOS Shortcut success signal.**
    - Surface a persistent "متصل ✓" in Settings after first capture; assist the 8-step build (deep links, copyable keywords). Files: `ios_shortcut_screen.dart`, `ios_shortcut_verify_screen.dart`, `settings_screen.dart`.

---

## P2 — Visual design improvements

12. **One brand gradient + tokenized blues.**
    - Collapse the 4+ blue gradients (`AppGradients`, `primaryGradient`, bills hero, method/onboarding heroes) into a single source; remove hardcoded hexes. Files: `app_gradients.dart`, `app_colors.dart`, `transactions_screen.dart` `_BillsHero`, `method_screen.dart`, `onboarding_screen.dart`.

13. **Kill parallel typography (`_alex`).**
    - Replace per-screen `_alex(...)` clones with `AppTypography`. Files: onboarding, method, goals, budgets screens.

14. **Unify icon language.**
    - Pick one family (lucide) for nav + actions; replace stray Material icons (`Icons.bar_chart_rounded` in bottom bar, etc.). Files: `app_shell.dart` and across features.

15. **Merge the 4 progress cards.**
    - `_BudgetCard`/`_GoalCard`/`_GoalPlannerCard`/`_BillCard` → one `ProgressItemCard`. Files: budgets/goals/transactions.

16. **Tokenize shadows & radii.**
    - Replace inline `BoxShadow`s and literal `28` radii with `AppShadows`/`AppRadius`; rework dark-mode depth (borders + subtle glow, since black-on-black shadows are invisible). Files: many feature cards, `app_shadows.dart`.

17. **Rebrand `VaultWidget`** to match the flat card system. File: `common/vault_widget.dart`.

---

## P3 — Trust & security (critical for a finance app)

18. **Make the privacy/security story visible.**
    - On-device processing + E2E encrypted backup (password never leaves device) are strong but buried in tiny text. Add a visible "your data is on your device" panel (Settings + onboarding). Files: `settings_screen.dart`, `backup_screen.dart`, onboarding.

19. **Surface AI consent & data-sent transparency.**
    - When AI parsing runs, show what sanitized text is sent; when it's skipped (no consent / rate-limited / circuit-broken), say so. Files: `_AiConsentCard` (method), `add_transaction_usecase.dart` signals, confirm sheet.

20. **Clarify destructive actions.**
    - Danger zone has two destructive entries both routing to `/privacy`; add explicit, differentiated confirmations. Files: `settings_screen.dart`, `privacy_screen.dart`.

21. **Biometric lock polish.**
    - App-lock gate exists (`core/security/app_lock_gate.dart`); ensure a single, branded lock screen with clear retry. (Recently de-looped — keep that behavior.)

---

## P4 — Premium feel

22. **Standardize loading on `PremiumSkeletonPage`.**
    - Replace raw `CircularProgressIndicator` (~16 files) with skeletons matching each screen's layout. File: `common/premium_loading.dart` + all data screens.

23. **Standardize empty/error states.**
    - One `AppErrorState` (today errors are bespoke `Text('حدث خطأ')`); consistent `AppEmptyState` placement. Files: ~18 error sites, `app_empty_state.dart`.

24. **A consistent motion spec.**
    - Apply `PremiumMotion` entrances + `AnimatedAmountText` everywhere money changes; define standard durations/curves. File: `common/motion.dart` + screens.

25. **Unified in-app banner/toast.**
    - Merge `AnnouncementBanner` + `_CelebrationBanner` + error snackbars into one typed system. Files: `app_shell.dart`, `common/widgets/announcement_banner.dart`.

---

## P5 — Data visualization

26. **Interactive charts.**
    - `spending_charts.dart`: tap a day/segment to filter; scrub trend line; tokenized colors + legend. Files: `common/charts/spending_charts.dart`, dashboard/reports.

27. **Multi-currency view.**
    - No FX today; per-currency totals only. Offer an optional approximate combined total (clearly labeled "approx") for multi-account users. Files: `dashboard_providers.dart`, `reports_providers.dart`.

28. **Category drill-down.**
    - From a category slice → filtered transactions (the plumbing exists via `transactionKindFilterProvider`/account filter). Files: dashboard `_analyticsCard`, reports, `transactions_providers.dart`.

---

## Cleanup (low effort, do alongside)

- **Remove dead `foundation_home_screen.dart`** (unrouted) after confirming. 
- **Retire legacy `TransactionRow`** in `common/widgets.dart` (superseded by `AppTransactionRow`).
- **Centralize entity→row mapping** so dashboard recent and transactions list share one mapper.
- **Complete l10n** — move hardcoded Arabic strings into ARB so the English locale is usable.
- **Fix stale `AppInsightType.ai` "amber" comment** (now blue).

---

## Suggested sequencing

1. **Foundations:** P0-#2 header, P0-#5 sheet scaffold, P2-#12 gradient/#13 typography, P0-#4 button bug → a clean token + component base.
2. **Core loop:** P0-#1 live data, P0-#3 smart inbox, P0-#6 dashboard, P1-#8 add flow.
3. **Destinations:** P1-#7 onboarding, P1-#9/#10 transactions/budgets/goals, P1-#11 shortcut.
4. **Polish:** P3 trust, P4 premium states/motion, P5 charts.
