# Mali Screen Migration Plan

Purpose: plan a safe migration from the current Flutter UI to the reference visual direction. This is planning only.

## Current App Screen Inventory

| Screen / Surface | Flutter file path | Route/tab | Purpose | Data/providers used | Actions | States | Visual redesign opportunity | Best reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| App shell / bottom navigation | `app/lib/features/app/app_shell.dart` | `/`, shell tabs | Hosts core tabs, capture runtime, announcements, celebrations | `shellIndexProvider`, `hasForceUpdateProvider`, capture runtime, notifications/engagement providers | switch tabs, handle capture confirmations, notification routes | force update, banners, bottom nav hide/show | Match glass/pill nav only after token/shared component phases; keep runtime logic untouched | REF-03, REF-01 |
| Splash | `app/lib/app.dart` | global overlay | Launch brand animation | theme/locale providers, timer | none | visible/fade out | Align brand mark and loading with REF-02 while preserving overlay behavior | REF-02 |
| Onboarding intro | `app/lib/features/onboarding/onboarding_screen.dart` | `/onboarding` | Value prop, how it works, privacy, country/currency | `onboardingSelectionProvider`, `saveCountryCurrencyUseCaseProvider` | next, skip, country picker | static pages, country search | Follow REF-02 page sequence, reduce hardcoded preview, add language screen only if approved | REF-02 |
| Auth | `app/lib/features/onboarding/auth_screen.dart` | `/onboarding/auth` | Apple/Google/email/guest auth | `authServiceProvider`, `AppSession` | provider sign-in, send OTP, guest paths | busy, auth error snackbar | Email-first visual direction; do not change guest logic unless approved | REF-02 |
| OTP | `app/lib/features/onboarding/otp_screen.dart` | `/onboarding/otp` | Verify email code | `authServiceProvider`, `AppSession` | verify | busy, invalid code | Dedicated OTP field/resend states from REF-02 | REF-02 |
| Onboarding method/setup | `app/lib/features/onboarding/method_screen.dart` | `/onboarding/method` | Android/iOS capture setup, AI consent, backup check | `baseCurrencyProvider`, `backupServiceProvider`, `userSettingsProvider`, Android SMS service, `AppSession` | request SMS, verify iOS, AI toggle, later | busy; backup found route; platform branch | Split visually into calmer steps; preserve route and service calls | REF-02 |
| iOS Shortcut setup | `app/lib/features/onboarding/ios_shortcut_screen.dart` | `/onboarding/ios-shortcut` | Standalone shortcut guide | `baseCurrencyProvider` | back | static | Merge visual language with REF-02 shortcut guide; avoid duplicate confusion | REF-02 |
| iOS Shortcut verify | `app/lib/features/onboarding/ios_shortcut_verify_screen.dart` | `/onboarding/ios-verify` | Wait for shared message or paste fallback | `NativeCaptureBridge`, `CapturedMessageProcessor`, `backupServiceProvider`, `AppSession` | re-check, paste, skip | polling/loading, setup incomplete, success via route | Stronger waiting/incomplete/success states | REF-02, REF-12 |
| Android listening | `app/lib/features/onboarding/listening_screen.dart` | `/onboarding/listening` | Wait for first capture | `AndroidSmsCaptureService`, `CaptureRuntime`, `backupServiceProvider`, `AppSession` | paste, skip | listening/pulse | Use global loading/waiting style and clear manual fallback | REF-02, REF-12 |
| First transaction | `app/lib/features/onboarding/first_transaction_screen.dart` | `/onboarding/first-transaction` | Review first captured transaction | `transactionByIdProvider`, `categoryCatalogProvider`, `dashboardDataProvider` | confirm, change category, continue | loading, error, pending, confirmed | Make first success/pending state more celebratory and clear | REF-02, REF-04 |
| Restore prompt | `app/lib/features/onboarding/restore_prompt_screen.dart` | `/onboarding/restore`, `/backup/restore` | Restore encrypted backup | `backupServiceProvider`, backup/dashboard/transaction/bills/budget/goal providers invalidated | restore, switch recovery/password, start fresh | busy, error, restore success | Match backup/restore visual from REF-02/REF-11 | REF-02, REF-11 |
| Force update | `app/lib/features/onboarding/force_update_screen.dart` | app shell block | Block app until update | `activeAnnouncementsProvider` | open update URL | fallback announcement | Tokenized error/block state | REF-12 |
| Dashboard | `app/lib/features/dashboard/dashboard_screen.dart` | tab 0 | Financial overview, pending review, analytics, recent activity | `dashboardDataProvider`, `dashboardAccountProvider`, `userSettingsProvider`, `accountsProvider`, date range provider | refresh, account/date changes, jump to transactions/pending | loading, error, empty, data | REF-03 hierarchy: summary, Smart Inbox, donut, budgets, recent, AI insight | REF-03 |
| Smart Inbox surfaces | `dashboard_screen.dart`, `transactions_screen.dart`, `confirm_transaction_sheet.dart`, `capture_entry_sheet.dart`, `manual_paste_screen.dart` | no dedicated route | Review captured/pending transactions | `transactionsPendingFilterProvider`, `transactionByIdProvider`, capture runtime, ingest use case | confirm, edit, paste, manual add | pending, unprocessable, success, empty | Make Smart Inbox feel like core feature without inventing route | REF-04 |
| Capture entry | `app/lib/features/capture/capture_entry_sheet.dart` | sheet | Choose paste/manual capture | capture/transaction use cases via child flows | paste, manual | sheet states | Use shared sheet and REF-04/06 style | REF-04, REF-06 |
| Manual paste | `app/lib/features/capture/manual_paste_screen.dart` | `/paste`, sheet | Paste bank SMS | `ingestCapturedMessageUseCaseProvider`, dashboard invalidation | paste/import | loading, error, success | Use REF-02 fallback and REF-04 Smart Inbox parse affordance | REF-02, REF-04 |
| SMS permission/share sheet | `app/lib/features/capture/sms_permission_screen.dart` | `/capture/sms-permission`, sheet | Explain SMS/share/manual paste | local UI | paste manually, later | static | Localize and align with permission states; do not change native bridge | REF-02 |
| Transactions list | `app/lib/features/transactions/transactions_screen.dart` | tab 1 | Search/filter/group transactions and bills | `transactionsListProvider`, `billsViewProvider`, filters/date/tab providers | search, filters, add bill, navigate details | loading, empty, error, data | Adopt REF-05 search/filter/date groups; reduce stacked tab complexity carefully | REF-05 |
| Transaction details | `app/lib/features/transactions/transaction_details_screen.dart` | `/transaction/:id` | Transaction detail page/sheet | `transactionByIdProvider`, `categoryCatalogProvider` | edit, change category, delete/share if supported | loading, error, found/missing | Use REF-06 details/action tile style; avoid unsupported actions | REF-05, REF-06 |
| Confirm transaction sheet | `app/lib/features/transactions/widgets/confirm_transaction_sheet.dart` | sheet via capture runtime | Review pending captured transaction | `transactionByIdProvider`, confirm/correct use cases indirectly | confirm, edit details, category/account/date changes | loading/error/pending/success | REF-04 review card and REF-06 sheets | REF-04, REF-06 |
| Change category sheet | `app/lib/features/transactions/widgets/change_category_sheet.dart` | sheet | Correct category | `categoryCatalogProvider`, `correctCategoryUseCaseProvider` | select/save | loading/error/list | REF-06 category picker | REF-06 |
| Manual transaction sheet | `app/lib/features/transactions/manual_transaction_sheet.dart` | sheet | Add/edit/delete manual transaction | account/category/transaction providers and use cases | save/delete | loading categories/accounts, validation | REF-06 edit transaction sheet | REF-06 |
| Budgets overview | `app/lib/features/budgets/budgets_screen.dart` | tab 2 / `/budgets` | Budgets and goals tabbed overview | `budgetsViewProvider`, `budgetsPageTabProvider` | switch tabs, create/edit budget | loading, empty, error, data | Use REF-07; consider visual separation of budgets/goals without logic change | REF-07 |
| Budget form | `app/lib/features/budgets/budget_form_screen.dart` | `/budgets/new`, `/budgets/:id/edit` | Create/edit/delete budget | `budgetByIdProvider`, `categoryCatalogProvider`, `accountsProvider`, save/delete use cases | save/delete | loading, validation, success route | REF-07 create/edit sheets/forms | REF-07 |
| Reports | `app/lib/features/reports/reports_screen.dart` | `/reports` | Spend analytics/reports | `reportsProvider`, `userSettingsProvider` | change range/tab, export | loading, error, empty/data | REF-08 overview/monthly/category/comparison/export states | REF-08 |
| Goals overview | `app/lib/features/goals/goals_screen.dart` | `/goals` and within budgets tab | Savings goals list | `goalsListProvider` | create/open | loading, empty, error, data | REF-09 goal overview and empty | REF-09 |
| Goal details | `app/lib/features/goals/goal_details_screen.dart` | `/goals/:id` | Goal progress/contributions | `goalDetailsProvider` | add contribution/withdraw/edit/delete | loading, missing/error, success | REF-09 details/deposit/withdraw/delete | REF-09 |
| Goal form | `app/lib/features/goals/goal_form_screen.dart` | `/goals/new` and edit flow | Create/edit goal | `baseCurrencyProvider`, save goal use case | save/delete | validation | REF-09 create/edit forms | REF-09 |
| Accounts overview | `app/lib/features/accounts/accounts_screen.dart` | `/accounts` | Manage accounts/wallets | `accountsProvider`, `activeCurrenciesProvider`, account repository, dashboard invalidation | add/edit/delete/default | loading, empty, error, data | REF-10 accounts overview/forms | REF-10 |
| Card details | `app/lib/features/cards/card_details_screen.dart` | `/card/:last4` | Card summary/details | card providers | view details | loading/error/data | REF-10 card details; avoid fake bank logos | REF-10 |
| Settings | `app/lib/features/settings/settings_screen.dart` | tab 3, `/settings`, `/profile` | Profile/settings/privacy/language/notifications/categories | `userSettingsProvider`, `notificationPreferencesProvider`, settings/category repositories | toggles, pickers, export, sign out/delete | loading provider values, sheets | REF-11 grouping and settings screens | REF-11 |
| Privacy | `app/lib/features/settings/privacy_screen.dart` | `/privacy` | Privacy/data actions | `dataWipeServiceProvider`, `AppSession` | export, backup, delete/reset | delete confirm, link errors | REF-11 privacy/security; REF-12 danger states | REF-11, REF-12 |
| Backup | `app/lib/features/backup/backup_screen.dart` | `/backup` | E2E backup/restore | `backupStatusProvider`, `backupServiceProvider`, `AppSession.isGuest` | enable, backup now, restore, disable | loading, error, guest gate, enabled/disabled, recovery code | REF-11 backup/restore card system | REF-11 |
| Subscriptions/Bills | `app/lib/features/subscriptions/subscriptions_screen.dart`, `transactions_screen.dart` bills tab | `/subscriptions`, transactions bills tab | Recurring bills/subscriptions | bills providers/repositories | add/edit bill | loading/empty/data | Use transaction/budget card language, not real brand logos | REF-05 |
| Achievements | `app/lib/features/achievements/achievements_screen.dart` | `/achievements` | Badges/streaks | achievements providers | view badges | loading/empty/data | Use REF-12 state language and tokenized cards | REF-12 |
| Global states | `app/lib/features/common/app_empty_state.dart`, `app_loading_state.dart`, `premium_loading.dart` | shared | Empty/loading/error visuals | none or passed callbacks | retry/primary action | empty/loading/error | Build REF-12 as shared state system | REF-12 |

