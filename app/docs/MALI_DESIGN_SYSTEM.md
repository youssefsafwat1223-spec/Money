# Mali — Flagship Design Language ("هدوء / Calm Capital")

Status: **approved with adjustments (see §0). P0+P1 in progress.** This evolves
the existing system, it does not replace it.

## 0. Approved adjustments (this revision)

1. **No arbitrary health score.** The ring's first real use is a concrete,
   explainable metric (Safe to Spend / budget safety / committed-vs-available),
   surfaced as plain language ("وضعك مستقر", "مصروفك أعلى من المعتاد",
   "التزاماتك تستهلك نسبة كبيرة من دخلك"), not a 0–100 score. A true health
   score is deferred until its model and drivers are defined.
2. **Accent gradient approved, restrained.** True-black canvas stays dominant.
   Gradient is reserved for AI insight, selected states, subtle glows, and a
   small number of flagship moments — **the hero balance stays directly on
   canvas**, never inside a gradient card.
3. First viewport prioritizes breathing room over fitting a fixed block count;
   balance / today's change / attention / Safe-to-Spend are the candidates, not
   a mandate.
4. `/design` gallery is debug-only, unreachable in release builds.
5. `w800`/`display()`/`amountHero()` are **not retired** — confirmed in use
   across 28 files / 53 call sites. New calm tokens are added alongside; any
   migration is a separate, intentional, screen-by-screen decision later.
6. Mixed-currency typography (Arabic + Latin + tabular figures + RTL, e.g.
   `"25,420 EGP"` / `"48,250.00 ج.م"`) is exercised together in the gallery.
7. `AttentionCard` will carry strict single-item priority rules when it's
   built (P2) — never a stack of alerts.
8. Safe-to-Spend will define an explicit incomplete-data fallback when it's
   wired (P3) — the `RingProgress` primitive already accepts a nullable value
   for this (neutral/indeterminate render), decided in P1.

### Corrections found during implementation research
- **Font is IBM Plex Sans Arabic / IBM Plex Sans** (`google_fonts`), not SF
  Pro — SF Pro isn't available via Google Fonts / isn't the app's brand font.
  The calm type tokens below use the existing `AppTypography.custom()`.
- **The live app currently renders on a single light theme**
  (`AppTheme.light`, bg `#F6F7FB`) — `app.dart` has an uncommitted diff that
  already stripped a previous mesh-gradient/dark setup. So "true-black canvas"
  is not the *ambient* app theme today. Resolution: `MaliScreen` paints its
  own explicit black canvas (the same pattern `onboarding/story_screen.dart`
  already uses locally), independent of the ambient theme — this delivers the
  approved identity without touching global `ThemeData` or any existing
  screen. Flagged here rather than assumed silently.
- **Token home reconsidered:** `AppColors` is a `ThemeExtension` with exactly
  one wired instance (`.light`); adding dark-only fields to it would be dead
  code today. The new canvas/surface/accent system instead lives in a
  standalone `lib/core/theme/mali_tokens.dart` (`MaliTokens`), used explicitly
  by Mali-prefixed primitives. `AppColors` semantics (income/expense/warning)
  are reused as-is for continuity, not duplicated.
- **Reveal/CountUp already exist** — `PremiumMotion` (staggered entrance,
  reduced-motion aware, play-once so rebuilds never replay it) and
  `AnimatedAmountText` (count-up, same reduced-motion handling) in
  `lib/features/common/motion.dart`. P1 reuses both rather than adding
  parallel `Reveal`/`CountUpText` widgets.

## Context

The dashboard today is functional but reads as a stack of near-identical white
rectangles — every section looks the same weight, so nothing feels important.
The goal is a **flagship, timeless** fintech surface that (a) keeps the current
dark-luxe identity and all live data wiring, (b) reorganizes the Home screen
around *importance*, not feature groups, and (c) replaces "another card" with a
small set of **distinct section archetypes**. The output is a **reusable design
system** every future screen inherits — not a one-off redesign.

Grounded in what already exists: `app_spacing.dart` (s1–s10, page=24, section=32,
card=20), `app_shadows.dart` (card / elevatedCard / floatingNav / ctaGlow),
`app_typography.dart` (tabular amount styles + display/title/body scale),
`app_motion.dart` (fast/normal/slow + curves + count-up), `AppColors` extension
(light+dark), `app_gradients.dart`, and `widgets/premium_glass_container.dart`.

## Design ethos — "Calm money"

Three principles that decide every pixel:
1. **One thing matters most.** The screen has a single hero truth; everything
   else is quieter. Hierarchy through *size, space, and stillness* — not color.
2. **Surfaces have depth, not decoration.** Elevation is expressed by surface
   lightness + soft ambient glow on the true-black canvas, never busy borders.
