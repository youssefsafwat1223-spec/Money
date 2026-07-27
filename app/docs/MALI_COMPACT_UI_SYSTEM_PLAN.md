# Mali — Compact UI System Plan

Project-wide compactness & information-density pass. Goal: a **compact, premium fintech**
experience (Linear / Revolut / Apple Wallet / Mercury) — more useful information per
viewport, without feeling crowded, cheap, or hard to read. **Presentation-only**: no
provider / repository / DB / sync / calculation changes.

Status: **Phase 0 + Phase 1 implemented.** Screens (Phase 2+) not yet migrated — pending
visual review of the `/design` gallery.

---

## 1. Current problems (from the audit)

The type scale is mostly within range; the two real problems are **excess vertical
whitespace** (topInset, card padding, section gaps, empty-state art) and **oversized-token
misuse** (large type for greetings / page & section titles / card titles / secondary metrics).

### 1a. Whitespace — biggest, most-repeated offenders (highest leverage first)
| Source | File | Current | Problem |
|---|---|---|---|
| Header top inset | `core/theme/widgets/calm_page_header.dart:32` | `topInset=64` | app-wide header dead space (~8 screens) |
| Card padding | `core/theme/widgets/mali_card.dart:34` | `EdgeInsets.all(24)` | every flagship card |
| Card padding | `features/common/app_card.dart` | `cardPadding=20` | every AppCard |
| Section gap | `core/theme/app_spacing.dart:19` | `sectionGap=32` | inter-section stacks |
| Stacked gaps | dashboard `_home` (6× `s6`=24), settings (11× `s5`=20) | 20–24 | bulk of scrolled whitespace |
| Empty-state art | `common/app_screen_scaffold.dart`, `settings`, `premium_ui` | `320–360px` squares | giant blank illustration boxes |
| Empty state | `common/app_empty_state.dart` | art `78`, `v=s7`(32), title `title2`(20) | oversized empties |
| Buttons | `app_theme.dart` themes + `app_button.dart` | height `56` | tall CTAs everywhere |
| Big all-paddings | `transactions_screen.dart:322` `all(32)`, many `all(24)` | 24–32 | hero/empty blocks |

### 1b. Typography misuse (large token on non-hero content) — systemic, via shared primitives
| Primitive | File | Token | Fix |
|---|---|---|---|
| Global page title | `common/app_header.dart:48-50` | `headline`/`calmTitle`(22) | keep page-title role, ensure ≤24 |
| Every empty-state heading | `common/app_empty_state.dart:60` | `title2`(20) | → `cardTitle`(16) |
| Every error-state heading | `common/app_error_state.dart:53` | `title2`(20) | → `cardTitle` |
| Every sheet title | `common/app_sheet_scaffold.dart:107` | `calmTitle`(22)→19 | already 19 (compact) |
| Section header | `common/section_header.dart:39` | `headline`(18) | → `sectionTitle`(19) |
| Default amount text | `common/motion.dart:82` | `title2`(20) | → `cardTitle` |

Per-screen misuse (greetings, section/card titles, secondary metrics) is catalogued in the
audit and migrated in Phases 2–3. Dashboard greeting `title2` for the username
(`dashboard_screen.dart:592`) and ring/vault `%` labels using `title1/title2` are typical.

### 1c. Legitimate heroes — **preserve** (the one dominant element per screen)
`balance_statement.dart` `balanceHero` (Home balance) · `reports_screen.dart:356` `amountHero`
(period total) · `transaction_details_screen.dart:212` `amountHero` · `confirm_transaction_sheet.dart:142`
`amountHero` · `manual_transaction_sheet` amount input (`balanceHero` 44). Card-face masked
numbers and avatar initials are sized-to-container, not headings — leave.

---

## 2. Proposed compact token scale

### 2a. Typography (add two semantic role tokens; keep the scale — it is in-range)
Existing scale (px): `balanceHero 52` · `amountHero 40` · `display/calmDisplay 32` ·
`title1 24` · `calmTitle 22` · `title2 20` · `headline 18` · `amountSmall 18` · `title 16` ·
`body/bodyStrong 16` · `callout 15` · `subhead 14` · `footnote 13` · `caption 12` · `micro 11`.

New semantic roles (fill the "section/card title" gap that is being filled by oversized tokens):
| Token | Size / weight | Role |
|---|---|---|
| `sectionTitle(c)` | **19 / w600** | section headings (replaces headline 18 / title2 20 misuse) |
| `cardTitle(c)` | **16 / w600** | card & list-group titles, empty/error headings, default amount text |

Role → token map (documented for migration): hero amount → `balanceHero`/`amountHero`;
large page title → `calmTitle`(22)/`title1`(24); standard page title → `calmTitle`(22);
section title → `sectionTitle`(19); card title → `cardTitle`(16); body → `body/bodyStrong`(16);
supporting → `subhead`(14)/`footnote`(13); caption → `caption`(12)/`micro`(11); nav label 10.

### 2b. Spacing (evolve semantic tokens — inherited app-wide)
| Token | Before | After | Note |
|---|---|---|---|
| `pagePadding` / `gutter` | 24 | **20** | mockup horizontal padding |
| `pagePaddingCompact` | 16 | 16 | — |
| `sectionGap` | 32 | **24** | major-section gap |
| `sectionGapCompact` | 20 | **16** | — |
| `listGap` | 12 | 12 | related-item gap |
| `cardPadding` | 20 | **16** | card interior |
| `cardPaddingCompact` (new) | — | **14** | simple/short cards |
| `fieldGap` | 16 | **12** | form field gap |
| `sheetPadding` | 24 | **20** | — |
| `sheetTopGap` | 16 | **12** | — |
| `buttonHeight` | 56 | **50** | ≥ 48 accessible |
| `buttonHeightCompact` | 48 | 46 | ≥ 44 accessible |
| `headerTopInset` (new) | — | **44** | CalmPageHeader top (was 64) |
| `rowPaddingV` (new) | — | **11** | list-row vertical padding |
| `navBarHeight` (new) | — | **54** | glass nav (was 62) |