## Migration Order

### Phase 0 — Safety Baseline

- Goal: capture current status before design migration.
- Allowed files: docs/reports only unless tests require local generated artifacts.
- Tasks:
  - Record current dirty tree.
  - Run baseline checks from `app/`: `flutter analyze`, `flutter test`, `flutter build macos --debug`.
  - Screenshot current key screens if possible.
  - Create `docs/redesign/phase_0_reference_baseline_report.md`.
  - Create `docs/redesign/phase_0_reference_self_review.md`.
- Stop after phase.

### Phase 1 — Design Tokens

- Goal: adapt theme tokens to reference direction.
- Allowed files: `app/lib/core/theme/**` and phase docs only.
- Tasks:
  - Add/adjust color, gradient, radius, spacing, shadow, typography tokens.
  - Do not touch feature screens yet.
  - Validate dark/light token contrast.
  - Run all gates and report.
- Stop after phase.

### Phase 2 — Shared Components

- Goal: prepare reusable UI primitives before screen work.
- Allowed files: `app/lib/features/common/**`, possibly theme files if missing token surfaced, phase docs.
- Tasks:
  - Evolve `AppHeader`, `AppCard`, `AppButton`, `AppSheetScaffold`, `AppEmptyState`, loading and error states.
  - Add `AppErrorState` if needed.
  - Add category avatar/progress primitives if UI-only.
  - No screen migration except minimal compile integration if necessary.
