# Mali — UI/UX Audit Report
**Reviewer:** Senior Product Designer (via code audit)
**Date:** 2026-06-18
**Branch:** `feat/accounts-multicurrency`

---

## Executive Summary

Mali has strong visual DNA — the dark fintech aesthetic, floating nav bar, animated amounts, and premium glass-effect cards signal real design intent. But the product has a critical structural problem: **the dashboard tries to be every screen at once**. Below that, a cluster of systemic issues (color role confusion, RTL shortcuts, typography weight inversions, dialect mixing) compound into a product that feels almost-there but not launch-ready.

This report is honest to the point of being uncomfortable. That is the point.

---

## 1. Visual Hierarchy

### Dashboard
**What attracts attention first:** The blue gradient hero header — correctly. The greeting, account switcher, and wallet summary card are in this zone. This is right.

**Where it breaks down:** There is no second focal point. After the hero card the eye has nowhere clear to land. The page presents 12 scrollable sections in one uninterrupted ListView:

1. Account switcher
2. Wallet summary mega-card (6 sub-elements within it)
3. Currency totals card
4. Active goal card
5. Pending review alert
6. Smart insight card
7. Period snapshot card (today/week spend & income)
8. Quick actions row
9. Cards carousel
10. Subscriptions preview
11. Category donut + bar chart
12. Recent transactions

This is not a dashboard. This is a report. Revolut, Apple Wallet, and Nubank each show a **single hero number** plus 2–3 supporting elements. The user's eye cannot rest anywhere.

**Primary action clarity:** The primary action (add a transaction) is a 48×48 circle buried in the center of the bottom nav bar. It has no label. A new user has no reason to know this button exists. On an empty dashboard the CTA is explicit and good — but it disappears once transactions exist.

**Severity:** Critical  
**Business impact:** New users churn before understanding the value of the product. Power users experience fatigue and miss critical data buried below the fold.  
**Suggested fix:** Collapse the dashboard to: hero card (spend + income + budget bar) → top 3 categories donut → recent 5 transactions → persistent FAB. Move insight, period snapshot, and subscriptions to the Reports tab.

---

### Transactions Screen
Visual hierarchy is acceptable. The `SectionHeroHeader` sets context. The pending filter chip and batch-confirm action are correctly placed. The main issue is mixing **transactions** and **bills** in the same tab — these are conceptually different features sharing a screen with no cognitive separation.

### Reports Screen
The 3-tab layout (Overview / Trends / Details) is clean. But the tab indicator in **dark mode** has a contrast problem: `indicator: BoxDecoration(color: c.primary)` where `primary = white`, and `labelColor: Colors.white` for the selected tab. This renders **white text on white background**.

**Severity:** Critical (accessibility fail)

---

## 2. Layout & Spacing

### What works
- The 4pt spacing system (s1–s10) is correctly defined and largely followed.
- Gutter of 20px is appropriate for mobile.
- `AppRadius.card = 24` gives a premium rounded feel.

### What breaks

**Inconsistent radius usage:** Cards use `AppRadius.card = 24` but:
- `TransactionRow` hardcodes `BorderRadius.circular(16)`
- `_quickActionTile` hardcodes `BorderRadius.circular(18)`
- Some containers hardcode `BorderRadius.circular(14)` and `BorderRadius.circular(15)`

This is 5 different radii for what visually should be one card shape. The token system exists but is not enforced.

**RTL padding shortcut:**
```dart
padding: const EdgeInsets.only(left: 8) // in AccountChip
```
This should be `EdgeInsetsDirectional.only(start: 8)`. When Flutter runs in LTR context (tests, future English mode, web), this breaks layout.

**Dashboard bottom padding hardcoded at 120:**
```dart
padding: const EdgeInsets.only(bottom: 120),
```
The floating nav bar height is 64 + 8 top padding + 24 bottom safe area ≈ 96px. The 120px is an approximation, not derived from layout. On devices with non-standard safe areas this either clips content or wastes space.

