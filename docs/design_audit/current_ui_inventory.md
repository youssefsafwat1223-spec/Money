# Mali — Current UI Inventory

> Design audit, read-only. No code changed. Paths are relative to `app/`.
> App: Arabic-first (RTL) on-device expense tracker. Bundle `com.youssefsafwat.mali`.
> Navigation: `go_router` (`lib/core/router/app_router.dart`) + a 5-tab IndexedStack shell
> (`lib/features/app/app_shell.dart`). Theme: Material 3 + `AppColors` ThemeExtension.

---

## 0. Navigation shell — the spine

**File:** `lib/features/app/app_shell.dart` (`AppShell`, `_FloatingBottomBar`, `_NavTab`)
- 5 primary tabs in an `IndexedStack` (state never destroyed): order in RTL is
  Dashboard `الرئيسية` → Transactions `المعاملات` → Reports `التقارير` → Budgets `الميزانيات` → Settings `الإعدادات`.
- **No global `AppBar`.** `appBar: null`, `extendBody: true`. Every screen draws its own header.
- **Floating pill bottom bar**: `Container` height 64, radius 32, `AppShadows.nav`, `Row(textDirection: rtl)`. Hides on scroll-down via `NotificationListener<UserScrollNotification>` + `AnimatedSlide`.
- Overlays stacked on top: `AnnouncementBanner` (top), `_CelebrationBanner` (transient toast for badges/streaks).
- Hosts the **capture runtime**: listens to `CaptureRuntime.instance.confirmRequests / navigationRequests / bankDiscoveryRequests` and opens sheets; drains shared SMS on resume (`_consumeSharedInput`), then `_refreshAll()`.
- **Issue:** mixes navigation, capture orchestration, engagement/notification scheduling, and celebration UI in one 600-line State class — hard to reason about; `_refreshAll()` does NOT invalidate `reportsProvider` (Reports lags other tabs).

---

## 1. Onboarding & Auth flows

### 1.1 OnboardingScreen — landing
- **Path:** `lib/features/onboarding/onboarding_screen.dart`
- **Purpose:** First-run welcome / value proposition; entry to auth.
- **Sections:** `MaliLogo(84, glow)` → title "مالي" (38px w900) → subtitle → `_OnboardingHeroPreview` (fake dashboard preview card with metrics + a BURGER BOUTIQUE txn + "auto-classified" badge) → 3 `_FeatureBullet` rows (zap/lock/globe) → bottom CTA `AppPrimaryButton` "سجّل وابدأ" + terms line.
- **Widgets:** `PremiumBackground`, `MaliLogo`, `AppPrimaryButton`, `_FeatureBullet`, `_OnboardingHeroPreview`, `_PreviewMetric`.
- **Style:** Single scrollable column; cool dark gradient preview card (`0xFF050A12→0xFF060D19`); hardcoded preview colors.
- **Issues:** Hero preview colors are hardcoded, not tokens; the fake preview duplicates dashboard styling that can drift. Country selection was moved out of here (now post-auth).
- **UX:** Good single-screen pitch; CTA label uses `registerAndStart`.

### 1.2 AuthScreen
- **Path:** `lib/features/onboarding/auth_screen.dart`
- **Purpose:** Sign in (Apple / Google / email OTP / guest).
- **Sections:** custom top bar (back `IconButton`) → `MaliLogo(68)` → headline `signInToStart` → subtitle → `_TrustRow` (3 trust chips) → **Apple button first** (`SignInWithAppleButton`, 56px, per Apple HIG) → Google (`_AuthButton` + `_GoogleMark` custom-painted G) → email field always visible + `FilledButton` (`c.cta`) "send OTP" → guest mode text button → terms.
- **Widgets:** `PremiumBackground`, `_AuthButton`, `_TrustRow`, `_GoogleMark`/`_GoogleMarkPainter`.
- **Routing nuance:** `_provider()` calls `AppSession.setIdentity` then routes; the router `refreshListenable` fires immediately, so post-auth UI (country picker) lives on the **next** screen (method) not here.
- **Issues:** Email field auto-focused on open (pops keyboard immediately). `_GoogleMark` is hand-painted rather than an asset.

### 1.3 OTP screen
- **Path:** `lib/features/onboarding/otp_screen.dart` — 6-digit code entry; demo code 123456 hinted; verify button.