- Stop after phase.

### Phase 3 — Onboarding

- Files: `app/lib/features/onboarding/**`, `app/lib/features/capture/sms_permission_screen.dart`, maybe `backup_screen.dart` and `privacy_screen.dart` only if used by onboarding design.
- Preserve: `AppSession`, auth providers, backup/capture logic, router behavior.
- Reference: REF-02, REF-12.
- Stop after phase.

### Phase 4 — Dashboard

- Files: `dashboard_screen.dart`, dashboard UI-only helper widgets, maybe common components.
- Preserve: `dashboardDataProvider`, `dashboardAccountProvider`, date/filter semantics.
- Reference: REF-03.
- Stop after phase.

### Phase 5 — Smart Inbox

- Files: dashboard Smart Inbox section, transactions pending filter UI, confirm transaction sheet, capture entry/paste UI only.
- Preserve: capture runtime, ingest use case, parser, AI, routes.
- Reference: REF-04.
- Stop after phase.

### Phase 6 — Transactions

- Files: `transactions_screen.dart`, list UI, filters, transaction row usage.
- Preserve: filters/provider semantics and bills data logic.
- Reference: REF-05.
- Stop after phase.

### Phase 7 — Transaction Details + Sheets

- Files: `transaction_details_screen.dart`, `manual_transaction_sheet.dart`, `confirm_transaction_sheet.dart`, `change_category_sheet.dart`, shared sheet refinements.
- Preserve: save/delete/confirm/correct use cases.
- Reference: REF-06.
- Stop after phase.

