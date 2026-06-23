# Mali — Redesign Execution Plan (for Antigravity)

> Practical, phase-by-phase plan. **Documentation only — do not implement from this doc alone.**
> Binding rules: `implementation_safety_contract.md`. Direction: `visual_direction.md`. Per-screen
> detail: `screen_by_screen_redesign_spec.md`. Findings: `docs/design_audit/*`. Paths relative to `app/`.
> **Foundations before screens.** One phase = compile + `flutter analyze` (0) + `flutter test` (green)
> + AR/EN + RTL/LTR + dark/light verification before moving on. Never commit/push automatically.

**Gate commands (run from `app/`):**
```bash
flutter analyze        # 0 issues
flutter test           # full suite green (~293 tests)
flutter gen-l10n       # only if ARB changed
```

**Do-not-touch (ALL phases unless a dedicated non-UI phase says so):** parsing `lib/engine/parser/**`,
use-cases `add_transaction_usecase`/`ingest_*`/dedup, AI `lib/engine/ai/**` + `supabase/functions/parse-sms`,
categorization `lib/engine/categorization/**`, provider *semantics* (`*_providers.dart`, `app_providers.dart`),
storage `lib/data/**` (Drift schema/migrations), auth/session/backup (`core/auth`, `app_session`,
`features/backup`, `core/security`), capture bridge `features/capture/services/**`, and `test/**`.

---

## Phase 0 — Safety & baseline

- **Goal:** lock a known-good starting point; no UI changes.
- **Files:** none (read-only).
- **Build:** nothing. Confirm: working tree state (`git status`), the 9 audit/redesign docs exist,
  `flutter analyze` clean, `flutter test` green. Snapshot baseline screenshots of all screens in AR+EN,
  dark+light for later diffing.
- **Do NOT touch:** anything.
- **Acceptance:** [ ] baseline analyze clean; [ ] baseline tests green; [ ] baseline screenshots saved;
  [ ] docs present; [ ] no code changed.
- **Tests/checks:** `flutter analyze`, `flutter test`.
- **Screenshot review:** capture Dashboard, Transactions, Reports, Budgets, Settings, Onboarding, Auth,
  key sheets — AR+EN × dark+light (baseline set).

## Phase 1 — Design tokens

- **Goal:** one coherent token foundation; fix the dark-mode button bug at the source.
- **Files:** `lib/core/theme/app_colors.dart`, `app_gradients.dart`, `app_typography.dart`,
  `app_spacing.dart`, `app_shadows.dart`, new `app_motion.dart`; `app_theme.dart` (wiring only).
- **Build:** finalize the single-accent palette + tint ladder; collapse all blues into one brand
  gradient set in `AppGradients`; confirm/extend `AppTypography` (no new inline styles); confirm
  `AppSpacing`/`AppRadius`; tokenize `AppShadows` (fix the hardcoded `cta` blue); add `AppMotion`
  constants (durations/curves). Add a documented rule + helper so `c.primary` is never a button bg.
- **Do NOT touch:** any feature screen yet; logic; tests.
- **Acceptance:** [ ] one gradient source; [ ] tokenized shadows; [ ] motion constants exist; [ ] no new
  hardcoded literals; [ ] dark/light palettes validated; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; grep `Color(0x` and `LinearGradient(` in `lib/features` to record
  the cleanup backlog (not all fixed yet).
- **Screenshot review:** N/A (no visual screens changed) — but verify the app still builds/runs in both
  modes.

## Phase 2 — Core components

- **Goal:** build/upgrade the shared component library every screen will use.
- **Files (new unless noted):** `app_header.dart`, `section_header.dart`, `sheet_scaffold.dart`,
  `app_error_state.dart`, `icon_circle_button.dart`, `app_badge.dart`, `app_filter_chip.dart`(+chip row),
  `progress_item_card.dart`, `charts/chart_card.dart`, `app_currency_dropdown.dart`/`app_amount_field.dart`;
  upgrade existing `app_screen_scaffold.dart`, `app_card.dart`, `app_button.dart`, `app_metric_card.dart`,
  `app_insight_card.dart`, `app_transaction_row.dart`, `app_empty_state.dart`, `premium_loading.dart`,
  `category_catalog.dart` (CategoryChip).