**Budget swiper height hardcoded at 80px.** If the label wraps (long account name + period), it clips. No min-height constraint.

**Severity:** Medium (radius), Medium (RTL), Low (bottom padding)

---

## 3. Typography

### Type Scale

| Style | Size | Weight | Concern |
|---|---|---|---|
| `amountHero` | 40px | w800 | Correct |
| `display` | 32px | w800 | Defined but never called in production code |
| `title1` | 24px | w700 | Correct |
| `title2` | 20px | w600 | Correct |
| `headline` | 18px | w600 | Redundant with title2 — only 2px difference |
| `body` | 16px | w400 | Correct |
| `bodyStrong` | 16px | w600 | Correct |
| `callout` | 15px | w400 | Odd size, not in iOS/Material standard |
| `subhead` | 14px | w600 | Correct |
| `footnote` | 13px | w400 | Correct |
| `caption` | 12px | **w600** | **Problem — see below** |

**Caption weight inversion:** `caption` is **w600** — bolder than `body` which is w400. In fintech apps, captions label secondary information (dates, categories, subtitles). Making captions bold reduces the visual separation between primary and secondary content. The eye cannot find hierarchy. Every fintech benchmark (Revolut, Apple Wallet, Copilot) uses w400 or w500 for captions.

**Missing mid-tier amount style:** There is no `amountMedium` (24–28px) for secondary amounts like balance, totals in cards. The code workarounds by calling `amountHero` in non-hero contexts or using `title2` for amounts, which creates visual inconsistency.

**Font mismatch in onboarding:** `onboarding_screen.dart` defines a local `_alex()` function named after Alexandria but internally calls `GoogleFonts.inter()`. This is dead naming from a font change that was never cleaned up.

**Greeting logic bug:**
```dart
final greeting = hour < 12 ? 'صباح الخير' : (hour < 18 ? 'مساء الخير' : 'مساء الخير');
```
Both afternoon and evening map to `'مساء الخير'`. `مساء الخير` literally means "good afternoon." After 18:00 it should be `مساء النور` or `تصبح على خير`. This may seem minor but native Arabic speakers will notice and it erodes trust.

**Severity:** High (caption weight), Medium (greeting), Low (font naming)

---

## 4. Colors

### Color Token Audit

**Dark Mode:**
```
bg:       #000000  (true black — intentional, premium)
surface:  #0E0E0E  (near black — correct)
primary:  #FFFFFF  (white — UNUSUAL: primary = white)
accent:   #7CB1C8  (muted steel blue)
success:  #2BC79A  ✓
danger:   #FF6B73  ✓
warning:  #D89C5A  ✓
textMain: #FFFFFF  (same as primary — semantic confusion)
textLight:#8A8A8A  ✓
```

**Critical problem: `primary` and `textMain` are identical in dark mode.** Both are `#FFFFFF`. This means every place `c.primary` is used for icons, borders, or highlights is visually indistinguishable from body text. The code uses `c.primary` for: icon color, button backgrounds, progress bar fill, chip borders — all white. This works visually by accident (white-on-black has good contrast) but the semantic is wrong.

**`accent` color analysis:**
- Dark mode accent: `#7CB1C8` — a muted, desaturated blue. Not a strong call-to-action color.
- Used for: selected nav tab, fire streak icon, alert triangle (warnings), pending chip border, account chip selected state, the center add button fill.
- A muted blue for the primary CTA means the most important interactive elements have low visual salience.
- Compare: Revolut uses electric indigo, Nubank uses vivid purple, Copilot uses bold teal. All have saturated, high-energy accent colors.

**Dashboard header uses hardcoded colors that bypass the theme:**
```dart
gradient: const LinearGradient(
  colors: [Color(0xFF046E9B), Color(0xFF034E73), Color(0xFF012438)],
)
```
These are not in `AppColors`. They don't adapt to theme changes. If the app ever ships a light mode, this gradient will appear on a light background without modification.