### 1.4 Method screen (post-auth setup) — heavy
- **Path:** `lib/features/onboarding/method_screen.dart` (`OnboardingMethodScreen`)
- **Purpose:** Country/currency picker (bottom sheet on entry), **date-of-birth**, AI-consent opt-in, and SMS/Shortcut setup instructions.
- **Sections:** drag-handle sheet card → gradient hero (`c.primaryGradient`) with icon+title+subtitle → platform branch: Android `_MethodStep` list / iOS `IosShortcutGuide` (8 numbered `_ShortcutStepRow`) → multi-currency note → `_AiConsentCard` (toggle) → primary CTA "Got it" (gradient) → "later, add manually".
- **Widgets:** `_showCountryPicker` (blurred bottom sheet, `_CountryTile`, `_FlagAvatar`), `IosShortcutGuide`, `_AiConsentCard`, `GlassCard`.
- **Issues:** Very dense single screen (country + DOB + AI consent + 8-step shortcut guide). The country picker auto-opens via `addPostFrameCallback` — can feel abrupt. Lots of hardcoded gradients.

### 1.5 Other onboarding sub-screens
- `listening_screen.dart` — "armed, waiting for first message" state after enabling capture.
- `first_transaction_screen.dart` — celebration of the first auto-captured transaction (Sprint 1 "first txn under 2 min").
- `ios_shortcut_screen.dart`, `ios_shortcut_verify_screen.dart` — Apple Shortcut setup + verification ("waiting for a message").
- `restore_prompt_screen.dart` — found-a-backup restore prompt (password / recovery code), used in onboarding and standalone.
- `force_update_screen.dart` — full-screen blocking update gate (rendered by `AppShell.build` when `hasForceUpdateProvider` is true).
- `onboarding_options.dart` — `onboardingCountries` data + `onboardingSelectionProvider`.
- `widgets/premium_ui.dart` — `PremiumBackground`, `GlassCard`, `maliPrimaryActionGradient/Foreground`.
- `widgets/bento_card.dart` — bento-style card (used in onboarding visuals).

---

## 2. Dashboard (`الرئيسية`)

- **Path:** `lib/features/dashboard/dashboard_screen.dart` (`DashboardScreen`, ConsumerWidget) + `dashboard_providers.dart`.
- **Purpose:** Home overview — greeting, account switcher, balance/spend, smart inbox, analytics, recent transactions.
- **States:** loading → `PremiumSkeletonPage(cardCount: 4)`; error → custom inline column ("تعذر تحميل لوحة التحكم") + retry `OutlinedButton`; empty → `_buildEmptyLayout`; data → `_buildLayout`.
- **Main sections (in order):**
  1. `_header` — greeting "صباح الخير، {name}", streak chip, account chip row (`_accountRow` → `_accountChipLight`, horizontal scroll, one chip per account with `name · currency`), month/range selector (`_monthSelector`: add-txn button, add-budget button, calendar, prev/next month, range label in a `Flexible`).
  2. `_financialCard` — primary balance/spend card.
  3. `_smartInbox` — shown when `pendingReviewCount > 0`; pending AI/SMS transactions to review.
  4. `_analyticsCard` — top categories + `dailySpendTrend` via `spending_charts.dart`.
  5. `_recentCard` — last 5 `AppTransactionRow`s, "عرض الكل" jumps to Transactions tab (`shellIndexProvider = 1`).
