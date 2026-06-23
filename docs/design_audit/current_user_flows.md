# Mali — Current User Flows

> Read-only audit. Steps trace actual code paths (files/widgets named).
> Router: `lib/core/router/app_router.dart`. Session gating: `lib/core/session/app_session.dart`
> (`SessionStatus.{unknown,needsOnboarding,authenticated}`).

---

## Flow 1 — First open / onboarding

**Path:** `/` → redirect → `/onboarding` → `/onboarding/auth` → (`/onboarding/otp`) → `/onboarding/method` → `/` (AppShell).

Steps:
1. `app_router` redirect: `needsOnboarding` + no identity → `/onboarding` (`OnboardingScreen`).
2. User reads value prop, taps "سجّل وابدأ" → `context.go('/onboarding/auth')`.
3. `AuthScreen`: picks Apple / Google / email / guest. On success `AppSession.setIdentity()` fires `refreshListenable`; router redirect sends `needsOnboarding + hasIdentity` → `/onboarding/method`.
4. `OnboardingMethodScreen` auto-opens the **country picker bottom sheet** (postFrame), then user sets **date of birth**, optional **AI consent**, and reads SMS/Shortcut setup. Taps "Got it" (`_ensureSetupReady` requires DOB) → finishes onboarding → `/`.

**Friction points:**
- Country picker auto-opens on a screen already dense with DOB + AI consent + an 8-step iOS guide → cognitive overload at the worst moment.
- DOB is mandatory (`_ensureSetupReady` blocks with a snackbar) but its value to the user is unexplained.
- Email path auto-focuses the field (keyboard jumps up) before the user chooses a method.
- The router redirect timing means post-auth UI must live on the *next* screen — fragile coupling already caused a bug (picker never showed when placed on AuthScreen).

**Opportunities:**
- Split setup into 2–3 light steps (country → DOB(+why) → capture setup) with a progress indicator.
- Make DOB optional or justify it inline ("for age-appropriate insights").
- Defer the iOS Shortcut guide to its own focused step with the verify loop.

---

## Flow 2 — Transaction capture (SMS auto + manual)

**A. Auto (shared SMS / notification):**
1. iOS Shortcut / Android share sends bank SMS → `NativeCaptureBridge` → `AppShell._consumeSharedInput()` on resume.
2. `IngestCapturedMessageUseCase` → `AddTransactionUseCase` → `ParserEngine` (isolate) → optional **AI** (`parse-sms` Edge Function) with grounding check.
3. Disposition: auto-confirm (`notifyOnly`), needs review (`requestConfirmation` → `confirm_transaction_sheet`), or `unprocessable` (snackbar with "إضافة" action → `capture_entry_sheet`).
4. `_refreshAll()` then optional confirm sheet + bank-discovery sheet.

**B. Manual:**
1. Dashboard `_quickHeaderButton` (+) or capture entry → `showCaptureEntrySheet` → choose paste (`manual_paste_screen`) or manual add (`manual_transaction_sheet`).
2. Fill amount/currency/account/category/date → save → `refreshTransactions` + invalidate dashboard.

**Friction points:**
- Auto-capture only drains **on resume** (`AppLifecycleListener.onResume`) — a capture that arrives while the app is foregrounded and idle won't appear live (providers are one-shot `FutureProvider`s, no Drift streams).
- Two separate add surfaces (paste vs manual) chosen via an extra sheet — extra tap.
- AI silently skips when: no consent, sender circuit-broken (3 grounding fails / 10 min), or daily rate-limit hit — user has no visible signal why a message wasn't auto-parsed.

**Opportunities:**
- Make data live (Drift `.watch()` streams or a global revision counter watched by all providers).
- Merge paste + manual into one sheet with a "paste SMS" affordance at top.
- Surface AI status subtly ("couldn't auto-read — add manually") which already exists for `unprocessable` but not for skipped-AI.

---

## Flow 3 — Smart inbox review

1. Pending transactions surface in 3 places: dashboard `_smartInbox` card, Transactions "معلقة" tab, and a notification → `confirm_transaction_sheet`.
2. In the confirm sheet: see amount, change category (`change_category_sheet` 4-col grid), pick account, edit date, "تعديل التفاصيل" (→ manual sheet), then "تأكيد" (`c.cta`).
3. Bulk path: Transactions pending tab shows `AppInsightCard` "مراجعة جماعية" → "تأكيد الكل".

**Friction points:**
- No single "inbox" home — the same concept is split across dashboard, a list tab, and sheets.
- "تعديل التفاصيل" jumps from the confirm sheet to a *different* full edit sheet (context switch, two form designs).
- Category change opens yet another full-height sheet.