3. **Motion is breath, not spectacle.** Content settles in; numbers count up;
   the hero has a slow parallax. Nothing bounces for attention.

Identity that is *not* Apple-Wallet: Mali leads with a **large typographic
balance "statement"** (no card around it), a **financial-health ring** as the
emotional anchor, and a **ledger timeline** rather than a list of receipts.

---

# 1. Design tokens (evolved)

### 1.1 Surface hierarchy (the fix for "repetitive cards")
Four canonical depths on the true-black canvas. Sections pick a depth by
*importance*, so they stop looking identical.

| Token | Dark value (approx) | Use |
|---|---|---|
| `canvas` | `#000000` + top radial glow | screen background |
| `surfaceRaised` | white @ 4% over canvas | quiet grouping (lists) |
| `surfaceFloating` | white @ 7% + ambient shadow | standard card |
| `surfaceGlass` | blur(24) + white @ 8% stroke | selector, nav, overlays |
| `surfaceAccent` | blue→indigo gradient | hero / insight only |

Reuse `AppColors` extension: add `canvasGlow`, `surfaceRaised`,
`surfaceFloating`, `strokeSoft`. Keep existing `income`/`expense`/semantics.

### 1.2 Color
- Keep true-black base + white primary (do **not** revert to teal/blue theme).
- **Accent**: refine the existing blue into a 2-stop accent gradient for hero &
  insight surfaces only (restraint = premium). Everything else is monochrome.
- Semantics unchanged: income green, expense red, warning amber, muted greys.
- Data viz palette (new, muted): 5 desaturated hues for category charts.

### 1.3 Elevation & shadows — evolve `AppShadows`
On dark, a drop shadow is nearly invisible, so elevation = **surface lightness +
a soft outer glow**. Add:
- `AppShadows.floatSoft` = ambient `y8 blur28 4%` + key `y2 blur8 6%`.
- `AppShadows.heroGlow` = colored blue glow `y16 blur48 22%` (hero only).
Keep `floatingNav`. Retire harsh single shadows on cards.

### 1.4 Radius
Add one token: `AppRadius.xxxl = 32` (hero + flagship surfaces). Keep
`xs4/sm8/md12/lg16/xl20/xxl28/pill`. Cards use `xxl(28)`, hero uses `xxxl(32)`.

### 1.5 Spacing — reuse as-is
`page = 24`, `section = 32`, `card padding = 20/24`, list gap = 12, 8pt rhythm.
Add `heroPadding = 28`. No new scale.

### 1.6 Typography — cap the weight, tighten the big numbers
Current scale is good but tops out at **w800 (too heavy for "premium calm")**.
Evolution:
- Retire w800. Display/amount hero → **w600–w700 max**, with **tighter tracking
  (-2% to -3%)** on 32px+ numbers. Keep tabular figures (already present).
- Add `AppTypography.balanceHero` (52, w600, -3% tracking, tabular) for the Home
  statement; `amountHero` (40→ keep for cards).
- Body 16/400, subhead 14/600, caption 12/500 unchanged.
- Arabic: system SF Arabic on iOS (San Francisco), generous line-height.

### 1.7 Motion — reuse `AppMotion`, add principles
Use existing durations/curves + `flutter_animate` (already a dep):
- **Reveal**: sections stagger up 12px + fade, 60ms apart, `emphasizedCurve`.
- **Hero**: `numberCountUp` (650ms) on balance; slow parallax on scroll.
- **Press**: `buttonPress` scale 0.97.
- **Reload-safe by rule**: every async widget uses `valueOrNull`/`dataOrWhen`
  (from `core/utils/async_reload_safe.dart`) — no placeholder flashes. (Locks in
  the flicker fixes we just made as a *system rule*.)

### 1.8 Iconography
`lucide_icons` (already used), single stroke weight (~1.6), rounded caps,
monochrome — accent blue only for active/primary. No filled icons.

---

# 2. Component library (reusable primitives + section archetypes)

### 2.1 Primitives (`lib/core/theme/widgets/` + `lib/features/common/`)
- `MaliScreen` — gradient/glow canvas + safe-area + parallax scroll host.
- `MaliCard` — surfaceFloating, r28, `floatSoft`, optional accent gradient.
- `GlassSurface` — wrap/extend existing `premium_glass_container`.
- `SectionHeader` — title (title2) + optional trailing action; consistent 8pt.
- `RingProgress` — CustomPainter arc (health + budgets).
- `Sparkline` / `MiniBars` — CustomPainter, no fl_chart weight for tiny charts.
- `CountUpText` — animated tabular number.
- `Reveal` — staggered entrance wrapper (thin over flutter_animate).
- `BrandMark` — reuse existing for subscription logos.

