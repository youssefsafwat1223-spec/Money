# V1 Localization Matrix

> **SUPERSEDED, 2026-09-17.** The "ship Arabic-first / do not claim English"
> recommendation in §2 below is **WITHDRAWN**. The owner has confirmed the V1
> product contract is Arabic (MSA) **+ English**, and English remains an OPEN
> requirement. The counts here are also stale — ARB keys went 338 → 930 and
> routes rendering Arabic under `en` went 15/19 → 10/19.
>
> Current state: **`V1_LOCALIZATION_MATRIX_2026-09-17.md`**.
>
> Kept unedited as the record of what was measured on 2026-09-15/16.

Measured 2026-09-15 against HEAD. Counts are Arabic string literals in
widget-bearing files (the user-facing surface) versus `l10n.*` references.
## 0. Runtime evidence — added 2026-09-16

Everything below was previously measured by counting source. This section is
the first **runtime** evidence: `integration_test/bilingual_walk_test.dart`
drives every V1 route on the Simulator in `ar`, then switches
`settings.language` to `en` — which is what `localeProvider` reads — and drives
them again.

| Measure | Result |
|---|---|
| Routes walked in Arabic | **19** |
| Routes walked in English | **19** |
| `Directionality` assertions | **38 / 38 passed** (RTL under `ar`, LTR under `en`) |
| Captures | **38** at 1320×2868, `~/.qirsh-qa/bilingual/` |
| Routes still rendering Arabic under `en` | **15 of 19** |

Arabic strings surviving a switch to English, by route:

| Route | Arabic strings | Route | Arabic strings |
|---|---|---|---|
| `/` | 88 | `/cards` | 18 |
| `/settings` | 82 | `/accounts` | 16 |
| `/profile` | 82 | `/privacy` | 12 |
| `/budgets` | 38 | `/backup` | 9 |
| `/reports` | 33 | `/data-transfer` | 9 |
| `/achievements` | 27 | `/announcements` | 7 |
| `/subscriptions` | 20 | `/paste` | 5 |
| `/goals` | 18 | | |

Four routes render no Arabic under `en`. Fifteen do.

### What the direction assertion could NOT see

It passed on all 38, and the English screenshots were still wrong. Containers
mirrored correctly while the **disclosure chevron kept pointing left** — correct
in Arabic, where forward is leftward; wrong in English. Fifteen call sites
hardcoded `chevronLeft`.

That is the honest limit of the assertion: it proves the direction was applied,
not that the picture is right. Only the side-by-side captures showed it. Fixed
via `DirectionalChevron`, verified on the re-run, and locked by
`test/core/theme/widgets/directional_chevron_test.dart`.

The tempting fix was wrong in a way worth recording. `IconData(...,
matchTextDirection: true)` reads like the answer; Flutter mirrors a matching
icon **only in RTL** (`widgets/icon.dart:334-344`), so with the bundled
left-chevron glyph it would have pointed left in LTR and right in RTL — broken
in both, including the language that already worked.

### What this means for the listing

English is not merely incomplete, it is **incoherent**: Arabic copy rendered
inside correctly-mirrored LTR containers. Declaring Arabic only on the App Store
remains correct, and is now supported by runtime evidence rather than a string
count.

---

## 1. The headline number
| | |
|---|---|
| ARB keys, ar / en | **338 / 338** — key sets asserted identical |
| User-facing strings still hardcoded in Arabic | **1728** |
| User-facing strings going through l10n | **219** |
| **UI localization coverage** | **11%** |
| Feature surfaces measured | 80 |
| Surfaces fully localized | 12 |

Internal Arabic (1,331 literals across 71 non-widget files) is **excluded and
must stay excluded**: bank names, SMS parser patterns and merchant-matching
keywords are DATA, not copy. Translating a merchant keyword would break the
matching it exists to perform.

## 2. What this means for V1

Qirsh is an Arabic-first product and Arabic is complete. English is **not**.
Reaching parity means extracting, translating and then re-verifying about
1,700 strings across ~35 routes — that is not a 24–48 hour task, and a mass
mechanical string extraction across a financial app mid-release is precisely
the class of change that breaks things silently.