**Opportunities:**
- A dedicated Smart Inbox surface (card stack / swipe to confirm / swipe to fix) consolidating all three entry points.
- Inline category + account editing inside the confirm sheet (no nested sheets).

---

## Flow 4 — Transaction categorization

1. Auto: `Categorizer` (merchant→category map + remote keywords) assigns a category; AI may override (`category_key`).
2. Manual correction: row → details sheet → change category, OR confirm sheet → `change_category_sheet` (grid of categories, scope "this only" vs "all of this merchant" via `CategoryCorrectionScope`).
3. Learning: `correctCategoryUseCase` persists a merchant→category mapping for future auto-categorization.

**Friction points:**
- Category grid is a big modal; choosing among ~24 categories with small labels is slow.
- The "apply to all merchant transactions" scope is powerful but easy to miss (radio at the bottom).

**Opportunities:**
- Quick-pick recent/most-used categories at the top of the grid.
- Make the scope choice a clearer, more prominent toggle.

---

## Flow 5 — Dashboard insights

1. Open app → Dashboard. Greeting + streak + account chip row + month/range selector.
2. Read `_financialCard` (balance/spend), `_smartInbox` (if pending), `_analyticsCard` (top categories + daily trend chart), `_recentCard` (last 5).
3. Switch account via chip row OR horizontal swipe (`_handleAccountSwipe`); change period via month arrows / range sheet.
4. "عرض الكل" → Transactions tab; tap a category/txn → details.

**Friction points:**
- The month/range selector packs 5 controls (add txn, add budget, calendar, prev, next, label) into one row — cramped, unclear hierarchy.
- Account swipe gesture is undiscoverable and competes with horizontal scroll.
- Per-currency totals with **no FX** — multi-currency users can't see a combined net worth.

**Opportunities:**
- Separate "primary action" (add) from "time navigation"; move add to a FAB or the bottom bar center.
- Optional converted total (with a clear "approx, FX" label) for multi-account users.
- Make charts interactive (tap a day/category to filter).

---

## Flow 6 — Budget flow

1. Budgets tab → `الميزانيات` sub-tab → metrics (count / used% / total) + budget cards, or empty state.
2. "+" → `budget_form_screen`: category, amount (suffix = account currency), period, account, show-on-header, suggested amount → save.
3. Budget progress drives dashboard header chips (`showOnHeader`) and notifications (80% / over) via `AppShell._syncEngagement`.

**Friction points:**
- Budgets and Goals share a tab but behave differently (sliver vs ListView; different card languages).
- "show on header" is a power feature buried in the form.
- Budget has no own currency — inherits account; account-agnostic budgets fall back to base currency (subtle).

**Opportunities:**
- Split Budgets and Goals into clearer destinations or a cleaner segmented view with shared layout.
- Visual budget health (ring/bar with semantic color via `AppColors.budgetState`).

---

## Flow 7 — Settings / Auth / Backup

1. Settings tab → profile card + grouped `_Section`s.
2. Security → App Lock (`AppLockService`, biometrics) and **Encrypted Backup** (`/backup`): set password / recovery code, back up, restore (`restore_prompt_screen`).
3. Auth management → sign out / delete account (danger zone) → returns to onboarding.
4. Appearance → theme segmented control + language + country pickers.

**Friction points:**
- Single 1700-line screen mixes profile, preferences, and a full category CRUD editor.
- Backup security model (E2E, password never leaves device) is strong but explained only in small text.
- Danger zone has two destructive entries ("start fresh" and "delete account") that both route to `/privacy`.

**Opportunities:**
- Split Settings into Profile / Preferences / Data & Security sub-pages.
- Elevate the trust story (encryption, on-device processing) into a visible security panel.

---

## Flow 8 — iOS Shortcut flow

1. `OnboardingMethodScreen` (iOS) shows `IosShortcutGuide` (8 steps) → or Settings → "إعداد اختصار آبل" (`showIosShortcutSheet`).
2. User builds an Automation in Apple Shortcuts that forwards matching bank SMS (by currency keyword) to Mali.
3. Verify: `ios_shortcut_verify_screen` waits for a test message; `listening_screen` shows "armed".
4. Each captured SMS flows into Flow 2A.

**Friction points:**
- 8 manual steps in another app is the single biggest onboarding drop-off risk; success depends on the user matching keyword filters per currency.
- Multi-currency users must repeat the whole Automation per currency.
- No in-app detection that the shortcut actually works besides the verify screen's passive wait.

**Opportunities:**
- A guided, illustrated, copy-paste-assisted shortcut builder; deep-link to Shortcuts where possible.
- Clear "connected ✓" status surfaced in Settings after the first successful capture.
- Detect and celebrate the first captured SMS (already partly done via `first_transaction_screen`).