### Phase 8 — Budgets

- Files: `budgets_screen.dart`, `budget_form_screen.dart`, budget UI-only helpers.
- Preserve: `budgetsViewProvider`, budget account/currency logic, save/delete use cases.
- Reference: REF-07.
- Stop after phase.

### Phase 9 — Reports

- Files: `reports_screen.dart`, `features/common/charts/**`, report UI-only helpers.
- Preserve: `reportsProvider`, report calculations, export semantics.
- Reference: REF-08.
- Stop after phase.

### Phase 10 — Goals

- Files: `goals_screen.dart`, `goal_details_screen.dart`, `goal_form_screen.dart`, goal UI-only helpers.
- Preserve: goal providers/use cases.
- Reference: REF-09.
- Stop after phase.

### Phase 11 — Accounts/Cards

- Files: `accounts_screen.dart`, card widgets/details UI-only files.
- Preserve: account repositories/providers and card route behavior.
- Reference: REF-10.
- Stop after phase.

### Phase 12 — Settings

- Files: `settings_screen.dart`, `privacy_screen.dart`, `backup_screen.dart`, settings UI-only helpers.
- Preserve: settings providers, app lock, backup/auth/privacy logic.
- Reference: REF-11.
- Stop after phase.

### Phase 13 — Global Empty / Loading / Error States

- Files: shared state widgets and final per-screen adoption only where still missing.
- Preserve: app logic.
- Reference: REF-12.
- Stop after phase.

### Phase 14 — Final QA And Screenshots

- Goal: full matrix verification.
- Tasks:
  - Run all gates.
  - Screenshot all migrated screens in Arabic RTL dark.
  - Spot-check English/LTR and light mode.
  - Create final QA report and self-review.
- Stop after phase.

## Safety Rules For Every Phase

Every phase must:

- Modify only allowed files.
- Preserve logic.
- Preserve routes unless explicitly approved.
- Preserve providers unless UI-only and documented.
- Avoid fake data.
- Avoid new packages unless approved.
- Run from `app/`:
  - `flutter analyze`
  - `flutter test`
  - `flutter build macos --debug`
- Create a phase report.
- Create a self-review report.
- Commit only if all checks pass and the user approves committing.
- Stop after each phase.

## Main Implementation Risks

- Current working tree is already dirty; baseline must separate existing changes from new redesign work.
- Reference images show some features/logos not supported or not approved; copying them would introduce fake scope.
- Smart Inbox is not a dedicated route; making it one would touch routing behavior.
- Reports route/tab mismatch in docs/current code must be verified before nav work.
- Heavy blur/glow can hurt Flutter performance.
- Hardcoded Arabic strings and incomplete l10n can make English/LTR verification fail.
- Shared component changes can ripple across many screens; Phase 2 must be cautious.
- `c.primary` is unsafe as a blind button background in dark mode per existing safety docs.
- Any change to parser/capture/auth/backup can break core product behavior and is forbidden.