### 2c. Component density (Phase 1 targets)
| Component | Before | After |
|---|---|---|
| CalmPageHeader topInset | 64 | 44 |
| CalmPageHeader title→amount / amount→strip gaps | 16 / 16 | 12 / 12 |
| MaliCard padding | 24 | 16 |
| AppCard padding | 20 | 16 |
| List row vertical padding | 8–12 | 11 (≈ 58–62px row) |
| Empty-state art / v-padding / title | 78 / 32 / `title2` | 56 / 20 / `cardTitle` |
| Button height (theme) | 56 | 50 |
| Input contentPadding v | 14 | 12 |
| Glass nav height / icon / pill radius | 62 / 22 / 25 | 54 / 20 / 22 |
| Section header v-margin / title | 8 / `headline`(18) | 6 / `sectionTitle`(19) |

---

## 3. Screen priority matrix (dominant element per screen)
| Screen | Hero (stays large) | Everything else → compact |
|---|---|---|
| Home | balance | greeting, controls, pulse, budget, insight, recent rows |
| Transactions | the ledger | header total, chips, day headers, rows |
| Add transaction | amount input | segmented, fields, primary |
| Budgets | budget status | header, per-budget cards, metrics |
| Accounts | account balance | account rows, cards |
| Reports | report summary | gauge, donut, merchant bars |
| Subscriptions/Bills | monthly total | rows |
| Goals/Plans | saved amount | rows |
| Settings | — (no hero) | dense rows |
| Smart Inbox / Notifications | — | dense list |

---

## 4. Migration phases
- **Phase 0 — tokens** (this change): spacing/density tokens + 2 typography roles. No screen rewrites.
- **Phase 1 — core primitives** (this change): CalmPageHeader, MaliCard, AppCard, list rows,
  buttons (theme), inputs (theme), chips/selectors, empty/error states, AppSheetScaffold, section
  headers, glass nav. Showcased in `/design` gallery (light + dark). **→ stop for visual review.**
- **Phase 2 — high-impact screens**: Home, Transactions, Add transaction, Budgets, Accounts. Stop for review.
- **Phase 3 — remaining**: Reports, Subscriptions, Bills, Goals/Plans, Smart Inbox, Settings, Notifications, details.
- **Phase 4 — entry flows**: onboarding / auth / setup (kept more cinematic; fix accidental oversizing only).
- **Phase 5 — final audit**: hardcoded oversized values, Arabic/English, light/dark, device sizes, text scaling, scroll depth, sheets+keyboard.

---

## 5. Accessibility guardrails
- Interactive hit area ≥ 44–48px even when the visual is smaller (wrap compact visuals in adequate tap targets; buttons stay ≥ 48/46).
- Preserve Arabic readability & line-height (`height` kept on type tokens; do not drop below current line-heights).
- Do NOT fix overflow by disabling text scaling. Keep `MediaQuery` textScaler behavior.
- Maintain contrast (unchanged colors), focus/selected states, screen-reader semantics, reduced-motion.
- Test with larger system text — content must remain usable.

## 6. Performance guardrails
- Preserve lazy list building & pagination; no `shrinkWrap` added to large data lists.
- Preserve reload-safe async (`skipLoadingOnReload`, `dataOrWhen`).
- No new expensive layouts (avoid `IntrinsicHeight`/`IntrinsicWidth` on large subtrees).
- RTL preserved.

## 7. Testing plan (after each phase)
`flutter analyze` (0 issues) · `flutter test` (green; onboarding-animation timer flake is pre-existing) ·
targeted widget tests · light/dark review · RTL review · Arabic+Latin+numbers+% overflow check at 360/390px.
Density checks: items-visible-before-scroll ↑, page height ↓ ~25–35%, hierarchy clearer, touch targets intact, nothing cramped.

## 8. Risks
- Token value changes ripple app-wide → a screen may look tight before its Phase-2/3 pass. Mitigation: conservative Phase-0 values, staged review.
- Row/card padding cuts could clip Arabic descenders → keep line-height, verify at small widths.
- Nav shrink could hurt tap accuracy → keep ≥48px hit area inside the 54px bar.
- Changing shared `buttonHeight`/input padding affects non-sheet forms too → intended, but review light mode.

## 9. Components that intentionally stay spacious
- The single hero per screen (balance, period total, account balance, transaction amount).
- Onboarding / auth / setup identity (cinematic; only fix accidental oversizing).
- Accent/insight flagship cards (restrained large radius + gradient) — density applies, identity kept.
- Rings/donut on dedicated report/detail screens (compact elsewhere).

## 10. Product decisions requiring approval
1. **Page horizontal padding 24 → 20** (mockup value). OK?
2. **Button height 56 → 50** app-wide (still ≥48). OK, or keep 52?
3. **Sheets stay always-dark** (current architecture) vs. follow light mode — out of scope here.
4. **Expense amount tint in add-sheet** (red) vs. neutral — currently follows mockup (colored).
5. Whether Settings dense rows should drop card grouping entirely (Phase 3 decision).