- **Widgets:** `AppCard`, `AppInsightCard`, `AppTransactionRow`, `AppEmptyState`, charts, `_quickHeaderButton`, `_HeroMetric`-like inline pieces, `AnimatedAmountText` (motion).
- **Style:** Custom per-screen header (not `SectionHeroHeader`); per-currency totals (no FX); privacy mode masks amounts as `••••`.
- **Issues:** Header is bespoke (different from every other screen's header). Month selector row is busy (5 controls). Account switcher also reachable by horizontal swipe (`_handleAccountSwipe`) — undiscoverable. Budget amount currency derived from selected account (no FX). Recent card duplicates row styling logic with Transactions.

---

## 3. Transactions (`المعاملات`)

- **Path:** `lib/features/transactions/transactions_screen.dart` + `transactions_providers.dart`.
- **Purpose:** Full transaction list with search/filter + a **Bills** (subscriptions/installments) tab.
- **Top-level tabs:** an outer pill tab bar splits **العمليات** (transactions) vs **الفواتير** (bills) — bills render `_BillsTab`.
- **Transactions list sections:** `_TransactionSearchField` → status `AppPillTabBar` (كل العمليات / معلقة / مؤكدة) → date-range chip row (`_DateRangeChips`, horizontal scroll, 8 presets incl. custom → `showDateRangePicker`) → `_KindFilterChips` (الكل/مصروفات/دخل/تحويلات) → **`_AccountFilterChips`** (new: "كل الحسابات" + per-account, shown only with 2+ accounts) → grouped list (`_DateHeader` + `AppTransactionRow`), or `AppEmptyState`. Bulk-confirm `AppInsightCard` when on pending tab.
- **Bills tab (`_BillsTab`, ConsumerStatefulWidget):** `_BillsTypeSegmented` (الاشتراكات/الأقساط) → `_BillsHero` (gradient card: monthly spend in base currency, functional `+`, stat row active/yearly/this-week) → if empty `_BillExample` (illustrative card + CTA), else section header + `_BillCard` list → recurring `_SuggestionCard`s → help link.
- **Widgets:** `AppTransactionRow`, `AppPillTabBar`, `AppInsightCard`, `AppEmptyState`, `BrandMark`, `_BillCard`, `_Tag`, `_HeroMetric`, `_Divider`.
- **Detail/edit sheets:** `transaction_details_screen.dart` (bottom sheet), `manual_transaction_sheet.dart` (add/edit), `widgets/confirm_transaction_sheet.dart` (review captured), `widgets/change_category_sheet.dart` (4-col category grid).
- **Issues:** Two tab systems stacked (transactions/bills outer + status inner) is heavy. The Bills hero gradient uses **hardcoded blues** (`0xFF046E9B/034E73/012438`) not tokens. `AppTransactionRow` styling re-implemented inline on dashboard recent card.

---

## 4. Smart Inbox / capture review

Not a dedicated screen — it's a **cross-surface flow**:
- **Dashboard `_smartInbox`** section (pending review summary, `AppInsightCard`).
- **Transactions "معلقة" tab** (`transactionsPendingFilterProvider`).
- **`widgets/confirm_transaction_sheet.dart`** — the review/confirm bottom sheet (blurred `BackdropFilter`, big amount, category chip with تغيير, account dropdown, date, "تعديل التفاصيل", confirm button `c.cta`). Opened by `AppShell` from notifications/shared SMS.
- **`bank_discovery/bank_discovery_confirmation_sheet.dart`** — "is this bank X?" confirmation when AI discovers an unknown sender.
- **`capture/capture_entry_sheet.dart`** — entry chooser (paste / manual add). `capture/manual_paste_screen.dart` — paste raw bank SMS.
- **Issues:** Smart-inbox concept is fragmented across 3 surfaces with no single "inbox" home; review sheet and manual-add sheet have overlapping but separately-built forms.

---

## 5. Budgets (`الميزانيات`)

- **Path:** `lib/features/budgets/budgets_screen.dart` + `budgets_providers.dart`; form `budget_form_screen.dart`.
- **Purpose:** Budgets + Goals, split by a top pill tab (`الميزانيات` / `الأهداف`).
- **Sections:** `_BudgetsTab` (3 `AppMetricCard`s: count / used% / total limit → list of `_BudgetCard` with progress; empty → `AppEmptyState` inline) and `_GoalsTab` (3 metrics → `_GoalPlannerCard` list; uses `SectionHeroHeader` via goals screen). Budget cards now show the linked account's currency.
- **Form:** `budget_form_screen.dart` — category dropdown, amount (suffix = selected account currency), period, account dropdown ("كل الحسابات" + accounts), show-on-header, suggested amount.
- **Widgets:** `AppMetricCard`, `AppEmptyState`, `_BudgetCard`, `CustomScrollView`/`Sliver*`.
- **Issues:** Budgets and Goals are conceptually different but crammed under one tab. `_BudgetsTab` uses slivers while `_GoalsTab` uses ListView — inconsistent scroll mechanics.

---

## 6. Goals

- **Path:** `lib/features/goals/goals_screen.dart`, `goal_form_screen.dart`, `goal_details_screen.dart`, `goals_providers.dart`.
- **Purpose:** Savings goals with a "vault" metaphor.
- **Sections:** `SectionHeroHeader` (the ONLY screen using it directly) + `_GoalCard` list (progress ring, saved/target tiles, per-goal currency). Details sheet: `VaultWidget` progress visual, contributions list, add-contribution. Form: name, target amount, **currency dropdown** (new), deadline (`Material` tile), recommended daily amount.
- **Widgets:** `SectionHeroHeader`, `VaultWidget`, `_GoalCard`, `_GoalAmountTile`, `AppPrimaryButton`.
- **Issues:** Goals live both under Budgets tab AND have their own `/goals` routes — two entry points. `VaultWidget` art style differs from the rest of the app's flat cards.

---

## 7. Reports / Insights (`التقارير` / "الرؤى")

- **Path:** `lib/features/reports/reports_screen.dart` + `reports_providers.dart`.
- **Purpose:** Spend analytics — overview, trends, details.
- **Sections:** `AppScreenScaffold` with a **plain** header (`Text('الرؤى')` + export button) → account selector → `_ReportDateRangeChips` (horizontal, presets) → `AppPillTabBar` (نظرة عامة / الاتجاهات / التفاصيل) → charts (`spending_charts.dart`) + `AppMetricCard`/`AppInsightCard`/category breakdown.
- **Widgets:** `AppScreenScaffold`, `AppPillTabBar`, `AppMetricCard`, `AppCard`, charts, `_ReportExportButton`.
- **Style:** Header title is "الرؤى" but the tab label is "التقارير" — naming mismatch. Header is plain (no gradient), unlike Goals' `SectionHeroHeader`.
- **Issues:** `reportsProvider` not in `_refreshAll()` → stale after captures until a date chip is tapped. Export writes a file + `share_plus`.

---

## 8. Settings & profile (`الإعدادات`)

- **Path:** `lib/features/settings/settings_screen.dart` (+ `settings_providers.dart`, `data_export.dart`, `privacy_screen.dart`).
- **Purpose:** Profile, account, security, appearance/language, data, support, danger zone.
- **Sections (`_Section` cards):** custom header (profile card on top, then title "الإعدادات والملف الشخصي") → **الحساب** (phone number, accounts/wallets, subscriptions, achievements, reports, iOS shortcut) → **الأمان** (`_AppLockTile`, encrypted backup) → **المظهر واللغة** (`_ThemeTile` segmented, language, country) → **البيانات** (privacy mode, AI suggestions, categories, CSV export) → **التنبيهات والدعم** (notifications sheet, invite, about, contact) → **منطقة الخطر** (start fresh, sign out, delete account).
- **Sub-sheets:** notifications prefs, quiet hours (`_HourPicker`), categories editor (`_CategoryGroup`, `_showCategoryForm`), phone-number sheet, settings picker (`_showSettingsPicker` with `_FlagAvatar`), info/about/contact sheets.
- **Widgets:** `_Section` (now `DecoratedBox`+`Material` so ListTile ink shows), `_NavTile`, `_SwitchTile`, `_ThemeTile`, `_TileIcon`, `PremiumMotion`.
- **Issues:** Very long single screen (1700+ lines). Currency-base setting was removed (currency now per-account). Mixes profile, settings, and a full category CRUD editor in one file.

---

## 9. Accounts / Cards / Backup / Privacy / Achievements

- **Accounts:** `lib/features/accounts/accounts_screen.dart` — multi-currency account list + add/edit sheet (`_AccountForm`, now scrollable). Route `/accounts`.
- **Cards:** `cards/card_details_screen.dart` (per-card-last4 view), `cards_carousel.dart`, `brand_mark.dart` (brand logo resolver), `card_network_badge.dart`. Route `/card/:last4`.
- **Backup:** `backup/backup_screen.dart` — E2E encrypted backup/restore. Route `/backup`, `/backup/restore`.
- **Privacy:** `settings/privacy_screen.dart` — "start fresh" / delete-all. Route `/privacy`.
- **Achievements:** `achievements/achievements_screen.dart` — badges/levels grid. Route `/achievements`. `celebration_runtime.dart` drives the celebration banner.
- **Foundation:** `foundation/foundation_home_screen.dart` — **NOT routed / appears unused** (dead screen — confirm before relying on it).

---

## Cross-cutting state coverage

| State | Pattern | Files |
|---|---|---|
| Loading | `PremiumSkeletonPage` (dashboard) vs raw `CircularProgressIndicator` (most others) | inconsistent across ~16 files |
| Empty | `AppEmptyState` | dashboard, transactions, budgets, subscriptions |
| Error | bespoke per screen — mostly `Text('حدث خطأ: $error')` or `'تعذر …'` | ~18 files, no shared error widget |
| RTL | `Directionality(textDirection: rtl)` wrapping (esp. in every bottom sheet) + bottom bar forces RTL | ~22 files |
| Dark/light | `AppColors` light/dark via ThemeExtension; `_ThemeTile` segmented control | global |

**Top inventory-level issues:** (1) no shared header component — at least 3 header styles (`SectionHeroHeader`, dashboard custom, plain Text); (2) loading/error states not standardized; (3) hardcoded blue gradients diverge from `AppColors` tokens; (4) `c.primary` mis-used as button background (white in dark mode — multiple fixed, audit the rest); (5) one dead screen (`foundation_home_screen.dart`).
