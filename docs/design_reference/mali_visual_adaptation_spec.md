# Mali Visual Adaptation Spec

Purpose: translate the reference direction into Flutter-safe visual rules. This is not an implementation diff.

## 1. What To Reuse In Flutter

### Tokens

Reuse and evolve existing token files:

- `app/lib/core/theme/app_colors.dart`
- `app/lib/core/theme/app_gradients.dart`
- `app/lib/core/theme/app_spacing.dart`
- `app/lib/core/theme/app_shadows.dart`
- `app/lib/core/theme/app_typography.dart`
- `app/lib/core/theme/app_motion.dart`
- `app/lib/core/theme/app_theme.dart`

Token targets:

- Primary violet/indigo scale.
- Neutral dark/light surface ladder.
- Semantic success/warning/danger/info/accent.
- Gradient tokens:
  - primary CTA gradient.
  - subtle surface gradient.
  - danger gradient.
  - optional accent illustration gradient.
- Radius scale: 4, 8, 12, 16, 20, 24.
- Spacing scale aligned to 8pt grid.
- Shadow/elevation:
  - card.
  - floating nav.
  - bottom sheet.
  - CTA glow.

### Shared Components

Reuse or evolve these current shared components:

- `AppScreenScaffold`
- `AppHeader`
- `AppCard`
- `AppMetricCard`
- `AppInsightCard`
- `AppButton`
- `AppPillTabBar`
- `AppSheetScaffold`
- `AppEmptyState`
- `PremiumSkeletonPage` / `AppLoadingState`
- `AppTransactionRow`
- `AppBudgetProgressCard`
- `ChartCard`
- `SectionHeader`
- `MaliLogo`
- `BrandMark`, but only for allowed/generic brand marks.

Add only if needed, as UI-only components:

- `AppErrorState`
- `CategoryAvatar`
- `AppProgressRing`
- `AppFinancialSummaryCard`
- `AppSearchFilterBar`
- `AppStateIllustration`
- `AppFormField` / `AppAmountField` / `AppCurrencyDropdown` only if not already adequate.

### Reusable Patterns

- Mobile-first RTL header pattern:
  - back/menu/action right or direction-aware.
  - title centered or right-aligned depending screen type.
  - subtitle compact.
- Summary card pattern:
  - large amount.
  - supporting label.
  - secondary metric.
  - progress ring/bar if useful.
- List row pattern:
  - avatar.
  - title/subtitle.
  - amount/status.
  - chevron/action only when navigable.
- Bottom sheet pattern:
  - shared drag handle.
  - title.
  - scrollable content.
  - sticky CTA area.
  - close affordance.
- Empty state pattern:
  - illustration.
  - title.
  - one concise helper line.
  - one primary action.
- Loading pattern:
  - skeletons that match final layout.
- Error pattern:
  - semantic red illustration.
  - recovery action.

### Screen Layouts

- Onboarding: use REF-02 structure as page-by-page target, but preserve route/session behavior until implementation is explicitly approved.
- Dashboard: use REF-03 hierarchy: financial summary, Smart Inbox, category breakdown, recent transactions, budgets, AI insight.
- Smart Inbox: use REF-04 visual language inside existing dashboard/transactions/review surfaces unless a dedicated route is approved.
- Transactions: use REF-05 search/filter/date grouping and REF-06 details/sheets.
- Budgets: use REF-07 overview/progress/details/forms/empty.
- Reports: use REF-08 cards/charts/insights/export/empty.
- Goals: use REF-09 overview/details/forms/contribution/empty.
- Accounts/Cards: use REF-10 list/details/forms/empty/error, without inventing bank-linking logic.
- Settings: use REF-11 grouped settings architecture while preserving current settings capabilities.
- Global states: use REF-12.

## 2. What To Simplify For Performance

- No heavy blur everywhere. Use blur only for high-value modal/sheet cases; prefer opaque/semi-opaque surfaces elsewhere.
- No excessive neon glow. Use shadows and borders sparingly; financial UI must stay readable.
- No complex shaders.
- No animated backgrounds by default. If motion is used, keep it subtle and optional.
- No image-heavy UI. Prefer vector/icon/widget-based illustrations.
- No fake 3D assets in Flutter unless simple static SVG/widget-based assets are explicitly created and approved.
- No per-row expensive gradients/shadows in long lists. List rows should be cheap to build.
- Avoid nested `BackdropFilter` in scrollable lists.
- Avoid custom painters for every list item unless cached/simple.
- Use `const` constructors and shared widgets where practical.
- Keep chart rendering bounded and simple; no live animated charts unless optional.
- Do not build full-screen generated-image backgrounds.