### 2.2 Section **archetypes** (each visually distinct — the anti-"white box")
| Archetype | Visual pattern | Screen use |
|---|---|---|
| **HeroStatement** | large type on canvas (no card), sparkline, trend | balance |
| **PulseRow** | inline chips: today's in/out/net | "what changed today" |
| **AttentionCard** | amber-accented, appears only if action needed | alerts |
| **HealthRing** | big ring + one-line verdict | financial health |
| **InsightCard** | accent-gradient surface, AI voice | AI insight |
| **LedgerTimeline** | day-grouped rows with a spine, not a boxed list | transactions |
| **ProgressRail** | 3 rings in a row on raised surface | budgets |
| **RailCarousel** | horizontal snap cards | subscriptions |
| **GoalOrbit** | single goal, ring + progress bar | goals |
| **OfferBanner** | gradient + illustration | offers |
| **GlassNav** | frosted floating bar + center action | bottom nav |

Every archetype composes the primitives; each is a widget with a `data` input,
wired to existing providers (`dashboardDataProvider`, `budgetsViewProvider`,
`subscriptionsProvider`, `goalsListProvider`, `transactionsListProvider`).

---

# 3. Dashboard information architecture (reordered by importance)

Answers the 4 questions top-to-bottom; secondary content sinks below the fold.

```
1. HeroStatement      → "How much do I have?"   (balance + trend + sparkline)
2. PulseRow           → "What changed today?"   (in / out / net today)
3. AttentionCard*     → "Anything to handle?"   (*only renders if needed)
4. HealthRing         → "How healthy am I?"     (score + verdict + drivers)
   ── fold ──
5. InsightCard        → the AI voice
6. LedgerTimeline     → recent activity (compact, 3–4 rows)
7. ProgressRail       → budgets
8. RailCarousel       → subscriptions
9. GoalOrbit          → top goal
10. OfferBanner       → contextual offer
+ GlassNav (persistent)
```

Rules: the top 4 blocks own the first screen and *breathe* (big margins).
`AttentionCard` and `OfferBanner` are conditional — no empty states shown.

---

# 4. Widget tree (Home)

```
MaliScreen (canvas + glow + parallax CustomScrollView)
├─ SliverAppBar (transparent, greeting + GlassSurface accountSelector + avatar)
├─ Reveal( HeroStatement( balance, trend, Sparkline, privacyMode ) )     ← valueOrNull
├─ Reveal( PulseRow( todayIn, todayOut, net ) )
├─ if(alerts) Reveal( AttentionCard(...) )
├─ Reveal( HealthRing( score, verdict, drivers ) )
├─ Reveal( InsightCard( insight ) )
├─ Reveal( Section( "آخر العمليات", LedgerTimeline(recent) ) )
├─ Reveal( Section( "الميزانية", ProgressRail(budgets) ) )
├─ Reveal( Section( "الاشتراكات", RailCarousel(subs) ) )
├─ Reveal( Section( "الأهداف", GoalOrbit(goal) ) )
├─ if(offer) Reveal( OfferBanner(offer) )
└─ (GlassNav lives in AppShell, not the scroll)
```

All data via the existing Riverpod providers; all async reads via
`dataOrWhen`/`valueOrNull`; no `invalidate` on hot providers.

---

# 5. Implementation phases

- **P0 — Tokens (no UI change yet).** Extend `AppColors` (surface hierarchy),
  `AppShadows` (floatSoft/heroGlow), `AppRadius` (xxxl), `AppTypography`
  (balanceHero, retire w800). Gate: analyze + existing tests still green.
- **P1 — Primitives.** `MaliScreen`, `MaliCard`, `SectionHeader`, `RingProgress`,
  `Sparkline`, `CountUpText`, `Reveal`, `GlassSurface`. Each with a widget test +
  a `/design` gallery route to eyeball them.
- **P2 — Archetypes.** Build the 11 section archetypes against the gallery with
  mock data (pure presentation, no providers yet).
- **P3 — Home assembly.** Recompose `dashboard_screen.dart` per the IA, wiring
  archetypes to live providers; keep the reload-safe patterns.
- **P4 — Motion + GlassNav.** Staggered reveal, hero parallax/count-up, frosted
  nav + center action in `app_shell.dart`.
- **P5 — Roll the system outward** (later): apply primitives to Reports,
  Accounts, Transactions so the language is app-wide.

### Verification (each phase)
`flutter analyze` (0 issues) + `flutter test`, then run on the iPhone to judge
glass/shadow/RTL fidelity (visual quality can't be asserted in tests). A hidden
`/design` gallery route lets us review primitives in isolation before assembly.

### Guardrails
- Presentation-only: **no changes to providers, sync, or data**.
- `BackdropFilter` capped to selector + nav (GPU cost).
- SF Pro = iOS system font; Android falls back (iOS-first flagship — accepted).
- Ship behind the existing Home, screen-by-screen; nothing else regresses.
