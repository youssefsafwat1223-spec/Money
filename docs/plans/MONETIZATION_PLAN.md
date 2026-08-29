# Mali — Complete Monetization Plan

> Strategy document — no code, no implementation. Business + product + technical plan only.
> Last updated: 2026-06-14

---

## 1. Best Monetization Models

Mali is a **trust-first financial tool**. Every monetization decision must pass one filter: *does the user feel like the app is on their side?*

### Tier 1 — Recommended Now

| Model | Why it fits |
|-------|-------------|
| **Freemium + Premium subscription** | Predictable revenue, respects user control, works on App Store |
| **Rewarded ads (opt-in only)** | User-controlled, high CPM, zero trust damage |
| **Contextual coupons & offers** | Massive cultural fit in Arab market, users love deals |

### Tier 2 — Recommended Later (Month 4+)

| Model | Why it fits |
|-------|-------------|
| **Affiliate partnerships** | Highest revenue per user, zero ad friction |
| **Native sponsored content** | Non-intrusive if done transparently |
| **API access / business tier** | For accountants, SMBs, families |

### Never

| Model | Why to avoid |
|-------|-------------|
| Banner ads in main app | Makes financial tool feel cheap. Destroys trust. |
| Interstitial / pop-up ads | Trust killer. Never in a financial app. |
| Selling user data | Illegal in most target markets + destroys brand permanently |
| Aggressive BNPL promotions | Predatory reputation risk |

---

## 2. Free Plan — What's Included

The free plan must be **genuinely useful** — not crippled. Arab market users uninstall immediately if they feel tricked.

**Free forever:**
- Unlimited SMS parsing for all supported banks (core value, never lock this)
- Unlimited transaction history (last 12 months)
- Up to 3 accounts / wallets
- Up to 5 budgets (any period)
- Up to 3 goals
- All system categories + up to 5 custom categories
- Basic monthly / weekly spending reports
- Subscription tracker (up to 10 subscriptions)
- Privacy mode
- Data export CSV — always free (trust signal)

**Why this much for free:** Mali's moat is automatic SMS parsing. If users can't experience it fully they won't subscribe. Give the core away; monetize the depth.

---

## 3. Rewarded Ads — Feature Gates

Rewarded ads work best when the user hits a natural friction point and is offered a gentle way through. Never forced — user chooses to watch.

| Feature | Gate |
|---------|------|
| Extend report to 90 days | Watch 1 ad → unlock for 7 days |
| Export PDF spending report | Watch 1 ad per export |
| Unlock 4th goal slot (temporarily) | Watch 1 ad → 30 days |
| "Merchant insights" — top 5 overspend | Watch 1 ad → see this week |
| Custom category icon & color | Watch 1 ad → unlock permanently |
| Yearly spending summary | Watch 1 ad → unlock |

**Rules:**
- Always optional — never block core functionality
- Clear label: "شاهد إعلاناً قصيراً لإلغاء القفل"
- No ads during: transaction entry, onboarding, financial review
- Max 2 ad opportunities surfaced per session
- Premium users: all rewarded gates open automatically, no ads shown

---

## 4. Premium-Only Features (Mali Plus)

| Category | Features |
|----------|---------|
| **Limits** | Unlimited accounts, budgets, goals, subscriptions, categories |
| **History** | Full all-time history (no 12-month cap) |
| **Reports** | Year-over-year comparison, per-merchant trends, category heatmap, predictive budget alerts |
| **Alerts** | Unusual spending detection, recurring charge amount changed, budget pacing warnings |
| **Power features** | Multi-currency display, sub-categories, scheduled weekly summary notification |
| **Parser** | Priority access to new bank rules before public release |
| **Experience** | No rewarded ads — all gates open automatically, early access to new features |
| **Data** | Encrypted backup & restore (user-controlled) |

**What premium is NOT:**
- Does not unlock better SMS parsing — always free
- Does not get exclusive offers/coupons — those are free too
- Not required for any core feature

---

## 5. Ad Placement Strategy

### ✅ Rewarded Ads
- **Where:** Behind specific feature gates (see section 3)
- **When:** Only when user taps a locked feature
- **Format:** Full-screen video, skippable after 5s
- **Frequency:** Max 2 per session, never twice in a row
- **Provider:** Google AdMob (highest fill rate in MENA), Applovin as backup

