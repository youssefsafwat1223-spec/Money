# Mali — Visual Direction

> The final visual direction for Mali's redesign. Synthesizes `reference_analysis_payvo.md`,
> `docs/design_audit/*`, `screen_by_screen_redesign_spec.md`, and `implementation_safety_contract.md`.
> Documentation only — no code. Mali keeps its **own identity**; Payvo informs *principles*, not pixels.
> Mali = Arabic-first, RTL/LTR, dark/light, on-device expense tracking + AI assistant. Not a bank.

---

## A. New Mali identity

Mali should feel:
- **Premium** — deep, calm canvas; one confident accent; big, clear money numerals; generous space.
- **Calm** — quiet surfaces, few dividers, restrained color; nothing competes with the user's data.
- **Smart** — AI presence is felt through clarity and gentle confidence cues (categorization, smart
  inbox), never through gimmicks.
- **Trustworthy** — high legibility, honest numbers, visible privacy + on-device/security messaging.
- **Financially clear** — hierarchy always answers "how much, what, when" instantly; amounts are
  tabular and unmistakable; debit/credit color-coded.
- **Human-crafted** — a consistent token + component system, intentional focus devices (one inverted
  card), real merchant logos, and Arabic typography that's clearly cared for.
- **Not AI-generated** — no random gradients, no decorative noise, no inconsistent spacing; every choice
  is systemic.
- **Not a generic fintech clone** — Mali's hue, its Arabic-first soul, the Smart Inbox, and the
  capture-from-SMS loop are the personality. No banking cosplay.

**One-line vision:** *A calm, premium Arabic-first money companion where your transactions are the hero,
the AI quietly does the sorting, and every screen reads in two seconds.*

---

## B. Design principles (10, strict)

