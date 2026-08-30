# AdMob Safety Model

Read this before entering any identifier. The failure modes are asymmetric, and
one of them crashes the app for every user on every launch.

## The crash risk — why a malformed App ID is not a normal typo

The Google Mobile Ads SDK validates the Android App ID in
`MobileAdsInitProvider`, a `ContentProvider` with `android:initOrder="100"`. It
runs at **process start, before any Dart code executes**.

A malformed value therefore raises the SDK's invalid-initialisation exception
and **crashes the app on every launch, for every user, whether or not ads are
enabled**. No Dart guard can intercept it — Dart has not started yet.

That is why the shape check lives in `build.gradle.kts` and **fails the build**
rather than warning. It is the only place that can still help.

The regex is not a guess:

```
^ca-app-pub-[0-9]{16}~[0-9]{10}$
```

It mirrors what the SDK itself enforces — verified by disassembling
`zzev#attachInfo` in `play-services-ads-api:25.3.0`. A looser gate would pass a
value that still crashes at launch, which would be worse than no gate at all.

The same regex is enforced independently in Dart
(`ReportAdsBuildConfig._appIdShape`) so the two layers cannot drift.

## The three states a release build can be in

| State | What happens |
|---|---|
| **Absent** | Android manifest keeps a *valid* Google sample ID so the SDK initialises and the app runs. Dart reports "not configured" ⇒ **no ad is ever requested**. Report still generates. |
| **Malformed** | **Build fails** (Android). Nothing ships. |
| **Valid production** | Ads serve normally. |

This is the fail-closed-for-ads contract: **no ads, no crash, and never a
production build quietly serving on Google's sample identifiers.**

## Why a release can never fall back to test IDs

`ReportAdsBuildConfig.resolve()` returns `null` — meaning "not configured" — if
the supplied value:

- is empty or whitespace, or
- fails shape validation, or
- **starts with Google's test publisher** `ca-app-pub-3940256099942544`.

That last check is deliberate. A production artifact running on sample
identifiers would look like it worked while earning nothing and violating
AdMob's terms. It is treated as *unconfigured*, not as valid.

Debug and profile builds always use the test identifiers, always. Development
and QA never touch a production ad unit.

## Both halves or nothing

`isConfiguredFor(platform)` requires **both** the App ID and the interstitial
unit ID for that platform.

An ad unit without a matching App ID would have the SDK initialise against
whatever the native layer happens to carry — in a release with no injected
value, the sample placeholder. That is exactly the silent test-identifier
shipping this guards against, so incomplete configuration means **no ad
opportunity**, and the report still generates.

Platform values never cross: iOS resolves iOS values, Android resolves Android
values, asserted by test.

## What is deliberately NOT here

Enforced by `app/test/architecture/report_ads_guards_test.dart`:

- **No rewarded ads** anywhere in the ads layer or in `lib/`.
- **No Qirsh-owned ad consent state** — Google UMP is the sole authority.
- **No `report_ads_config` table or symbol** in the client. Ad config is build
  configuration, not a remote row.
- **No Drift schema bump** — R4 stays on v31.
- **The ads layer never reads entitlement tables directly.**
- **No production ad IDs in source** — only the Google test publisher's units.

No IDFA / App Tracking Transparency prompt is requested in V1. iOS declares one
`SKAdNetworkIdentifier` (`cstr6suwn9.skadnetwork`) in `Info.plist`.
