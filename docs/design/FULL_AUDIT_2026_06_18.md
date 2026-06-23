# Mali — Complete UI/UX Audit
**Reviewer:** Lead Product Designer + Senior Flutter Architect (code-only analysis)
**Date:** 2026-06-18
**Branch:** `feat/accounts-multicurrency`
**Method:** Full static analysis of Flutter source. No simulator used.

---

## 1. App Screen Inventory

### Shell Screens (always rendered)

| Screen | File | Route | Purpose | Main Widgets |
|---|---|---|---|---|
| AppShell | `lib/features/app/app_shell.dart` (624 lines) | `/` | Root container. IndexedStack of 4 tabs + floating bottom nav. Listens to CaptureRuntime confirm/nav/bank-discovery streams. | `IndexedStack`, `_FloatingBottomBar`, `AnnouncementBanner`, `_CelebrationBanner` |

### Tab Screens

| Screen | File | Route | Purpose | Main Widgets |
|---|---|---|---|---|
| Dashboard | `lib/features/dashboard/dashboard_screen.dart` (1988 lines) | `/` (tab 0) | Home: greeting, wallet summary, budget, insights, recent txns. | `RefreshIndicator`, `ListView`, `_walletSummary`, `_reviewCard`, `_smartInsightCard`, `_periodSnapshotCard`, `_quickActions`, `CardsCarousel`, `_whereMoneyWent`, `_recent` |
| Transactions | `lib/features/transactions/transactions_screen.dart` (1311 lines) | `/` (tab 1) | Transaction list (date-grouped) + Bills. Search, filter by type, batch confirm. | `SectionHeroHeader`, `_TransactionSearchField`, `_KindFilterChips`, `_BatchConfirmChip`, `_MainSegmented`, `TransactionRow`, `_BillsTab` |
| Budgets | `lib/features/budgets/budgets_screen.dart` (594 lines) | `/budgets` (tab 2) | Budgets + Goals segmented. Progress cards, empty states. | `SectionHeroHeader`, `_PlannerSegmented`, `_BudgetCard`, `_GoalPlannerCard` |
| Settings | `lib/features/settings/settings_screen.dart` (1483 lines) | `/settings` (tab 3) | User profile, preferences, category management, notification settings, data export. Also acts as secondary navigation hub for Reports, Accounts, Achievements, Subscriptions. | `_SettingsHeader`, `_Section`, `_NavTile`, `_SettingsTile`, `_CategoryGrid` |

### Full-Screen Routes (outside tabs)

| Screen | File | Route | Purpose |
|---|---|---|---|
| Reports | `lib/features/reports/reports_screen.dart` | `/reports` | Monthly analytics: overview (donut/bars), trends (anomaly/delta), details (merchant table). 3-tab layout. |
| Accounts | `lib/features/accounts/accounts_screen.dart` | `/accounts` | Multi-currency account list. Add/edit/delete accounts. |
| Subscriptions | `lib/features/subscriptions/subscriptions_screen.dart` | `/subscriptions` | Bills (subscriptions + installments) with auto-detection suggestions. |
| Goals | `lib/features/goals/goals_screen.dart` | `/goals` | Goals list (also appears inside Budgets tab via segmented). |
| Goal Details | `lib/features/goals/goal_details_screen.dart` | `/goals/:id` | Single goal progress, deposit history. |
| Goal Form | `lib/features/goals/goal_form_screen.dart` | `/goals/new` | Create/edit goal. |
| Budget Form | `lib/features/budgets/budget_form_screen.dart` | `/budgets/new`, `/budgets/:id/edit` | Create/edit budget rule. |
| Card Details | `lib/features/cards/card_details_screen.dart` | `/card/:last4` | Per-card transaction history and metrics. |
| Transaction Details | `lib/features/transactions/transaction_details_screen.dart` | `/transaction/:id` | Full transaction view. Also served as modal sheet. |
| Achievements | `lib/features/achievements/achievements_screen.dart` | `/achievements` | XP level, badge grid, streak counter. |
| Backup | `lib/features/backup/backup_screen.dart` | `/backup` | Export/import data. |
| Privacy | `lib/features/settings/privacy_screen.dart` | `/privacy` | Privacy tools, data wipe. |

### Onboarding Routes

| Screen | File | Route | Purpose |
|---|---|---|---|
| Onboarding | `lib/features/onboarding/onboarding_screen.dart` (1063 lines) | `/onboarding` | 4-page welcome flow: Welcome → How It Works → Privacy → Country. |
| Auth | `lib/features/onboarding/auth_screen.dart` | `/onboarding/auth` | Sign in with Google/Apple/Email. |
| OTP | `lib/features/onboarding/otp_screen.dart` | `/onboarding/otp` | Email OTP verification. |
| Method | `lib/features/onboarding/method_screen.dart` | `/onboarding/method` | Choose capture method (iOS Shortcut / manual). Modal slide-up. |
| iOS Shortcut | `lib/features/onboarding/ios_shortcut_screen.dart` | `/onboarding/ios-shortcut` | Setup guide for iOS Shortcut. |
| iOS Verify | `lib/features/onboarding/ios_shortcut_verify_screen.dart` | `/onboarding/ios-verify` | Verify shortcut works. |
| Listening | `lib/features/onboarding/listening_screen.dart` | `/onboarding/listening` | "We're listening" state after setup. |
| First Transaction | `lib/features/onboarding/first_transaction_screen.dart` | `/onboarding/first-transaction` | Celebrate first successfully parsed transaction. |
| Restore Prompt | `lib/features/onboarding/restore_prompt_screen.dart` | `/onboarding/restore`, `/backup/restore` | Prompt to restore from backup. |

### Capture/Input Screens

| Screen | File | Route | Purpose |
|---|---|---|---|
| Manual Paste | `lib/features/capture/manual_paste_screen.dart` | `/paste` | Paste raw SMS text for parsing. |
| SMS Permission | `lib/features/capture/sms_permission_screen.dart` | `/capture/sms-permission` | Android SMS permission request. |
| Capture Entry Sheet | `lib/features/capture/capture_entry_sheet.dart` | (modal) | 3-option picker: manual entry, paste SMS, share from messages. |

### Hidden / Dev Screens

| Screen | File | Route | Purpose |
|---|---|---|---|
| Foundation Home | `lib/features/foundation/foundation_home_screen.dart` | (no route in production router) | Dev/QA parser test interface. Not accessible in production. |

### Sheets / Modals (not full screens)

- `ManualTransactionSheet` — add/edit transaction
- `ConfirmTransactionSheet` — AI-triggered review approval
- `BankDiscoveryConfirmationSheet` — new bank detected
- `ChangeCategorySheet` — reassign category
- `BillFormSheet` — add/edit bill/subscription
- `CaptureEntrySheet` — capture method picker

**Total production screens: 28 (routes) + 6 modal sheets**

---

## 2. Navigation Audit

### Current Navigation Map

```
AppShell (IndexedStack)
│
├── Tab 0: Dashboard (/)
│   ├── → /reports (smart insight tap)
│   ├── → /goals/:id (goal card tap)
│   ├── → /achievements (streak badge tap)
│   └── → /card/:last4 (cards carousel tap)
│
├── Tab 1: Transactions
│   ├── → TransactionDetailsScreen (sheet)
│   └── [Bills sub-tab]
│
├── Tab 2: Budgets (/budgets)
│   ├── Segmented: Budgets | Goals
│   ├── → /budgets/new, /budgets/:id/edit
│   └── → /goals/:id (goal card tap)
│
└── Tab 3: Settings (/settings)
    ├── → /accounts
    ├── → /reports  ← DUPLICATE (also reachable from tab 0)
    ├── → /achievements  ← DUPLICATE (also reachable from tab 0)
    ├── → /subscriptions
    ├── → /privacy
    ├── → /backup
    └── → /onboarding/method (add capture method)

Floating: Center Add Button → CaptureEntrySheet (modal)

Standalone routes (no tab owns them):
  /reports, /accounts, /subscriptions, /achievements, /goals
  → All opened via push(). Back button returns to caller.
  → /profile is an alias for /settings (identical widget!)
```

### Problems

**P1 — Reports has no tab. Severity: Critical.**
Reports is one of the three core product features but lives exclusively behind:
- Settings > "الرؤى والتقارير"
- Smart insight card tap on Dashboard

A user who doesn't tap the smart insight card will never naturally find Reports. It is the second-most important screen in a fintech app and has no first-class placement.

**P2 — Settings acts as a secondary navigation hub. Severity: High.**
The Settings tab links to: Reports, Accounts, Achievements, and Subscriptions. These are product features, not preference links. A user trying to manage subscriptions must first navigate into Settings — the wrong mental model. Every major fintech (Revolut, Copilot, Monarch) keeps subscriptions and accounts as first-class, not buried under settings.

**P3 — `/profile` route is an alias for `/settings`. Severity: Medium.**
```dart
// app_router.dart:250–252
GoRoute(
  path: '/profile',
  builder: (context, state) => const SettingsScreen(), // identical to /settings
),
```
This means navigating to `/profile` and `/settings` renders the same screen. Any internal link to `/profile` adds confusion. The route adds zero UX value and is dead weight.

**P4 — Subscriptions has no tab. Severity: High.**
Subscriptions/bills are a key retention feature. They currently live exclusively at `/subscriptions`, reachable only from Settings. Users who pay recurring bills monthly will not build a habit if they must dig into Settings to find it.

**P5 — Goals and Budgets share one tab with a segmented control. Severity: Medium.**
These are distinct concepts (spending limits vs. savings targets). Combining them under `AppLucideIcons.wallet` with label "الميزانيات" creates confusion. The wallet icon suggests "accounts" not "budgets". Additionally, `/goals` exists as a full route but is only reachable via the segmented tab — there is no way to deep-link to the Goals list outside the Budgets tab context.

