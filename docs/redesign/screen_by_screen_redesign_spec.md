# Mali — Screen-by-Screen Redesign Spec

> Read-only design spec. **No implementation.** Pairs with
> `implementation_safety_contract.md` and `docs/design_audit/*`. Paths relative to `app/`.
> Every screen below has the same 12 sections. Shared baselines (motion, RTL, dark mode,
> data-safety) are defined once in §0 and referenced as "see Global Baselines" to stay specific
> without repetition.

---

## 0. Global Baselines & Shared Component Glossary

### 0.1 Component glossary (requested name → actual/planned file)

| Requested name | Maps to | File | Status |
|---|---|---|---|
| `AppScaffold` | `AppScreenScaffold` | `lib/features/common/app_screen_scaffold.dart` | exists — adopt everywhere |
| `AppHeader` | **NEW** unified header (flat + gradient variants, title/subtitle/metrics/actions/back) | `lib/features/common/app_header.dart` (new) | build first |
| `SectionHeader` | **NEW** in-page section label (reuse `_DateHeader` pattern) | `lib/features/common/section_header.dart` (new) | build first |
| `AppCard` | `AppCard` | `lib/features/common/app_card.dart` | exists |
| `AppButton` | `AppPrimaryButton`/`AppButton` | `lib/features/common/app_button.dart` | exists |
| `AppMetricCard` | `AppMetricCard` | `lib/features/common/app_metric_card.dart` | exists |
| `ChartCard` | **NEW** wrapper around `spending_charts.dart` | `lib/features/common/charts/chart_card.dart` (new) | build in chart phase |
| `TransactionRow` | `AppTransactionRow` | `lib/features/common/app_transaction_row.dart` | exists — retire legacy `TransactionRow` |
| `InsightCard` | `AppInsightCard` | `lib/features/common/app_insight_card.dart` | exists |
| `EmptyState` | `AppEmptyState` | `lib/features/common/app_empty_state.dart` | exists |
| `LoadingState` | `PremiumSkeletonPage` | `lib/features/common/premium_loading.dart` | exists — adopt everywhere |
| `SheetScaffold` | **NEW** shared bottom-sheet shell | `lib/features/common/sheet_scaffold.dart` (new) | build first |
| `CategoryChip` | **NEW** + `CategoryAvatar` | `lib/features/common/category_catalog.dart` (extend) | build in inbox phase |
| `BudgetProgressCard` | **NEW** merged `ProgressItemCard` (budgets/goals/bills) | `lib/features/common/progress_item_card.dart` (new) | build in cards phase |
| `AppErrorState` | **NEW** shared error widget | `lib/features/common/app_error_state.dart` (new) | build first |
| `IconCircleButton` | **NEW** (merge `_HeroCircle` + `_quickHeaderButton`) | `lib/features/common/icon_circle_button.dart` (new) | build in buttons phase |
| `AppBadge` | **NEW** (merge `_Badge`/`_Tag`/due-pill) | `lib/features/common/app_badge.dart` (new) | build in badges phase |

### 0.2 Global motion baseline (applies to all screens unless overridden)
- Entrance: `PremiumMotion` staggered fade+rise, 60–80ms stagger per section (`lib/features/common/motion.dart`).
- Money values: `AnimatedAmountText` count-up on change.
- Buttons: theme `NoSplash` + 120ms scale/opacity press feedback (standardize).
- Charts: 600ms ease-out draw-in on first paint (chart phase).
- Loading: `PremiumSkeletonPage` shaped to the screen (no raw spinners).
- Success/error: shared in-app banner (merge `AnnouncementBanner` + `_CelebrationBanner`); destructive = snackbar/danger banner.
- Respect `MediaQuery.disableAnimations`.

