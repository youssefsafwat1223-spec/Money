# Phase 1 Reference Tokens Report

Date: 2026-06-24

Result: PASS

Scope: Phase 1 Design Tokens only. No screens, shared components, providers, routes, business logic, data/domain/engine code, parser, AI categorization, auth, backup, Supabase, or capture bridge files were modified.

## Inputs Read

- `docs/design_reference/mali_reference_analysis.md`
- `docs/design_reference/mali_visual_adaptation_spec.md`
- `docs/design_reference/mali_screen_migration_plan.md`
- `docs/design_reference/mali_codex_execution_guardrails.md`
- `docs/redesign/phase_0_6_clean_head_repair_report.md`
- `docs/redesign/phase_0_6_clean_head_repair_self_review.md`

## Pre-Check

Working tree before token work: clean.

Recent baseline commits:

```text
47461575 docs: baseline Mali visual reference migration
7ab9556a fix(ui): repair clean-head build errors before reference migration
```

Stashes before and after Phase 1:

```text
stash@{0}: On feat/accounts-multicurrency: backup: dirty tree before Mali reference Phase 1 tokens
stash@{1}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

Pre-work gates:

```text
flutter analyze: PASS - No issues found.
flutter test: PASS - 241 tests passed.
flutter build macos --debug: PASS - built money_companion.app.
```

## Files Changed

```text
app/lib/core/theme/app_colors.dart
app/lib/core/theme/app_gradients.dart
app/lib/core/theme/app_spacing.dart
app/lib/core/theme/app_shadows.dart
app/lib/core/theme/app_typography.dart
app/lib/core/theme/app_motion.dart
app/lib/core/theme/app_theme.dart
docs/redesign/phase_1_reference_tokens_report.md
docs/redesign/phase_1_reference_tokens_self_review.md
```

No icon token alias changes were needed in:

```text
app/lib/core/utils/app_lucide_icons.dart
app/lib/core/utils/lucide_icon_map.dart
```

## Existing Token APIs Preserved

Backward-compatible names used by current screens were preserved:

```text
AppColors.bg
AppColors.surface
AppColors.surfaceElevated
AppColors.surface2
AppColors.primary
AppColors.onPrimary
AppColors.cta
AppColors.onCta
AppColors.ctaSoft
AppColors.accent
AppColors.income
AppColors.expense
AppColors.success
AppColors.warning
AppColors.danger
AppColors.info
AppColors.neutral
AppColors.disabled
AppColors.border
AppColors.divider
AppColors.textPrimary
AppColors.textSecondary
AppColors.textMuted
AppColors.textMain
AppColors.textSec
AppColors.textLight
AppColors.gradA
AppColors.gradB
AppColors.primaryGradient
AppColors.budgetState()
AppSpacing.s1 through AppSpacing.s10
AppSpacing.gutter
AppRadius.sm/md/lg/card/cardLg/button/nav/pill/full
AppTypography.amountHero/amountMedium/amountSmall/display/title1/title2/headline/body/bodyStrong/callout/subhead/footnote/caption
AppGradients.heroHeader/ctaBlue/darkSurface/aiPremium/walletCard/aiSubtle
AppShadows.card/float/nav/cta
AppMotion.fast/normal/slow/emphasized/standardCurve/emphasizedCurve/sheetCurve/cardRevealCurve/numberCountUp/chartAnimation
```

## Color System Summary

`app_colors.dart` now defines a Mali reference palette:

- Dark first obsidian/navy base: `bg`, `surface`, `surfaceElevated`, `surfaceCard`, `surfaceMuted`.
- Violet/indigo Mali accent: `primary`, `cta`, `ctaSoft`, `gradA`, `gradB`.
- Subtle pink secondary accent: `accent`.
- Financial semantics: `income`, `expense`, `success`, `danger`, `warning`, `info`.
- UI structure: `border`, `divider`, `neutral`, `disabled`, `disabledFg`.
- Text hierarchy: `textPrimary`, `textSecondary`, `textMuted`.

New contrast-oriented tokens were added:

```text
onSurface
onSurfaceMuted
successBg / onSuccess
dangerBg / onDanger
warningBg / onWarning
infoBg / onInfo
ctaBg / ctaFg aliases
successFg / dangerFg / warningFg / infoFg aliases
```

## Dark / Light Strategy

Dark mode is the primary visual direction:

- `#0C0D11` obsidian background.
- Layered surfaces from `#15161C` to `#232633`.
- Violet CTA `#6C5CFF` and softer primary `#8D7CFF`.
- Clear, cool text colors for Arabic and financial numbers.

Light mode is not an inversion:

- Clean off-white background `#F6F7FB`.
- White cards and soft grey elevated fields.
- Same violet CTA family for identity continuity.
- Dark neutral text for readability.

## Contrast Safety Strategy

The token layer now provides explicit foreground/background pairs for future components:

- CTA: `cta` / `onCta`.
- Primary: `primary` / `onPrimary`.
- Surface: `surface` or `surfaceCard` / `onSurface`.
- Muted surface: `surfaceMuted` / `onSurfaceMuted`.
- Semantic badges and states: `successBg`, `dangerBg`, `warningBg`, `infoBg` plus matching foreground/semantic colors.