**P6 — Hardcoded `TextDirection.rtl` in bottom nav row. Severity: Low.**
```dart
// app_shell.dart:475
child: Row(textDirection: TextDirection.rtl, children: [...]),
```
This locks the nav bar order to Arabic layout. If the app ever supports English (LTR), the nav bar order will remain Arabic-RTL regardless of locale. Should use `Directionality.of(context)`.

### Recommended Navigation Map

```
AppShell (IndexedStack — 5 tabs)
│
├── Tab 0: الرئيسية (Home — house icon)
│   Reduced dashboard: hero card + pending review + top 3 categories + recent 5 txns
│
├── Tab 1: العمليات (Activity — receipt icon)
│   Transactions list with search. Bills moved here as sub-tab.
│
├── [Center +] Add Transaction (FAB — kept as-is)
│
├── Tab 2: الميزانية (Plan — target icon)
│   Budgets only. Goals moved to a sub-tab or /goals full screen.
│
├── Tab 3: الرؤى (Reports — chart icon)
│   Current /reports screen promoted to first-class tab.
│
└── Tab 4: الإعدادات (Settings — gear/person icon)
    Clean settings: profile, security, preferences, data, about.
    Remove feature navigation links (Reports, Achievements, Subscriptions).

Subscriptions: accessible from Activity tab's Bills sub-tab.
Accounts: accessible from home hero card "إدارة الحسابات" shortcut.
Achievements: accessible from dashboard streak badge (modal, not full push).
```

---

## 3. Design System Audit

### 3.1 Colors

**File:** `lib/core/theme/app_colors.dart`