- **Build:** implement each component against tokens; widgetbook/demo optional. `SheetScaffold` must
  provide RTL + drag handle + max-height + scrollable body + optional blur + tokenized radius.
- **Do NOT touch:** screens (they migrate in later phases); logic; tests.
- **Acceptance:** [ ] all listed components exist, token-driven, RTL-safe, dark/light-safe; [ ] no
  `c.primary` button bg; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; add light widget tests for new components if cheap (no logic).
- **Screenshot review:** component gallery/demo in AR+EN × dark+light (header, card, button, sheet, chip,
  badge, progress card, chart card, states).

## Phase 3 — Navigation shell

- **Goal:** unify the app frame (nav + headers + page padding) on the new components.
- **Files:** `lib/features/app/app_shell.dart` (`_FloatingBottomBar`/`_NavTab`), `app_screen_scaffold.dart`;
  light touches to each tab to host `AppHeader` (deeper screen work in later phases).
- **Build:** sharpen the floating pill active node; unify icons to lucide; consider center capture "+";
  ensure consistent page padding + safe areas; route all screens through `AppScreenScaffold`+`AppHeader`.
- **Do NOT touch:** capture orchestration logic in `app_shell` (`_consumeSharedInput`, `_syncEngagement`,
  celebration/notification scheduling) — UI of the bar only; providers; logic.
- **Acceptance:** [ ] one nav style, one header system live across tabs; [ ] RTL nav order correct;
  [ ] dark/light correct; [ ] scroll-hide still works; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; manual nav in RTL/LTR.
- **Screenshot review:** all 5 tabs' header + bottom bar, AR+EN × dark+light; verify active node + hide-on-scroll.

## Phase 4 — Dashboard

- **Goal:** premium, calm financial overview; money-as-hero; alive.
- **Files:** `lib/features/dashboard/dashboard_screen.dart` (+ read-only `dashboard_providers.dart`).
- **Build:** `AppHeader` (gradient) with greeting/streak/account control; balance/spend hero
  (`amountHero` + change pill + `AnimatedAmountText`); Smart-Inbox `AppInsightCard` (if pending);
  analytics `ChartCard`; recent `AppTransactionRow` via shared mapper; period stepper via
  `IconCircleButton`; move "add" out of the header.