**Recommendation — ship V1 Arabic-first.** Declare Arabic as the app's language
in App Store metadata and do not claim full English support. English remains
available for the 338 localized keys, including the entire new guidance surface.

The alternative — blocking V1 until English parity — costs weeks. The
unacceptable option is shipping a bilingual claim the app cannot honour: a
reviewer switching the device to English would see a mostly-Arabic UI, which is
both a rejection risk and simply untrue.

This is a scope decision with App Store consequences, so it is recorded here and
in the risk register rather than quietly marked PASS.

## 3. What IS fully bilingual today

| Surface | Status |
|---|---|
| Help / "How to use Qirsh" | **AR PASS · EN PASS** — asserted in both locales and both directions |
| First-use coach marks | **AR PASS · EN PASS** — asserted in both locales |
| Category names (all 26) | **AR PASS · EN PASS** — F-1, resolved from the stable key |
| Coupons / savings surfaces | localized (pre-existing `l10n.*` usage) |
| 12 further feature surfaces | no hardcoded Arabic remaining |

## 4. Per-surface coverage

`hard` = hardcoded Arabic literals · `l10n` = localized references.

| Coverage | hard | l10n | Surface |
|---|---|---|---|
| 6% | 167 | 11 | `settings/settings_screen.dart` |
| 0% | 122 | 0 | `transactions/transactions_screen.dart` |
| 0% | 93 | 0 | `budgets/budgets_screen.dart` |
| 0% | 92 | 0 | `dashboard/dashboard_screen.dart` |
| 0% | 90 | 0 | `subscriptions/bill_form_sheet.dart` |
| 0% | 79 | 0 | `design_gallery/design_gallery_screen.dart` |
| 0% | 64 | 0 | `subscriptions/bill_details_sheet.dart` |
| 0% | 62 | 0 | `transactions/transaction_details_screen.dart` |
| 0% | 59 | 0 | `subscriptions/subscriptions_screen.dart` |
| 0% | 57 | 0 | `accounts/account_form_sheet.dart` |
| 0% | 54 | 0 | `settings/data_transfer_screen.dart` |
| 0% | 44 | 0 | `reports/reports_screen.dart` |
| 0% | 40 | 0 | `settings/planning_currency_repair_screen.dart` |
| 0% | 40 | 0 | `plans/plans_screen.dart` |
| 0% | 32 | 0 | `budgets/budget_form_screen.dart` |
| 0% | 31 | 0 | `reporting/ui/report_config_page.dart` |
| 6% | 30 | 2 | `settings/privacy_screen.dart` |
| 0% | 28 | 0 | `transactions/manual_transaction_sheet.dart` |
| 0% | 27 | 0 | `capture/manual_paste_screen.dart` |
| 0% | 24 | 0 | `goals/goal_details_screen.dart` |
| 0% | 24 | 0 | `cards/card_form_sheet.dart` |
| 0% | 22 | 0 | `goals/goal_form_screen.dart` |
| 0% | 22 | 0 | `backup/backup_screen.dart` |
| 0% | 21 | 0 | `goals/goals_screen.dart` |
| 0% | 19 | 0 | `cards/my_cards_screen.dart` |
| 0% | 18 | 0 | `dashboard/widgets/daily_spend_card.dart` |
| 0% | 18 | 0 | `transactions/widgets/confirm_transaction_sheet.dart` |
| 18% | 18 | 4 | `onboarding/ios_shortcut_guide.dart` |
| 0% | 16 | 0 | `achievements/achievements_screen.dart` |
| 0% | 16 | 0 | `plans/plan_form_sheet.dart` |
| 0% | 16 | 0 | `cards/brand_mark.dart` |
| 0% | 15 | 0 | `announcements/announcements_screen.dart` |
| 0% | 15 | 0 | `common/account_range_controls.dart` |
| 0% | 14 | 0 | `foundation/foundation_home_screen.dart` |
| 0% | 14 | 0 | `backup/restore_payload_repair_view.dart` |
| 0% | 13 | 0 | `accounts/account_detail_screen.dart` |
| 0% | 13 | 0 | `budgets/allocate_income_sheet.dart` |
| 0% | 12 | 0 | `dashboard/widgets/monthly_spend_card.dart` |
| 0% | 12 | 0 | `common/charts/spending_charts.dart` |
| 0% | 12 | 0 | `accounts/account_deletion_sheet.dart` |
| 0% | 11 | 0 | `settings/planning_server_repair_section.dart` |
| 0% | 11 | 0 | `bank_discovery/bank_discovery_confirmation_sheet.dart` |
| 0% | 11 | 0 | `dashboard/widgets/obligations_card.dart` |
| 0% | 10 | 0 | `cards/bank_mark.dart` |
| 0% | 10 | 0 | `dashboard/widgets/budgets_card.dart` |
| 71% | 10 | 24 | `onboarding/setup_screen.dart` |
| 0% | 10 | 0 | `planning_sync/planning_conflicts_sheet.dart` |
| 0% | 8 | 0 | `reporting/ui/report_preview_screen.dart` |
| 0% | 8 | 0 | `app/app_shell.dart` |
| 0% | 7 | 0 | `accounts/accounts_screen.dart` |
| 0% | 6 | 0 | `capture/sms_permission_screen.dart` |
| 0% | 6 | 0 | `app/startup_loading_screen.dart` |
| 0% | 6 | 0 | `cards/card_details_screen.dart` |
| 0% | 6 | 0 | `common/app_transaction_row.dart` |
| 71% | 6 | 15 | `onboarding/restore_prompt_screen.dart` |
| 0% | 5 | 0 | `capture/capture_entry_sheet.dart` |
| 0% | 5 | 0 | `dashboard/widgets/coupons_corner.dart` |
| 0% | 5 | 0 | `transactions/widgets/change_category_sheet.dart` |
| 0% | 5 | 0 | `common/planning_repair_gate.dart` |
| 0% | 4 | 0 | `dashboard/widgets/transactions_panel.dart` |
| 0% | 3 | 0 | `onboarding/force_update_screen.dart` |
| 0% | 2 | 0 | `common/widgets.dart` |
| 0% | 2 | 0 | `common/top_banner.dart` |
| 0% | 2 | 0 | `common/widgets/announcement_banner.dart` |
| 0% | 1 | 0 | `app/app_boot_loader.dart` |
| 0% | 1 | 0 | `cards/card_network_badge.dart` |
| 94% | 1 | 17 | `coupons/coupon_widgets.dart` |
| 0% | 1 | 0 | `onboarding/widgets/onboarding_scaffold.dart` |
| 100% | 0 | 1 | `ads/qirsh_ad_banner.dart` |
| 100% | 0 | 9 | `capture/widgets/sms_capture_disclosure.dart` |
| 100% | 0 | 29 | `referrals/referrals_screen.dart` |
| 100% | 0 | 5 | `coupons/savings_confirm_sheet.dart` |
| 100% | 0 | 8 | `coupons/merchant_offers_screen.dart` |
| 100% | 0 | 12 | `coupons/savings_screen.dart` |
| 100% | 0 | 15 | `coupons/coupons_screen.dart` |
| 100% | 0 | 16 | `onboarding/story_screen.dart` |
| 100% | 0 | 3 | `onboarding/brand_screen.dart` |
| 100% | 0 | 8 | `onboarding/auth_screen.dart` |
| 100% | 0 | 11 | `help/coach_marks.dart` |
| 100% | 0 | 29 | `help/help_screen.dart` |

## 5. If parity is later funded

Order by user exposure, not by string count: `dashboard_screen` and
`transactions_screen` are what a reviewer and a new user see first, even though
`settings_screen` holds more strings. Extract per surface, land each with a
both-locale widget test like the Help screen's, and keep the ar/en key-set
equality assertion that already guards the ARB files.
