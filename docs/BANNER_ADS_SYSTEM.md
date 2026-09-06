# Banner Ads System — the approved plan, and what was built

**Approved 2026-09-01** by two independent reviewers (Fable and Codex) acting as
delegated product/engineering reviewers. This is the plan they converged on
after one adversarial reconciliation round, plus what shipped against it.

It extends `REPORT_ADS_SYSTEM.md`; it does not replace it. Everything that
document says about UMP, ATT, entitlement and build-time configuration still
holds and is now shared by both formats.

**Nothing is enabled.** Both flags are seeded OFF and fail closed.

---

## 1. Review outcome

Both reviewers returned **APPROVE WITH CHANGES**. They agreed on the
architecture and differed on three points, each resolved by reading source
rather than by preferring a reviewer:

| Question | Fable | Codex | Resolution and why |
|---|---|---|---|
| Ship the Reports placement? | ship | cut | **Cut.** Reports is `NestedScrollView` + `TabBarView`; `Visibility.of` catches the outer shell tab but not an inactive inner tab page. Reports also already carries the export interstitial, and Fable itself called it weak inventory. |
| Banner size | anchored adaptive, pre-resolved | fixed 320×50 | **Anchored adaptive, pre-resolved, `AdSize.banner` fallback.** The SDK doc guarantees a stable height per width/device, so it is as layout-stable as a fixed size and pays better. Inline adaptive — the format Google nominally recommends for scrollable content — finalises its height only *after* load, which is the jank being avoided. |
| Signed-out users ad-eligible? | change the policy | keep it | **Keep it.** Fable's premise was that sign-in is optional; `app_router.dart:70-82` redirects `needsOnboarding` and `sessionExpired` to `/onboarding/auth`, AppShell exists only at `/`, and nothing in the app ever sets the vestigial `authMethod = 'guest'`. There is no signed-out population on these screens to lose. Fable re-checked and accepted. |

