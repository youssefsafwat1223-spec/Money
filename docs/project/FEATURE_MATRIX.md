# Qirsh — feature matrix

**As of 2026-09-02.** Every cell was verified against source today. Where a
previous report claimed otherwise, this file is right and the report is stale.

## Legend

- **Impl** — the code exists and is complete.
- **Wired** — production code actually reaches it. *A feature can be fully
  implemented and tested and still be unreachable; three are.*
- **Tested** — covered by the automated suite.
- **Runtime** — exercised in a running app (simulator or emulator).
- **Device** — exercised on physical hardware.
- **Backend** — the server side it depends on is deployed.
- **Flag** — default state.
- **Prod** — validated in production with real users/partners.

`—` means not applicable. **No column below has a single ✅ under Device or
Runtime: no physical device has ever been attached to this machine, and no
simulator or emulator run has been performed.**

---

## Capture and parsing

| Feature | Impl | Wired | Tested | Runtime | Device | Backend | Flag | Prod |
|---|---|---|---|---|---|---|---|---|
| Android automatic SMS | ✅ | ✅ *(fixed 2026-09-02)* | ✅ | ❌ | ❌ | — | opt-in, default off | ❌ Play approval pending |
| Android share-to-Qirsh | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| iOS Shortcuts capture | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `process-ios-sms` | always on | ❌ |
| iOS share extension (text) | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| iOS share extension (URL) | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Manual paste | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Parser engine | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ catalog rules | `parser_engine_version=v1` | ❌ |
| Categorization | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ catalog | always on | ❌ |
| Smart Inbox | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ `smart_inbox_pull_sync` OFF | OFF | ❌ |
| Durable capture queue | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| **Proof-Carrying engine** | ✅ | **❌ zero callers** | ✅ | ❌ | ❌ | ✅ `parse-sms` shadow route | n/a — cannot activate by flag | ❌ |

## Money and planning

| Feature | Impl | Wired | Tested | Runtime | Device | Backend | Flag | Prod |
|---|---|---|---|---|---|---|---|---|
| Transactions | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Accounts / multi-currency | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ `planning_accounts_sync` OFF | OFF | ❌ |
| Cards | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Budgets | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ OFF | OFF | ❌ |
| Goals | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ OFF | `enable_goals` ON | ❌ |
| Subscriptions / bills | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ OFF | OFF | ❌ |
| Plans | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ OFF | OFF | ❌ |
| Reports + PDF export | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Dashboard | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |

## Sync, data and identity

| Feature | Impl | Wired | Tested | Runtime | Device | Backend | Flag | Prod |
|---|---|---|---|---|---|---|---|---|
| Local Drift (SQLCipher) | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Cloud ledger sync | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ through 0092 | **all OFF** | ❌ |
| Encrypted backup | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ storage bucket | always on | ❌ |
| Restore | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | always on | ❌ |
| Authentication (Google/Apple) | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | always on | ❌ |
| Onboarding | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Account deletion / wipe | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `0084` applied (verified) | always on | ❌ |
| Feature flags | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `catalog-flags` | — | ❌ |
| Notifications (local) | ✅ | ✅ | ✅ | ❌ | ❌ | — | user pref | ❌ |
| APNs push | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ functions exist | — | ❌ no key |

## Monetization

| Feature | Impl | Wired | Tested | Runtime | Device | Backend | Flag | Prod |
|---|---|---|---|---|---|---|---|---|
| Report interstitial | ✅ | ✅ | ✅ | ❌ | ❌ | — | `enable_report_ads` OFF | ❌ no ad unit |
| Banner (transactions) | ✅ | ✅ | ✅ | ❌ | ❌ | — | OFF ×2 | ❌ no ad unit |
| UMP consent | ✅ | ✅ | ✅ | ❌ | ❌ | — | — | ❌ |
| Ad-free entitlement | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `0083` | — | ❌ |
| Referrals | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `0083` | `enable_referrals` OFF | ❌ |
| Coupons catalog | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ `0081/0082` applied | `enable_coupons` OFF | ❌ |
| Merchant offers | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ `0094` source-only | OFF | ❌ |
| Affiliate ingestion | ✅ | ✅ | ✅ fixture | ❌ | ❌ | ❌ `0096` source-only | OFF | ❌ no network |
| Affiliate attribution | ✅ | ✅ | ✅ fixture | ❌ | ❌ | ❌ `0097` source-only | OFF | ❌ no network |
| **Affiliate click gateway** | ✅ | **❌ zero callers** | ✅ | ❌ | ❌ | ❌ | OFF | ❌ |
| Savings ledger | ✅ | ✅ | ✅ | ❌ | ❌ | — local only | `enable_savings_claims` OFF | ❌ |
| Share-to-Qirsh (offers) | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |

## Platform and operations

| Feature | Impl | Wired | Tested | Runtime | Device | Backend | Flag | Prod |
|---|---|---|---|---|---|---|---|---|
| Admin panel | ✅ | ✅ | ✅ 140 tests | ❌ | — | ✅ through 0092 | — | ❌ |
| Localization AR/EN | ✅ | ✅ | ✅ freshness gate | ❌ | ❌ | — | — | ❌ |
| Privacy / consent screens | ✅ | ✅ | ✅ | ❌ | ❌ | — | always on | ❌ |
| Biometric lock | ✅ | ✅ | ✅ | ❌ | ❌ | — | user pref | ❌ |
| Android signing | ✅ | — | ✅ guard | — | ❌ | — | — | ❌ not enrolled |
| iOS signing / provisioning | ⚠️ partial | — | ✅ guard | — | ❌ | — | — | ❌ portal blocked |
| Telemetry | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ `0098` source-only — events dropped until applied | consent-gated | ❌ |

---

## The four rows that matter most

1. **Proof-Carrying engine — implemented, tested, unreachable.** A flag flip
   cannot activate it; there is no call site. Shipping dormant is the reviewed
   decision.
2. **Affiliate click gateway — implemented, tested, unreachable.** Deliberate:
   no network is contracted and wiring a gated egress path early adds
   accidental-activation risk for no benefit.
3. **Android automatic SMS — was unreachable, now wired.** This was the release
   blocker; it is fixed, and a reachability guard prevents the regression.
4. **Every Device and Runtime cell is ❌.** That is the honest ceiling on any
   readiness claim above ENGINEERING COMPLETE.
