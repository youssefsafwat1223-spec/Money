# Phase 2 Reference Shared Components Report

Date: 2026-06-24

Result: PASS

Scope: Phase 2 Shared Components only. No feature screens, app shell, routes, providers, business logic, domain/data/engine code, parser, AI categorization, auth, backup, Supabase, capture bridge, or database files were modified.

## Inputs Read

- `docs/design_reference/mali_reference_analysis.md`
- `docs/design_reference/mali_visual_adaptation_spec.md`
- `docs/design_reference/mali_screen_migration_plan.md`
- `docs/design_reference/mali_codex_execution_guardrails.md`
- `docs/redesign/phase_1_reference_tokens_report.md`
- `docs/redesign/phase_1_reference_tokens_self_review.md`

## Pre-Check

Working tree before Phase 2 component work: clean.

Recent baseline:

```text
cf068be1 feat(ui): add Mali reference design token foundation
47461575 docs: baseline Mali visual reference migration
7ab9556a fix(ui): repair clean-head build errors before reference migration
```

Stashes before and after Phase 2:

```text
stash@{0}: On feat/accounts-multicurrency: backup: dirty tree before Mali reference Phase 1 tokens
stash@{1}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

Pre-work gates from `app/`:

```text
flutter analyze: PASS
flutter test: PASS - 241 tests passed
flutter build macos --debug: PASS
```

## Files Changed

Shared component files:

```text
app/lib/features/common/app_budget_progress_card.dart
app/lib/features/common/app_button.dart
app/lib/features/common/app_card.dart
app/lib/features/common/app_category_chip.dart
app/lib/features/common/app_empty_state.dart
app/lib/features/common/app_error_state.dart
app/lib/features/common/app_header.dart
app/lib/features/common/app_loading_state.dart
app/lib/features/common/app_metric_card.dart
app/lib/features/common/app_screen_scaffold.dart
app/lib/features/common/app_sheet_scaffold.dart
app/lib/features/common/app_status_pill.dart
app/lib/features/common/app_transaction_row.dart
app/lib/features/common/category_avatar.dart
app/lib/features/common/chart_card.dart
app/lib/features/common/premium_loading.dart
app/lib/features/common/section_header.dart
app/lib/features/common/widgets.dart
```

Formatting-only common files:

```text
app/lib/features/common/mali_logo.dart
app/lib/features/common/motion.dart
app/lib/features/common/vault_widget.dart
```

Reports:

```text
docs/redesign/phase_2_reference_components_report.md
docs/redesign/phase_2_reference_components_self_review.md
```

## Components Created / Updated

### `AppScreenScaffold`

- Added optional `bottomArea`.
- Added `safeArea` and `ambient` switches.
- Kept existing `body`, `header`, `padding`, `bottomNavPadding`, `resizeToAvoidBottomInset`, and `extendBodyBehindHeader` API.
- Retained cheap ambient background but shifted it to Phase 1 violet/pink tokens.
- No route or provider logic added.

### `AppHeader`

- Added optional `subtitle`, `leading`, `trailing`, and `compact`.
- Preserved existing `title`, `action`, and `showBack`.
- Supports overflow-safe title/subtitle text.
- Keeps navigation behavior delegated to the caller or default `AppBar`.

### `SectionHeader`

- Added overflow protection for title/subtitle.
- Kept optional `action` slot and existing constructor shape.

### `AppCard`

- Added `AppCardVariant` with `base`, `elevated`, `gradient`, and `danger`.
- Added optional `margin` and `radius`.
- Preserved existing `child`, `onTap`, `padding`, `border`, `gradient`, and `semanticsLabel`.
- Uses Phase 1 `surfaceCard`, borders, gradients, and shadow tokens.

### `AppButton`

- Added `AppDangerButton`.
- Added `isDanger`, `loading`, and `disabled` to the backwards-compatible `AppButton` wrapper.
- Primary buttons now use the tokenized `AppGradients.primaryCta` and subtle `AppShadows.ctaGlow`.
- Press feedback now uses `AppMotion.buttonPress` and `AppMotion.buttonCurve`.
- Existing `AppPrimaryButton`, `AppSecondaryButton`, `AppGhostButton`, and `AppButton` APIs remain usable.

### `AppMetricCard`

- Added `AppMetricStyle.info`.
- Added optional `onTap`.
- Uses `surfaceCard`, border, and shadow tokens.
- Value remains passed in preformatted; no calculations were added.

### `AppTransactionRow`

- Replaced private avatar/badge fragments with shared `CategoryAvatar` and `AppStatusPill`.
- Added optional `isConfirmed` visual state.
- Still receives all transaction display values as parameters.
- Does not import providers or repositories.

### `AppInsightCard`

- Existing API preserved. It already supported semantic tones and stayed unchanged in this phase.

### `AppEmptyState`

- Added optional `illustration` slot.
- Updated default visual to tokenized squircle illustration container.
- Kept existing icon/title/subtitle/action API.

### `AppLoadingState` / Skeletons

- Added `AppSkeletonBlock`.
- Added `AppSkeletonRow`.
- Updated `PremiumSkeletonPage` colors to `surfaceCard` and `surfaceMuted`.
- Existing animated skeleton remains cheap and respects existing reduced-motion helper.

### `AppErrorState`

- Added new shared error state with semantic danger visual, title, description, and optional retry action.
- No business logic or retry behavior is embedded; retry is passed as a callback.

### `AppSheetScaffold`

- Removed hard-forced RTL direction so sheets inherit caller direction.
- Removed default heavy backdrop blur.
- Added tokenized sheet surface, border, radius, and shadow.
- Added `showDragHandle` and `showCloseButton`.
- Preserved title/subtitle/body/bottomAction/leading/trailing/padding/scrollable API.
- Remains keyboard-safe using `viewInsets`.

### `AppCategoryChip`

- Made `icon` optional while preserving existing call sites that pass one.
- Added directional padding and overflow protection.
- Uses `onCta` for selected contrast.

### `CategoryAvatar`

- Moved to its own reusable `category_avatar.dart`.
- Supports category, merchant initial, explicit icon/color, and label fallback.
- Kept `widgets.dart` barrel export so existing imports continue working.
- Does not use real merchant logos.

### `AppBudgetProgressCard` / `BudgetProgressCard`

- Added optional `remainingText`.
- Added `BudgetProgressCard` alias with `name` for future screen migration naming.
- Progress and display strings are passed in; no budget calculations were added.

### `ChartCard`

- Added optional `legend`.
- Added configurable `aspectRatio`.
- Existing title/subtitle/action/child API remains compatible.

### `AppStatusPill` / `AppBadge`

- Added shared semantic status component for `neutral`, `success`, `warning`, `danger`, `info`, `pending`, and `confirmed`.
- `AppBadge` is a compact alias.

## Component API Summary

- All new components are UI-only and parameter-driven.
- Existing shared component constructor parameters were preserved.
- New parameters are optional except in new components.
- Screen migration is intentionally deferred; no feature screen imports or call sites were modified.

## Token Usage Summary

Components now consistently use Phase 1 tokens:

- Colors: `context.colors`, `surfaceCard`, `surfaceMuted`, `surfaceElevated`, `cta`, `onCta`, `dangerBg`, `successBg`, `warningBg`, `infoBg`.
- Spacing/radius: `AppSpacing`, `AppRadius`.
- Typography: `AppTypography`.
- Gradients: `AppGradients.primaryCta`, `AppGradients.danger`, `AppGradients.subtleSurface`.
- Shadows: `AppShadows.card`, `AppShadows.elevatedCard`, `AppShadows.sheet`, `AppShadows.ctaGlow`.
- Motion: `AppMotion.buttonPress`, `AppMotion.buttonCurve`.

## Dark / Light Support

- Shared surfaces use tokenized colors rather than hardcoded dark values.
- Sheet/card/button/status components use token foreground/background pairs.
- Loading states use token surface colors.
- No dark-only assumptions were added.

## RTL / LTR Support

- New/updated components use directional padding/alignment where relevant.
- `AppSheetScaffold` now inherits ambient direction instead of forcing RTL.
- Text overflow is constrained in headers, chips, section headers, and state components.
- `CategoryAvatar` uses an LTR island only for initials.

## Accessibility / Overflow Notes

- Buttons and tappable cards keep semantic labels/buttons.
- Button heights remain at least 48-56 where applicable.
- Header, section, chip, and sheet title text now guard against overflow.
- Error/empty/loading components keep concise text structure with caller-provided actions.

## Performance Notes

- No heavy blur is used by default in the shared sheet.
- No new packages were added.
- Long-list row components avoid per-row heavy filters.
- Skeleton animation remains the existing lightweight gradient animation and respects reduced motion.
- Status pills and avatars are simple containers/icons.

## Backward Compatibility Notes

- `widgets.dart` remains the shared barrel.
- Existing exports remain, with new exports added for `AppErrorState`, `AppStatusPill`, and `CategoryAvatar`.
- `CategoryAvatar` remains available through `widgets.dart`.
- `AppButton` remains compatible with old `label`, `onPressed`, `isPrimary`, `height`, and `icon`.
- `AppSheetScaffold`, `AppHeader`, `AppCard`, `AppCategoryChip`, `ChartCard`, and `AppBudgetProgressCard` only gained optional parameters.

## Intentionally Not Touched

```text
app/lib/features/onboarding/**
app/lib/features/dashboard/**
app/lib/features/capture/**
app/lib/features/transactions/**
app/lib/features/budgets/**
app/lib/features/reports/**
app/lib/features/goals/**
app/lib/features/accounts/**
app/lib/features/settings/**
app/lib/features/app/**
app/lib/core/router/**
app/lib/domain/**
app/lib/data/**
app/lib/engine/**
app/pubspec.yaml
app/pubspec.lock
app/macos/**
supabase/**
database/schema files
```

No fake data, fake features, fake logos, or new routes were added.

No stash was applied, popped, or dropped.

## Validation Results

Final commands from `app/`:

```text
flutter analyze
Result: PASS
Summary: No issues found. (ran in 5.2s)
```

```text
flutter test
Result: PASS
Summary: 241 tests passed.
Notes: Existing Drift multiple-database warnings appeared, same debug-only class as baseline.
```

```text
flutter build macos --debug
Result: PASS
Summary: Built build/macos/Build/Products/Debug/money_companion.app.
Notes: Existing plugin SPM and CocoaPods deployment target warnings appeared.
```

The first macOS build attempt was blocked by the managed sandbox because Flutter needed to write SDK cache files. It was rerun with escalation and passed.

The macOS build regenerated these validation artifacts:

```text
app/macos/Runner.xcodeproj/project.pbxproj
app/macos/Runner.xcworkspace/contents.xcworkspacedata
app/macos/Podfile.lock
```

Only those generated artifacts were reverted/removed after the build.

`git diff --check`: PASS.

## Remaining Risks

- Existing screens already consume shared components, so visual defaults may shift before their dedicated migration phases. No screen call sites were changed.
- `widgets.dart` still includes the legacy `TransactionRow` that imports domain entities. It was existing behavior and was not expanded. Future phases can migrate to the UI-only `AppTransactionRow`.
- Some common illustration widgets still use their pre-existing local custom visuals; only mechanical formatting touched `mali_logo.dart`, `motion.dart`, and `vault_widget.dart`.

## Phase 3 Readiness

Phase 3 Onboarding can start after this commit because:

- Working tree began clean.
- Changes stayed within `app/lib/features/common/**` and Phase 2 docs.
- Analyze, tests, and macOS debug build passed.
- Stashes remain intact.
- No feature screen, route, provider, or business logic files were changed.