### 0.3 Global RTL baseline
- Direction comes from the app locale + `AppScreenScaffold`/`SheetScaffold` (don't re-wrap per widget).
- Use `EdgeInsetsDirectional` / `AlignmentDirectional`; mirror chevrons via `Directionality.of(context)`.
- Fixed-height chips/rows scale with `MediaQuery.textScalerOf` (clamp 0.8–1.25 already set in `app.dart`).

### 0.4 Global dark-mode baseline
- All color via `context.colors`. **`c.primary` is white in dark** → never a button background (use `c.cta`); validate contrast (safety contract §9).
- Dark depth = borders + subtle glow, not black-on-black `BoxShadow`.
- Gradients are tokens (`AppGradients`) and must read correctly in both modes (the bills/onboarding hardcoded blues are the same in light mode today — fix).

### 0.5 Global data & logic safety (applies to EVERY screen)
Do **not** change during UI redesign: parsing (`lib/engine/parser/**`), transaction/use-cases
(`add_transaction_usecase`, `ingest_*`, dedup), AI/categorization (`lib/engine/ai/**`,
`lib/engine/categorization/**`, `supabase/functions/parse-sms`), provider semantics
(`*_providers.dart`, `app_providers.dart`), storage (`lib/data/**`, Drift schema/migrations),
auth/session/backup (`core/auth`, `app_session`, `features/backup`, `core/security`), capture bridge
(`features/capture/services/**`), and `test/**`. Screens may only `ref.watch`/`ref.read` existing
providers. (Repeated per-screen as "see §0.5".)

---

# PRIMARY TABS

---

## Screen 1 — Dashboard (`الرئيسية`)

**1. Identity** — `DashboardScreen`; `lib/features/dashboard/dashboard_screen.dart`; tab index 0 (no route, IndexedStack); home overview; intent: "at a glance, where do I stand and what needs my attention."

**2. Current structure** — Header: bespoke `_header` (greeting + streak chip + `_accountRow` chips + `_monthSelector` with 5 controls). Sections: `_financialCard`, `_smartInbox` (if pending), `_analyticsCard` (top categories + trend chart), `_recentCard` (last 5 `AppTransactionRow`). Nav: chip row / horizontal swipe `_handleAccountSwipe`; "عرض الكل" → tab 1. Actions: add txn, add budget, calendar, prev/next month. Empty: `_buildEmptyLayout` + `AppEmptyState`. Loading: `PremiumSkeletonPage(cardCount:4)`. Error: bespoke inline column + retry.

**3. Problems (audit)** — bespoke header unlike all other screens; `_monthSelector` crams 5 controls; account swipe undiscoverable; per-currency totals, no FX; recent card re-implements row mapping; not live (resume-only refresh).

**4. Redesign goal** — Calm, premium "command center": one clear balance hero, an attention zone (smart inbox), a glanceable analytics block, recents. Time-nav and "add" visually separated. Feels alive (updates without manual refresh once the data-liveness phase lands).

**5. Proposed layout** —
- Header: **`AppHeader` (gradient variant)** — greeting + streak as a metric/badge; account switcher becomes a single segmented/menu control (not a hidden swipe).
- Hero: wallet/balance card (shared tokenized `walletCard` gradient) with `AnimatedAmountText`, period label, and a compact period stepper (‹ month ›) — **move "add" out of here**.
- Primary content: Smart Inbox `AppInsightCard` (only when pending) → Analytics `ChartCard` (top categories + interactive trend).
- Secondary: Recent `AppCard` with `AppTransactionRow`s + "عرض الكل".
- Bottom action: capture "+" relocated to bottom-bar center (see Screen 0/AppShell) or a single FAB; remove the add-budget button from the dashboard header.

**6. Component decisions** — `AppScreenScaffold` + `AppHeader`; `AppCard`; `AppInsightCard`; `ChartCard`; `AppTransactionRow`; `AppEmptyState`; `PremiumSkeletonPage`; `AppErrorState`; `IconCircleButton` for period stepper. Centralize entity→row mapping (shared with Transactions).

**7. Visual notes** — gutter 24; cards radius `card`(24); `AppShadows.card` (+border in dark). Typography: balance `amountHero`; section titles `title2`; metadata `caption`. Colors: credit `success`, debit `danger`, interactive `cta`. Icons: lucide only. Chart: tokenized palette, soft grid.

**8. Motion** — staggered section entrance; balance count-up; chart draw-in; skeleton matches hero+inbox+analytics+recent; refresh = subtle shimmer.

**9. RTL** — account switcher + period stepper mirror; chevrons direction-aware; greeting right-aligned.

**10. Dark mode** — wallet gradient must be a token reading well in both modes; ensure greeting/metric text contrast on gradient; no `c.primary` buttons in header.

**11. Data/logic safety** — see §0.5. `dashboardDataProvider`, `dashboardAccountProvider`, `accountsProvider`, `userSettingsProvider` are read-only here.

**12. Acceptance** — [ ] uses `AppHeader`+`AppScreenScaffold`; [ ] add action removed from header; [ ] account switch is a visible control; [ ] skeleton+error+empty standardized; [ ] no hardcoded colors/`_alex`; [ ] AR/EN + RTL + dark/light verified; [ ] analyze+tests green.

---

## Screen 2 — Transactions (`المعاملات`)

**1. Identity** — `TransactionsScreen`; `lib/features/transactions/transactions_screen.dart`; tab 1 (also `/` deep-link to pending); browse/search/filter all transactions + Bills; intent: "find, review, and correct my transactions."

**2. Current structure** — Outer pill tabs العمليات/الفواتير. Transactions: `_TransactionSearchField` → status `AppPillTabBar` (كل/معلقة/مؤكدة) → `_DateRangeChips` → `_KindFilterChips` → `_AccountFilterChips` → grouped `_DateHeader`+`AppTransactionRow`, bulk-confirm `AppInsightCard`. Bills: `_BillsTab` (`_BillsTypeSegmented`, `_BillsHero`, `_BillCard`/`_BillExample`, `_SuggestionCard`). Empty `AppEmptyState`; loading skeleton/spinner; error bespoke.

**3. Problems (audit)** — two stacked tab systems; `_BillsHero` hardcoded blue gradient; row mapping duplicated; filter chips were a wrapping pile (now scroll).

**4. Redesign goal** — Fast, scannable ledger with lightweight filters; Bills clearly separated (own destination or a clean segmented view) so the transaction list isn't buried under two tab rows.

**5. Proposed layout** —
- Header: **`AppHeader` (flat)** "المعاملات" + search affordance.
- Filter zone: one `AppChipRow` (kind) + a single date control opening a range sheet (`SheetScaffold`); account filter only when 2+ accounts.
- Primary content: sticky `SectionHeader` date groups + `AppTransactionRow`.
- Bills: move to its own screen/route OR a single segmented toggle at top (avoid double tab rows); Bills uses the merged `BudgetProgressCard` for `_BillCard`.
- Sheets: details/edit/confirm/change-category all via `SheetScaffold`.

**6. Components** — `AppScreenScaffold`+`AppHeader`; `SectionHeader`; `AppTransactionRow`; `AppInsightCard` (bulk confirm); `AppEmptyState`; `PremiumSkeletonPage`; `AppErrorState`; `AppFilterChip`/`AppChipRow`; `BudgetProgressCard` (bills); `SheetScaffold`.

**7. Visual notes** — group headers `subhead`/`caption`; amount color by debit/credit; bills hero uses tokenized gradient; chips scale-aware; radius `card`.

**8. Motion** — list items stagger on first load; chip selection 180ms; pull-to-refresh shimmer; row tap → sheet slide-up.

**9. RTL** — amounts leading-aligned per RTL; chevrons mirror; chip row scrolls RTL.

**10. Dark mode** — `_BillsHero` gradient tokenized (no hardcoded blue); confirm/CTA = `c.cta` not `c.primary`.

**11. Data/logic safety** — see §0.5. `transactionsListProvider`, `billsViewProvider`, all filter `StateProvider`s read-only; do not change filter semantics.

**12. Acceptance** — [ ] at most one tab row visible at a time; [ ] bills hero tokenized; [ ] shared row mapping; [ ] all sheets via `SheetScaffold`; [ ] states standardized; [ ] AR/EN+RTL+dark verified; [ ] gates green.

---

## Screen 3 — Reports / Insights (`التقارير` / "الرؤى")

**1. Identity** — `ReportsScreen`; `lib/features/reports/reports_screen.dart`; tab 2 + route `/reports`; spend analytics; intent: "understand my trends and breakdowns."

**2. Current structure** — `AppScreenScaffold` + plain header (`Text('الرؤى')` + export) → account selector → `_ReportDateRangeChips` → `AppPillTabBar` (نظرة عامة/الاتجاهات/التفاصيل) → charts + `AppMetricCard`/`AppInsightCard`/breakdown. Loading skeleton; error bespoke.

**3. Problems (audit)** — header title "الرؤى" vs tab "التقارير" naming mismatch; plain header vs Goals' gradient hero; `reportsProvider` excluded from `_refreshAll` (stale); static charts.

**4. Redesign goal** — A credible analytics surface that feels premium and interactive; consistent naming; charts you can tap to drill into.

**5. Proposed layout** —
- Header: **`AppHeader` (flat)** with consistent name (pick one: التقارير/الرؤى) + export action.
- Controls: account selector + single date control (range sheet via `SheetScaffold`) + `AppPillTabBar`.
- Primary: `ChartCard`s (trend, category donut) — interactive (tap → filtered transactions).
- Secondary: `AppMetricCard` summary row + category breakdown list.

**6. Components** — `AppScreenScaffold`+`AppHeader`; `AppPillTabBar`; `ChartCard`; `AppMetricCard`; `AppCard`; `AppInsightCard`; `PremiumSkeletonPage`; `AppErrorState`.

**7. Visual notes** — chart colors tokenized + legend; metric values `amountSmall`; radius `card`; consistent spacing `s4`.

**8. Motion** — chart draw-in; tab switch cross-fade; metric count-up.

**9. RTL** — chart axis/labels RTL-aware; legend mirrors.

**10. Dark mode** — chart palette must contrast on `bg`; export button `cta`.

**11. Data/logic safety** — see §0.5. `reportsProvider`, `dashboardAccountProvider` read-only. (Live-refresh of reports is a data-phase concern, not this UI phase.)

**12. Acceptance** — [ ] header consistent + named once; [ ] `ChartCard` adopted; [ ] interaction added or explicitly deferred; [ ] states standardized; [ ] AR/EN+RTL+dark; [ ] gates green.

---

## Screen 4 — Budgets + Goals (`الميزانيات`)

**1. Identity** — `BudgetsScreen`; `lib/features/budgets/budgets_screen.dart`; tab 3; budgets + goals; intent: "set limits and savings targets and track them."

**2. Current structure** — top pill (الميزانيات/الأهداف). Budgets: 3 `AppMetricCard` + `_BudgetCard` list (slivers) / inline `AppEmptyState`. Goals: 3 metrics + `_GoalPlannerCard` (ListView). Forms via sheets. Loading spinner; error bespoke.

**3. Problems (audit)** — budgets+goals crammed in one tab; sliver vs ListView mismatch; 4 different progress cards across app; `_BudgetsTab`/`_GoalsTab` divergent.

**4. Redesign goal** — Two coherent, visually consistent trackers; one progress-card language; clear "health" cues.

**5. Proposed layout** —
- Header: **`AppHeader` (gradient)** with the metric strip (count/used%/total) as header metrics.
- Toggle: `AppPillTabBar` (Budgets/Goals).
- Primary: list of **`BudgetProgressCard`** (shared) — ring/bar with `AppColors.budgetState` semantic color; goals reuse the same card with target/saved + per-goal currency.
- Empty: `AppEmptyState` inline (consistent placement, not centered-sliver).
- Bottom action: "+" add (budget/goal) via `SheetScaffold` forms.

**6. Components** — `AppScreenScaffold`+`AppHeader`; `AppPillTabBar`; `AppMetricCard` (header metrics); `BudgetProgressCard`; `AppEmptyState`; `PremiumSkeletonPage`; `AppErrorState`; `SheetScaffold`.

**7. Visual notes** — progress semantic colors (success/warning/danger via `budgetState`); unify radius `card`; consistent scroll (one mechanism).

**8. Motion** — progress ring/bar animates to value; card stagger; metric count-up.

**9. RTL** — progress fills RTL; metric strip mirrors.

**10. Dark mode** — ring track on `surface2`; ensure value text contrast; CTA `cta`.

**11. Data/logic safety** — see §0.5. `budgetsViewProvider`, `goalsProvider`, `accountCurrency()` helper read-only. (Budget=account currency, goal currency already in data layer — no logic change.)

**12. Acceptance** — [ ] one shared progress card; [ ] consistent scroll; [ ] header metrics; [ ] states standardized; [ ] AR/EN+RTL+dark; [ ] gates green.

---

## Screen 5 — Settings & Profile (`الإعدادات`)

**1. Identity** — `SettingsScreen`; `lib/features/settings/settings_screen.dart`; tab 4; preferences/security/data/support; intent: "manage my account, security, data, and app behavior."

**2. Current structure** — custom `_SettingsHeader` (profile card + title) → `_Section` groups (الحساب/الأمان/المظهر/البيانات/الدعم/الخطر) with `_NavTile`/`_SwitchTile`/`_ThemeTile`; many sub-sheets (notifications, quiet hours, categories CRUD, phone, pickers). Loading/error per-row.

**3. Problems (audit)** — 1700-line single screen mixing profile, prefs, and full category CRUD; long scroll; `_Section` previously hid ListTile ink (fixed).

**4. Redesign goal** — A clean, grouped settings hub with a strong profile/trust header; heavy editors (categories) split into their own surfaces.

**5. Proposed layout** —
- Header: **`AppHeader`** profile variant (avatar, email, auth method) — elevate trust ("بياناتك على جهازك").
- Primary: grouped `AppCard` sections via `SectionHeader` + `_NavTile`/`_SwitchTile` (kept, restyled).
- Move category CRUD to its own screen/route; keep a nav tile pointing to it.
- Sheets: all via `SheetScaffold`.

**6. Components** — `AppScreenScaffold`+`AppHeader`; `SectionHeader`; `AppCard`; `AppButton`; `SheetScaffold`; reuse `_ThemeTile`/`_NavTile`/`_SwitchTile` restyled.

**7. Visual notes** — section labels `caption`; danger zone uses `danger` tokens; profile card `surface`+border; radius `card`.

**8. Motion** — `PremiumMotion` group stagger (already used); switch toggle feedback.

**9. RTL** — tiles leading icon on the right; chevrons mirror (`Icons.chevron_left` is intentional in RTL — keep direction-aware).

**10. Dark mode** — sheet "save" buttons must be `cta` not `c.primary` (several offenders here); `_ThemeTile` selected color contrast.

**11. Data/logic safety** — see §0.5. `userSettingsProvider`, `notificationPreferencesProvider`, `AppLockService`, theme providers read-only; do not alter settings persistence.

**12. Acceptance** — [ ] `AppHeader` profile; [ ] category CRUD extracted; [ ] all sheets `SheetScaffold`; [ ] zero `c.primary` buttons; [ ] AR/EN+RTL+dark; [ ] gates green.

---

# ONBOARDING & AUTH

---

## Screen 6 — Onboarding landing

**1. Identity** — `OnboardingScreen`; `lib/features/onboarding/onboarding_screen.dart`; route `/onboarding`; first-run pitch; intent: "understand what Mali does and start."
**2. Current** — `PremiumBackground`; logo+title+subtitle; `_OnboardingHeroPreview` (fake dashboard, hardcoded colors); 3 `_FeatureBullet`; bottom `AppPrimaryButton`. No empty/error; static.
**3. Problems** — hardcoded preview colors; `_alex` typography clones; preview can drift from real dashboard.
**4. Goal** — Crisp, premium first impression; on-brand preview using tokens.
**5. Layout** — keep single scroll: logo → headline → tokenized hero preview → 3 bullets → CTA + terms. Optionally a 2–3 dot pager if value props grow.
**6. Components** — `PremiumBackground`, `MaliLogo`, `AppPrimaryButton`, `AppCard` (preview), `AppTypography`.
**7. Visual** — replace `_alex` with `AppTypography`; preview gradient from `AppGradients`; spacing `s5/s6`.
**8. Motion** — logo glow; staggered bullet reveal; CTA press feedback.
**9. RTL** — text right-aligned; bullets icon-trailing in RTL.
**10. Dark mode** — preview gradient token reads in both modes; CTA `cta`.
**11. Safety** — see §0.5. No session/auth changes here.
**12. Acceptance** — [ ] no `_alex`/hardcoded colors; [ ] tokenized preview; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 7 — Auth

**1. Identity** — `AuthScreen`; `lib/features/onboarding/auth_screen.dart`; route `/onboarding/auth`; sign-in; intent: "get in quickly and safely."
**2. Current** — custom top bar; logo; headline/subtitle; `_TrustRow`; Apple first; Google (`_GoogleMark`); email field (auto-focused) + `FilledButton(cta)`; guest; terms. Error via snackbar.
**3. Problems** — email field auto-focus pops keyboard; `_GoogleMark` hand-painted; `_alex` clones; post-auth UI coupling to router redirect.
**4. Goal** — Trustworthy, minimal auth; method buttons primary, email secondary; no premature keyboard.
**5. Layout** — `AppHeader` (flat, back) → logo → headline → `_TrustRow` (→ `AppBadge` row) → Apple → Google → "or email" collapsible field (not autofocused) → guest → terms.
**6. Components** — `AppHeader`/back, `AppButton`, `AppBadge`, `AppTypography`; keep `SignInWithAppleButton`.
**7. Visual** — buttons 56px theme; email field via global `inputDecorationTheme`; spacing consistent.
**8. Motion** — section fade-in; button press feedback; loading spinner inside button.
**9. RTL** — provider buttons full-width (direction-agnostic); back chevron mirrors.
**10. Dark mode** — Apple button style per brightness; email CTA `cta`.
**11. Safety** — see §0.5. **Do not change** `AppSession`/auth providers or the redirect contract (UI only).
**12. Acceptance** — [ ] no autofocus keyboard; [ ] `AppHeader`; [ ] no `_alex`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 8 — OTP

**1. Identity** — `OtpScreen`; `lib/features/onboarding/otp_screen.dart`; route `/onboarding/otp`; verify email code.
**2. Current** — code field, verify button, demo hint, invalid-code error.
**3. Problems** — bespoke styling; ensure shared field/button.
**4. Goal** — focused single-purpose verify screen.
**5. Layout** — `AppHeader`(back) → instruction → segmented OTP field → verify `AppButton` → resend.
**6. Components** — `AppHeader`, `AppButton`, `AppTypography`, themed input.
**7. Visual** — large code field; `caption` hint.
**8. Motion** — error shake on invalid; button loading.
**9. RTL** — code field LTR digits within RTL layout.
**10. Dark mode** — field contrast; CTA `cta`.
**11. Safety** — see §0.5. Auth verify logic unchanged.
**12. Acceptance** — [ ] shared field/button; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 9 — Method / post-auth setup

**1. Identity** — `OnboardingMethodScreen`; `lib/features/onboarding/method_screen.dart`; route `/onboarding/method`; country + DOB + AI consent + capture setup; intent: "configure Mali to start capturing."
**2. Current** — sheet card; gradient hero; country picker (auto-opens); DOB; `_AiConsentCard`; Android steps / iOS `IosShortcutGuide` (8 steps); CTA; "later".
**3. Problems** — overloaded single screen; auto-opening picker abrupt; mandatory DOB unexplained; hardcoded gradients; `_alex`.
**4. Goal** — A short, guided multi-step setup that doesn't overwhelm.
**5. Layout** — split into steps with a progress indicator: (a) country/currency, (b) DOB with rationale (or optional), (c) AI consent, (d) capture setup (Android share / iOS Shortcut → defer detailed guide to Screen 11). Use `SheetScaffold` for the country picker (manual open).
**6. Components** — `AppScreenScaffold`+`AppHeader`, `SheetScaffold`, `AppCard`, `_AiConsentCard` (restyled), `AppButton`, `AppTypography`; `_FlagAvatar`/`_CountryTile`.
**7. Visual** — tokenized hero gradient; remove `_alex`; consistent spacing.
**8. Motion** — step transitions; consent toggle feedback.
**9. RTL** — stepper mirrors; country list RTL.
**10. Dark mode** — hero token; CTA `cta`.
**11. Safety** — see §0.5. `saveCountryCurrencyUseCaseProvider`, `onboardingSelectionProvider`, settings persistence unchanged.
**12. Acceptance** — [ ] stepped flow; [ ] picker via `SheetScaffold`; [ ] DOB justified/optional; [ ] no `_alex`/hardcoded gradient; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 10 — Listening / armed

**1. Identity** — `ListeningScreen`; `lib/features/onboarding/listening_screen.dart`; route `/onboarding/listening`; "armed, waiting for first message."
**2–12 (compact)** — Current: status illustration + "armed" copy + paste/skip. Problems: bespoke style/spinner. Goal: reassuring waiting state. Layout: `AppHeader` + centered status (icon + copy) + secondary actions (paste/skip). Components: `AppHeader`, `AppEmptyState`-style centerpiece, `AppButton`. Visual: tokens; `caption`. Motion: gentle pulse on the "listening" icon. RTL: centered (safe). Dark: icon/accent contrast. Safety: §0.5 (capture bridge untouched). Acceptance: [ ] tokenized; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 11 — iOS Shortcut setup + verify

**1. Identity** — `IosShortcutScreen` / `IosShortcutVerifyScreen`; `lib/features/onboarding/ios_shortcut_screen.dart`, `ios_shortcut_verify_screen.dart`; routes `/onboarding/ios-shortcut`, `/onboarding/ios-verify`; build + verify the Apple Automation.
**2–12 (compact)** — Current: 8 numbered steps (`_ShortcutStepRow`), verify waits for a message. Problems: longest drop-off; per-currency repetition; no success signal. Goal: guided, illustrated, lower-friction setup with a clear "connected ✓". Layout: `AppHeader` + step list (`SectionHeader` per step group) + copyable keyword + deep-link to Shortcuts + verify state. Components: `AppScreenScaffold`+`AppHeader`, `AppCard` steps, `AppButton`, `AppBadge` (connected). Visual: numbered tokens; `subhead`/`caption`. Motion: step reveal; success transition on first capture. RTL: numbers/steps RTL. Dark: step icons contrast. Safety: §0.5 — capture services unchanged; "connected" is a read-only signal. Acceptance: [ ] success state surfaced; [ ] tokenized; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 12 — Restore prompt

**1. Identity** — `RestorePromptScreen`; `lib/features/onboarding/restore_prompt_screen.dart`; routes `/onboarding/restore`, `/backup/restore`; restore E2E backup.
**2–12 (compact)** — Current: password / recovery-code entry, restore/skip. Problems: bespoke; trust messaging small. Goal: confident, secure restore. Layout: `AppHeader` + explanation (encryption/trust) + themed fields + `AppButton`. Components: `AppHeader`, themed inputs, `AppButton`, `AppInsightCard` (security note). Visual: tokens; lock iconography. Motion: button loading; error feedback. RTL: fields LTR-content within RTL. Dark: field/CTA contrast (`cta`). Safety: §0.5 — **backup/restore logic untouched** (UI only). Acceptance: [ ] trust messaging visible; [ ] tokenized; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 13 — Force update

**1. Identity** — `ForceUpdateScreen`; `lib/features/onboarding/force_update_screen.dart`; rendered by `AppShell` when `hasForceUpdateProvider`; blocking update gate.
**2–12 (compact)** — Current: full-screen message + update button (`c.primary` bg → dark-mode bug). Problems: `c.primary` button. Goal: clear, unavoidable, on-brand block. Layout: centered illustration + headline + `AppButton` (store link). Components: `AppButton`, `AppTypography`. Visual: tokens. Motion: subtle entrance. RTL: centered. Dark: **fix `c.primary`→`cta`** (already flagged). Safety: §0.5. Acceptance: [ ] `cta` button; [ ] AR/EN+RTL+dark; [ ] gates green.

---

# SECONDARY SCREENS

---

## Screen 14 — Accounts

**1. Identity** — `AccountsScreen`; `lib/features/accounts/accounts_screen.dart`; route `/accounts`; multi-currency accounts; intent: "manage my accounts/wallets."
**2. Current** — `Scaffold`+AppBar; account list; add/edit `_AccountForm` sheet (now scrollable); delete.
**3. Problems** — form overflow (fixed via scroll); bespoke header.
**4. Goal** — Clean account manager; consistent header + sheet.
**5. Layout** — `AppHeader`(back) + account `AppCard` list (name, currency, default badge) + add FAB/button; edit/add via `SheetScaffold` form.
**6. Components** — `AppScreenScaffold`+`AppHeader`, `AppCard`, `AppBadge` (default), `SheetScaffold`, `AppButton`, `AppCurrencyDropdown`.
**7. Visual** — flag/currency chips; radius `card`.
**8. Motion** — list stagger; sheet slide.
**9. RTL** — leading flag right; chevrons mirror.
**10. Dark mode** — form fields/CTA contrast.
**11. Safety** — see §0.5. `accountsProvider`, `accountRepository` read-only via UI; account CRUD use-cases unchanged.
**12. Acceptance** — [ ] `AppHeader`+`SheetScaffold`; [ ] currency dropdown shared; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 15 — Card details

**1. Identity** — `CardDetailsScreen`; `lib/features/cards/card_details_screen.dart`; route `/card/:last4`; per-card view; intent: "see a card's transactions/summary."
**2–12 (compact)** — Current: AppBar; card visual + txn list; loading/error/RTL present. Problems: bespoke header; ensure `AppTransactionRow`. Goal: premium card visual + clean list. Layout: `AppHeader` + card hero (`BrandMark`/`card_network_badge`) + `AppTransactionRow` list. Components: `AppHeader`, `AppCard`, `AppTransactionRow`, `PremiumSkeletonPage`, `AppErrorState`. Visual: tokenized card gradient. Motion: card reveal; list stagger. RTL: amounts leading. Dark: gradient token. Safety: §0.5 (`cardsProvider` read-only). Acceptance: [ ] shared row+header+states; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 16 — Backup

**1. Identity** — `BackupScreen`; `lib/features/backup/backup_screen.dart`; route `/backup`; E2E backup; intent: "protect my data."
**2–12 (compact)** — Current: AppBar; backup/restore controls; password/recovery; loading/error. Problems: trust story small; bespoke header. Goal: a confidence-inspiring security surface. Layout: `AppHeader` + `AppInsightCard` (encryption explainer) + action `AppCard`s (backup now, restore, recovery code) + `AppButton`. Components: `AppHeader`, `AppCard`, `AppInsightCard`, `AppButton`, `SheetScaffold`. Visual: lock iconography; tokens. Motion: progress states. RTL: safe. Dark: CTA `cta`. Safety: §0.5 — **backup logic/crypto untouched**. Acceptance: [ ] trust panel; [ ] shared components; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 17 — Privacy / start fresh / delete

**1. Identity** — `PrivacyScreen`; `lib/features/settings/privacy_screen.dart`; route `/privacy`; destructive data actions; intent: "reset or delete my data."
**2–12 (compact)** — Current: AppBar; start-fresh + delete-all actions; confirmations. Problems: two destructive paths both here; needs differentiation. Goal: safe, explicit, scary-when-needed. Layout: `AppHeader` + explanatory `AppInsightCard(danger)` + clearly separated destructive `AppButton`s with typed confirmations (`SheetScaffold` dialog). Components: `AppHeader`, `AppInsightCard`, `AppButton(danger)`, `SheetScaffold`. Visual: `danger` tokens; clear hierarchy. Motion: confirm friction (hold/confirm). RTL: safe. Dark: danger contrast. Safety: §0.5 — wipe/delete use-cases untouched (UI only). Acceptance: [ ] differentiated confirmations; [ ] tokenized; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 18 — Achievements

**1. Identity** — `AchievementsScreen`; `lib/features/achievements/achievements_screen.dart`; route `/achievements`; gamification; intent: "see my badges/level."
**2–12 (compact)** — Current: AppBar; badges/levels grid; error handling. Problems: bespoke header/cards. Goal: rewarding, premium badge gallery. Layout: `AppHeader`(gradient) with level metric + badge grid (`AppCard`/grid) + locked/unlocked states. Components: `AppHeader`, `AppCard`, `AppBadge`, `AppEmptyState`, `PremiumSkeletonPage`. Visual: badge color via tokens; consistent grid spacing. Motion: badge unlock celebration (ties to `celebration_runtime`). RTL: grid RTL. Dark: badge contrast. Safety: §0.5 (`achievementsProvider` read-only). Acceptance: [ ] shared header/cards/states; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 19 — Goals (dedicated) + details + form

**1. Identity** — `GoalsScreen`/`GoalDetailsScreen`/`GoalFormScreen`; `lib/features/goals/*`; routes `/goals`, `/goals/new`, `/goals/:id`; savings goals.
**2–12 (compact)** — Current: `SectionHeroHeader` (only direct user) + `_GoalCard`; details `VaultWidget` + contributions; form name/amount/currency/deadline. Problems: two entry points (here + Budgets tab); `VaultWidget` off-brand; `_alex` in form. Goal: one coherent goals experience reusing `BudgetProgressCard`. Layout: `AppHeader`(gradient) + `BudgetProgressCard` list; details via `SheetScaffold` (progress visual + contributions + add); form via `SheetScaffold` with `AppCurrencyDropdown` + deadline `Material` tile. Components: `AppHeader`, `BudgetProgressCard`, `SheetScaffold`, `AppCurrencyDropdown`, `AppButton`. Visual: rebrand vault to flat-card progress; remove `_alex`. Motion: progress animate; contribution add success. RTL: progress RTL. Dark: ring/CTA contrast. Safety: §0.5 — goal use-cases/currency persistence unchanged (already in data layer). Acceptance: [ ] single goals experience; [ ] shared progress card; [ ] no `_alex`; [ ] AR/EN+RTL+dark; [ ] gates green.

---

# SHEETS & MODALS (all adopt `SheetScaffold`)

---

## Screen 20 — Confirm captured transaction (Smart Inbox core)

**1. Identity** — `showConfirmTransactionSheet`; `lib/features/transactions/widgets/confirm_transaction_sheet.dart`; opened by `AppShell` from capture/notifications; intent: "quickly approve/fix an auto-captured transaction."
**2. Current** — blurred `BackdropFilter` sheet; big amount; category chip (تغيير → change-category sheet); account dropdown; date; "تعديل التفاصيل" (→ manual sheet); confirm `cta`.
**3. Problems** — nested sheets (category/edit) cause context switches; two form designs; part of fragmented inbox.
**4. Goal** — One-tap approve with inline edit; the heart of a consolidated Smart Inbox.
**5. Layout** — `SheetScaffold` → amount hero + `AppBadge` (AI/pending) → inline `CategoryChip` quick-pick (no nested sheet) → inline account/date → confirm + "edit more" (only if needed).
**6. Components** — `SheetScaffold`, `CategoryChip`, `AppBadge`, `AppButton`, `AppCurrencyDropdown`.
**7. Visual** — amount `amountHero`; tokens; radius from `SheetScaffold`.
**8. Motion** — slide-up; confirm success → banner; swipe affordances (confirm/fix) if inbox stack.
**9. RTL** — amount/category leading per RTL.
**10. Dark mode** — confirm `cta` (already fixed from `c.primary`); blur surface contrast.
**11. Safety** — see §0.5. `confirmTransactionUseCaseProvider`, `correctCategoryUseCase` read/called as-is — **no logic change**, only inline the UI.
**12. Acceptance** — [ ] category editable inline; [ ] `SheetScaffold`; [ ] `cta` confirm; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 21 — Change category

**1. Identity** — `showChangeCategorySheet`; `lib/features/transactions/widgets/change_category_sheet.dart`; intent: "recategorize + choose scope."
**2–12 (compact)** — Current: blurred sheet; 4-col category grid (`CategoryAvatar`); scope radios (this/merchant); save `cta`. Problems: big modal; scope easy to miss; was overflowing (fixed). Goal: fast pick with quick-access + clear scope. Layout: `SheetScaffold` → recent/most-used row → `CategoryChip` grid → prominent scope toggle → save. Components: `SheetScaffold`, `CategoryChip`, `AppBadge`/toggle, `AppButton`. Visual: selection ring `cta` (fixed from `c.primary`); grid even (fixed). Motion: selection feedback. RTL: grid RTL. Dark: ring/CTA contrast. Safety: §0.5 — `CategoryCorrectionScope`/use-case unchanged. Acceptance: [ ] quick-pick + clear scope; [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 22 — Manual transaction (add/edit)

**1. Identity** — `manual_transaction_sheet.dart`; add/edit a transaction; intent: "log/fix a transaction by hand."
**2–12 (compact)** — Current: form (amount/currency/account/category dropdown/date/note); category dropdown had value/items crash (fixed: dedupe + always-include selected). Problems: bespoke fields; overlaps confirm sheet. Goal: one reliable add/edit form reused by confirm "edit more". Layout: `SheetScaffold` → `AppAmountField`+`AppCurrencyDropdown` → account → `CategoryChip`/dropdown → date → note → save. Components: `SheetScaffold`, `AppAmountField`, `AppCurrencyDropdown`, `CategoryChip`, `AppButton`. Visual: global `inputDecorationTheme`. Motion: save success banner. RTL: numeric LTR within RTL. Dark: field/CTA contrast. Safety: §0.5 — add/update use-cases unchanged; keep the dedupe/value-guard already in place. Acceptance: [ ] shared fields; [ ] no dropdown crash; [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 23 — Bill form (subscription/installment)

**1. Identity** — `bill_form_sheet.dart`; add/edit bill; intent: "track a subscription/installment."
**2–12 (compact)** — Current: name/currency dropdown/amount/frequency/account/reminder. Problems: bespoke fields; currency list logic duplicated. Goal: consistent with manual form. Layout: `SheetScaffold` → name → `AppAmountField`+`AppCurrencyDropdown` → frequency → account → reminder toggle → save. Components: `SheetScaffold`, shared fields, `AppButton`. Visual: tokens. Motion: save banner. RTL: safe. Dark: CTA `cta`. Safety: §0.5 — bill repo/use-cases unchanged. Acceptance: [ ] shared fields/currency dropdown; [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 24 — Budget form

**1. Identity** — `budget_form_screen.dart`; add/edit budget; intent: "set a spending limit."
**2–12 (compact)** — Current: category/amount(suffix=account currency)/period/account/show-on-header/suggested. Problems: bespoke fields; `_alex`. Goal: consistent form; budget inherits account currency (already wired). Layout: `SheetScaffold` → category → `AppAmountField` (account-currency suffix) → period → account → show-on-header toggle → save. Components: `SheetScaffold`, shared fields, `AppButton`. Visual: remove `_alex`; tokens. Motion: save banner. RTL: safe. Dark: CTA `cta`. Safety: §0.5 — budget use-cases/currency logic unchanged. Acceptance: [ ] no `_alex`; [ ] shared fields; [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 25 — Bank discovery confirmation

**1. Identity** — `bank_discovery_confirmation_sheet.dart`; "is this bank X?" after AI discovery; intent: "confirm an unknown sender's bank."
**2–12 (compact)** — Current: RTL sheet; confirm/reject mapping. Problems: bespoke chrome. Goal: trustworthy, simple yes/no. Layout: `SheetScaffold` → bank candidate card → confirm/reject `AppButton`s. Components: `SheetScaffold`, `AppCard`, `AppButton`, `AppBadge`. Visual: tokens. Motion: result banner. RTL: safe. Dark: CTA contrast. Safety: §0.5 — `bank_discovery_controller`/mapping use-cases unchanged. Acceptance: [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

## Screen 26 — Capture entry + manual paste

**1. Identity** — `capture_entry_sheet.dart`, `manual_paste_screen.dart`; choose add method / paste SMS; intent: "add a transaction or paste a bank SMS."
**2–12 (compact)** — Current: entry chooser → paste or manual. Problems: extra hop between paste vs manual. Goal: one add surface with paste affordance at top. Layout: `SheetScaffold` → "paste bank SMS" field/CTA at top → divider → manual fields (reuse Screen 22). Components: `SheetScaffold`, shared fields, `AppButton`. Visual: tokens. Motion: paste→parse feedback. RTL: paste field LTR-friendly. Dark: CTA `cta`. Safety: §0.5 — paste→ingest pipeline unchanged. Acceptance: [ ] merged add surface; [ ] `SheetScaffold`; [ ] AR/EN+RTL+dark; [ ] gates green.

---

# REMOVE / CLEANUP (not redesigned)

- **`foundation/foundation_home_screen.dart`** — unrouted/dead. **Remove** after confirming no references (uses a `c.primary` button too). Not part of the product surface.
- **Legacy `TransactionRow`** in `lib/features/common/widgets.dart` — retire in favor of `AppTransactionRow`.
- **App-lock gate** (`lib/core/security/app_lock_gate.dart`) — not a product screen but a gate; keep its de-looped behavior, restyle button to `cta` (already flagged). Treat as a small polish item, not a redesign target.

---

## Suggested sequencing (mirrors safety contract §1)

1. **Foundations:** build `AppHeader`, `SheetScaffold`, `SectionHeader`, `AppErrorState`, `IconCircleButton`, `AppBadge`, `AppFilterChip`/`AppChipRow`, `ProgressItemCard`, `ChartCard`, `AppCurrencyDropdown`/`AppAmountField`; collapse gradients into `AppGradients`; purge `c.primary` button backgrounds; remove `_alex` clones as touched.
2. **Core loop:** Dashboard (1), Confirm sheet / Smart Inbox (20, 21), Transactions (2), add/paste merge (22, 26).
3. **Destinations:** Reports (3), Budgets+Goals (4, 19), Settings (5).
4. **Onboarding:** 6–13.
5. **Secondary + sheets:** 14–18, 23–25.
6. **Polish:** charts interaction (3), motion pass, states pass, cleanup/removals.

Each numbered item = one phase = analyze + tests + AR/EN + RTL + dark verification before moving on.
