# Qirsh AdMob And PDF Reports Plan

## Goal

Add a monetization layer using AdMob while keeping Qirsh useful and premium. Also build a full PDF financial report that users can export/share, with optional ad-supported access rules.

## Product Direction

Ads should not make the app feel cheap. Use ads as a light monetization gate around high-value outputs, especially full reports, not inside core financial workflows.

Primary idea:

- User can generate a full PDF report.
- Free users may watch an ad or have a daily/monthly limited number of full reports.
- Premium users can export without ads.
- The report is marketed as a polished "Qirsh Financial Snapshot".

## AdMob Placements

Preferred placements:

- Rewarded ad before exporting full PDF report for free users.
- Optional rewarded ad to unlock advanced insights for the current period.
- Native ad in a non-critical discovery area, such as coupons/offers feed, only if it does not compete with partner coupons.

Avoid:

- Ads during transaction confirmation.
- Ads on manual SMS paste flow.
- Ads on auth/onboarding.
- Ads inside sensitive transaction details.
- Interstitial ads after every action.

## Device And Platform Handling

The app should automatically detect platform and ad availability:

- iOS: use iOS AdMob unit IDs.
- Android: use Android AdMob unit IDs.
- Debug: use test ad unit IDs only.
- If ads fail to load, do not block critical app usage.
- If user is premium, ads should be disabled.
- If region/legal constraints apply, disable personalized ads.

## Ad Consent

Need a consent and privacy flow:

- Ask for ad personalization consent when required.
- Store consent in settings.
- Allow changing consent later from settings.
- Use non-personalized ads if consent is not granted.
- Make ads opt-out for premium users.

## PDF Report Product

Report sections:

- Cover page: Qirsh logo, user display name, selected account/currency, date range.
- Executive summary: income, expenses, net cashflow, top category, biggest merchant.
- Daily spending chart.
- Category breakdown.
- Merchant breakdown.
- Subscriptions and installments.
- Budget performance.
- Goals progress.
- Notable insights:
  - highest spending day
  - repeated merchants
  - unusual spikes
  - remaining budget
- Transactions appendix, optional.

Report filters:

- Selected account or all accounts.
- Currency.
- Date range: week, month, quarter, year, custom.
- Include/exclude transaction appendix.
- Arabic-first layout, with English option later.

## PDF UX

Flow:

1. User opens Reports.
2. Chooses date range/account.
3. Taps "تصدير تقرير PDF".
4. If premium: generate immediately.
5. If free: show "شاهد إعلاناً لفتح التقرير الكامل" or limited free export.
6. Generate PDF.
7. Preview/share/save.

Important states:

- Loading report data.
- Generating PDF.
- Ad loading.
- Ad failed, with fallback message.
- Export success.
- Share failed.

## Data Needed

Use existing repositories/providers:

- Transactions by date range/account.
- Budgets and budget progress.
- Goals.
- Subscriptions/installments.
- Categories.
- User settings and profile data.
- Active account/base currency.

New data:

- `report_exports`
  - `id`
  - `user_id` nullable
  - `install_id`
  - `date_range`
  - `account_scope`
  - `used_rewarded_ad`
  - `created_at`

- `ad_events`
  - `ad_unit`
  - `placement`
  - `event_type`: load, show, reward, fail
  - `error_code`
  - `created_at`

## Implementation Phases

### Phase 1: PDF Report MVP

- Build report data aggregator.
- Build PDF renderer.
- Export/share PDF from Reports screen.
- Add Arabic layout and Qirsh branding.
- Add tests for report data calculations.

### Phase 2: AdMob Integration

- Add AdMob dependency and platform setup.
- Add test ad unit IDs.
- Add rewarded ad service.
- Add ad events logging.
- Gate full PDF export for free users.

### Phase 3: Monetization Rules

- Add premium/free entitlement check.
- Add export limits.
- Add settings consent controls.
- Add remote config for enabling/disabling placements.

### Phase 4: Marketing Layer

- Add in-app marketing card:
  - "تقريرك المالي الكامل في ملف PDF"
  - "اعرف أين ذهب كل قرش"
- Add shareable report cover.
- Add watermarked free report option if needed.

## Technical Notes

- Generate PDF locally when possible.
- Do not send transaction data to ad providers.
- Keep ad IDs/config out of source; use env/remote config.
- Use test ads in debug.
- Use production ads only in release.
- Make report generation independent from ad loading so premium/offline paths stay stable.

## First Build Checklist

- Define report data model.
- Add `ReportExportService`.
- Add PDF template with Qirsh logo.
- Add export button in Reports.
- Add rewarded ad service behind feature flag.
- Add test ad units.
- Add event logging.
- Run `flutter analyze`.