1. **One accent, scaled by tints.** A single Mali accent + a tonal ladder + neutrals. No second hero
   color, no competing gradients. (Kills the audit's "4+ blue gradients".)
2. **Money is the hero.** The most important number on any screen is the largest, most contrasted
   element; everything else is support.
3. **Tokens or it doesn't ship.** Every color, gradient, type style, radius, shadow, and motion value
   comes from `lib/core/theme/*`. No literals in feature code (safety contract §4–6).
4. **Clarity over decoration.** If an effect doesn't improve comprehension or trust, remove it. No
   glows, gloss, or 3D in functional screens.
5. **Arabic-first, RTL-true.** Layouts are designed in RTL and verified in LTR — never the reverse.
   Numerals, alignment, nav order, chart axes all mirror correctly.
6. **One way to do each thing.** One header, one card, one button family, one sheet scaffold, one row,
   one chip, one badge — shared components only (safety contract §7–8).
7. **Calm density.** Space and weight create hierarchy; dividers are the exception. Generous gutter and
   inter-section rhythm.
8. **Focus by inversion, not noise.** Draw attention with exactly one elevated/inverted element per
   surface (Smart Inbox item, next-due bill), not with color spam.
9. **Trust is visible.** On-device processing, encryption, AI consent, and privacy toggles are surfaced,
   not buried.
10. **Dark-mode is a first-class mode.** Validate contrast in both modes every phase. `c.primary` is
    never a blind button background (it's white in dark) — interactive = `c.cta`, contrast-checked.

---

## C. Final visual system direction

> Direction only — exact hex tuning happens in the Phase-1 token PR. Mali **keeps its hue family**
> (do not adopt Payvo `#5389FF`). The note below is how each token category should evolve.

- **Colors** (`lib/core/theme/app_colors.dart`)
  - Keep the dual `AppColors` ThemeExtension + `context.colors`. Keep near-black dark `bg` (`#01070C`)
    and cool-grey light `bg` (`#F4F7FA`).
  - Define **one** accent (`cta`) per mode and a small tint ladder (`cta`, `ctaSoft`, `ctaTintBg`) so
    "accent at 12%/20%/100%" is tokenized instead of `withValues(alpha:)` everywhere. Mali's accent may
    be brightened for dark-mode vibrancy but must remain Mali's blue-teal identity, not Payvo's royal.
  - Keep semantic `success`/`warning`/`danger`; keep `budgetState(ratio)`.
  - **Fix:** `primary` stays brand-text only (white in dark) and is banned as a button background.
- **Gradients** (`lib/core/theme/app_gradients.dart`)
  - Collapse all blues into **one brand gradient set**: `brandHero` (headers), `walletCard`, `aiSubtle`.
    Remove the bills hero hardcoded blues and the onboarding preview literals; route them to tokens.
  - Gradients must read correctly in light AND dark (no fixed dark-blue showing in light mode).
- **Typography** (`lib/core/theme/app_typography.dart`)
  - Keep Inter + IBM Plex Sans Arabic (Arabic-first) — borrow Payvo's *feel* (humanist, tabular money),
    not Mulish. Tabular figures on all amounts. **Delete all per-screen `_alex()` clones** as touched.
  - Confirm the scale: `amountHero/amountMedium/amountSmall`, `display/title1/title2/headline`,
    `body/bodyStrong/callout/subhead/footnote/caption`. Add a style only by adding to `AppTypography`.
- **Spacing** (`AppSpacing`) — keep the 4pt scale (strongest part of the system); `gutter 24`,
  inter-section `s5/s6`, intra-card `s3/s4`. Adopt consistently (some screens under/over-pad today).
- **Radius** (`AppRadius`) — standardize: cards `card(24)`/`cardLg(32)`, pills `pill`, inputs/buttons
  `button(16)`, nav `nav(28)`. **Remove literal `28`** in sheets → use a token via `SheetScaffold`.
- **Shadows** (`AppShadows`) — use `card/float/nav` tokens; **fix `cta` shadow hardcoded blue** → token.
  In dark mode rely on borders + a faint accent glow (black-on-black shadows are invisible).
- **Cards** — `AppCard` is the base; merged `ProgressItemCard` for budgets/goals/bills; selective
  white/elevated variant for the single focus item. No bespoke card containers.
- **Buttons** — `AppButton`/themed `FilledButton` (bg `cta`, 56px, radius `button`); pill action button
  with leading circular icon for primary actions; `IconCircleButton` for round icon actions. Ban
  `c.primary` backgrounds.
- **Headers** — one `AppHeader` (flat + `brandHero` gradient variants; title/subtitle/metrics/actions/
  back), via `AppScreenScaffold`. Retire the 3 current header styles.
- **Bottom navigation** — keep the floating pill; sharpen the active node (filled accent circle), unify
  icons to lucide, consider a center capture "+". Direction-aware order.
- **Sheets/modals** — one `SheetScaffold` (RTL, drag handle, max-height, scrollable, optional blur,
  tokenized radius). All ~20 sheets adopt it.
- **Transaction rows** — `AppTransactionRow` only (retire legacy `TransactionRow`); brand avatar + title
  + date caption + tabular amount (debit `danger` / credit `success`) + AI/pending `AppBadge`.
- **Charts** — `ChartCard` wrapping `spending_charts.dart`: rounded soft bars with the current period
  highlighted, smooth line with end-dot, optional radial gauge for budget/goal health; tokenized accent
  scaled by intensity; faint gridlines; interactive (tap to filter) where feasible.
- **Empty states** — `AppEmptyState` everywhere (icon + title + subtitle + optional CTA), consistent
  placement; the bills "example" becomes an empty variant.
- **Loading states** — `PremiumSkeletonPage` shaped per screen; retire raw spinners.
- **Icons** — one family (lucide via `AppLucideIcons`); consistent stroke; rounded-tile treatment for
  category/nav. Replace stray Material icons.
- **Illustrations** — minimal, on-brand line/flat marks for empty/onboarding; **no stock photography or
  3D renders** in product screens. Flags (SVG) and merchant logos (`BrandMark`) stay.
- **Motion** (new `lib/core/theme/app_motion.dart` constants) — durations (fast 120 / base 250 /
  slow 380), standard curves (easeOutCubic), `PremiumMotion` staggered entrances, `AnimatedAmountText`
  count-up, chart draw-in, skeleton shimmer, success/error via the shared banner. Respect
  `disableAnimations`.

---

## D. Payvo → Mali adaptation map

| Mali area | Payvo inspiration | How to adapt (Mali-specific) |
|---|---|---|
| **Dashboard** | balance hero + change pill + inline "Financial Health" chart + floating nav | Make Mali's **spend/balance** the hero with `amountHero` + a period-change pill; inline `ChartCard` (top categories + trend). **No** Send/Received/Transfer-List. Account switcher = a visible control (not hidden swipe). Per-currency, no FX. RTL: title right, amounts trailing. |
| **Smart Inbox** | the selective **white card** focus + clean list rows | This is Mali's signature. One elevated/inverted "needs review" card with AI-confidence cue; inline approve/fix. Consolidate the 3 fragmented surfaces. No banking actions. |
| **Transactions** | brand-avatar list, airy rows, amount right-aligned, big page title | Use `AppTransactionRow` + `BrandMark`; one filter chip row; single date control → range sheet. Keep status (pending/confirmed) which Payvo lacks (Mali is review-centric). RTL amount alignment. |
| **Budgets** | radial gauge / bar intensity for "health" | `ProgressItemCard` with ring/bar colored by `budgetState` (success/warning/danger). Borrow the gauge *style* for budget health, not banking. |
| **Reports** | metric-with-evidence cards + soft line/bar charts | `AppMetricCard` + `ChartCard`; tap a slice → filtered transactions. Borrow the "big number + tiny chart + short label" pattern. Consistent name (التقارير/الرؤى — pick one). |
| **Goals** | progress visuals, premium feel | `ProgressItemCard` progress ring (rebrand `VaultWidget` to match flat system); per-goal currency; celebrate milestones via shared banner. |
| **Accounts/Cards** | the light-gradient premium card + balance eye-toggle | A tasteful `walletCard` token gradient for the card visual + privacy eye. **No** VISA/banking chrome implying Mali issues cards; cards here = the user's own cards detected from SMS. |
| **Onboarding** | bold hero, clean auth, identity rigor | Calm stepped onboarding (country/currency → DOB → capture setup); on-brand hero gradient (token); no stock photos. Country/currency-aware. |
| **Auth/Backup** | clean auth tabs, "money's safe space" trust framing | Mali auth = Apple/Google/email/guest; elevate the **on-device + E2E encryption** trust story (Mali's real differentiator) as a visible panel, not marketing fluff. |
| **Settings** | quiet grouped lists, icon tiles, profile header | `AppHeader` profile variant + grouped `AppCard` sections; extract category CRUD to its own screen. Trust panel for privacy/security. |
| **iOS Shortcut flow** | n/a in Payvo — Mali-unique | Keep guided; borrow Payvo's *clarity* (numbered steps, calm cards, clear success state "متصل ✓"). This is Mali's hardest flow; make it the most reassuring. |

---

## E. Anti-copy rules (explicit)

- **Do NOT copy Payvo screens** — no 1:1 layout reproduction of any Payvo screen.
- **Do NOT copy Payvo branding** — name, wordmark, tone, marketing copy.
- **Do NOT copy the Payvo logo** — the circular "sunset/ripple over water" mark, in any variation.
- **Do NOT copy Payvo text** — headlines, labels ("Change the way you money", "Your money's safe
  space"), microcopy.
- **Do NOT clone exact layouts** — borrow *principles* (one accent, money-hero, selective inversion,
  floating nav), recompose for Mali's content and RTL.
- **Do NOT turn Mali into a banking app** — no money movement, transfers, send/receive, pay-now,
  people-to-pay, card issuance, or any feature Mali doesn't actually have.
- **Do NOT add fake banking features** — only design for Mali's real features (Smart Inbox, capture,
  categorization, budgets, insights, reports, goals, accounts/cards, onboarding/auth/backup).
- **Do NOT prioritize decoration over clarity** — no 3D renders, stock photography, glows, or
  glossy/skeuomorphic effects in functional screens; legibility (esp. Arabic) and trust come first.
- **Do NOT adopt Payvo's exact palette/font as Mali's identity** — keep Mali's hue family and
  Arabic-first type stack; borrow only the discipline (single accent, tabular numerals, humanist feel).