## 3. What Not To Copy

- Copyrighted logos.
- Fake merchant logos.
- External app identity.
- Payvo styling directly.
- Exact generated image layouts if they conflict with real app logic.
- Fake features shown in references but not present in the app.
- Fake bank account linking.
- Fake card network/bank identity beyond existing data.
- Transaction split/share/export features unless current code supports them or a later product task approves them.
- "Send money", "transfer to person", or bank-like product language.
- Any real brand/logo from references unless the asset already exists and use is legally/product-approved.

## 4. Dark Mode Rules

- Dark is primary.
- Background: very dark navy/black token.
- Surface ladder: at least 3 levels for card/list/sheet hierarchy.
- Borders: subtle but visible on dark.
- CTAs: violet gradient, high contrast text.
- Semantic colors must meet contrast on dark surfaces.
- Use tabular financial numbers.
- Do not rely on glow alone to show hierarchy.

## 5. Light Mode Rules

- Same layouts and spacing.
- Surface ladder should become clean white/off-white.
- Reduce glow; keep borders/shadows lighter.
- Primary violet remains the brand accent, not a full-screen wash.
- Error/success/warning states should remain legible.

## 6. Arabic / RTL Rules

- Design Arabic first.
- Use directional Flutter APIs:
  - `EdgeInsetsDirectional`
  - `AlignmentDirectional`
  - direction-aware icons
  - `TextDirection.ltr` islands for technical strings.
- Keep currency/amount alignment consistent.
- Avoid squeezing long Arabic labels inside fixed-width pills; let text wrap or use tighter copy.
- Test with text scale up to the existing app clamp.
- English/LTR should preserve the same component hierarchy, not a separate design.

## 7. Component Adaptation Targets

| Component | Reference behavior | Flutter adaptation |
| --- | --- | --- |
| App header | Minimal, centered/right title, small actions | One `AppHeader` variant set; no per-screen header reinvention |
| Bottom nav | Glass rounded pill with active violet item | Tokenized `AppShell` bottom bar; avoid heavy blur in low-end mode |
| Cards | Border, dark surface, soft depth | `AppCard` variants: base, elevated, gradient, danger |
| CTA | Violet gradient, 48-56 high | `AppButton.primary` tokenized gradient |
| Secondary button | Border/surface | `AppButton.secondary` |
| Danger button | Red outline/filled | `AppButton.danger` |
| Category avatar | Colored rounded icon | `CategoryAvatar` using category tokens |
| Transaction row | Avatar + merchant + category + status + amount | Single `AppTransactionRow` everywhere |
| Budget progress | Ring/bar + status color | Merge budgets/goals progress language |
| Charts | Donut/line/bar in cards | Existing chart widgets inside `ChartCard`, tokenized colors |
| Sheet | Drag handle, close, scroll body, sticky action | Mandatory `AppSheetScaffold` |
| Empty state | Purple illustration + CTA | `AppEmptyState` visual upgrade |
| Loading | Skeleton matching screen | `PremiumSkeletonPage` variants |
| Error | Red illustration + retry | Add `AppErrorState` |

## 8. Current App Compatibility Notes

- Current shell has 4 active bottom tabs in code: Dashboard, Transactions, Budgets, Settings. Some older docs mention 5 tabs including Reports. Do not change navigation without approval.
- Reports is routed at `/reports`, not necessarily a bottom tab in current code.
- Smart Inbox is not a dedicated route; it exists across Dashboard pending card, Transactions pending filter, and confirm sheets.
- Budget details may not exist as a standalone route; current budget card/form flow should be verified before implementation.
- Account details route is not explicit; card details route exists as `/card/:last4`.
- Settings/Profile: `/profile` maps to `SettingsScreen`.
- Onboarding current code still has guest paths, while recent product preference says email-first should be required. Do not change logic during visual phases.

## 9. Acceptance Checklist For Visual Adaptation

- Colors are tokenized.
- Typography uses `AppTypography`.
- No new hardcoded gradients in feature files.
- Shared components are used before screen migration.
- Arabic/RTL and English/LTR have been considered.
- Dark and light modes both work.
- No fake data was added.
- Existing providers/routes/business logic preserved.
- Reference logos/features not copied blindly.