| Token | Dark Value | Light Value | Issue |
|---|---|---|---|
| `bg` | `#000000` | `#F2F7FB` | Correct. True black for dark — intentional premium choice. |
| `surface` | `#0E0E0E` | `#FFFFFF` | Correct. |
| `surface2` | `#1A1A1A` | `#E3EEF5` | Correct. |
| `primary` | `#FFFFFF` | `#056A95` | **Problem:** In dark mode `primary` = white = same as `textMain`. Semantically broken. Used as icon color, button bg, progress fill, chip border — all white, indistinguishable from text. |
| `accent` | `#7CB1C8` | `#4F8AA6` | **Problem:** Too muted/desaturated for a primary CTA color. Used as selected nav icon, pending chip border, center add button fill. At 44% saturation it has low visual salience. Compare: Revolut electric indigo, Nubank vivid purple. |
| `textMain` | `#FFFFFF` | `#0E2230` | Dark = same as `primary`. See above. |
| `textLight` | `#8A8A8A` | `#5C7484` | Contrast on bg: ~4.9:1 (dark) — barely passes AA. On surface2 (#1A1A1A): ~4.1:1 — fails AA for 12px text. |
| `gradA` | `#1A1A1A` | `#0789BB` | Dark: `#1A1A1A` → `#000000` = invisible gradient. These are legacy tokens kept for backward compat. `comment: "Kept for backward compatibility"`. |
| `gradB` | `#000000` | `#034F73` | Same issue. `primaryGradient` is useless in dark mode. |
| `border` | `#2A2A2A` | `#D5E2EB` | Correct. |
| `success/warning/danger` | `#2BC79A / #D89C5A / #FF6B73` | `#14946E / #C57F2C / #D4493D` | All correct — good semantic colors. |

**Missing tokens:**
- No `onPrimary` (color to use ON a primary-colored surface)
- No `onAccent` (color to use ON an accent-colored surface)
- No `AppGradients` constant — hero gradient repeated in 3+ files with raw hex

**Hardcoded colors outside AppColors:**

| File | Value | Context | Problem |
|---|---|---|---|
| `dashboard_screen.dart:102` | `Color(0xFF046E9B)`, `Color(0xFF034E73)`, `Color(0xFF012438)` | Hero header gradient | Not in AppColors. Won't adapt to theme changes. |
| `dashboard_screen.dart:529` | `Color(0xFF011C2B)`, `Color(0xFF023A57)` | Wallet summary card inner gradient | Not in AppColors. |
| `section_hero_header.dart:33` | Same 3 hero colors | All non-dashboard screens | Shared component, same issue — centralization needed. |
| `app_shell.dart:457` | `Color(0xFF1C1C1E)` | Bottom nav bar dark background | Should be `c.surface` or `c.surface2`. |
| `app.dart:326–393` | Multiple hex values | Splash logo lines | Acceptable (brand marks). |

**Contrast failures (dark mode, WCAG AA):**
- `textLight` (#8A8A8A) on `surface2` (#1A1A1A): 4.1:1 — fails for 12px text (requires 4.5:1)
- `accent` (#7CB1C8) on dashboard header (#034E73): 2.1:1 — fails (3:1 minimum for UI components)
- Selected account chip text on gradient header: inaccessible

### 3.2 Typography

**File:** `lib/core/theme/app_typography.dart`

| Style | Size | Weight | Issue |
|---|---|---|---|
| `amountHero` | 40px | w800 | Correct. |
| `display` | 32px | w800 | **Defined but never used in production code.** Dead style. |
| `title1` | 24px | w700 | Correct. |
| `title2` | 20px | w600 | Correct. |
| `headline` | 18px | w600 | Only 2px different from title2. Marginal distinction. |
| `body` | 16px | w400 | Correct. |
| `bodyStrong` | 16px | w600 | Correct. |
| `callout` | 15px | w400 | Non-standard size. Not in iOS HIG or Material type scale. |
| `subhead` | 14px | w600 | Correct. |
| `footnote` | 13px | w400 | Correct. |
| `caption` | 12px | **w600** | **Critical problem.** Caption is BOLDER than body (w400). Captions should label secondary info (dates, categories). w600 at 12px visually competes with body text. Destroys visual hierarchy. Every fintech benchmark uses w400 or w500 for captions. |

**Missing styles:**
- `amountMedium` (24–28px, w700, tabular) — needed for card-level secondary amounts. Currently code falls back to `title2` for amounts, losing the tabular figures feature.
- `amountSmall` (18–20px, w600, tabular) — needed for inline amounts in lists.

**Font naming bug:**
```dart
// onboarding_screen.dart:18–33
TextStyle _alex(double size, FontWeight weight, ...) {
  return GoogleFonts.inter(  // Named _alex but calls inter — dead rename
```
`_alex` was the Alexandria font helper. The font was swapped to Inter but the function name was never updated. Creates confusion for future maintainers.

**Dialect issues in copy:**
- `'مساء الخير'` is used for BOTH hour 12–18 AND hour 18+. Evening should be `'مساء النور'`.
- Mix of Egyptian dialect (`'هيظهر هنا'`, `'هنعرض'`) and Gulf MSA (`'أكثر أماكن صرفك'`) in the same screen.
- Reports `_money()` hardcodes `ر` (Saudi Riyal symbol) regardless of user currency setting:
  ```dart
  // reports_screen.dart:115 — always SAR, ignores multi-currency
  return privacyMode ? '•••• ر' : '${Formatters.amount(amount)} ر';
  ```

### 3.3 Spacing

**File:** `lib/core/theme/app_spacing.dart`

The 4pt scale (s1–s10) is solid and largely followed. Issues:

- `padding: const EdgeInsets.only(bottom: 120)` — hardcoded 120px bottom padding in multiple screens (dashboard, transactions, budgets). Not derived from nav bar height. The nav bar is 64 + 8 + safe area ≈ 96–100px. 120 is an over-approximation that wastes screen space.
- `padding: const EdgeInsets.only(left: 8)` — directional padding in `dashboard_screen.dart:1961`. Should be `EdgeInsetsDirectional.only(start: 8)`.

### 3.4 Border Radius

**File:** `lib/core/theme/app_spacing.dart` defines: `sm=8, md=16, lg=18, card=24, cardLg=32, pill=999`

**Problem:** `lg = 18` is too close to `md = 16`. This creates two tokens with 2px difference — designers cannot meaningfully distinguish them, and developers pick randomly between them.

**Audit of hardcoded `BorderRadius.circular()` calls:**

Spot-checked violations (38+ files total):
```
TransactionRow widget:         BorderRadius.circular(16)  ← should be AppRadius.md
_reviewCard (dashboard):       BorderRadius.circular(16)  ← should be AppRadius.md
capture_entry_sheet.dart:      BorderRadius.circular(16)  ← AppRadius.md
sms_permission_screen.dart:    BorderRadius.circular(16)  ← AppRadius.md
manual_paste_screen.dart:      BorderRadius.circular(16) × 5 ← AppRadius.md
goal_form_screen.dart:         BorderRadius.circular(16) × 9 ← AppRadius.md
goal_details_screen.dart:      BorderRadius.circular(16) × 5 ← AppRadius.md
app_shell.dart:                BorderRadius.circular(32)  ← should be AppRadius.cardLg
settings_screen.dart:          BorderRadius.circular(16) × 4 ← mixed with AppRadius.card usages
```

The token system exists but is not consistently enforced. Approximately 40% of radius values in feature code are inline literals, not token references.

### 3.5 Shadows

**No `AppShadows` token file exists.** Every shadow is an inline `BoxShadow(...)` definition:
```dart
// dashboard_screen.dart:112 — one of ~15 inline shadow definitions
BoxShadow(
  color: const Color(0xFF034F73).withValues(alpha: 0.25),
  blurRadius: 26,
  offset: const Offset(0, 14),
),
```
Different screens use different blur radii (10, 14, 18, 26, 30) and different offsets (4, 8, 10, 14) with no system. The card elevation hierarchy is inconsistent — some components feel floating while adjacent ones feel flat.

### 3.6 Icons

**`lib/core/utils/app_lucide_icons.dart`** provides a centralized `AppLucideIcons` enum using `LucideIcons`. This is the correct pattern.

**Problem:** `settings_screen.dart` uses `Icons.` (Material Icons) for 15+ tiles while the rest of the app uses `AppLucideIcons`. This creates visible icon style inconsistency — Material Icons have a different stroke weight, fill style, and geometry than Lucide Icons.

```dart
// settings_screen.dart — Material Icons mixed with Lucide
icon: Icons.account_balance_wallet_outlined,  // Material
icon: Icons.bar_chart_outlined,               // Material
icon: AppLucideIcons.inbox,                   // Lucide — inconsistent
icon: Icons.language_outlined,               // Material
icon: AppLucideIcons.moon,                   // Lucide — inconsistent
```

### 3.7 TabBar Pattern Inconsistency

Two different TabBar implementations co-exist:

**Reports screen** (`reports_screen.dart:74–76`):
```dart
labelColor: Colors.white,  // hardcoded — white on white in dark mode (white indicator)
indicator: BoxDecoration(color: c.primary, ...)  // c.primary = white in dark mode
```
This renders selected tab text as white ON a white indicator — completely illegible in dark mode.

**Subscriptions screen** (`subscriptions_screen.dart:76–85`):
```dart
labelColor: brightness == dark ? c.accent : Colors.white,  // conditional — correct pattern
indicator: BoxDecoration(
  color: brightness == dark ? c.accent.withValues(alpha: 0.22) : c.primary,
)  // correct pattern
```

The subscriptions screen got it right; the reports screen did not. Both should use the same conditional pattern.

### 3.8 Buttons

- `FilledButton`: Used for primary CTA (dashboard range sheet, onboarding)
- `ElevatedButton.icon`: Used for secondary actions
- `InkWell` + `Container`: Used for custom interactive tiles (account chips, quick actions, nav tiles)
- `GestureDetector` + `Container`: Used for bottom nav items and center add button

No unified `AppButton` component. Button tap area sizes:
- Center add button: 48×48 — borderline (minimum 44pt)
- Pending filter chip close (×): `Icon(Icons.close, size: 14)` — 14px icon, no padding — **well below 44pt minimum**
- AI badge: `Icon` at 9px font — not tappable but still tiny

---

## 4. Page-by-Page UI/UX Audit

### 4.1 Splash Screen (`lib/app.dart`)

**What works:** Sophisticated logo assembly animation — staggered line draws, letter-spacing tween, breathing progress bar, ambient liquid background. One of the best splash screens in the codebase.

**What is weak:** The logo sits in the middle third with empty dark space above and below. The animated progress bar ("جاري التحميل...") uses `AppTypography.footnote` — very small and hard to read.

**What feels premium:** The easeOutExpo curves and the ambientCanvas liquid drift feel genuinely high-end.

**What feels outdated:** The word "مالي" below the logo is in a standard Inter weight. Could be heavier (w800) to match the hero impact.

**RTL:** Not applicable (logo only).

**Missing states:** No offline/error state during splash. If Supabase fails to connect, the splash just hangs.

---

### 4.2 Onboarding (`lib/features/onboarding/onboarding_screen.dart`, 1063 lines)

**What works:**
- 4-page flow is reasonable for the product's complexity
- `PremiumBackground` gives a consistent branded feel
- Country picker with flag emojis is clean
- Progress dots at top give orientation

**What is weak:**
- 1063 lines in one file — the 4 page classes, the bottom bar, the top frame, and page content are all in one monolith
- `_alex()` function is named after Alexandria font but calls `GoogleFonts.inter()` — stale dead code
- No skip button after page 1 — users who understand the product can't fast-forward
- Page 3 "Privacy" has text-heavy content that reads as a disclaimer, not as a selling point
- Country selection on page 4 is required — but the user hasn't created an account yet. First-time users who abandon before auth lose this preference.

**What is confusing:**
- Page order: Welcome → How It Works → Privacy → Country. The Privacy page (page 3) breaks flow. The user's mental journey is: understand → trust → set up. Privacy should come BEFORE the value proposition, not interrupt it.
- "التالي" (Next) CTA has identical styling across all 4 pages, but on page 4 it triggers a backend call. No loading indicator.

**Visual hierarchy:** Solid — large bold headline, smaller body text, clear CTA.

**RTL:** `Directionality.of(context)` is used correctly — good.

**Missing states:** No loading state when country save fails.

---

### 4.3 Dashboard (`lib/features/dashboard/dashboard_screen.dart`, 1988 lines)

**What works:**
- Hero header gradient is visually striking and brand-consistent
- `AnimatedAmountText` counter-up animation is premium
- Privacy mode (`••••`) integration throughout
- Swipe-to-switch-account gesture is discoverable
- `PremiumMotion` staggered reveal on load
- `_reviewCard` (pending transactions alert) has the right priority placement — directly below the hero

**What is visually weak:**
- The hero has two items that share equal weight: "المصروف" and "الدخل". Neither dominates. Users cannot answer the question "am I doing well this month?" with a single glance.
- The wallet summary card (`_walletSummary`) contains 6 nested sub-elements: date picker chip, spend/income row, budget pill, balance/saved glass pills, budget swiper (PageView), sparkline. This is 6 distinct UI patterns on one card — extreme density.
- The `_periodSnapshotCard` shows today's spend/income AND week spend/income — 4 numbers. These largely duplicate the wallet summary's spend/income but for shorter windows. Redundant.
- `_quickActions` row: 3 equal-weight tiles for "ألصق رسالة", "ميزانية", "هدف". The primary action (paste message) should visually dominate.
- The 12 sections create a scroll journey of ~3,000px. The bottom sections (category donut, subscriptions preview, recent transactions) are never seen in normal usage.

**What is confusing:**
- `AlertTriangle` icon on the `_smartInsightCard` when spending is UP. AlertTriangle signals error/danger, not just "higher spending." Users may feel alarmed rather than nudged.
- The `_reviewCard` and `_smartInsightCard` use similar card styles (surface bg, border) but one is actionable (tap → review queue) while the other is informational (tap → reports). The tap affordances are not differentiated.
- The budget pill inside `_walletSummary` shows "استخدمت X% من ميزانية Y". But if no budget is set it reads "اضغط لضبط ميزانية كل المصروفات" — a CTA inside an informational summary card. Mixing states.

**Visual hierarchy issues:**
- 12 sections with no visual separator or "fold" concept. Everything is presented with equal visual weight.
- Section count: Header (1) → Currency Totals (conditional) → Goal Card (conditional) → Pending Review → Smart Insight → Period Snapshot → Quick Actions → Cards Carousel → Subscriptions Preview → Category Chart → Recent Transactions = 9–11 items.

**Spacing/alignment:**
- `padding: const EdgeInsets.only(bottom: 120)` — hardcoded, not derived from nav bar height
- `const EdgeInsets.only(left: 8)` at line 1961 — RTL risk

**Color/contrast:**
- Dashboard header gradient: 3 hex colors not in `AppColors`
- Wallet summary card inner gradient: 2 more hex colors not in `AppColors`
- `accent` (#7CB1C8) on gradient header: WCAG fail (2.1:1)

**Arabic copy issues:**
- `hour < 18 ? 'مساء الخير' : 'مساء الخير'` — both branches identical; evening greeting is wrong
- `'هنعرض لك اتجاه الصرف'` — Egyptian dialect; inconsistent with Gulf MSA elsewhere
- `'استمر بنفس الهدوء'` — colloquial; not consistent with formal financial tone

**Recommended Home structure (max 5 sections):**
1. Hero card — single primary number (net spend = spent − income), secondary line (split), budget bar, account switcher
2. Pending review — only if count > 0
3. Top 3 categories — mini donut + bar list
4. Recent transactions — last 5
5. Quick actions row — paste SMS as primary, budget/goal as secondary

Everything else (smart insight, period snapshot, sparkline, cards carousel, subscriptions preview, full category chart) → Reports tab.

---

### 4.4 Transactions (`lib/features/transactions/transactions_screen.dart`, 1311 lines)

**What works:**
- Search field (`_TransactionSearchField`) exists and is functional — good
- Date range chips with preset options are clean
- Date-grouped list with `_DateHeader` labels is standard and clear
- `_BatchConfirmChip` for bulk confirming pending items is a great UX feature
- `SectionHeroHeader` with metrics (count, pending, total) provides solid context

**What is visually weak:**
- `SectionHeroHeader` subtitle: `'${view.range.label} · كل التفاصيل تفتح من أسفل الشاشة.'` — the second clause ("details open from bottom") is instructional copy that belongs in onboarding, not a persistent header subtitle. After the first use, this text is noise.
- The segmented control (`_MainSegmented`) between Transactions and Bills is hidden at the top of the scroll content area. Users must scroll past the date range chips to see it.
- The `_EmptyState` for no transactions is basic — just an icon and two lines. The empty state for the full empty app is excellent (`_emptyState` in dashboard); the transaction-level empty state does not match that quality.

**What is confusing:**
- Mixing **transactions** (bank activity history) and **bills** (recurring payments) in one screen under one segmented tab is conceptually awkward. A transaction is historical; a bill is a future obligation. They belong in different mental models.
- The pending filter chip has a close button (×) with `Icon(Icons.close, size: 14)` — 14px tappable icon, no padding. This is below minimum tap target size.

**RTL:**
- `padding: const EdgeInsets.only(bottom: AppSpacing.s3)` at line 76 — bottom-only, no RTL impact
- Kind filter chips use `ChoiceChip` which respects text direction — correct

**Missing states:**
- No empty state for "no results found" in search (search exists, but no empty result state visible in the code)
- No error state for individual transaction load failure

---

### 4.5 Transaction Details (`lib/features/transactions/transaction_details_screen.dart`)

**What works:**
- The modal sheet with `BackdropFilter` blur is premium and consistent with iOS feel
- Drag handle at top correctly sized (40×4.5px)
- Hero avatar (78px `CategoryAvatar`) centered with amount below — clear visual hierarchy
- Close + Edit buttons in a header row — good structure
- Pending confirmation card at the bottom — correct placement for primary action

**What is weak:**
- The sheet title "تفاصيل العملية" centered between close and edit buttons is fine — but `textAlign: TextAlign.center` is hardcoded. Should use `TextAlign.start` per Arabic convention.
- `Icons.close` and `Icons.edit_outlined` — Material Icons in a Lucide-icon app
- The pending status indicator inside the transaction row uses `c.textLight.withValues(alpha: 0.1)` for the badge background — near invisible. The most important status indicator in the app uses the least contrast of any badge.
- AI badge text size: `fontSize: 9.0` — below 11px minimum readable size

**Missing states:**
- No skeleton/loading state — shows `CircularProgressIndicator` (inconsistent with `PremiumSkeletonPage` used everywhere else)

---

### 4.6 Reports (`lib/features/reports/reports_screen.dart`)

**What works:**
- 3-tab structure (Overview / Trends / Details) is a reasonable decomposition
- `SectionHeroHeader` with 3 key metrics (total, daily avg, highest day) gives quick context
- Anomaly detection card in Trends tab is a good insight feature
- Category donut + bar list in Overview tab is visually clear

**What is broken:**

**Critical:** Tab indicator in dark mode renders white text on white background:
```dart
// reports_screen.dart:74–76
labelColor: Colors.white,      // always white, regardless of indicator color
indicator: BoxDecoration(color: c.primary, ...),  // c.primary = white in dark mode
```
Selected tab = white text (#FFFFFF) on white indicator (#FFFFFF) = completely invisible.

**What is weak:**
- `_money()` function hardcodes `ر` (SAR) regardless of user's currency:
  ```dart
  return privacyMode ? '•••• ر' : '${Formatters.amount(amount)} ر';
  ```
  If the user's account is in AED, EGP, or any other currency, Reports shows `ر` — factually wrong.
- No date range control on the Reports screen itself. Reports uses the same `transactionsDateRangeProvider` as the Transactions tab — the period shown in Reports is controlled by a picker on the Transactions tab, not the Reports screen. Users have no way to change the period while in Reports without leaving.
- `CategoryDonutChart` has no tap handler — tapping a slice does nothing. Every fintech competitor (Copilot, Monarch, Revolut) allows tapping a category to see filtered transactions.
- Reports accessible from Settings, from Dashboard smart insight, but NOT as a tab. Discovoverability is poor.

**RTL:** Good — no directional hardcodes found.

---

### 4.7 Budgets (`lib/features/budgets/budgets_screen.dart`)

**What works:**
- The segmented tabs (Budgets | Goals) and their respective headers are clean
- `_BudgetCard` shows name, progress bar, amount remaining — clear structure
- Empty state cards for both budgets and goals are simple and actionable

**What is weak:**
- Budget and Goals share one screen tab. They are conceptually different (spending limit vs. savings target) but crammed together.
- `SectionHeroHeader` for budgets shows: number of budgets, % used ratio, total limit. The "% used ratio" is aggregate across all budgets — misleading when individual budgets have very different amounts.
- `const SizedBox(height: 120)` at bottom — hardcoded, same issue as dashboard.
- `_PlannerSegmented` implements its own styled segmented control, duplicating logic also in `reports_screen.dart` and `subscriptions_screen.dart`. Three different implementations of the same pill segmented pattern.

**Missing states:**
- No empty state for "no transactions this period" within a specific budget card
- No state for a budget that has expired (past month budget shown in current month view)

---

### 4.8 Goals Screen (`lib/features/goals/goals_screen.dart`)

**What works:**
- Goal cards with progress rings and remaining amounts are clean
- Vault widget is premium and unique

**What is weak:**
- Goals only accessible via Budgets tab segmented switch OR via `/goals` direct route. No way to navigate directly to Goals without going through Budgets. Confusing mental model.
- Goal card shows "متبقي X ريال" — hardcoded "ريال" regardless of goal currency.
- `GoalDetailsScreen` and `GoalFormScreen` both use `BorderRadius.circular(16)` extensively — inconsistent with AppRadius tokens.

---

### 4.9 Subscriptions (`lib/features/subscriptions/subscriptions_screen.dart`)

**What works:**
- The `_BillsHeader` with monthly total and counts is useful at a glance
- Auto-detected subscription suggestions with brand marks is a smart feature
- Two tabs (Subscriptions | Installments) makes sense — these are genuinely different

**What is weak:**
- Subscriptions are buried in Settings. Users with active bills will not naturally navigate there.
- TabBar in subscriptions screen: In dark mode uses `c.accent` as selected label color AND `c.accent.withValues(0.22)` as indicator background. An accent-on-accent-tinted-bg pattern. Readable but inconsistent with Reports tab pattern.
- `SizedBox(height: _tabHeight(subs, insts, suggestions))` — `_tabHeight` is a calculated height function for the TabBarView inside a ListView. This pattern prevents natural scroll behavior. The tab view has a fixed calculated height that may be wrong for long lists.

---

### 4.10 Settings (`lib/features/settings/settings_screen.dart`, 1483 lines)

**What works:**
- Organized into clearly labeled sections
- Category grid with color swatches is visually distinct

**What is broken:**
- 1483 lines in one file — unmaintainable
- Mixes Material Icons (`Icons.bar_chart_outlined`, `Icons.language_outlined`) with Lucide Icons (`AppLucideIcons.inbox`, `AppLucideIcons.moon`) — 15+ Material Icons used
- Acts as a secondary navigation hub (see Navigation Audit §2)
- `/profile` route maps to `SettingsScreen` — duplicate with no distinction

**What is confusing:**
- "الملف الشخصي والتحليل" section contains: Accounts, Reports, Achievements, Subscriptions, iOS Shortcut. These are not profile items — they are feature screens. The section title is wrong.
- Notification preferences section mixes `AppLucideIcons.inbox` with multiple `Icons.*` — visual inconsistency within one screen.

**RTL:** Mostly fine. `_SettingsTile` and `_NavTile` use `ListTile` which handles RTL correctly.

---

### 4.11 Achievements (`lib/features/achievements/achievements_screen.dart`)

**What works:**
- XP progress bar is clear
- Locked/unlocked badge states are visually distinct
- Streak counter placement at top is correct

**What is weak:**
- Only reachable via: Dashboard greeting badge tap OR `/achievements` push from Settings. No tab. No badge count in bottom nav.
- Badge grid uses `BorderRadius.circular(AppRadius.card)` — correct, consistent.
- Screen uses `SectionHeroHeader` correctly with achievement metrics.

---

### 4.12 Onboarding Sub-Screens

**ListeningScreen / IosShortcutScreen / IosShortcutVerifyScreen / FirstTransactionScreen:**
These screens have not been fully analyzed but share the `SectionHeroHeader` pattern. The iOS Shortcut flow (3 screens) for a feature that many Android users will never use is a significant complexity investment. Consider moving this entirely to Settings > "إعداد اختصار آبل" post-onboarding.

---

## 5. Dashboard-Specific Audit

### Sections Currently Shown

| # | Section | Lines | Conditional? | Data Dependency |
|---|---|---|---|---|
| 1 | Hero header (gradient) | ~100 | Always | accounts |
| 2 | Greeting + account switcher | ~50 | Always | — |
| 3 | Wallet summary card | ~200 | Always | spend, income, budget, trend |
| 4 | Currency totals card | ~40 | Only if multi-currency | currencies |
| 5 | Active goal card | ~60 | Only if goal exists | goals |
| 6 | Pending review card | ~70 | Only if pending > 0 | pendingReviewCount |
| 7 | Smart insight card | ~70 | Only if !isEmpty | weekChangeRatio |
| 8 | Period snapshot card | ~110 | Only if !isEmpty | today/week spend, income |
| 9 | Quick actions row | ~40 | Only if !isEmpty | — |
| 10 | Cards carousel | ~20 | Always | cards |
| 11 | Subscriptions preview | ~80 | Only if subs exist | subscriptions |
| 12 | Category chart (donut + bars) | ~80 | Only if !isEmpty | categories |
| 13 | Recent transactions | ~80 | Only if !isEmpty | recent |

**Maximum sections visible simultaneously:** 13
**Minimum sections (empty state):** 3 (hero, empty state card, quick actions implied)

### Cognitive Load Assessment

**Score: Extreme.** A user with data sees 10–13 sections. There is no visual fold, no "above the fold" concept. Critical features (pending review) compete with informational widgets (period snapshot) which compete with gamification (cards carousel) at the same visual weight.

### Primary Metric Clarity

**Score: Poor.** Two equal-weight metrics ("المصروف" / "الدخل") share the hero row. Neither dominates. The user cannot form a single-glance assessment. Compare: Revolut shows account balance in `amountHero`. Apple Wallet shows balance centered at 48px. Copilot shows net spending as the primary number.

### Primary CTA Clarity

**Score: Poor.** The primary CTA (add a transaction via the center + button) has no label, no explanation, and is visually equal to a nav tab. New users may not know it exists. Once the empty state disappears (after first transaction), there is no persistent call-to-action guiding the user to add more.

### Smart Inbox / Pending Review Visibility

**Score: Good.** The `_reviewCard` IS present on the dashboard — this is correct. But it only appears if `pendingReviewCount > 0`, so a new user who has not parsed any transactions never sees this affordance.

### AI Review Visibility

**Score: Medium.** The `_reviewCard` subtitle correctly identifies AI-parsed transactions: `'$aiCount منها بالذكاء الاصطناعي.'` But this is buried in a caption under the review count. The AI identity is underplayed.

### Budget Visibility

**Score: Poor.** The budget status is embedded inside the 6-element wallet summary card, 3 elements deep. Users who don't expand the wallet summary (mentally) never "see" the budget.

### Recommended Final Home Structure (5 sections max)

```
1. [Hero Card]
   - Account switcher chips
   - Net spend (amountHero, single primary number)
   - Secondary row: income (+) / expenses (−) split
   - Budget progress bar (if set) or "Set budget" CTA
   - Period range chip

2. [Pending Review] (conditional — only if pendingCount > 0)
   - "X عملية تحتاج مراجعتك" + AI count badge
   - Tap → transactions tab with pending filter

3. [Top Categories] (conditional — if data exists)
   - Mini donut (3 slices) + 3 bar rows
   - "اقرأ المزيد" tap → Reports

4. [Recent Transactions] (5 items max)
   - TransactionRow × 5
   - "كل العمليات" tap → Transactions tab

5. [Quick Actions]
   - "ألصق رسالة" (primary, wider)
   - "ميزانية" | "هدف" (secondary, equal width)
```

Everything else moves to Reports, Budgets, or Settings.

---

## 6. AI Financial Assistant UX Audit

### Is AI Visible Enough?

**Score: 3/10 — Mostly hidden.**

The app is described as an "AI Financial Assistant" but the only visible AI indicators are:
- A tiny `AI` badge (9px font) on transaction rows
- One sentence in the review card subtitle: `'$aiCount منها بالذكاء الاصطناعي.'`
- The `ai_parser_client.dart` and `add_transaction_usecase.dart` do significant AI work but none of this is surfaced to the user

### Is Smart Inbox First-Class?

**Score: 4/10.**

The pending review card IS on the dashboard — that is correct. But:
- It only appears when transactions are pending (a new user sees nothing)
- It lacks a name — "Smart Inbox" or "صندوق المراجعة الذكية" is never shown. It's called "X عملية تحتاج مراجعة"
- The icon is `AlertTriangle` (danger!) not an AI or inbox icon
- The tap takes the user to the Transactions tab with a filter applied — not a dedicated inbox screen

### Is Transaction Confidence Visible?

**Score: 1/10 — Not visible at all.**

`parseConfidence` is stored on every transaction (0.0–1.0). This is a rich signal — the app knows how confident it is about each parse. Yet this is never shown to the user. No confidence bar, no percentage, no "I'm 93% sure this was a restaurant" indicator. The AI work is completely invisible.

### Is Review/Approval Flow Fast Enough?

**Score: 6/10.**

The confirm flow: tap review card → transactions tab opens with pending filter → tap transaction row → bottom sheet opens → find confirm button → tap confirm = 4 taps. Copilot Money achieves this in 1 gesture (swipe right). The infrastructure for instant confirmation exists (`CaptureRuntime.confirmRequests` stream, `ConfirmTransactionSheet`), but it requires notification-triggered open — not accessible from the UI.

### Are AI Insights Useful or Hidden?

**Score: 5/10.**

The smart insight card is present and shows week-over-week comparison with a percentage. This is useful. But:
- It uses `AlertTriangle` for spending UP and `medal` for spending DOWN — wrong semantic
- It navigates to `/reports` on tap — correct destination
- The anomaly detection in Reports Trends tab is a good feature, almost invisible (3 taps from dashboard)

### Does the App Feel Like an Assistant or a Spreadsheet?

**Score: 4/10 — Currently closer to spreadsheet.**

An assistant proactively tells you things. The app's AI work is reactive (user adds transaction → AI categorizes → awaits confirmation). The "smart insight" card is the only proactive element, and it's one of 12 dashboard sections with no visual priority.

**What Would Make the AI Identity Stronger:**
1. Name the AI feature. "مالي يراقب صرفك" or "مساعدك المالي الذكي" as a persistent identity.
2. Show confidence on pending transactions: a small confidence bar or percentage in the `TransactionRow` pending state.
3. Give the pending review card a dedicated name and style: "صندوق الذكاء الاصطناعي" with a spark/AI icon, not `AlertTriangle`.
4. Add a brief explanation when AI categorizes: "مالي صنّف هذه العملية كمطعم بثقة 88%، هل هذا صحيح؟"
5. Show AI action history: how many transactions AI parsed this month, with what accuracy.

---

## 7. Arabic RTL & Copy Audit

### RTL Layout Correctness

Overall RTL handling is good. The app uses:
- `Directionality(textDirection: TextDirection.rtl)` in all modal sheets
- `TextDirection.rtl` in the bottom nav `Row`
- `EdgeInsets.symmetric` and `EdgeInsets.fromLTRB` with equal left/right values (symmetric) for most gutters

**Violations found:**
- `dashboard_screen.dart:1961`: `padding: const EdgeInsets.only(left: 8)` — directional padding, should be `EdgeInsetsDirectional.only(start: 8)`
- `TextDirection.rtl` hardcoded in bottom nav Row (`app_shell.dart:475`) — works now but will break in LTR mode

### Mixed Arabic Dialects

The app mixes three registers with no consistency:

| Context | Dialect | Example |
|---|---|---|
| Dashboard empty state | Egyptian | `'الداش بورد هيمتلئ بكل التفاصيل'`, `'هيظهر هنا'`, `'هنعرض'` |
| Smart insight | Gulf informal | `'استمر بنفس الهدوء'`, `'راقب أكثر تصنيف صرف'` |
| Settings/nav tiles | Gulf MSA | `'أكثر أماكن صرفك'`, `'تحقق من البيانات'` |
| Transactions | Gulf MSA | `'اقرأ صرفك كاتجاهات يومية'` |
| Error messages | Gulf MSA | `'تعذر تحميل لوحة التحكم الآن.'` |

**Recommendation: Gulf MSA (Modern Standard Arabic with Gulf coloring).** This is the register used by Revolut Arabic, and is natural to Saudi, UAE, Kuwaiti, and Qatari users who are the primary audience. Remove all Egyptian dialect strings.

### Financial Arabic Clarity

- `'المصروف'` for "spending" — correct, standard
- `'الدخل'` for "income" — correct
- `'وفّرت'` for "saved" — correct
- `'زيادة صرف'` for "overspent" — slightly informal; could be `'تجاوز الميزانية'`
- `'قيد المراجعة'` for "pending" — correct and formal

### Currency Issue

Reports hardcodes `ر` (Saudi Riyal) regardless of user's actual currency:
```dart
// reports_screen.dart:115
return privacyMode ? '•••• ر' : '${Formatters.amount(amount)} ر';
```
A UAE user sees "105.00 ر" in Reports instead of "105.00 د.إ". This is a factual error, not a UI issue.

### Greeting Logic Bug

```dart
// dashboard_screen.dart:461
final greeting = hour < 12 ? 'صباح الخير' : (hour < 18 ? 'مساء الخير' : 'مساء الخير');
```
Both hour ≥ 12 branches return `'مساء الخير'`. Evening (hour ≥ 18) should return `'مساء النور'`.

### Recommended Arabic Tone

**Gulf MSA, second-person singular masculine (standard):**
- Short sentences. No subordinate clauses.
- Direct, warm, not overly formal.
- Numbers always in Arabic-Indic digits (already using `Formatters`).
- No Egyptian dialect (`هيـ`, `هنـ` prefixes).
- No transliterated English (`الداش بورد`, `جاهز للـ sync`).

---

## 8. Accessibility Audit

### Contrast Failures (WCAG AA, dark mode)

| Element | Foreground | Background | Ratio | Passes AA? |
|---|---|---|---|---|
| `textLight` on `bg` | #8A8A8A | #000000 | 4.9:1 | ✓ (barely, for large text only) |
| `textLight` on `surface2` | #8A8A8A | #1A1A1A | 4.1:1 | ✗ 12px text needs 4.5:1 |
| `accent` on header gradient | #7CB1C8 | #034E73 | ~2.1:1 | ✗ UI component needs 3:1 |
| Reports selected tab | #FFFFFF | #FFFFFF | 1:1 | ✗ Completely invisible |
| Pending badge | #8A8A8A α0.1 | surface | ~1.1:1 | ✗ Invisible |

### Font Sizes Below 11px

| Location | Size | Widget | Issue |
|---|---|---|---|
| Pending badge "معلّقة" | 9px | `TransactionRow` | Below minimum readable. WCAG requires 12px+ (4.5:1 contrast). |
| AI badge "AI" | 9px | `TransactionRow` | Same issue. |
| Nav label (selected) | 10px | `_NavTab` | Borderline. 10px is tight for Arabic glyphs. |

### Tap Target Sizes Below 44pt

| Element | Size | Issue |
|---|---|---|
| Pending filter close (×) | 14px icon, no padding | 14px total — far below 44pt minimum |
| Greeting streak badge | ~40×28px pill | Below 44pt height |
| Account management icon in header | estimated 32×32px | Below minimum |

### Icon-Only Buttons

- Center add button (`+`) has no label and no `Tooltip`. A screen reader user has no way to know this opens the capture entry sheet.
- The streak badge in the greeting row has no label — tapping it opens `/achievements` but there is no `Tooltip` or semantic label.

### Screen Reader Readiness

**Zero `Semantics` widgets found in the entire codebase** (confirmed by grep: 0 results). No `semanticLabel` on images, no `ExcludeSemantics` on decorative elements, no `MergeSemantics` on compound widgets. The app is essentially unreadable by VoiceOver or TalkBack.

This is the most critical accessibility gap. A user with visual impairment cannot use this app.

### Color-Only Indicators

- Transaction type (income = green, expense = dark text) is conveyed only by color. No shape, icon, or sign difference beyond the `+`/`−` prefix in amounts.
- Budget state (safe/warning/danger) in budget cards uses only color (green/orange/red). No text state label.

---

## 9. Component Reuse & Technical Design Debt

### Hardcoded Colors (7+ files)

| File | Hardcoded Values | Should Be |
|---|---|---|
| `dashboard_screen.dart` | `0xFF046E9B`, `0xFF034E73`, `0xFF012438`, `0xFF011C2B`, `0xFF023A57` | `AppGradients.heroHeader`, `AppGradients.walletCard` |
| `section_hero_header.dart` | `0xFF046E9B`, `0xFF034E73`, `0xFF012438` | `AppGradients.heroHeader` |
| `app_shell.dart` | `0xFF1C1C1E` | `c.surface` or `c.surface2` |
| `reports_screen.dart` | `Colors.white` (labelColor) | Conditional `c.accent`/`Colors.white` |

### Hardcoded Radii (38+ files)

Extensive `BorderRadius.circular(16)` use that should be `AppRadius.md`. Files most affected: `manual_paste_screen.dart` (×5), `goal_form_screen.dart` (×9), `goal_details_screen.dart` (×5), `settings_screen.dart` (×4 plus mixed AppRadius calls), `transactions_screen.dart`.

### Duplicated Segmented Control Pattern

Three files implement a visually identical pill-shaped segmented control with different code:
- `budgets_screen.dart` — `_PlannerSegmented`
- `reports_screen.dart` — `TabBar` with custom indicator
- `subscriptions_screen.dart` — `TabBar` with custom indicator (correct conditional colors)
- `transactions_screen.dart` — `_MainSegmented`

Should be one `AppPillSegmentedControl` widget.

### Duplicated TabBar Pattern (Reports vs. Subscriptions)

Reports' tab indicator has a critical dark mode bug (`c.primary` = white indicator + white text). Subscriptions has the correct conditional pattern. The correct pattern should be extracted to a shared `AppPillTabBar` widget used by both.

### Repeated Card Pattern

"Surface card with border and optional shadow" appears in ~25 places. None use a shared `AppCard` widget. Each has slightly different padding, border-width, or border-opacity:
- `c.border` width 1.0 — most common
- `c.border.withValues(alpha: 0.5)` — transaction details
- `c.primary.withValues(alpha: 0.14)` — smart insight card
- `c.accent.withValues(alpha: 0.35)` — review card

### Repeated Empty State Pattern

`_EmptyState` (or equivalent) is implemented separately in:
- Dashboard (`_emptyState`) — excellent 3-step guide
- Transactions (`_EmptyState` class) — basic icon + text
- Budgets (`_EmptyBudgetCard`, `_EmptyGoalsCard`) — card-style empty states
- Goals — inline in goals screen

No shared empty state component. Each has different visual weight.

### `_alex()` Function Dead Name (`onboarding_screen.dart:18`)

Function name references "Alexandria" font but calls `GoogleFonts.inter()`. Should be renamed to `_textStyle()` or inlined into `AppTypography`.

### `gradA`/`gradB` Legacy Tokens

`AppColors.gradA` and `AppColors.gradB` in dark mode are `#1A1A1A` → `#000000` — a near-invisible gradient. The comment says "Kept for backward compatibility." These tokens have no use in dark mode and are misleading. Should be deprecated or set to the actual hero gradient colors.

### `/profile` Route Alias

```dart
GoRoute(path: '/profile', builder: (ctx, s) => const SettingsScreen())
```
Dead alias. No feature distinction from `/settings`. Should be removed.

### Settings Screen: Material Icons Mixed with Lucide Icons

15+ `Icons.*` (Material) in `settings_screen.dart` while the app design system uses `AppLucideIcons`. Creates visible icon weight/style inconsistency. All should migrate to `AppLucideIcons` equivalents.

---

## 10. Severity-Based Issue Register

| # | Issue | Severity | Screen | File | Why It Matters | Suggested Fix | Effort |
|---|---|---|---|---|---|---|---|
| 1 | Reports tab: white text on white indicator (dark mode) | Critical | Reports | `reports_screen.dart:74` | Selected tab is invisible — unusable in dark mode | Change `labelColor: Colors.white` → conditional `c.accent`/`Colors.white`; change indicator color to `c.accent` | 15 min |
| 2 | Zero Semantics/accessibility widgets in entire codebase | Critical | All | All feature files | App is inaccessible to VoiceOver/TalkBack users. Potential App Store accessibility rejection. | Add `Semantics` to all interactive and informational widgets | 2+ weeks |
| 3 | `caption` font weight w600 — heavier than body (w400) | Critical | All | `app_typography.dart:109` | Destroys visual hierarchy. Captions look bolder than body text. | Change to `FontWeight.w400` | 5 min |
| 4 | Reports currency hardcoded to SAR (`ر`) | Critical | Reports | `reports_screen.dart:115` | Factually wrong for non-SAR users (UAE, Egypt, etc.) | Use `Currency.arabicLabel(userCurrency)` from `settings_providers.dart` | 30 min |
| 5 | Pending transaction badge near-invisible (`alpha: 0.1`) | Critical | Transactions | `widgets.dart:141` | Most important status indicator uses lowest contrast. Users miss pending transactions. | Use `c.warning.withValues(alpha: 0.18)` + `c.warning` text; or use accent-colored chip | 15 min |
| 6 | Reports not a navigation tab | High | App shell | `app_shell.dart:434` | Core feature buried behind 2 navigation steps | Add Reports as 5th tab; replace wrench/Settings or restructure nav | 4 hours |
| 7 | Settings acts as secondary feature navigation hub | High | Settings | `settings_screen.dart:96–130` | Wrong mental model — product features under preferences | Move feature links (Subscriptions, Achievements) to dedicated tab or dashboard shortcuts | 2 hours |
| 8 | Dashboard has 12+ sections — extreme cognitive overload | High | Dashboard | `dashboard_screen.dart:80–240` | Users cannot form a mental model. Feature discovery fails. | Reduce to 5 sections per §5 recommendations | 1 week |
| 9 | `wrench` icon for Settings tab | High | App shell | `app_shell.dart:438` | Wrench = tools/maintenance. Universal convention is gear or person icon. | Change to `AppLucideIcons.settings` or `AppLucideIcons.user` | 5 min |
| 10 | Inactive nav tabs show no labels | High | App shell | `app_shell.dart:573` | First-time users cannot identify tabs. Especially true for Arabic audience. | Show label always (remove `if (selected)` guard) | 15 min |
| 11 | Evening greeting always shows "مساء الخير" (bug) | High | Dashboard | `dashboard_screen.dart:461` | Wrong copy after 6pm. Arabic speakers notice immediately. Erodes trust. | Add `'مساء النور'` for `hour >= 18` | 5 min |
| 12 | `_alex()` function: named Alexandria but calls Inter | Medium | Onboarding | `onboarding_screen.dart:18` | Dead naming creates confusion. Future devs may expect Alexandria font. | Rename to `_text()` or remove and use `AppTypography` | 15 min |
| 13 | Hero gradient (3 colors) hardcoded outside AppColors | Medium | Dashboard, Header, Reports, Subscriptions | `dashboard_screen.dart:102`, `section_hero_header.dart:33` | Cannot theme-switch. Light mode would need manual override. | Create `AppGradients.heroHeader` constant | 30 min |
| 14 | `gradA`/`gradB` tokens are invisible in dark mode | Medium | Any | `app_colors.dart:80–81` | `#1A1A1A → #000000` gradient is invisible. Misleading token name. | Set to match hero gradient or deprecate | 30 min |
| 15 | Segmented control pattern duplicated 4 times | Medium | Reports, Subscriptions, Budgets, Transactions | Multiple | Inconsistent behavior + dark mode bug in Reports version | Extract `AppPillTabBar` widget | 2 hours |
| 16 | Settings uses Material Icons (`Icons.*`) not Lucide | Medium | Settings | `settings_screen.dart:98–299` | Visual inconsistency — different icon weight/style from rest of app | Replace 15+ icons with `AppLucideIcons` equivalents | 1 hour |
| 17 | `BorderRadius.circular(16)` instead of `AppRadius.md` — 38+ files | Medium | All | Multiple | Token system exists but not enforced. Inconsistent radii. | Global find-replace `circular(16)` → `circular(AppRadius.md)` etc. | 2 hours |
| 18 | No `AppShadows` — all shadows are inline | Medium | All | Multiple | Elevation hierarchy is inconsistent across components | Create `AppShadows` token file; audit and replace ~15 shadow definitions | 3 hours |
| 19 | `EdgeInsets.only(left: 8)` in dashboard | Medium | Dashboard | `dashboard_screen.dart:1961` | Will break in LTR mode (English) | Replace with `EdgeInsetsDirectional.only(start: 8)` | 5 min |
| 20 | `padding: 120px` bottom hardcoded in 3 screens | Medium | Dashboard, Transactions, Budgets | Multiple | Wastes 20–24px of screen space on every scroll. Wrong on devices with non-standard safe areas. | Compute from `MediaQuery.viewPaddingOf(context).bottom + 64 + 8` | 30 min |
| 21 | AI confidence (0.0–1.0) stored but never shown | Medium | All | `transaction_entity.dart` | Users don't know AI certainty. Reduces trust in AI classification. | Show small confidence bar or % on pending transaction rows | 4 hours |
| 22 | Tap target < 44pt: filter close icon (14px) | High | Transactions | `transactions_screen.dart:100` | User cannot reliably tap the close button on small phones | Wrap in `GestureDetector` with 44pt minimum hit area | 15 min |
| 23 | Mixed Arabic dialects (Egyptian + Gulf + MSA) | Medium | Dashboard, Onboarding | `dashboard_screen.dart:697–699`, `onboarding_screen.dart` | Inconsistent voice. Alienates non-Egyptian users. | Audit all copy, replace Egyptian dialect with Gulf MSA | 2 hours |
| 24 | `/profile` route is alias for `/settings` (dead route) | Low | Router | `app_router.dart:250` | Navigation confusion. Zero functional value. | Remove the route | 5 min |
| 25 | `display` typography style defined but never used | Low | — | `app_typography.dart:52` | Dead code. Creates false impression the style is used somewhere. | Remove or document as reserved | 5 min |
| 26 | `headline` (18px) and `title2` (20px) too close | Low | — | `app_typography.dart:64–74` | 2px distinction is invisible. Designers/devs pick randomly. | Merge or increase gap to 4px minimum | 30 min |
| 27 | `AppRadius.lg = 18` and `AppRadius.md = 16` too close | Low | — | `app_spacing.dart:27` | Same issue as typography. Indistinguishable at runtime. | Remove `lg` or set it to `20` | 30 min |
| 28 | Reports has no date range picker of its own | Medium | Reports | `reports_screen.dart` | Period displayed is controlled by Transactions tab setting. Confusing ownership. | Add month picker chip to Reports header | 2 hours |
| 29 | `CategoryDonutChart` has no tap handler | Medium | Reports, Dashboard | `reports_screen.dart`, `dashboard_screen.dart` | Standard fintech UX: tap slice → filtered transactions. Expected by users. | Add `onSliceTapped` callback | 4 hours |
| 30 | Bottom nav bar bg hardcoded `Color(0xFF1C1C1E)` | Low | AppShell | `app_shell.dart:457` | Not a theme token. Will not adapt to theme changes. | Replace with `c.surface` or `c.surface2` | 5 min |

---

## 11. Redesign Readiness Score

| Dimension | Score | Key Finding |
|---|---|---|
| **Visual Design** | 6.5/10 | Strong dark aesthetic, good spacing scale, sophisticated animations. Undermined by hardcoded gradients, muted accent, and caption weight inversion. |
| **UX** | 5/10 | Dashboard overload is structural. Reports not a tab. Settings misused as feature navigation. No swipe-to-confirm. |
| **Accessibility** | 2/10 | Zero Semantics widgets. Multiple WCAG contrast failures. Sub-minimum tap targets. Reports tab invisible in dark mode. |
| **Arabic RTL Quality** | 7/10 | Strong Directionality usage, correct font stack. Dragged down by dialect mixing, greeting bug, hardcoded ر in Reports. |
| **Fintech Trustworthiness** | 6.5/10 | Dark palette signals premium. Privacy mode, on-device storage, multi-currency are solid. AI confidence hidden kills trustworthiness. |
| **Modernity** | 8/10 | Floating nav, blur effects, animated amounts, glassmorphic sheets — all genuinely modern. These are genuine strengths. |
| **AI Assistant Identity** | 3/10 | AI does significant work (parse, categorize, confidence) but none is visible. No AI name, no confidence display, no assistant voice. App feels like a manual tracker with invisible AI. |
| **Component Consistency** | 5/10 | Good token system exists but enforced in only ~60% of code. 3 segmented control implementations, 4 empty state implementations, shadow chaos, icon library mixing. |
| **Readiness for Premium Redesign** | 7/10 | Design system foundation (AppColors, AppTypography, AppSpacing) is solid. Clean Riverpod architecture. The bones are good — the execution layer needs cleanup. |

**Overall: 5.7/10**

The app is buildable. The architecture is clean. The design intent is right. But the gap between "designed" and "implemented" is approximately 40% of the design token system, and the product information architecture (navigation + dashboard structure) needs a fundamental rethink before a premium redesign can land correctly.

---

## 12. Recommended Implementation Roadmap

---

### Phase 1: Critical Safe Fixes (3–5 days)

**Goal:** Fix all critical bugs that break the app today. Zero risk. Zero redesign.

**Files affected:**
- `lib/core/theme/app_typography.dart`
- `lib/features/reports/reports_screen.dart`
- `lib/features/dashboard/dashboard_screen.dart`
- `lib/core/router/app_router.dart`
- `lib/features/app/app_shell.dart`

**What to change:**
1. `caption` weight: `FontWeight.w600` → `FontWeight.w400`
2. Reports tab indicator: `color: c.primary` → `isDark ? c.accent : c.primary`; `labelColor: Colors.white` → `isDark ? c.accent : Colors.white`
3. Evening greeting: add `hour >= 18 ? 'مساء النور'` branch
4. Reports `_money()`: replace hardcoded `ر` with `Currency.arabicLabel(userCurrency)` from provider
5. `wrench` icon → `AppLucideIcons.settings` (or `AppLucideIcons.user`)
6. Remove `/profile` alias route
7. `EdgeInsets.only(left: 8)` → `EdgeInsetsDirectional.only(start: 8)` in dashboard
8. Pending badge contrast: `c.textLight.withValues(alpha: 0.1)` → `c.warning.withValues(alpha: 0.18)`, text color `c.warning`
9. Pending filter close icon: add 44pt hit area wrapper
10. Bottom nav bar dark bg: `Color(0xFF1C1C1E)` → `c.surface`

**What NOT to change:** Navigation structure, screen layouts, component architecture.

**Risks:** Zero. All changes are 1-line fixes.

**Acceptance criteria:**
- `flutter analyze` = 0 issues
- `flutter test` = all passing
- Reports tab readable in dark mode
- Caption text visually lighter than body text

---

### Phase 2: Design Token Cleanup (1 week)

**Goal:** Enforce the existing token system. No new design. No layout changes.

**Files affected:** 38+ files with `BorderRadius.circular()`, `_alex()` function, `AppColors`, shadow inline definitions.

**What to change:**
1. Create `AppGradients` class in `lib/core/theme/app_gradients.dart`:
   ```
   static const heroHeader = LinearGradient([0xFF046E9B, 0xFF034E73, 0xFF012438])
   static const walletCard = LinearGradient([0xFF011C2B, 0xFF023A57])
   ```
   Replace all inline gradient definitions in `dashboard_screen.dart`, `section_hero_header.dart`.
2. Create `AppShadows` class: `card`, `float`, `hero` shadow presets. Replace ~15 inline `BoxShadow`.
3. Replace all `BorderRadius.circular(16)` with `BorderRadius.circular(AppRadius.md)`. `circular(24)` with `AppRadius.card`. `circular(32)` with `AppRadius.cardLg`.
4. Replace `_alex()` with `AppTypography` calls or rename it.
5. Replace all `Icons.*` in `settings_screen.dart` with `AppLucideIcons` equivalents.
6. Extract `AppPillTabBar` shared widget. Replace Reports, Subscriptions, Budgets, Transactions segmented implementations.
7. Deprecate/remove `gradA`/`gradB` tokens or set them to actual hero gradient values.
8. Remove `display` typography style or document it as a reserved style.
9. Fix `AppRadius.lg = 18` — either remove or change to `20`.

**What NOT to change:** Screen layouts, navigation, copy, any features.

**Risks:** `borderRadius.circular(99)` pill shapes — confirm replacing with `AppRadius.pill`. Some `circular(16)` might be intentionally different from `AppRadius.md = 16` (they're equal — safe to replace). Run visual regression screenshots before and after.

**Acceptance criteria:**
- `grep -r "BorderRadius.circular" lib/ | grep -v "AppRadius"` returns 0 results for feature files
- `grep -r "Color(0x" lib/features` returns 0 results (all colors through tokens)
- `grep -r "Icons\." lib/features/settings` returns 0 results (all Lucide)

---

### Phase 3: Home/Dashboard Redesign (1.5 weeks)

**Goal:** Reduce dashboard from 12 sections to 5. Establish a single primary number. Make the AI review card first-class.

**Files affected:**
- `lib/features/dashboard/dashboard_screen.dart` (major)
- `lib/features/dashboard/dashboard_providers.dart`
- `lib/features/common/section_hero_header.dart`

**What to change:**
1. Remove from dashboard: period snapshot card, subscriptions preview, cards carousel, smart insight card (move to Reports), quick actions row (replace with FAB affordance).
2. Hero card: change primary metric from side-by-side spend/income to single "net spend" at `amountHero` size. Secondary row shows the split.
3. AI review card: rename to "صندوق الذكاء الاصطناعي", replace `AlertTriangle` with `AppLucideIcons.inbox` or `AppLucideIcons.sparkle`. Make it visually dominant when pending count > 0.
4. Category mini-donut: 3 slices, 3 bar rows. Tappable (navigates to Reports).
5. Recent transactions: cap at 5 items, "عرض الكل" link.
6. Quick actions: embed in hero card or as floating inline strip.

**What NOT to change:** `DashboardData` provider shape, `_walletSummary` inner logic (only the wrapping layout changes), `CardsCarousel` component (it moves to another screen).

**Risks:** Dashboard providers expose many data fields. Removing sections from UI does not remove the data fetches — review `dashboardDataProvider` for unused fields after removal.

**Acceptance criteria:**
- Dashboard has exactly 5 sections in non-empty state
- Single dominant number visible at `amountHero` size without scrolling
- Review card (if pending > 0) visible without scrolling

---

### Phase 4: Smart Inbox and AI Review UX (1 week)

**Goal:** Make the AI identity visible and fast.

**Files affected:**
- `lib/features/transactions/widgets/confirm_transaction_sheet.dart`
- `lib/features/common/widgets.dart` (TransactionRow)
- `lib/features/dashboard/dashboard_screen.dart`

**What to change:**
1. Add `parseConfidence` display to pending `TransactionRow`: a small horizontal bar (0→100%) in the card footer, or a `%` figure next to the pending badge.
2. Rename pending review card to "صندوق مراجعة مالي الذكي" or "المراجعة الذكية".
3. Add `Dismissible` wrap to `TransactionRow` for pending transactions: swipe-right → confirm, swipe-left → ignore. This replaces the 4-tap confirm flow with 1 gesture.
4. Add AI source context to `ConfirmTransactionSheet`: "صنّفت هذه العملية كـ [category] بثقة [confidence]%. هل هذا صحيح؟"
5. Add AI identity chip to dashboard header: small "Powered by Mali AI" or sparkle icon that opens an AI stats modal.

**What NOT to change:** `AddTransactionUseCase` AI logic, `_resolveAiConfidence`, Sprint D/E server changes. These are correct as-is.

**Risks:** `Dismissible` on `TransactionRow` requires list key management. Ensure each transaction has a stable key.

**Acceptance criteria:**
- Pending transactions show confidence indicator
- Swipe-to-confirm works from transaction list
- Confirm sheet shows AI confidence explanation

---

### Phase 5: Transactions and Search (3 days)

**Goal:** Clean up the Transactions screen. Move Bills.

**Files affected:**
- `lib/features/transactions/transactions_screen.dart`
- `lib/features/app/app_shell.dart` (navigation restructure)

**What to change:**
1. Remove Bills sub-tab from Transactions. Bills move to Subscriptions screen OR to Budgets tab as "الالتزامات".
2. Remove `SectionHeroHeader` subtitle `'كل التفاصيل تفتح من أسفل الشاشة.'` — replace with period label only.
3. Make search bar persistent (not inside scroll content) — move to top of screen, always visible.
4. Add empty search results state: icon + "لم نجد عمليات بهذه الكلمة. جرب اسم تاجر آخر."
5. Fix bottom padding: replace `120` with computed value.

**What NOT to change:** Transaction grouping logic, date range chips, `_KindFilterChips`, `TransactionRow`.

**Acceptance criteria:**
- Search bar always visible on screen load
- Bills accessible without going through Transactions
- Empty search state renders correctly

---

### Phase 6: Reports and Analytics (4 days)

**Goal:** Promote Reports to first-class tab. Fix currency bug. Add date control. Enable chart interaction.

**Files affected:**
- `lib/features/reports/reports_screen.dart`
- `lib/core/router/app_router.dart`
- `lib/features/app/app_shell.dart`
- `lib/features/common/charts/spending_charts.dart`

**What to change:**
1. Add Reports as a permanent tab in `_FloatingBottomBar`. Update `_items` list. Update `IndexedStack` in shell.
2. Remove Reports from Settings navigation section.
3. Add month picker to `SectionHeroHeader` in Reports (or as a chip row below it). Reports should manage its own date range independently of the Transactions tab.
4. Fix `_money()` function to use user currency from settings.
5. Add `onSliceTapped` callback to `CategoryDonutChart`: tap category → push to Transactions tab with category filter applied.
6. Fix tab indicator using `AppPillTabBar` (from Phase 2).

**What NOT to change:** `ReportsProvider` data logic, chart rendering internals.

**Risks:** Adding a 5th tab requires reducing tab spacing or label sizes. Test with long Arabic labels on small screen (320pt width).

**Acceptance criteria:**
- Reports accessible as bottom nav tab
- Correct currency in all money displays
- Donut chart tappable → filtered transaction list
- Reports has its own date range control

---

### Phase 7: Wallet / Budgets / Goals (1 week)

**Goal:** Separate Budgets and Goals. Promote Subscriptions. Clean up forms.

**Files affected:**
- `lib/features/budgets/budgets_screen.dart`
- `lib/features/goals/goals_screen.dart`
- `lib/features/subscriptions/subscriptions_screen.dart`
- `lib/features/settings/settings_screen.dart`
- `lib/core/router/app_router.dart`

**What to change:**
1. Separate Goals from Budgets: Goals become a dedicated section or sub-page, not a segmented tab inside Budgets.
2. Give Subscriptions first-class access: add "الفواتير والاشتراكات" shortcut from dashboard hero card or from Transactions tab.
3. Fix all hardcoded "ريال" currency strings in Goals and Budgets cards.
4. Fix `SizedBox(height: 120)` hardcoded bottom padding.
5. Replace all `BorderRadius.circular(16)` in goal_form_screen and goal_details_screen with `AppRadius.md`.
6. Accounts: accessible from home hero card "إدارة الحسابات" link, not only via Settings.

**What NOT to change:** Budget/goal entity logic, Riverpod providers, form validation.

**Acceptance criteria:**
- Goals accessible without going through Budgets tab
- Subscriptions accessible from main navigation (not only Settings)
- All currency displays respect user's currency setting

---

### Phase 8: Settings / Profile / Onboarding Polish (4 days)

**Goal:** Clean settings to pure preferences. Fix onboarding dead code and flow.

**Files affected:**
- `lib/features/settings/settings_screen.dart`
- `lib/features/onboarding/onboarding_screen.dart`
- `lib/core/router/app_router.dart`

**What to change:**
1. Remove from Settings: Reports link, Achievements link, Subscriptions link (these are now tabs or accessible from other paths).
2. Rename Settings top section "الملف الشخصي والتحليل" to "الملف الشخصي" (remove feature links from this section).
3. Add "معلومات عن مالي" (About Mali) section to Settings.
4. Break `settings_screen.dart` (1483 lines) into: `_ProfileSection`, `_GeneralSection`, `_NotificationsSection`, `_CategoriesSection`, `_DataSection` as separate private widgets.
5. Remove `_alex()` font function from `onboarding_screen.dart`, replace with `AppTypography` calls.
6. Add "تخطي" (Skip) to onboarding after page 1.
7. Reorder onboarding: Welcome → How It Works → Country → Privacy → Auth. Move privacy to before auth decision, not before country selection.

**What NOT to change:** `userSettingsProvider`, notification preference logic, backup/restore flows.

**Acceptance criteria:**
- Settings contains only profile and preference items (no feature navigation)
- `settings_screen.dart` split into logical widget classes
- Onboarding has a skip option

---

## 13. Final Summary For ChatGPT

### Implementation Prompt Input

**Current Biggest Problems (Priority Order):**

1. **Reports tab is invisible.** `/reports` is not a bottom nav tab. It is buried in Settings. This is the most important navigation fix in the product.
2. **Dashboard shows 12 sections.** Cognitive overload. Users cannot identify the primary metric or primary action. Need to cut to 5 sections max.
3. **Zero accessibility implementation.** No `Semantics` widgets. Reports tab invisible in dark mode (white on white). Tap targets below 44pt. The app cannot be used by VoiceOver/TalkBack users.
4. **AI identity is invisible.** The app parses, categorizes, and scores transactions with AI (0.0–1.0 confidence) but none of this is shown to the user. There is no AI-branded experience. The app feels like a manual tracker.
5. **`caption` font weight w600 > `body` weight w400.** The smallest text in the app is bolder than the largest body text. This inverts the visual hierarchy on every screen.
6. **Settings is misused as a secondary navigation hub.** Reports, Achievements, and Subscriptions are accessible only through Settings. Wrong mental model.
7. **Token system exists but is ~40% enforced.** 38+ files use inline `BorderRadius.circular()`. Hero gradient is hardcoded in 4 places. No `AppShadows` or `AppGradients`. Icon library mixes Material and Lucide in the same screen.
8. **Arabic dialect mixing.** Egyptian dialect in dashboard empty state. Gulf MSA in headers. Colloquial in insight copy. Evening greeting bug (always shows "مساء الخير").
9. **Reports currency hardcoded to SAR.** Non-Saudi users see wrong currency symbol.
10. **No swipe-to-confirm on pending transactions.** 4 taps to confirm. Copilot achieves it in 1 gesture.

**Target Visual Direction:**
- Premium fintech dark mode: true-black canvas, white typography, vivid single accent color (increase accent saturation to ~65–70% from current ~44%)
- Clean information hierarchy: one dominant number per screen, clear primary/secondary/tertiary text weight
- 24px rounded cards, 16px rounded inputs and buttons (already defined in AppRadius — just needs enforcement)
- Arabic RTL with Gulf MSA copy tone throughout
- Modernity signals to KEEP: floating blur nav bar, animated amounts, glassmorphic modal sheets, staggered PremiumMotion reveals

**Screens That Need Redesign (Priority Order):**
1. Dashboard — reduce to 5 sections, add single primary number, promote AI review card
2. Reports — promote to tab, add date picker, fix dark mode bug, add chart interaction
3. App Shell — add 5th tab, replace wrench icon, show inactive labels
4. Settings — remove feature navigation, split into components
5. Transactions — separate Bills, make search persistent
6. Transaction Row — increase pending badge contrast, add confidence indicator, add swipe-to-confirm

**Screens That Are Acceptable As-Is (Minor Polish Only):**
- Onboarding (fix dialect + skip button)
- Transaction Details sheet (fix icons, fix `textAlign`)
- Achievements (fine, keep as push route)
- Backup/Privacy (utility screens, acceptable)

**Components That Need Rebuilding:**
1. `AppPillTabBar` — replace 4 separate segmented/tab implementations
2. `AppCard` — shared surface card widget with standard padding, border, shadow
3. `AppEmptyState` — replace 4 different empty state implementations
4. `AppGradients` — centralize the 2 hero gradient definitions
5. `AppShadows` — centralize the ~15 inline shadow definitions
6. `_CenterAddButton` in nav bar — add Semantics, add Tooltip

**Design Tokens to Enforce:**
- `AppRadius.md = 16` everywhere `BorderRadius.circular(16)` exists (38+ files)
- `AppRadius.card = 24` everywhere `BorderRadius.circular(24)` exists
- `AppColors` for ALL color usage — zero `Color(0x...)` outside `app_colors.dart`
- `AppTypography` for ALL text styles — zero `GoogleFonts.inter()` outside `app_typography.dart`
- `AppSpacing` for ALL spacing — computed bottom padding from `MediaQuery`
- `AppLucideIcons` for ALL icons — zero `Icons.*` in feature code

**Navigation Changes Recommended:**
- Bottom nav: 5 tabs → Home / Activity / [+] / Reports / Settings
- Remove `/profile` route
- Move Subscriptions out of Settings to Activity tab (Bills sub-tab) or as dedicated section
- Reports as primary tab; remove from Settings navigation section
- Goals accessible directly (not only via Budgets segmented)

**Priority Order for Implementation:**
1. Phase 1: Critical fixes (3–5 days) — 0 risk, maximum impact
2. Phase 2: Token cleanup (1 week) — prerequisite for redesign
3. Phase 3: Dashboard redesign (1.5 weeks)
4. Phase 4: AI Smart Inbox UX (1 week)
5. Phase 6: Reports promotion + fix (4 days)
6. Phase 5: Transactions (3 days)
7. Phase 7: Wallet/Budgets/Goals (1 week)
8. Phase 8: Settings/Onboarding polish (4 days)

**Risks:**
- Adding a 5th tab: test with 320pt width devices. Arabic labels on 5 tabs at 10px font may overflow.
- Dashboard restructure: `dashboardDataProvider` fetches data for all 12 sections. After removing sections, audit unused provider calls to avoid unnecessary database queries.
- Reports as tab: `reportsProvider` uses the same `transactionsDateRangeProvider` as the transactions tab. Decoupling this requires either a separate reports date range provider or accepting that both share the same period.
- Swipe-to-confirm: `Dismissible` requires stable keys. Using `tx.id` as key is correct; ensure no duplicate IDs in the list.
- Accessibility sprint: adding `Semantics` to all widgets is a large surface area. Prioritize: interactive elements first (buttons, tappable rows), then informational elements (amounts, labels).

---

*This audit is based entirely on static analysis of the Flutter source code. No simulator was used. All file paths, line numbers, and code snippets are drawn directly from the working tree as of 2026-06-18.*
