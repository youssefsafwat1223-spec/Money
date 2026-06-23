# Phase 1 Tokens Report

## Files Changed
* `lib/core/theme/app_colors.dart`
* `lib/core/theme/app_gradients.dart`
* `lib/core/theme/app_shadows.dart`
* `lib/core/theme/app_spacing.dart`
* `lib/core/theme/app_theme.dart`
* `lib/core/theme/app_motion.dart` (New File)
* `lib/features/common/motion.dart`

## Token Systems Updated
* **Color System:** Transitioned from specific named tones (e.g., `gradA`, `textMain`) to a semantic color system featuring `income`, `expense`, `success`, `warning`, `danger`, `primary`, `onPrimary`, `cta`, `onCta`, and distinct elevation surfaces (`surfaceElevated`). Legacy properties were kept as getters for safety backwards compatibility.
* **Gradient System:** Collapsed disparate gradients into a unified `AppGradients` class with purposeful names: `brandHero`, `walletCard`, and `aiSubtle`.
* **Typography:** Reviewed `AppTypography`. It is correctly structured using Inter and IBM Plex Sans Arabic. No modifications were needed to keep it safely anchoring the rest of the application.
* **Spacing/Radius:** Added explicit layout tokens to `AppSpacing` (e.g., `pagePadding: 24`, `sectionGap: 32`, `buttonHeight: 56`) and semantic radii to `AppRadius` (`sm`, `md`, `lg`, `pill`, `full`).
* **Shadows:** Standardized `AppShadows` to use subtle `card`, `float`, `nav`, and `cta` glow layers with proper low opacities. 
* **Motion:** Extracted fixed durations and curves into a centralized `AppMotion` token scale. Updated `motion.dart` to rely on them seamlessly.

## Primary / Dark-Mode Risk Mitigation
We resolved the `c.primary` dark mode risk by introducing `primary` paired with `onPrimary`. If a container ever leverages `primary` as a background, it now has a guaranteed readable foreground color `onPrimary`. Likewise, all interactive surfaces utilize `cta` paired explicitly with `onCta`. The `AppTheme` generation binds these safe combos to standard Material states (e.g., `FilledButton` foreground).

## What Was Intentionally Not Touched
* No core UI components (Cards, Headers, Bottom Nav) were created or modified.
* No feature screens (Dashboard, Smart Inbox, Transactions, Onboarding, etc.) were touched.
* The stash remains untouched and unpopped. 
* Business logic, providers, parsing and supabase modules remained untouched.
* No generated junk files were deleted.

## Checks
* `flutter analyze` completed with no issues found.
* `flutter test` passed all tests.

## Status
* **Phase 1 Complete:** Yes. The structural design tokens are safely implemented.
* **Phase 2 Safe to Start:** Yes. The foundation is robust and ready for UI components to migrate to without breaking existing views.
