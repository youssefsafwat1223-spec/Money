# Mali — Current Visual System

> Read-only extraction of the live design tokens and visual behavior.
> Sources: `lib/core/theme/*` and per-feature hardcoded values. Paths relative to `app/`.

---

## Colors — `lib/core/theme/app_colors.dart`

`AppColors` is a `ThemeExtension`; read via `context.colors`. Palette is **"Bahama Blue" fintech**.

### Light
| Token | Hex | Role |
|---|---|---|
| `bg` | `#F4F7FA` | cool grey canvas |
| `surface` | `#FFFFFF` | cards/sheets |
| `surface2` | `#EAF0F5` | secondary fill / input fill |
| `primary` | `#062635` | **brand text / dark navy** — *not for interactive elements* |
| `cta` | `#006B8F` | buttons, links, interactive (Material seed color) |
| `accent` | `#2F80A8` | accents / AI |
| `success` | `#0F9F6E` | positive/credit |
| `warning` | `#E06F4F` | warning (80% budget) |
| `danger` | `#D93D54` | negative/debit/destructive |
| `textMain` | `#062635` | primary text |
| `textSec` | `#64748B` | secondary text |
| `textLight` | `#94A3B8` | hints/metadata |
| `border` | `#D7E1E8` | hairlines |
| `gradA/gradB` | `#006B8F` / `#062635` | legacy `primaryGradient` |

### Dark
| Token | Hex | Role |
|---|---|---|
| `bg` | `#01070C` | near-black canvas |
| `surface` | `#06131C` | cards/sheets |
| `surface2` | `#0B1C29` | secondary fill |
| `primary` | `#FFFFFF` | **white brand text** ⚠️ (mis-used as button bg → invisible white buttons) |
| `cta` | `#1A8DB0` | interactive |
| `accent` | `#4DA3C7` | accents/AI |
| `success` | `#28C99B` | positive |
| `warning` | `#FF8A65` | warning |
| `danger` | `#FF6B73` | negative/destructive |
| `textMain` | `#FFFFFF` | text |
| `textSec` | `#A8B7C4` | secondary |
| `textLight` | `#6F8190` | hints |
| `border` | `#193044` | hairlines |
| `gradA/gradB` | `#0A2833` / `#01070C` | legacy gradient |

- Helper: `budgetState(ratio)` → `danger` ≥1.0, `warning` ≥0.8, else `success`.
- Theme seeds Material `ColorScheme.fromSeed(seedColor: c.cta)` so chips/switches/progress stay blue (not navy). `splashFactory: NoSplash`.

### ⚠️ Color inconsistencies (key findings)
1. **`primary` is white in dark mode** but is used as a `FilledButton` background in several places → invisible buttons in dark mode (multiple fixed to `c.cta`; audit the rest). Token doc literally warns "do not use for interactive elements."
2. **Hardcoded blues bypass tokens.** `AppGradients` and `AppShadows` use `#006B8F / #073B50 / #062635 / #034F73`; the bills hero uses `#046E9B / #034E73 / #012438`; onboarding preview uses `#050A12 / #060D19`. These don't all equal `c.cta`/`c.accent` → drift between "token blue" and "gradient blue".
3. `AppInsightType.ai` comment says "amber tint" but maps to `c.accent` (blue) — stale intent from a previous palette.

---

## Typography — `lib/core/theme/app_typography.dart`

- Dual font: **Inter** (Latin/numbers) with fallback **IBM Plex Sans Arabic**, then **Alexandria** (emergency). All via `google_fonts`.
- Named styles (size / weight / line-height):
  - `amountHero` 40/w800/1.10 (tabular, -0.5 tracking), `amountMedium` 24/w700/1.20, `amountSmall` 18/w600/1.25
  - `display` 32/w800/1.18, `title1` 24/w700/1.25, `title2` 20/w600/1.30, `headline` 18/w600/1.35
  - `body` 16/w400/1.50, `bodyStrong` 16/w600/1.50, `callout` 15/w400/1.46, `subhead` 14/w600/1.43, `footnote` 13/w400/1.38, `caption` 12/w500/1.33
- `textTheme()` maps these into Material slots.
- **Notes:** generous line-heights (good for Arabic). Tabular figures only on amounts. **Inconsistency:** several screens build their own `_alex(...)` helper (onboarding, method, goals, budgets) that re-creates the same font stack instead of using `AppTypography` — parallel typography systems.

---

## Radius — `lib/core/theme/app_spacing.dart` (`AppRadius`)

`sm 8` · `md 16` · `lg 18` · `card 24` · `cardLg 32` · `pill 999` · `button 16` · `nav 28`.
- **Inconsistency:** sheets use a literal `28` radius in several places instead of a token; cards mix `card (24)` and `cardLg (32)`.

