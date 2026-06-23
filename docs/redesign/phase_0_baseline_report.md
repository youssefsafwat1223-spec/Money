# Phase 0 Baseline Report

## A. Git status summary
* **Modified files**: Over 90 files modified across `lib/core`, `lib/features`, `lib/engine`, `lib/data`, `lib/domain`, `test/`, `assets/`, `ios/`, `supabase/`, and `../admin`.
* **Untracked files**: Over 30 files untracked, primarily new components in `lib/features/common/` (e.g., `app_card.dart`, `app_button.dart`, `app_screen_scaffold.dart`), theme files (`app_gradients.dart`, `app_shadows.dart`), test files, root scripts (`patch_tx.py`), and Next.js caches in `../admin`.
* **Pre-existing changes**: It appears significant work towards Phase 1 (tokens) and Phase 2 (core components) has already been started or staged in the working tree, along with backend/admin modifications.
* **Files safe to touch in Phase 1**: `lib/core/theme/app_colors.dart`, `lib/core/theme/app_gradients.dart`, `lib/core/theme/app_typography.dart`, `lib/core/theme/app_spacing.dart`, `lib/core/theme/app_shadows.dart`, `lib/core/theme/app_motion.dart`, and `lib/core/theme/app_theme.dart` (for wiring only).
* **Files that must not be touched**: Any feature screens (`lib/features/...` except for token/theme definitions), business logic, parser logic, AI logic, storage, auth, capture bridge, tests, and any backend/edge functions.

## B. Analyze result
* **Command run**: `flutter analyze`
* **Pass/Fail**: Pass
* **Warnings/errors**: No issues found!

## C. Test result
* **Command run**: `flutter test`
* **Pass/Fail**: Fail
* **Failing tests**: 1 test failed:
  * `/Users/youssef/Documents/Money/app/test/data/catalog_seed_loader_test.dart: SeedLoader seeds bundled catalog assets once`

## D. Phase 1 readiness
Phase 1 **CANNOT** start safely. The test suite is currently failing, and the Phase 0 safety contract requires a completely green test suite before any UI phases can begin.

## E. Phase 1 allowed scope
Phase 1 is allowed to touch exactly:
* AppColors
* AppGradients
* AppTypography
* spacing tokens
* radius tokens
* shadow tokens
* motion constants
* contrast helpers/guards if already part of the theme system

## F. Phase 1 forbidden scope
Phase 1 must not touch:
* parser logic
* AI/categorization logic
* transaction use cases
* providers/business logic
* storage
* auth/backup
* capture bridge
* edge functions
* full screen redesigns
* dashboard layout
* smart inbox layout
* transaction list layout
* budget/report screens
