# Safe Redesign Specification — Mali App

This specification document details the execution plan for mapping the premium visual direction of Mali into concrete, production-safe Flutter widgets, styling sheets, and layout updates.

---

## 1. Design Token Translation (Phase 1)

We will modify the styling system in `lib/core/theme/` to reflect the extracted palette:
*   **Colors (`app_colors.dart`)**:
    *   Dark Base: Update `AppColors.dark.bg` to `Color(0xFF0C0D11)` and `surface` to `Color(0xFF141623)`.
    *   Accent: Update `cta` to the electric blue `Color(0xFF5488FE)` and `accent` to `Color(0xFF238AFF)`.
    *   Light Base: Maintain `bg` as `Color(0xFFF4F7FA)` and `surface` as `Color(0xFFFFFFFF)`.
*   **Typography (`app_typography.dart`)**:
    *   Dual Fallbacks: Ensure all text styles define `fontFamilyFallback: [GoogleFonts.ibmPlexSansArabic().fontFamily!]` to support RTL Arabic text correctly.
    *   Hero Figures: Add tabular configurations `fontFeatures: [FontFeature.tabularFigures()]` inside `amountHero` and other amount indicators to prevent number sizing jitter during updates.
*   **Icons (`app_lucide_icons.dart`)**:
    *   Maintain the current mappings in `app_lucide_icons.dart`. No new library packages will be added.

---

## 2. Shared Component Library (Phase 2)

We will update or create clean, reusable visual components in `lib/features/common/` that screens will inherit:
*   **AppScreenScaffold**: Replaces standard scaffold with dynamic liquid ambient gradients (using lightweight `RadialGradient` layers in a static or slow-drifting loop).
*   **AppHeader**: Custom header that mirrors dynamically under RTL/LTR and integrates navigation actions.
*   **AppCard**: Container with a thin border decoration (`1px` width with `8%` white opacity) and a dark glass background sheen.
*   **AppButton**: Material button with micro-scale press animations (`TweenAnimationBuilder` scaling to `0.97` on tap down).
*   **AppMetricCard**: Customized representation for account balances with tight tracking numerals.
*   **AppTransactionRow**: Polished item card displaying category indicator color, round icon, transaction description, and status indicator.
*   **AppInsightCard**: Horizontal alert widget summarizing financial statistics.
*   **AppEmptyState**: SVG/Lucide abstract vector layout indicating empty folders/states.
*   **AppLoadingState**: Sleek, RTL-flowing gradient shimmer overlay.
*   **AppSheetScaffold**: Floating modal sheets with frosted background blurs.
*   **AppCategoryChip**: Category badge chips with transparent pastel backgrounds matching category colors.
*   **BudgetProgressCard**: Customized progress bar card featuring warnings for over-budget limits.

---

## 3. UI Migration Mapping (Phases 3 to 9)

We will systematically replace UI layouts in existing screen files with the new components, adhering to the allowed file boundaries:
*   **Phase 3 (App Shell)**: Confined to `lib/features/app/app_shell.dart`. Updates navigation tabs to floating translucent glass sheets.
*   **Phase 4 (Dashboard)**: Confined to `lib/features/dashboard/dashboard_screen.dart`. Updates card styling, alignment, and metrics displays.
*   **Phase 5 (Smart Inbox)**: Updates transaction confirmation and review forms. Confined to existing files within `capture` (e.g. `sms_permission_screen.dart`, `manual_paste_screen.dart`, and bottom entry sheets).
*   **Phase 6 (Transactions)**: Updates transaction scroll lines and detail bottom sheets in `lib/features/transactions/`.
*   **Phase 7 (Budgets)**: Customizes budget listing bars and visual indicator states in `lib/features/budgets/`.
*   **Phase 8 (Reports/Goals)**: Updates chart layouts and goal gauges in their respective folders.
*   **Phase 9 (Onboarding/Settings)**: Polishes the visual onboarding screens and security toggles.

---

## 4. Exclusion & Fallback Strategy

The following conceptual features are **excluded** from this redesign:
*   *Swipe-to-confirm Smart Inbox*: If not already in the app, we keep the existing tap confirmation triggers but style them with the new premium outline look.
*   *Merchant map visualizer*: Keep the standard textual merchant details or existing maps; do not add map integrations.
*   *Biometric animations*: Keep the system biometrics trigger, decorating only the trigger button with the pulsing glow.
*   *New confidence scales or budget scores*: Keep the calculations exactly as they are currently computed by the database logic.
*   *Split-bill / Privacy blur toggle*: If the feature does not exist, do not write logic or UI elements for it.