### ✅ Native Ads (carefully)
- **Where:** Only in Discover / Offers section — never in main app flow
- **Format:** Card that looks like an offer, clearly labeled "ممول" or "إعلان"
- **Content:** Relevant financial products only (cards, savings, insurance)
- **Frequency:** Max 1 native card per 5 organic cards in Discover feed

### ❌ Banner Ads — Never
- Destroys the premium feel
- Distracts during financial review
- CPM is low — not worth the trust damage

### ❌ Interstitials — Never
- Full stop. No exceptions for a financial app.

---

## 6. Sweepstakes / Raffles — Good Idea or Risky?

**Too risky as a feature. Better reframed.**

**The legal problem:**
- **Saudi Arabia:** Gambling and prize promotions restricted under Islamic finance principles
- **UAE:** Requires a permit from Ministry of Economy for any raffle or prize draw
- **Egypt:** Less strict but still sensitive

**The reframe that works — Savings Challenges:**
- "Save 500 SAR this month → unlock an exclusive merchant discount"
- "Hit your grocery budget for 4 weeks → get a partner coupon"
- Brand partners pay for the reward. You earn affiliate revenue. User gets genuine value.

**Verdict:** Skip sweepstakes entirely. Run savings challenges with brand rewards instead.

---

## 7. Coupon and Offers Strategy

Highest-potential feature for the Arab market. The region has extremely high deal-seeking behavior (Noon, Amazon.ae, Carrefour, Talabat).

### Core Principle
**Contextual relevance wins.** A coupon for a restaurant shown after the user spent at restaurants this week is worth 10x a random coupon.

### User Flow
- Discover tab with partner offers (free for all users — drives retention)
- Contextual offer surfacing: "You spent 200 SAR at Carrefour — here's a discount for next time"
- Coupons filterable by category (food, shopping, travel, health)
- One-tap copy of coupon code
- Expiry countdowns
- **Matching logic runs on-device** — no spending data sent to server

### Revenue Models
| Model | How |
|-------|-----|
| CPC | Partner pays per tap on their offer |
| CPR | Partner pays when user redeems the code (unique code per user) |
| Flat sponsorship | Partner pays for featured placement for 30 days |

### What to Avoid
- Never show loan or high-interest BNPL offers
- Never show irrelevant offers (gym coupon to someone who never spent on fitness)
- Max 3 offer notifications per week
- User can disable the Discover tab entirely

---

## 8. Affiliate Partnership Strategy

Highest revenue per user model. You earn when users take valuable actions (open account, get card, buy insurance).

### Tier 1 — High Priority (launch with)

| Partner Type | Example Brands | Revenue Model |
|---|---|---|
| Digital banks / neobanks | STC Pay, Tamara, Lean | CPA per account opened |
| Credit cards | AMEX, Visa partners, Mada | CPA per approved application |
| Investment platforms | Wahed, Sarwa, Biyak | CPA per funded account |
| Insurance | Tawuniya, Bupa Arabia | CPA per quote or purchase |
| Telco plans | STC, Zain, Ooredoo | CPA per plan switch |

### Tier 2 — Future

| Partner Type | Example | Revenue Model |
|---|---|---|
| E-commerce | Noon, Amazon.ae | Commission per purchase |
| Travel | Almosafer, Booking.com | Commission per booking |
| Real estate | Bayut, Property Finder | Lead fee |
| Cars | Syarah, Motory | Lead fee |

### Contextual Trigger Examples

- User has 3 different banks → "Compare credit cards — find the best cashback for your spending pattern"
- User has recurring STC subscription → "You're paying X SAR/month on telecom — see better plans"
- User's goal is 50% reached → "Put your savings to work — explore investment options"
- User tracks multiple currencies → "Open a multi-currency account"

### Transparency Rules
- Every affiliate recommendation labeled: "قد نحصل على عمولة إذا اشتركت"
- Explanation that financial data is NOT shared with partner
- User can turn off financial recommendations in settings

### Revenue Projection (rough)
- CPA for digital bank account: $10–$30 per conversion
- CPA for credit card: $30–$80 per approved application
- 10,000 active users × 2% conversion on credit card = $6,000–$16,000 per campaign

---

## 9. Pricing Tiers

### Recommended Prices (Arab Market)

