# Mali Reference Analysis

Purpose: extract the new Mali visual direction from the provided reference images. This is analysis only. Do not implement UI from this file directly.

## Source Images Analyzed

The requested folder `app/docs/design_reference/images/` was not present. The available reference images were found in `app/docs/images/` and analyzed as the provided source set.

| Ref ID | Actual file | Size | Interpreted area |
| --- | --- | --- | --- |
| REF-01 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_04_09 AM.png` | 1536x1024 | Design system dark mode board |
| REF-02 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_13_15 AM.png` | 1536x1024 | Onboarding full flow |
| REF-03 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_17_25 AM.png` | 941x1672 | Dashboard |
| REF-04 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_19_47 AM.png` | 1536x1024 | Smart Inbox and review/edit states |
| REF-05 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_22_18 AM.png` | 1672x941 | Transactions list, details, edit sheet, empty |
| REF-06 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_24_18 AM.png` | 1536x1024 | Transaction details and bottom sheets |
| REF-07 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_42_53 AM.png` | 1536x1024 | Budgets |
| REF-08 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_53_40 AM.png` | 1536x1024 | Reports |
| REF-09 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_55_57 AM.png` | 1536x1024 | Goals |
| REF-10 | `app/docs/images/ChatGPT Image Jun 24, 2026, 11_58_44 AM.png` | 1536x1024 | Accounts and cards |
| REF-11 | `app/docs/images/ChatGPT Image Jun 24, 2026, 12_01_20 PM.png` | 1536x1024 | Settings |
| REF-12 | `app/docs/images/ChatGPT Image Jun 24, 2026, 12_03_22 PM.png` | 1536x1024 | Global empty/loading/error states |

## A. Extracted Visual Direction

### Color Direction

- Primary identity shifts toward premium violet/indigo, with a blue-violet Mali mark and CTA gradient.
- Dark base is nearly black/navy, not pure black: reference board shows background around `#0C0D11`, surface around `#16171D`, elevated surface around `#1E2027`, and border around `#2A2D36`.
- Primary/violet range in REF-01: `#6C5CFF`, light `#8D7CFF`, dark `#4B3EE6`.
- Semantic colors:
  - Success green around `#22C55E`.
  - Warning amber/orange around `#F59E0B`.
  - Danger red around `#EF4444`.
  - Info blue around `#3B82F6`.
  - Accent pink around `#F472B6`.
- Gradients:
  - Primary 135-degree violet gradient, e.g. `#6C5CFF -> #3B5E6` in the board; adapt to real token names after visual QA.
  - Accent gradient pink/purple, used sparingly for visual assets or highlights.
- Rule: references use contrast through surface layering, borders, and controlled glow. Do not flood the UI with neon.

### Typography Direction

- Arabic-first typography, with the reference explicitly calling out "Typography (Arabic First)".
- Hierarchy shown in REF-01:
  - Display 1: 32px bold.
  - Display 2: 24px bold.
  - Headline: 20px semi-bold.
  - Title: 16px semi-bold.
  - Body 1: 14px regular.
  - Body 2: 12px regular.
  - Caption: 11px regular.
- Financial numbers are tabular, large, and clear; amounts should use Latin-style tabular numerals where the current app already does so, with currency labels kept readable in Arabic.
- Headline text is compact and confident; support copy is short and not marketing-heavy.

### Spacing And Radius

- 8pt grid is explicit in REF-01: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64.
- Radius scale shown: 4, 8, 12, 16, 20, 24.
- Cards generally sit at 16-24 radius; phone-frame mockups often use 20-24.
- Bottom sheets use large top radii, around 24-30, with a visible drag handle.
- Touch targets are large: CTAs approximately 48-56 high.

### Card Style

- Dark cards are elevated through:
  - subtle gradient surface.
  - thin border.
  - soft shadow/glow.
  - internal section dividers.
- Cards are dense but not cramped. Most reference screens prefer stacked cards with clear title, metric, and action rows.
- Avoid nested decorative card-on-card overload; use nested cards only for meaningful grouped data, such as a transaction receipt inside transaction details.

### Button Style

- Primary buttons are full-width violet gradient with rounded radius around 14-16.
- Secondary buttons are bordered/dark-surface buttons.
- Tertiary buttons are text-only violet/blue labels.
- Danger buttons are red gradient or red outline depending on action severity.
- Disabled buttons are low-opacity surface/gradient, not invisible.

### Icon Style

- Outline icons dominate in the design-system board.
- Filled/gradient icons appear inside circular/squircle avatar backgrounds.
- Icons are meaningful and simple; avoid mixing many families in one screen.
- Bottom nav icons are large enough to read and paired with Arabic labels.

### Category Avatar Style

- Category avatars are circular or rounded-square chips with colored backgrounds and simple white/colored icons.
- Category colors:
  - Food/restaurants: orange/red.
  - Transport: blue.
  - Groceries: green.
  - Shopping: amber/pink.
  - Bills: teal/green.
  - Health: red/pink.
  - Entertainment: purple.
  - Transfers: violet/blue.
  - Other: neutral.
- Use generic category/merchant avatars. Do not copy real merchant logos shown in references unless an asset already exists and use is explicitly approved.

