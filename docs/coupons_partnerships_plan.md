# Qirsh Coupons And Partnerships Plan

## Goal

Build a coupons area inside Qirsh where partner offers appear to users in a useful, finance-native way. The product should feel closer to Waffer-style partner offers, but integrated with spending behavior, dashboard context, and merchant/category intelligence.

## Product Shape

Coupons should not feel like random ads. They should appear when they can save the user money:

- Dashboard section: "عروض توفر عليك" with 2-4 relevant coupons.
- Dedicated coupons screen: searchable partner offers by category, merchant, city/country, and expiry.
- Merchant-aware suggestions: if the user spends at restaurants, groceries, subscriptions, or delivery, show relevant coupons.
- Transaction detail suggestion: after a matching transaction, show "كان ممكن توفر..." when a coupon exists.
- Optional notification: remind the user before a coupon expires, only if they saved/viewed it.

## Data Model

Core tables or remote catalog entities:

- `coupon_partners`
  - `id`
  - `name_ar`
  - `name_en`
  - `logo_url`
  - `website_url`
  - `country_codes`
  - `is_active`

- `coupons`
  - `id`
  - `partner_id`
  - `title_ar`
  - `title_en`
  - `description_ar`
  - `description_en`
  - `coupon_code`
  - `image_url`
  - `category_key`
  - `merchant_keywords`
  - `country_codes`
  - `starts_at`
  - `ends_at`
  - `terms_ar`
  - `terms_en`
  - `deeplink_url`
  - `tracking_url`
  - `priority`
  - `is_featured`
  - `is_active`

- `coupon_events`
  - `coupon_id`
  - `event_type`: view, copy, save, open_partner, redeem_hint
  - `user_id` nullable
  - `install_id`
  - `created_at`

## Admin Flow

Admin must be able to:

- Add/edit partner.
- Upload partner logo and coupon image.
- Add coupon title, description, code, country, category, and date range.
- Mark coupon as featured.
- Preview Arabic/English card.
- Disable expired or problematic offers quickly.
- See basic analytics: views, copies, saves, click-through.

## App UX

Dashboard placement:

- Below main financial summary and before lower insight sections.
- Compact horizontal cards.
- Card contains image/logo, offer title, partner, expiry, and copy/open button.
- If no relevant coupons, hide the section.

Coupons screen:

- Header: "الكوبونات"
- Tabs or chips: الكل، مطاعم، تسوق، توصيل، اشتراكات، قريباً ينتهي
- Search by partner or offer.
- Coupon details bottom sheet with terms, copy button, and partner CTA.

Coupon card states:

- New
- Saved
- Expiring soon
- Copied
- Used hint, if user taps partner link after copy

## Relevance Logic

Ranking should combine:

- User country.
- Selected account/base currency country.
- Spending categories in recent period.
- Merchant names from recent transactions.
- Coupon priority from admin.
- Expiry date.
- Saved/clicked history.

Simple first version:

1. Filter active coupons by country and date.
2. Boost category matches from recent spending.
3. Boost merchant keyword matches.
4. Show featured fallback if no strong match.

## Implementation Phases

### Phase 1: Foundation

- Add local/remote coupon catalog entities.
- Add DAO/repository.
- Add seeded sample coupons for local testing.
- Add dashboard section consuming repository.
- Add copy/open tracking events.

### Phase 2: Admin And Images

- Add admin CRUD for partners and coupons.
- Add image upload.
- Add active/expiry controls.
- Add analytics dashboard.

### Phase 3: Personalization

- Rank coupons using transaction categories and merchants.
- Add transaction-detail suggestions.
- Add saved coupons.
- Add expiry reminders.

### Phase 4: Partner Operations

- Partner contract template.
- UTM/tracking agreement.
- Redemption reporting.
- Manual monthly partner performance export.

## Safety And Compliance

- Clearly mark offers as partner coupons.
- Do not imply financial advice.
- Show expiry and terms.
- Track clicks/copies, not sensitive transaction details.
- Keep user identity out of partner tracking URLs unless explicitly agreed and privacy-reviewed.

## First Build Checklist

- Create coupon model and repository.
- Create sample coupon catalog.
- Add dashboard `CouponsRail`.
- Add coupon details sheet.
- Add copy coupon action.
- Add event logging.
- Add empty state and country filtering.
- Run `flutter analyze`.