Existing screen code can continue using older text aliases until Phase 2 and screen migrations.

## Gradient Strategy

`app_gradients.dart` now exposes controlled named gradients only:

- `primaryCta`: violet CTA gradient for important actions.
- `subtleSurface`: quiet card/sheet depth.
- `accentIllustration`: pink/violet/blue illustration accent.
- `danger`: rare warning or destructive emphasis.
- `brandHero`: dark premium brand backdrop.

Legacy gradient aliases remain mapped to these new tokenized gradients.

No random gradients, heavy neon, or copied external brand styling were added.

## Typography Strategy

`app_typography.dart` now uses an Arabic-first stack through the existing `google_fonts` dependency:

```text
IBM Plex Sans Arabic -> Inter -> Alexandria
```

Updates:

- Arabic readability is the default.
- Financial amount styles keep tabular figures.
- Negative letter spacing was removed for RTL safety.
- Added `title`, `label`, and `micro` styles for future components.
- Existing typography method names remain available.

No new font package was added.

## Spacing / Radius Strategy

`app_spacing.dart` now formalizes the requested 8pt-inspired scale:

```text
4, 8, 12, 16, 20, 24, 32, 40, 48, 64
```

Semantic aliases added:

```text
pagePadding
pagePaddingCompact
sectionGap
sectionGapCompact
cardPadding
cardPaddingLarge
listGap
chipPadding
chipGap
fieldGap
iconGap
buttonGap
buttonHeight
buttonHeightCompact
sheetPadding
sheetTopGap
screenPadding
```

Radius tokens now include:

```text
xs
sm
md
lg
xl
xxl
small
medium
large
xlarge
card
cardLg
sheet
button
chip
nav
pill
full
```

## Shadow Strategy

`app_shadows.dart` now uses restrained premium shadows:

- `card`
- `elevatedCard`
- `sheet`
- `floatingNav`
- `ctaGlow`

Legacy aliases remain:

```text
float -> elevatedCard
nav -> floatingNav
cta -> ctaGlow
```

No heavy glow, expensive blur, or animated background effect was introduced.

## Motion Strategy

`app_motion.dart` now provides future-ready constants:

- Durations: `fast`, `normal`, `slow`, `emphasized`, `buttonPress`, `cardReveal`, `sheetEnter`, `sheetExit`.
- Curves: `standardCurve`, `emphasizedCurve`, `sheetCurve`, `buttonCurve`, `cardRevealCurve`.
- Existing chart and number timing tokens remain.

No animations were implemented in screens.

## Theme Wiring

`app_theme.dart` was updated only to wire the new token foundation into Material defaults:

- `ColorScheme` secondary accent.
- Card color from `surfaceCard`.
- Divider theme from `divider`.
- Bottom sheet defaults from `surfaceElevated` and `AppRadius.sheet`.
- Progress indicators from `cta` and `surfaceMuted`.
- Button text from `AppTypography.title`.
- Disabled button foreground from `disabledFg`.
- Chip theme from muted surface/CTA tokens.
- Inputs from `surfaceMuted`.

No routes, navigation behavior, providers, or screen-specific logic changed.

## Intentionally Not Touched

```text
app/lib/features/**
app/lib/features/common/**
app/lib/core/router/**
app/lib/domain/**
app/lib/data/**
app/lib/engine/**
app/pubspec.yaml
app/pubspec.lock
app/macos/**
supabase/**
database/schema files
parser / AI categorization / auth / backup / capture bridge logic
```

No fake data or fake features were added.

No new packages were added.

No stash was applied, popped, or dropped.

## Validation Results

All final commands were run from `app/`.

```text
flutter analyze
Result: PASS
Summary: No issues found. (ran in 31.1s)
```

```text
flutter test
Result: PASS
Summary: 241 tests passed.
Notes: Existing Drift multiple-database warnings appeared, same class of warnings recorded in baseline runs.
```

```text
flutter build macos --debug
Result: PASS
Summary: Built build/macos/Build/Products/Debug/money_companion.app.
Notes: Existing plugin SPM and CocoaPods deployment target warnings appeared.
```

The first build attempt was blocked by the managed sandbox because Flutter needed to write its SDK cache. The same command was rerun with escalation and passed.

The successful macOS build regenerated validation artifacts:

```text
app/macos/Runner.xcodeproj/project.pbxproj
app/macos/Runner.xcworkspace/contents.xcworkspacedata
app/macos/Podfile.lock
```

Only those generated validation artifacts were reverted/removed after the build.

`git diff --check`: PASS.

## Remaining Risks

- Existing screens may visually shift because they already consume global color, radius, typography, chip, bottom sheet, input, and button theme defaults. This is expected for token work but should be screenshot-reviewed in Phase 2/Phase 14.
- Static shadow tokens are not theme-extension based yet; Phase 2 can decide whether component wrappers should apply different shadows per brightness.
- Existing screens still include local one-off colors and typography helpers. Those are intentionally deferred to later screen/component phases.

## Phase 2 Readiness

Phase 2 Shared Components can start after this commit because:

- Working tree began clean.
- Token changes stayed within allowed Phase 1 files.
- Analyze, tests, and macOS debug build passed.
- Stashes remain intact.
- No screen/component/business logic/provider/route files were changed.