---

## Spacing — `AppSpacing` (4pt base)

`s1 4 · s2 8 · s3 12 · s4 16 · s5 20 · s6 24 · s7 32 · s8 40 · s9 48 · s10 64`; `gutter 24`; `cardPadding 20`.
- Widely used and consistent — the strongest part of the token system.

---

## Shadows — `lib/core/theme/app_shadows.dart`

- `card` (0x0A black, blur 8, y2) · `float` (0x14, blur 20, y8) · `nav` (0x0D, blur 30, y10) · `cta` (**0x33006B8F** — hardcoded blue, y4).
- **Inconsistency:** `cta` shadow color is a hardcoded blue (not `c.cta`); many feature cards define their own `BoxShadow` inline instead of using these.

---

## Gradients — `lib/core/theme/app_gradients.dart`

- `heroHeader` (`#062635→#073B50→#01070C`) — used by `SectionHeroHeader`.
- `walletCard`, `ctaBlue`, `darkSurface`, `aiPremium` (`#4DA3C7→#006B8F`, renamed from `aiAmber`).
- Plus `AppColors.primaryGradient` (gradA→gradB).
- **Inconsistency:** at least 4 different blue gradient definitions across `AppGradients`, `primaryGradient`, the bills hero, and the method/onboarding heroes — no single "brand gradient."

---

## Icons

- Primary set: **`AppLucideIcons`** (`lib/core/utils/app_lucide_icons.dart`) — a local subset wrapper over the lucide font (zap, lock, globe, wallet, target, receipt, repeat, etc.).
- **Mixed with Material icons** in many places (`Icons.bar_chart_rounded` in the bottom bar, `Icons.add`, `Icons.calendar_month_outlined`, `Icons.chevron_*`). No single icon language.
- Flags: SVG via `flutter_svg` from `assets/flags/{code}.svg` (`_FlagAvatar`). Brand logos: `assets/brand(s)/` via `BrandMark`.
- Logo: `AppAssets.logoLight/logoDark` (PNG) + `MaliLogo` widget.

---

## Animation style — `lib/features/common/motion.dart`

- `AnimatedAmountText` (count-up amounts), `PremiumMotion` (staggered entrance, `delay`-based), used in dashboard/settings/reports.
- `flutter_animate` is in the stack. Durations seen: 180ms (tabs/selection), 250ms (bottom bar slide), 380/280ms (route transitions in `app_router`).
- Respects `MediaQuery.disableAnimations` in celebration timing.
- **Inconsistency:** entrance animations applied on some screens (settings, reports) but not others; no global motion spec.

---

## Chart style — `lib/features/common/charts/spending_charts.dart`

- `fl_chart` based; used by dashboard analytics + reports.
- Static (no tap/scrub), colors partly defined inside the chart file.
- **Opportunity:** tokenize colors, add interaction, unify legends.

---

## Dark mode behavior

- Full dual palette via `AppColors.light/dark` + `ThemeMode` (`theme_mode_provider.dart`, persisted in `user_settings`, instant override).
- `_ThemeTile` segmented control (تلقائي/فاتح/داكن) in Settings.
- True-near-black bg (`#01070C`), white text, blue CTA.
- **Risks:** (1) `c.primary`=white misuse; (2) hardcoded light-leaning shadows (`0x0A000000`) are barely visible on near-black — depth relies on borders in dark; (3) hardcoded gradient hexes don't adapt to mode (e.g., bills hero is the same dark blue in light mode).

---

## Arabic / RTL behavior

- Arabic-first; UI strings are largely **hardcoded Arabic** in widgets (Egyptian/Gulf dialect mix), with l10n ARB (`app_ar.arb`, `app_en.arb`) used mainly in onboarding/auth.
- RTL handled by wrapping sheets/rows in `Directionality(textDirection: rtl)` and forcing the bottom bar to RTL; directional icons swap via `Directionality.of(context)`.
- `MediaQuery.textScaler` clamped to **0.8–1.25** in `app.dart` (accessibility scaling capped).
- **Inconsistencies:** (1) many strings not in ARB → English locale is incomplete; (2) `Directionality(rtl)` is re-applied per-sheet rather than relying on a global locale/directionality — repetitive and error-prone; (3) mixed Western/Arabic-indic digits handled ad hoc (e.g., grounding check, formatters).

---

## Token-system health summary

- **Strong:** spacing scale, typography scale (when used), dual-mode color tokens, semantic helpers (`budgetState`, `AppMetricStyle`).
- **Weak / drifting:** multiple parallel blue gradients & hardcoded hexes; `c.primary` misuse; per-screen `_alex` typography clones; literal radii (28) and inline `BoxShadow`s; mixed icon families; incomplete l10n; non-tokenized chart colors.
