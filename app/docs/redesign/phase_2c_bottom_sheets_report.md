# Phase 2C: Bottom Sheets & AppSheetScaffold Migration Report

## Overview
This phase focused on migrating the application's bottom sheets to a unified `AppSheetScaffold` foundation. This change aligns the bottom sheets with the Phase 1 design tokens (specifically `AppColors`, `AppSpacing`, and `AppTypography`) while introducing the specified visual treatments such as subtle glassmorphism and rounded corners.

## Files Migrated
1. **Foundation Component:**
   - `lib/features/common/app_sheet_scaffold.dart`: Enhanced to handle trailing actions, safe area for the keyboard, scrollable body content, leading actions, subtitles, and a bottom action area. Also includes RTL support and a predefined drag handle.

2. **Feature Sheets:**
   - `lib/features/transactions/widgets/confirm_transaction_sheet.dart`: Migrated to use `AppSheetScaffold`. Content is wrapped in a scrollable column; bottom actions moved to `body`.
   - `lib/features/transactions/widgets/change_category_sheet.dart`: Migrated to use `AppSheetScaffold`. Eliminated duplicated modal boilerplate (Directionality, BackdropFilter, Container).
   - `lib/features/transactions/manual_transaction_sheet.dart`: Replaced the hardcoded modal structure in `_buildForm` and the main build method. The top action bar text was passed directly to the scaffold's `title` property.
   - `lib/features/capture/capture_entry_sheet.dart`: Refactored to leverage `AppSheetScaffold`.
   - `lib/features/subscriptions/bill_form_sheet.dart`: Replaced the dual-sheet (`_BillFormSheetState` and `_BillServicePicker`) modal implementation with `AppSheetScaffold`.

## Architecture Decisions
1. **AppSheetScaffold as the Unified Root**: Instead of every sheet manually declaring `showModalBottomSheet` wrapper components with `Directionality(textDirection: TextDirection.rtl)`, `ClipRRect`, and `BackdropFilter`, this boilerplate was pushed to `AppSheetScaffold`.
2. **Scrollability Control**: Introduced `scrollable: true` and an optional `padding` to `AppSheetScaffold` to adapt it for both simple sheets (e.g., capture) and complex forms (e.g., manual transactions) without clipping during keyboard activity.
3. **Preservation of Business Logic**: No business logic, routing behavior, or global state interactions were modified. We purely focused on the presentation layer wrapping the existing forms and controls.
4. **Phase 1 Aesthetics**: The scaffold was designed with `c.surface.withValues(alpha: 0.95)` and `ImageFilter.blur(sigmaX: 20, sigmaY: 20)` to ensure a premium, floating appearance that adheres to the Phase 1 restrictions on over-glow.

## Test Results
- `flutter test`: 241/241 passed successfully.
- `flutter analyze`: Passed with 0 issues.

## Remaining Work
- **Cleanup of Generated Junk (Group G)**: The build artifacts and temporary scripts are still present and must be removed in a dedicated clean-up task.
- **Phase 2D/3**: Migrating the primary feature screens (Dashboard, Inbox, etc.) to use the unified components and tokens.
- **Stash Resolution**: Safe restoration of feature-specific component updates (Groups E, F, H) as needed for subsequent phases.