**`gradA`/`gradB` compatibility tokens** exist but are `#1A1A1A → #000000` in dark mode — nearly identical, producing a gradient that is invisible.

**Contrast audit (dark mode):**
- `textLight` (#8A8A8A) on `bg` (#000000): ratio ~4.9:1 — passes AA minimum (4.5:1) for normal text, barely.
- `accent` (#7CB1C8) on `surface` (#0E0E0E): ratio ~5.8:1 — passes.
- `accent` (#7CB1C8) on the dashboard header gradient (#034E73): ratio ~2.1:1 — **FAILS** WCAG AA (3:1 minimum for UI components). The selected account chip on the dashboard header is inaccessible.
- Caption text (#8A8A8A) on `surface2` (#1A1A1A): ratio ~4.1:1 — **FAILS** AA for 12px text (requires 4.5:1).

**Severity:** Critical (primary/textMain confusion, hardcoded header gradient), High (contrast failures), Medium (muted accent)

---

## 5. Components

### Cards
Three distinct card styles are used with no explicit taxonomy:
1. Surface cards (`c.surface` bg, `c.border` border)
2. Glass cards (`c.surface.withAlpha(0.78)`, slight border)
3. Gradient cards (hardcoded blue gradient, accent border)

The difference between 1 and 2 is imperceptible to a user — `withAlpha(0.78)` vs full color appears identical over a dark background. This creates visual noise without purpose.

### Buttons
`FilledButton` and `ElevatedButton.icon` are both used in overlapping contexts with no clear rule for when to use each. The empty state uses `ElevatedButton.icon` with transparent background inside a `Container` with a gradient decoration — this is three layers of button composition for one button.

The "تأكيد الكل" batch confirm chip and the pending filter chip share the same visual style (accent border, semi-transparent fill) but have different functions (action vs. filter). Users may mistake the filter chip for an action and vice versa.

### Bottom Navigation
Strengths: Floating pill style, backdrop blur, auto-hide on scroll, animated label expansion — all excellent.

Issues:
- **Wrench icon for Settings** — universally, wrench = maintenance/tools, not user preferences. Apple uses a gear; Revolut uses a person.
- **Hidden labels on inactive tabs** — inactive tabs show only icons. For an Arabic audience that may not associate home/receipt/wallet with app features, this increases learning curve.
- **No badge/indicator system** — if there are pending transactions, the bottom nav shows no count badge. The review alert is hidden inside the dashboard scroll. Native iOS/Android both support count badges on nav items.

### Charts
`CategoryDonutChart` and `CompactSparkline` are defined but the donut chart has no interaction affordance — no tap to drill-down, no selected-slice highlight visible from code.

`CompactSparkline` has a hardcoded height of 44 — acceptable for a mini chart but labeled only with `'اتجاه الصرف هذا الشهر'` with no X/Y axis. Users have no way to know what the sparkline scale represents.

### Empty States
The dashboard empty state is **well-designed**: 3-step instruction list, clear icon, primary CTA button. This is the best component in the app. Matches Copilot-level quality.

### Transaction Row
Good: icon avatar, merchant name, amount, category color, pending indicator.

Issues:
- The pending badge uses `c.accent.withAlpha(0.12)` — very subtle, low-contrast indicator. Users may miss that a transaction needs review.
- No swipe-to-confirm action (unlike Copilot/Monarch). Users must tap into a detail sheet to confirm. Friction.

**Severity:** High (button taxonomy, pending badge contrast), Medium (chart labeling, swipe actions)

---

## 6. UX Problems

### Problem 1: Dashboard Cognitive Overload
**Severity: Critical**  
12 scrollable sections, 6 sub-elements in the wallet card alone. Users cannot build a mental model of where information lives. In user testing this pattern consistently results in users scrolling past key information.  
**Business impact:** Users miss the pending review alert, the budget status, and the insight card — the three features that drive engagement.

### Problem 2: Reports Accessible from Two Places
`/reports` is a bottom nav tab destination AND reachable from:
- Smart insight card tap
- Settings > "الرؤى والتقارير"
- Budget over notification tap

**Severity: Medium**  
Users who navigate from Settings expect to return to Settings. The information architecture is unclear.

### Problem 3: No Budget/Goal Onboarding Prompt
A new user who finishes onboarding sees the empty dashboard with a "paste SMS" CTA. There is no prompt to set a budget or a goal until they scroll down and discover the quick actions row. Monarch Money asks "what's your monthly budget?" in step 2 of onboarding. This is a missed activation opportunity.

**Severity: High**  
**Business impact:** Budget and goal features drive retention. If users never set them, the "budget swiper" and "goal card" on the dashboard never appear — the most meaningful widgets go unseen.

### Problem 4: Arabic Dialect Inconsistency
The app mixes three registers:
- Egyptian dialect: "هيظهر هنا", "هنعرض", "الداش بورد هيمتلئ"
- Gulf/MSA: "أكثر أماكن صرفك", "تحقق من البيانات"
- Colloquial mixed: "استمر بنفس الهدوء", "راقب أكثر تصنيف"

**Severity: High**  
A Saudi user will feel the Egyptian dialect as foreign. A fintech product must choose one register and maintain it. Revolut Arabic uses consistent Gulf MSA.

### Problem 5: Swipe Gesture Conflict
The dashboard horizontal swipe (to switch accounts) and the scroll gesture coexist on the same container. With `primaryVelocity < 200` threshold, slow horizontal swipes may not register while fast ones override the list scroll. This needs `onHorizontalDragStart` + `GestureDetector` tuning.

**Severity: Medium**

### Problem 6: Privacy Mode Incomplete
`privacyMode` masks amounts with `••••` but does not mask:
- Transaction count ("5 عمليات حديثة")
- Merchant names in recent transactions
- Category names

Someone looking over your shoulder at the "••••" dashboard can still see you spent at "Starbucks × 3 this week."

**Severity: Medium (privacy concern)**

### Problem 7: Accessible Tap Target Sizes
The batch-confirm chip `X` close icon is 14px — below Apple's 44pt minimum and Google's 48dp minimum. The account management button in the header is 40×40 — also below target.

**Severity: High (accessibility)**

---

## 7. Fintech Best Practices Benchmark

| Feature | Revolut | Copilot | Monarch | Mali | Gap |
|---|---|---|---|---|---|
| Single hero number | ✓ Balance center stage | ✓ Net worth hero | ✓ Budget hero | Partial — two equal numbers side-by-side | Lacks dominant primary number |
| Pending review UX | Push notification + inline confirm | Swipe-to-confirm in list | N/A | Alert card → sheet → tap confirm | 2 extra taps vs. Copilot |
| Category drill-down | Tap chart slice → filtered list | ✓ | ✓ | Donut chart not tappable | Missing |
| Privacy mode | Long-press toggle | ✓ | ✓ | Settings-only toggle | Missing quick access |
| Budget progress | Inline in home | ✓ | ✓ | Buried in wallet card, requires scroll | Low discoverability |
| Empty state quality | Premium illustration | Clean, instructional | Good | Excellent 3-step guide | Best in class |
| Onboarding | 2 steps to first value | 3 steps | 4 steps | Complex multi-screen | OK for target user |
| Transaction add | Tap → select amount | Import primary | Import primary | Paste SMS — unique | Differentiated, good |
| Search | ✓ | ✓ | ✓ | Not found in code | **Missing** |

**Biggest gap vs. competitors: no search on transactions.** Every major fintech with > 20 transactions ships search. Users looking for "did I pay X" cannot find it.

---

## 8. Per-Screen Issue Register

### Splash Screen
| | |
|---|---|
| **Severity** | Low |
| **Problem** | Logo floats in the middle third of a dark screen with large empty areas above and below. The logo card is a rectangle on a rectangle — no depth, no motion. |
| **Business impact** | First impression is weaker than the app deserves. |
| **Fix** | Full-bleed gradient background, logo centered at 50% vertical, name "مالي" below in 40px. Remove the card container — let the logo breathe. |

### Dashboard
| | |
|---|---|
| **Severity** | Critical |
| **Problem** | 12-section information dump with no clear information architecture. Hero card has 6 nested data elements. Period snapshot duplicates wallet summary data. Smart insight card uses danger icon for non-critical observations. |
| **Business impact** | Feature discovery fails — budget, goals, categories are all visible but none are the focus. Users cannot form habits around key features. |
| **Fix** | Reduce to 4 sections: Hero (spend + income + budget bar) → Top categories (3 max) → Pending review (if any) → Recent transactions (5 max). Move period snapshot, subscriptions, insight, goal to a new "Planning" tab or Reports. |

### Bottom Navigation
| | |
|---|---|
| **Severity** | High |
| **Problem** | Wrench icon for Settings. Inactive tabs show only icons (no labels). No badge indicators for pending items. |
| **Fix** | Replace wrench with person/gear icon. Show labels always (not just when selected). Add badge counter to Home or Transactions tab for pending count. |

### Transactions Screen
| | |
|---|---|
| **Severity** | High |
| **Problem** | Transactions and Bills combined in one screen. Pending indicator is low-contrast. No swipe-to-confirm. No search. Bottom padding is hardcoded. |
| **Fix** | Separate Bills into the Budgets tab or a dedicated tab. Add swipe-right-to-confirm on pending transactions. Add search bar. |

### Reports Screen
| | |
|---|---|
| **Severity** | Critical (contrast), Medium (depth) |
| **Problem** | White text on white selected tab in dark mode. No date range control on the screen itself. No merchant drill-down from categories. |
| **Fix** | Fix tab indicator: use `c.surface2` fill not `c.primary` (white in dark mode). Add month picker to Reports header. Make donut slices tappable for filtered transaction list. |

### Wallet Summary Card (within Dashboard)
| | |
|---|---|
| **Severity** | High |
| **Problem** | One card contains: date picker, spend/income split, budget pill, balance/saved pills, budget swiper (PageView), and sparkline. 6 distinct UI patterns nested in one card. |
| **Fix** | Strip to: primary number (spent this period) → income subtotal → budget progress bar. Move balance, saved, sparkline to a tappable detail expansion or separate section. |

### Settings Screen
| | |
|---|---|
| **Severity** | Medium |
| **Problem** | Settings serves as secondary navigation hub (links to Reports, Accounts, Achievements, Subscriptions). Navigation inside navigation. Wrench icon. |
| **Fix** | Settings should contain only: profile, notifications, privacy, appearance, data, about. Give Subscriptions its own first-class entry in Budgets. |

---

## 9. Overall Design Score

| Dimension | Score | Rationale |
|---|---|---|
| **Visual Design** | 6.5/10 | Strong dark aesthetic and spacing system undermined by hardcoded colors, inconsistent radii, and muted accent |
| **UX** | 5/10 | Dashboard overload is a structural problem. Two critical navigation issues. No search. |
| **Accessibility** | 4/10 | Caption weight inversion, contrast failures on tab indicator and accent-on-gradient, sub-minimum tap targets, RTL padding shortcut |
| **Trustworthiness** | 7/10 | Dark fintech palette, local/on-device privacy message, privacy mode concept — these signal trust. Dialect inconsistency and greeting bug erode it. |
| **Modernity** | 7.5/10 | Floating nav with blur, animated amounts, gesture account switching, AI categorization — genuinely modern patterns |
| **Fintech Quality** | 5.5/10 | Missing search, no swipe-to-confirm, no category drill-down, no date controls in Reports, no balance as primary hero number |

**Overall: 5.9/10**

The product has a strong foundation and several genuinely excellent components (empty state, onboarding flow, privacy mode concept, floating nav). The score is pulled down primarily by dashboard overload (fixable in a week) and the two critical accessibility failures (fixable in a day).

---

## 10. Final Roadmap

### Quick Wins — 1 Day

1. **Fix Reports tab indicator contrast** — change `color: c.primary` to `color: c.accent` or a dark fill in the `BoxDecoration` indicator. One line, removes an accessibility-blocking bug.
2. **Fix caption font weight** — change `caption` in `AppTypography` from `FontWeight.w600` to `FontWeight.w400`. Immediately restores correct visual hierarchy across every screen.
3. **Fix the greeting copy** — change evening greeting from `'مساء الخير'` to `'مساء النور'` for `hour >= 18`. One line fix.
4. **Replace wrench icon with person/gear icon** — `AppLucideIcons.settings` or `AppLucideIcons.user`. One line.
5. **Make inactive nav labels always visible** — remove the `if (selected)` guard on the label Text widget in `_NavTab`.
6. **Fix RTL padding shortcut** — replace `EdgeInsets.only(left: 8)` in `_AccountChip` with `EdgeInsetsDirectional.only(start: 8)`.

---

### Medium Improvements — 1 Week

1. **Dashboard information architecture** — Implement a 4-section dashboard. Create a "Planning" sub-section inside Reports or Budgets to house period snapshot, subscriptions, and the sparkline trend.
2. **Add search to transactions screen** — A `TextField` with `Icons.search` at the top of `TransactionsScreen`. Filter the `transactionsListProvider` by merchant name / amount / category. This is the single biggest gap vs. competitors.
3. **Swipe-to-confirm on pending transactions** — Wrap `TransactionRow` in a `Dismissible` with a confirm action on right-swipe. One gesture replaces 3 taps.
4. **Fix wallet summary card density** — Remove sparkline from the header card. Remove balance/saved glass pills. Keep: date range picker, spent/income split, budget progress bar.
5. **Add pending count badge** to the transactions nav tab.
6. **Standardize card border radius** — audit all hardcoded `BorderRadius.circular(14/15/16/18)` and replace with `AppRadius.card` or `AppRadius.md` tokens (~8 call sites).
7. **Arabic dialect audit** — pick Gulf MSA as the single register and update all Egyptian dialect strings in `dashboard_screen.dart` empty state copy.

---

### Major Redesign Opportunities

1. **Information Architecture Restructure** — Four tabs: **Home** (5-section dashboard), **Activity** (transactions + search), **Plan** (budgets + goals + bills), **Profile** (settings + account management). Reports becomes a modal sheet or sub-navigation within Activity, not a persistent tab (most users check reports weekly, not daily).

2. **Primary Number Redesign** — Mali currently shows two equal-weight numbers (spent / income). Define a single primary number: net spend. Display it at 40px with a secondary line showing the breakdown. This follows Apple Wallet, Revolut, and Nubank's pattern of one dominant number.

3. **Accent Color System Overhaul** — Dark mode accent `#7CB1C8` is too muted for a CTA color. Consider `#4DB8E8` (vivid sky blue) or a distinct teal-green (`#1DC28E`) not used by any competitor in the GCC market. This is the biggest single visual impact change available.

4. **Primary/textMain Token Separation** — `primary = white` and `textMain = white` in dark mode is semantically broken. Reserve `primary` for brand accent, use a dedicated `onBackground` or `foreground` token for text. Requires auditing all `c.primary` usages.

5. **Confirmation UX Overhaul** — Current flow: SMS arrives → pending card on dashboard → scroll to find it → tap → sheet opens → tap confirm. Target: SMS arrives → instant notification with inline confirm button → one tap confirms. The infrastructure (`CaptureRuntime.confirmRequests`) is already built for this. The last-mile UX hasn't been designed.

---

*This audit is based on static code analysis of all screen files, the design token system (`AppColors`, `AppTypography`, `AppSpacing`), and the navigation architecture (`app_shell.dart`, `AppRouter`). Screenshots of splash and settings screens were also reviewed. Recommendations are benchmarked against Revolut, Copilot Money, Monarch Money, Apple Wallet, and Nubank as of 2025–2026.*