| Plan | SAR | AED | EGP | Billing |
|------|-----|-----|-----|---------|
| **Mali Free** | 0 | 0 | 0 | Forever |
| **Mali Plus Monthly** | 19 | 19 | 59 | Monthly |
| **Mali Plus Annual** | 149 | 149 | 449 | Yearly (~35% off) |
| **Mali Plus Lifetime** | 349 | 349 | — | One-time (launch promo only) |

**Notes:**
- Lifetime deal: launch offer only, remove after 60 days. Creates early revenue + word-of-mouth.
- Price in local currency on App Store — never show "USD equivalent"
- Annual plan typically converts better than monthly in this region

### Future Tiers (Month 9+)

| Plan | Price | What |
|------|-------|------|
| Mali Family | 249 SAR/year | 2 users, shared reports |
| Mali Business | Custom | Teams, accountants, API access |

---

## 10. MVP vs Future Monetization

### Month 1–2: Minimum Viable Monetization
**Goal:** Validate willingness to pay.

- ✅ Free plan with defined limits
- ✅ Mali Plus subscription (monthly + annual)
- ✅ Lifetime deal (60 days only)
- ✅ Rewarded ads for 2–3 feature gates
- ❌ No offers, affiliates, or native ads yet

**Success signal:** 3–5% of active users convert to Plus within 60 days.

### Month 3–4: Add Offers
- ✅ Discover tab with partner coupons
- ✅ 5–10 launch partners (Noon, Carrefour, food delivery)
- ✅ Admin panel for offer management

### Month 5–6: First Affiliate
- ✅ One credit card or neobank partner
- ✅ Single contextual trigger
- ✅ Affiliate disclosure reviewed by legal

### Month 7–9: Scale Monetization
- ✅ More affiliates (insurance, investment)
- ✅ Native ads in Discover (clearly labeled)
- ✅ Savings challenges with partner rewards
- ✅ A/B test premium pricing

### Month 10–12: Business Tier & API
- ✅ Family plan
- ✅ Business plan (accountants, SMBs)
- ✅ Affiliate API for automated campaign management

---

## 11. UX Rules — Ads Must Never Feel Annoying

**10 non-negotiable laws:**

1. **Never interrupt a financial action.** No upsell during transaction entry, budget review, or goal tracking.

2. **Rewarded ads are always a choice, never a surprise.** User taps → sees gate → chooses to watch. Never auto-play.

3. **Premium pitch only at friction points.** Show upgrade prompt only when user hits a limit — not randomly.

4. **One pitch per session.** If user dismisses a premium upsell, don't show another one that session.

5. **The free experience must feel complete.** Free users should never feel punished. Plus users feel *empowered*.

6. **Offers are in their own section.** Dashboard, transactions, and budgets are completely ad-free.

7. **No dark patterns.** No pre-ticked subscription boxes. No "cancel anytime" in tiny print. No hiding the free option.

8. **Every affiliate recommendation is transparent.** "We may earn a commission" always visible.

9. **User data is never the product.** Financial data stays on device. No spending data leaves for ad targeting.

10. **Ads adapt to user status.** Premium users: zero ads, zero gates. Free user who watched an ad today: no more ads today.

---

## 12. Technical Architecture Needed

> Do not build now. Build as monetization scales.

| Component | Purpose | When needed |
|-----------|---------|-------------|
| Feature flag system | Gate premium features, A/B test | ✅ Already built |
| Offer catalog | Dynamic offers from admin | ✅ Already built |
| In-App Purchase (IAP) | Apple/Google subscription billing | Month 1 |
| Ad SDK (AdMob) | Rewarded ads | Month 2 |
| Affiliate link tracker | Track CPA conversions | Month 5 |
| Revenue analytics | MRR, churn, LTV per segment | Month 4 |
| A/B test framework | Test prices, copy, placement | Month 6 |
| Offer matching engine | Contextual surfacing (on-device) | Month 4 |
| Webhook receiver | Affiliate networks confirm conversions | Month 5 |
| Subscription management API | Pause, upgrade, refund flows | Month 3 |

---

## 13. Admin Dashboard Modules Needed

Add to existing admin panel in future phases:

| Module | What it shows |
|--------|---------------|
| Revenue Dashboard | MRR, ARR, new subscribers, churn, LTV |
| Subscription Manager | Active subscribers, plan distribution, cancellations |
| Offer Manager | ✅ Already planned — CRUD for offers/coupons |
| Affiliate Campaign Manager | Active campaigns, click rates, CPA conversions |
| Ad Performance | Rewarded ad impressions, eCPM, revenue per user |
| A/B Test Manager | Running tests, variants, conversion rates |
| User Segments | Free vs Plus, country, activity level |
| Cohort Analysis | Retention by signup month, conversion timing |
| Revenue by Country | Which market drives the most revenue |

---

## 14. Legal and Trust Risks

### High Priority

| Risk | Detail | Action |
|------|--------|--------|
| Apple / Google IAP rules | All subscriptions must use App Store billing (30% cut). Cannot link to external payment. | Integrate StoreKit / Billing before launch |
| Saudi PDPL | Any data shared with affiliates requires explicit consent. Financial behavioral data requires disclosure. | Legal review before any affiliate launch |
| UAE Consumer Protection | "Paid partnership" / "ممول" label required on all affiliate content | Add to design system |
| Gambling laws | Sweepstakes prohibited or regulated in Saudi / UAE | Use savings challenges instead |
| VAT on digital services | SA: 15%, UAE: 5%, EG: 14% | Register for VAT before subscription launch |

### Medium Priority

| Risk | Detail |
|------|--------|
| App Store Guideline 3.2.1 | Apps cannot use IAP to purchase content delivered outside the app. Affiliate links to external apps are allowed. |
| Financial product recommendations | Some GCC regulators require advisory license. Frame as "options to explore" not "recommendations". |
| AdMob placement policies | Rewarded ads must not be misleading. Cannot show ads to users under 13. |

---

## 15. 12-Month Monetization Roadmap

```
MONTH 1–2 — Foundation
────────────────────────────────────────────────────────
Launch Mali Plus (monthly + annual)
Lifetime deal — 60 days only
2–3 rewarded ad gates (report extension, PDF export)
AdMob SDK integration
Apple / Google IAP integration
Basic revenue tracking in admin

Goal: First 100 paying subscribers
────────────────────────────────────────────────────────

MONTH 3–4 — Discover & Offers
────────────────────────────────────────────────────────
Launch Discover tab with coupons
5–10 launch partners (e-commerce + food)
Admin offer management live
Revenue analytics dashboard (MRR, churn)
A/B test premium pricing

Goal: Offers engagement > 20% of DAU
────────────────────────────────────────────────────────

MONTH 5–6 — First Affiliate
────────────────────────────────────────────────────────
One credit card or neobank affiliate live
Single contextual trigger
Affiliate disclosure + legal review
Conversion tracking via webhook

Goal: First affiliate revenue $500–$2,000
────────────────────────────────────────────────────────

MONTH 7–8 — Scale Affiliates
────────────────────────────────────────────────────────
Add insurance + investment partners
Native sponsored cards in Discover (clearly labeled)
Savings challenges with partner rewards
Contextual matching engine (on-device)

Goal: Affiliate revenue > subscription revenue
────────────────────────────────────────────────────────

MONTH 9–10 — Optimize & Expand
────────────────────────────────────────────────────────
A/B test pricing, copy, gate placement
Referral program: invite a friend → 1 month free
Family plan launch
Annual push campaign (Ramadan / year-end)

Goal: LTV > 3x CAC
────────────────────────────────────────────────────────

MONTH 11–12 — Business Tier & Platform
────────────────────────────────────────────────────────
Mali for Business (teams, accountants)
Affiliate API for self-serve campaigns
B2B partnerships (HR platforms, corporate benefits)
Regional expansion push (new country = new catalog)

Goal: Multiple revenue streams, MRR > $10,000
────────────────────────────────────────────────────────
```

---

## One-Page Summary

```
NOW (Month 1):     Free + Premium subscription + 2 rewarded ads
SOON (Month 3):    Offers/coupons in Discover tab
LATER (Month 5):   First affiliate partnership
FUTURE (Month 9+): Family plan, business tier, self-serve affiliate API

NEVER:             Banner ads, interstitials, selling user data,
                   sweepstakes, predatory BNPL, dark patterns

CORE RULE:         The app must always feel like it is on the user's side.
                   Every monetization decision is filtered through this.
```