- **Do NOT touch:** `dashboardDataProvider`/`dashboardAccountProvider` semantics; FX logic (none);
  capture; logic. (Data-liveness is a separate, explicitly-scoped change — coordinate, don't sneak it in.)
- **Acceptance:** [ ] matches Screen 1 acceptance in the spec; [ ] no `_alex`/hardcoded colors; [ ]
  standardized empty/loading/error; [ ] AR/EN+RTL+dark/light; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; verify privacy mode masks amounts.
- **Screenshot review:** dashboard data/empty/loading/error, AR+EN × dark+light; multi-account; long
  account names; textScaler 1.25.

## Phase 5 — Smart Inbox

- **Goal:** Mali's signature review surface; consolidate the 3 fragmented entry points.
- **Files:** `lib/features/transactions/widgets/confirm_transaction_sheet.dart`,
  `widgets/change_category_sheet.dart`, dashboard `_smartInbox` section, Transactions pending tab;
  `bank_discovery/bank_discovery_confirmation_sheet.dart`.
- **Build:** confirm sheet on `SheetScaffold` with amount hero + AI-confidence `AppBadge` + inline
  `CategoryChip` quick-pick + inline account/date (no nested sheets); selective inverted "needs review"
  card; consistent confirm (`cta`). Keep "edit more" → manual sheet.
- **Do NOT touch:** `confirmTransactionUseCase`, `correctCategoryUseCase`, `CategoryCorrectionScope`,
  AI confidence computation, dedup — **UI only**.
- **Acceptance:** [ ] Screen 20/21 acceptance met; [ ] inline category edit; [ ] `SheetScaffold`;
  [ ] `cta` confirm; [ ] AR/EN+RTL+dark/light; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests (esp. existing `ai_cascade_test` must stay green — do not alter logic).
- **Screenshot review:** confirm sheet (AI/pending states), change-category grid, bank-discovery sheet,
  AR+EN × dark+light; overflow at large text.

## Phase 6 — Transactions

- **Goal:** fast, scannable ledger; reduce tab nesting; polish rows.
- **Files:** `lib/features/transactions/transactions_screen.dart`, `transaction_details_screen.dart`,
  `manual_transaction_sheet.dart`; `app_transaction_row.dart` (polish); `capture/capture_entry_sheet.dart`
  + `manual_paste_screen.dart` (merge add surfaces).
- **Build:** one filter chip row + single date control (range sheet); `SectionHeader` date groups;
  retire legacy `TransactionRow`; merge paste+manual into one add sheet (`SheetScaffold`); move Bills to
  its own destination or single segmented toggle (no double tab rows).
- **Do NOT touch:** filter semantics (`transactionsListProvider` and filter `StateProvider`s), dedup,
  the manual-sheet dropdown value-guard/dedupe already in place, logic.
- **Acceptance:** [ ] Screen 2/22/26 acceptance; [ ] ≤1 tab row visible; [ ] shared row mapping; [ ]
  all sheets `SheetScaffold`; [ ] AR/EN+RTL+dark/light; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; verify filters/search still behave.
- **Screenshot review:** list/empty/loading/error, filters open, details sheet, add/paste sheet, bills,
  AR+EN × dark+light.

## Phase 7 — Budgets / Goals / Reports

- **Goal:** consistent progress visuals + premium charts + clear warning states.
- **Files:** `budgets/budgets_screen.dart`, `budget_form_screen.dart`, `goals/*` (screen/details/form),
  `reports/reports_screen.dart`; `progress_item_card.dart`, `charts/chart_card.dart`.
- **Build:** unify budgets/goals on `ProgressItemCard` (ring/bar via `budgetState`); rebrand
  `VaultWidget` to the flat system; `ChartCard` for reports (interactive where feasible); consistent
  header metrics; warning/over states use semantic tokens; forms on `SheetScaffold` with shared
  `AppCurrencyDropdown`/`AppAmountField`; remove `_alex` in forms.
- **Do NOT touch:** budget/goal/report provider semantics; budget=account-currency & goal-currency logic
  (already in data layer); export logic; storage.
- **Acceptance:** [ ] Screen 3/4/19 acceptance; [ ] one progress card; [ ] consistent charts; [ ]
  no `_alex`; [ ] AR/EN+RTL+dark/light; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; verify budget alert thresholds unaffected (logic untouched).
- **Screenshot review:** budgets/goals lists + empty + warning/over, goal details, reports tabs + charts,
  AR+EN × dark+light.

## Phase 8 — Onboarding / Auth / Backup / Shortcut

- **Goal:** calm, trustworthy entry; surface privacy/security; lower Shortcut friction.
- **Files:** `onboarding/*` (onboarding, auth, otp, method, listening, first_transaction,
  ios_shortcut(+verify), restore_prompt, force_update), `backup/backup_screen.dart`,
  `settings/privacy_screen.dart`.
- **Build:** stepped onboarding (country/currency → DOB(+rationale) → capture setup) with progress;
  country picker via `SheetScaffold`; clean auth (no autofocus keyboard); trust panel (on-device + E2E);
  guided shortcut with success state; remove `_alex`/hardcoded gradients; force-update button → `cta`.
- **Do NOT touch:** `AppSession`/auth providers & redirect contract, OTP/email verify, backup crypto,
  capture services, `saveCountryCurrencyUseCase` — UI only.
- **Acceptance:** [ ] Screen 6–13/16/17 acceptance; [ ] trust messaging visible; [ ] no `_alex`/
  hardcoded gradients; [ ] AR/EN+RTL+dark/light; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; verify onboarding routing still reaches `/` (don't change session).
- **Screenshot review:** each onboarding step, auth, OTP, restore, force-update, backup, privacy,
  AR+EN × dark+light.

## Phase 9 — Motion & polish

- **Goal:** cohesive micro-interactions + standardized states.
- **Files:** `common/motion.dart`, `app_motion.dart`, `charts/*`, `premium_loading.dart`, the shared
  banner (merge `announcement_banner` + `_CelebrationBanner`), touch-ups across screens.
- **Build:** apply `PremiumMotion` entrances + `AnimatedAmountText` everywhere money changes; chart
  draw-in; skeletons on every data screen (retire spinners); success/error via the shared banner;
  button press feedback. Respect `disableAnimations`.
- **Do NOT touch:** logic; provider semantics; tests.
- **Acceptance:** [ ] consistent motion spec applied; [ ] all loading = skeletons; [ ] one banner system;
  [ ] reduced-motion respected; [ ] analyze+tests green.
- **Tests/checks:** analyze; tests; verify with "reduce motion" enabled.
- **Screenshot/recording review:** short clips of entrance, count-up, chart draw, sheet, success/error,
  AR+EN × dark+light.

## Phase 10 — QA

- **Goal:** full-quality pass before sign-off.
- **Files:** none functional (fix-only as issues surface).
- **Build:** nothing new — verify and fix regressions.
- **Do NOT touch:** logic (fixes are UI-only; escalate if a fix needs logic).
- **Acceptance:** [ ] `flutter analyze` clean; [ ] `flutter test` green; [ ] AR + EN correct; [ ] RTL +
  LTR correct; [ ] dark + light correct; [ ] small screens (SE-class) OK; [ ] no overflow at textScaler
  1.25; [ ] no hardcoded colors/gradients/`_alex`/`c.primary` buttons (grep clean); [ ] every screen on
  shared header/card/button/sheet; [ ] screenshots match the intended direction.
- **Tests/checks:** `flutter analyze`; `flutter test`; grep guards:
  `grep -rn "Color(0x" lib/features`, `grep -rn "backgroundColor: c.primary" lib/features`,
  `grep -rn "_alex(" lib/features`, `grep -rn "LinearGradient(" lib/features`.
- **Screenshot review:** full matrix — every screen × AR/EN × RTL/LTR × dark/light × (default + 1.25
  text scale) × (large + small device); diff against Phase-0 baseline.

---

## Cross-phase guardrails (recap)

- One screen/component per phase; reviewable diffs; no big-bang rewrite.
- Tokens only; no hardcoded colors/gradients/typography; no new gradient outside `AppGradients`.
- All sheets via `SheetScaffold`; all screens via `AppScreenScaffold`+`AppHeader`.
- `c.primary` never a blind button background.
- `flutter analyze` + `flutter test` green after every phase; preserve AR/EN + RTL/LTR + dark/light.
- Escalate (stop & ask) if any UI task seems to require a logic/provider/schema/test change.

## Cleanup tracked alongside (not a screen phase)
- Remove dead `foundation/foundation_home_screen.dart` (confirm unrouted first).
- Retire legacy `TransactionRow` (`common/widgets.dart`).
- Centralize entity→row mapping (dashboard recent + transactions).
- Move hardcoded Arabic strings into ARB (`flutter gen-l10n`) to repair the English locale.
- Fix stale `AppInsightType.ai` "amber" comment (now blue).