### Transaction Row Style

- Rows are card-like or contained in list cards with:
  - avatar on the right in RTL.
  - merchant/title.
  - category/subtitle/date.
  - amount aligned on the opposite side.
  - status badge such as confirmed/pending.
- Income is green, expenses are red or neutral with minus sign, pending/review state uses amber or violet badge.
- Date grouping is shown in Transactions references.
- Search/filter controls are prominent and high-value.

### Budget Progress Style

- Progress bars are thick enough to scan.
- Budget overview uses summary cards and progress ring.
- Warning/danger states are visually explicit:
  - healthy: violet/green.
  - warning: amber.
  - over budget: red panel with alert icon and percent.
- Budget cards include category avatar, limit, spent/remaining, percent, and progress.

### Chart Style

- Donut charts with center labels for category spend.
- Line/trend charts in translucent chart containers with low-contrast gridlines.
- Bar charts for reports and global states.
- Charts use category colors from tokens, not random colors.
- Tooltips/callouts appear as small purple labels.

### Bottom Sheet Style

- Bottom sheets are dark, rounded top, with drag handle and close button.
- Layout pattern:
  - Handle/close.
  - Title.
  - Form/list body.
  - Sticky primary action.
- Sheets include category picker, edit transaction, split transaction, notes, delete confirmation, share receipt, reminder, quick add.
- Use one shared sheet scaffold. Avoid raw per-sheet containers.

### Empty / Loading / Error State Style

- Empty states:
  - centered purple vector illustration.
  - concise title.
  - one-line helper.
  - one primary CTA.
- Loading states:
  - skeleton rows/cards that match the final layout.
  - one circular loading state for goals is acceptable but should use token colors.
- Error states:
  - red semantic illustration.
  - clear title and retry/return action.
  - specific errors: no internet, failed load, not found, operation failed, session ended, unauthorized, unexpected.

### Dark / Light Mode Rules

- Dark mode is primary and fully specified by references.
- Light mode should reuse the same component hierarchy but invert surfaces, borders, and text contrast.
- In light mode, keep violet identity but reduce glow/shadow intensity.
- No hardcoded dark-only backgrounds in feature code; every visual needs token mapping.
- Gradients must be tokenized and validated in both modes.

### Arabic / RTL Rules

- Arabic is primary, not a translation afterthought.
- RTL layout:
  - Primary content starts on the right.
  - Navigation order is intentionally RTL.
  - Amounts and currency blocks stay readable and aligned.
  - Latin values such as email, OTP, card numbers, currency codes, dates, and IDs need LTR islands.
- Arabic copy should be natural, warm, and concise.
- Avoid long paragraphs in setup and empty states.

## B. Reference-To-App Mapping

| Reference | Best mapped app area | Notes |
| --- | --- | --- |
| REF-01 | `lib/core/theme/**`, `lib/features/common/**` | Design tokens, shared components, states, icon/category systems |
| REF-02 | `lib/features/onboarding/**`, auth, backup restore, capture setup | Onboarding brief target; email-first flow shown |
| REF-03 | `dashboard_screen.dart`, `app_shell.dart` | Dashboard composition and bottom nav direction |
| REF-04 | Dashboard smart inbox, Transactions pending tab, confirm/edit sheets | Smart Inbox should become visually stronger without route changes unless approved |
| REF-05 | `transactions_screen.dart`, `transaction_details_screen.dart`, edit sheets | Search/filter and empty state patterns |
| REF-06 | `transaction_details_screen.dart`, `manual_transaction_sheet.dart`, `change_category_sheet.dart`, confirm/delete/share sheets | Bottom sheet language |
| REF-07 | `budgets_screen.dart`, `budget_form_screen.dart` | Budget overview/details/forms/state patterns |
| REF-08 | `reports_screen.dart` | Reports overview/monthly/category/comparison/export/empty |
| REF-09 | `goals_screen.dart`, `goal_details_screen.dart`, `goal_form_screen.dart` | Goals overview/details/forms/contribution sheets |
| REF-10 | `accounts_screen.dart`, `card_details_screen.dart`, cards widgets | Accounts/cards overview, forms, empty/error |
| REF-11 | `settings_screen.dart`, `privacy_screen.dart`, `backup_screen.dart` | Settings information architecture and states |
| REF-12 | `AppEmptyState`, `PremiumSkeletonPage`, future `AppErrorState` | Global states across all app areas |

## C. Reference Risks

- Some reference screens show real merchant/service logos such as Starbucks, Uber, Amazon, Netflix, McDonald's, Vodafone, CIB, Visa. These are visual references only; do not copy logos or brand marks into Flutter unless already in repo and explicitly approved.
- Some reference screens imply features that may not exist or may not be routed today, such as dedicated Smart Inbox route, full account connection error, statement view, split transaction, share receipt, advanced report export formats. Treat these as visual inspiration only unless existing code supports them.
- The references are generated concepts. If a layout conflicts with current data, providers, or routing, simplify the visual to fit current app logic.
- Heavy glow, blur, and image-like illustrations must be simplified for Flutter performance and maintainability.