Two claims of mine were wrong and are corrected here: the bottom nav is **not**
a native platform view any more (`MaliGlass` is pure Flutter; the "platform
view" comments in `app_shell.dart` and `app_router.dart` are stale), and
`ReportAdsBuildConfig.resolve` was `@visibleForTesting`, which by itself killed
the two-config-file option.

---

## 2. Placements

### Shipped

**`transactions_list`** — the transactions tab, after the first complete date
section, only when another section follows.

It is the only surface in the app that is high-dwell, browsing-intent, and
carries no destructive or financial-confirmation action. It sits below a
finished card rather than between two transaction rows, because the rows are
tappable and an ad flush against one is the accidental-click layout Google's
discouraged-placements guidance names directly. It does not appear on the
pending-review filter: that list is a correction workflow where the user is
fixing how their money was classified.

### Cut from V1

**Reports** — see §1. **Coupons** — excluded entirely, not merely labelled: it
is an owned affiliate marketplace with tracked commercial CTAs, a third-party
banner competes with those offers and can be confused for one even at the end of
the list, and `enable_coupons` is dark at 0% so the placement would earn nothing
in exchange for that risk. **Budgets** — bottom-of-scroll inventory with poor
viewability. **Dashboard** — the best future inventory, deferred only because
`dashboard_screen.dart` is owned by a concurrent session; this is the first
follow-up.

### Never

Permanent. Onboarding, auth, SMS capture and permission screens, Smart Inbox,
capture review/confirmation, transaction detail, add/edit transaction, any
confirmation or destructive dialog, account deletion, the privacy screen, all
consent/UMP surfaces, backup & restore, data transfer, budget and goal
create/edit, card and account detail, error and empty states, the force-update
screen, the savings confirm sheet, the savings breakdown, and merchant offer
detail.

The rule behind the list: an ad may not sit next to a decision about money, may
not interrupt the loop where a user corrects how a transaction was classified,
and may not be the thing that fills an empty or failed state.

Enforcement is a **positive allowlist** in `report_ads_guards_test.dart` — the
set of files allowed to mention `QirshAdBanner`, asserted exactly. Enumerating
forbidden screens is unbounded and stops covering anything added later;
enumerating permitted ones is finite and fails closed.

---

## 3. Architecture

```
features/ads/
  admob_build_config.dart     six build inputs, shape-validated, fail-closed
  mobile_ads_initializer.dart ONE SDK init, single-flight, bounded, non-throwing
  ad_placement.dart           the placement enum + placement -> unit mapping
  banner_ad_controller.dart   one banner's lifecycle, behind a testable loader
  banner_ads_providers.dart   the non-visual gates
  banner_ads_analytics.dart   consent-gated, key-only telemetry
  qirsh_ad_banner.dart        the ONE widget a feature screen may use
```

A feature screen writes `const QirshAdBanner(placement: AdPlacement.x)` and
nothing else. It never sees a `BannerAd`, an `AdSize`, an ad-unit id, a consent
object or an entitlement state. A guard asserts no Google Mobile Ads import or
symbol appears anywhere in `lib/` outside `features/ads/` and
`features/report_ads/`.

### Configuration

One file, six inputs: `ADMOB_APP_ID_{IOS,ANDROID}`,
`ADMOB_INTERSTITIAL_{IOS,ANDROID}`, `ADMOB_BANNER_{IOS,ANDROID}`. Debug and
profile builds always resolve Google's test units. A release requires
well-formed production values and can never fall back to the test publisher.
Guards assert exactly six names and that no other file in `lib/` reads an
`ADMOB_*` environment value — so adding an AdMob input is always a visible diff.

---

## 4. The gates

Every one must pass. Any false means no banner **and no request**.

1. `enable_banner_ads` (master, default false)
2. `enable_banner_transactions_list` (per-placement, default false)
3. `AdMobBuildConfig.isBannerConfiguredFor(platform)` — app id **and** unit
4. entitlement is `verifiedInactive` — `verifiedActive` and `unknownOrStale`
   both mean no ad
5. UMP `canRequestAds()`
6. `Visibility.of(context)` — see §5
7. `ModalRoute.isCurrent` — not covered by a pushed route
8. `modalRouteOpen == false` — not covered by a sheet or dialog
9. available width ≥ 320
10. the per-placement request throttle (30s) has elapsed

Gates 1–5 are resolved in `bannerEligibilityProvider` **before the widget is
inserted into the list at all**. An unanswered lookup counts as false: a
momentary slot for an ad-free user is still a slot.

**Ad-free users get zero surface** — no request, no reserved space, no widget,
and no telemetry event that would imply an impression opportunity.

---

## 5. The IndexedStack finding

The shell is a 5-tab `IndexedStack`. Flutter wraps every child in
`Visibility(visible: i == index, maintainState: true, maintainSize: true,
maintainAnimation: true, maintainInteractivity: true)`
(`basic.dart:4886`). With `maintainSize: true` that path does **not** use
`Offstage` and does **not** disable `TickerMode` — the child stays mounted and
laid out, and only painting is skipped (`visibility.dart:266`).

So a naive banner on a background tab would be built, sized, and would request
an ad nobody can see. Whether AdMob would count that as an impression is not
something the Flutter source can prove, so it is not claimed here — but the
request is wasted either way and the exposure is not worth testing empirically.

`Visibility.of(context)` (`visibility.dart:248`) is the framework's own answer:
it walks every ancestor visibility scope and registers a dependency, so the
banner rebuilds the moment its tab is hidden or shown. When hidden it disposes
the ad rather than holding a native view attached to a screen nobody is looking
at.

---

## 6. Layout: no jank, by sequencing

The obvious design reserves the ad's height first. It has a worse failure mode:
on a no-fill the user is left looking at an empty box, and collapsing that box
later moves a tappable transaction row under a finger already on its way down.

So: resolve the adaptive height (cheap, no ad), request the ad, and insert the
slot **only once an ad is in hand**. A failure is then completely invisible — no
box, no collapse, no movement. A success is one insertion whose height never
subsequently changes; nothing in the controller can shrink a visible slot.

---

## 7. Lifecycle

One controller per mounted placement, one request per mount. A rebuild, a
scroll, a theme change or a provider invalidation never re-requests. A load
failure is terminal for that mount — **no retry**. There is no client-side
refresh timer and no refresh on resume: the SDK's console-configured refresh
interval is the only refresh, because a client timer on a platform-view banner
is an invalid-traffic risk.

A **per-placement 30-second throttle**, held statically so it survives the
unmount a tab switch causes, stops rapid tab-flicking from becoming a request
storm.

---

## 8. Consent

Unchanged and shared: Google UMP is the sole authority, gathered once per
session from `AppShell`, with no Qirsh-owned advertising-consent boolean
anywhere. Every request is non-personalized — `AdRequest(nonPersonalizedAds:
true)` plus the legacy `npa` extra, matching `REPORT_ADS_SYSTEM.md` §13's
no-ATT decision. No `NSUserTrackingUsageDescription`, no ATT prompt.

One real fix here: the session consent gate returned early in release when
`enable_report_ads` was off, so a banners-on/report-ads-off release would never
have gathered consent and every banner would have failed closed silently. It now
fires when **any** ads product may serve, and a guard test pins that.

---

## 9. Telemetry

Four keys, all outcomes: `banner_ad_requested`, `banner_ad_loaded`,
`banner_ad_failed`, `banner_ad_impression` (from the SDK's own
`onAdImpression`). The `dimension` carries the placement key.

Consent-gated on `cloudProcessingEnabled`, read fresh per send; fire-and-forget;
failures swallowed. Never attached: amount, currency, merchant, bank, category,
SMS content, account, or any spending signal — and a guard asserts the ads layer
imports nothing from `domain/`, `engine/` or `data/repositories/`, so no ad
targeting can be built out of a user's bank messages.

There is deliberately **no** `*_suppressed_*` event. An event meaning "this user
was eligible for an ad but we withheld it" is exactly the impression-opportunity
signal the ad-free design promises never to emit.

Deferred migration `0099` (was 0098) allowlists these keys in `record_metric`, which previously
allowed only `app_open` and silently dropped everything else — including the
report-export ad events that have been emitted and discarded since R4.

---

## 10. Failure model

SDK failure, no fill, timeout, consent unavailable, missing ad unit, offline,
entitlement lookup error, telemetry error — every one results in **no banner and
a working app**. Nothing in the ads layer can fail into a financial screen: it
holds no financial state, imports no financial types, and the transactions list
renders identically whether the banner is there or not.

---

## 11. External prerequisites (NOT done, cannot be done here)

1. **AdMob console** — create the two banner ad units (iOS, Android) and supply
   `ADMOB_BANNER_IOS` / `ADMOB_BANNER_ANDROID` at build time. Until then a
   release build resolves null and serves nothing, by design.
2. **`app-ads.txt`** — does not exist. Google has required `app-ads.txt`
   verification for newly configured apps since January 2025. It must be
   published at `https://qirsh.site/app-ads.txt` with the publisher's real
   AdMob ID; a placeholder is worse than absence, so none is committed.
   This also retroactively benefits the existing interstitial.
3. **`SKAdNetworkItems`** — `ios/Runner/Info.plist` carries exactly one entry
   (Google's own, `cstr6suwn9.skadnetwork`). Google's published list should be
   added to improve iOS bidding demand. Not invented here: the list must come
   from Google's current published source.
4. **AdMob console refresh interval** — the design relies on the console's own
   banner refresh setting, because there is no client timer. It must actually be
   set.
5. **Play Data Safety / App Store privacy** — the SDK's auto-merged `AD_ID`
   permission must be reflected in the store declarations.
6. **Physical device QA** — see `MANUAL_BANNER_QA_CHECKLIST.md`. No Android
   device has ever been attached to this machine and iOS needs Apple portal
   access that requires an unavailable 2FA code.

---

## 12. Rollout

Both flags OFF. Turn on `enable_banner_ads` and
`enable_banner_transactions_list` together; either one alone shows nothing.
Kill either independently — the master removes the format, the placement flag
removes one surface without taking the format with it.
