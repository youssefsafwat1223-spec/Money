# Report Ads System — Specification (V1, design-only) — **r3**

> Status: **DESIGN ONLY.** No code, no migrations, no dependencies, no ad-unit
> registration, no staging/production contact. Baseline tree `8d33cff5`,
> **Drift v31 (no bump — see §11)**, server migrations 0001→0082.
> Companions: [REFERRAL_REWARDS_SYSTEM.md](./REFERRAL_REWARDS_SYSTEM.md),
> [REFERRAL_ADS_ADMIN_SYSTEM.md](./REFERRAL_ADS_ADMIN_SYSTEM.md).
> r2: Standard Interstitial, UMP consent authority, no `adConsentState`,
> corrected offline/time claims, v31 retained.
> **r3: three-state entitlement decision (VERIFIED_ACTIVE / VERIFIED_INACTIVE /
> UNKNOWN_OR_STALE), explicit freshness TTL, lookup-failure fail-open-for-the-ad,
> session/account isolation, `entitlement_events` ledger rename, UMP vs
> product-analytics consent split, kill-switch hardening classified as REQUIRED
> before production enablement, `report_ads_config` eliminated.**

## 1. Purpose

A light monetization gate **around the Report Export action only** — never inside
a financial workflow. A user without an active ad-free entitlement may see one
interstitial as part of exporting; a user with the entitlement exports with no
ad. **The report is byte-identical either way, and ad availability never blocks
the export.**

## 2. Canonical Vocabulary (shared by all three specs)

| Term | Value |
|---|---|
| Entitlement type (V1) | `report_export_ad_free` |
| Entitlement sources | `referral_reward`, `admin_grant` (future: `promotion`, `subscription`) |
| Current-state table | `user_entitlement_state` — UNIQUE `(user_id, entitlement_type)` |
| Immutable ledger | **`entitlement_events`** (append-only: grant/extend/revoke/shorten) |
| Report-ads rollout gate | `enable_report_ads` (FeatureFlagService) |
| Referral rollout gate | `enable_referrals` (FeatureFlagService) |
| **Ad format (V1)** | **Google Standard Interstitial** (`InterstitialAd`) |
| Ad result states | `loaded`, `impression`, `displayed`, `dismissed`, `failed_to_load`, `failed_to_show`, `unavailable`, `lifecycle_interrupted` |
| Ad consent authority | **Google UMP** (`canRequestAds`) — not a Qirsh setting |
| Product-analytics consent | **Qirsh `cloudProcessingEnabled`** — separate from UMP (§18) |
| Entitlement decision | `VERIFIED_ACTIVE` \| `VERIFIED_INACTIVE` \| `UNKNOWN_OR_STALE` |
| Entitlement freshness TTL | **5 min** (recommended; short and operationally reasonable) |
| Failure policy (V1) | **fail-open** — export always proceeds |

**Removed in r2:** `AD_SUCCESS` / `AD_COMPLETED` / reward vocabulary,
`RewardedAd`, `RewardedInterstitialAd`, `OnUserEarnedReward*`, a Qirsh
`adConsentState`, and the `require_when_online` Admin policy.

## 3. Current report architecture (repository truth)

```
report_config_sheet.dart :: runReportGeneration(context, ref, request)
  → ReportGenerationController.generate(...)     [dart:isolate PDF render]
      ReportStage: idle→collecting→composing→rendering→writing→ready
      → ReportResult { export: ManagedExport, bytes, snapshot }
  → ReportPreviewScreen → ReportFileService.share(export)
```

- **One choke point.** `runReportGeneration(...)` is the only path from a
  `ReportRequest` to a shared PDF. The gate wraps its front; the isolate is never
  touched.
- Report correctness (Money, `ReportContentOptions`, `privacyMode` masking, PDF
  render) is isolate-local and out of the gate's reach (§13).
- **Ads: clean slate.** No `google_mobile_ads`, no ad-unit IDs, no
  `GADApplicationIdentifier`, no SKAdNetwork list, no ATT descriptor (verified
  across `pubspec.yaml`, `Info.plist`, `AndroidManifest.xml`,
  `Runner.entitlements`, `PrivacyInfo.xcprivacy`).
- `docs/admob_and_reports_plan.md` holds older loose notes; **this spec
  supersedes them** for the Report-Export placement (in particular its "rewarded
  ad before exporting" line, which r2 rejects — §4).

## 4. Ad format: **Standard Interstitial**

**Report Export is an ordinary user-requested application action.** The user is
not receiving a separate benefit in exchange for consuming an ad — they asked for
their own report, and under fail-open they get it whether or not an ad shows.
Modeling the report as a "reward" would misrepresent the transaction to the user
and to the ad network.

| Format | V1 verdict |
|---|---|
| **Standard Interstitial** | **CHOSEN.** A full-screen ad shown at a natural transition point in a flow the user initiated. No reward semantics, no reward callback, no implied exchange. |
| Rewarded Interstitial | **Rejected in r2.** Implies the export is a reward earned by watching; incompatible with fail-open (where the "reward" arrives regardless). |
| Rewarded Ad | Rejected. Opt-in "watch to earn" framing; the user never opted in. |

There is **no** `OnUserEarnedReward` dependency anywhere in the design. Future
rewarded formats may be reconsidered **only** for a genuine optional benefit
("watch an ad to unlock an extra temporary benefit") — explicitly **out of V1**.

## 5. Fail-open policy (unchanged, reinforced)

**The export is never permanently prevented by a third-party ad network.**
Reports are a local, user-owned feature; ads are best-effort monetization on top.

| Result state | Trigger | Export |
|---|---|---|
| `displayed` → `dismissed` | ad shown, user closed it | **proceeds** |
| `failed_to_load` | no-fill, network error, SDK error | **proceeds immediately** |
| `failed_to_show` | SDK refuses to present | **proceeds** |
| `unavailable` | nothing preloaded / SDK not initialized / `canRequestAds == false` | **proceeds, no wait** |
| `lifecycle_interrupted` | backgrounded / process killed during the ad | **proceeds once on resume** |
| offline | no network | **proceeds** |
| consent state forbids an ad request | UMP `canRequestAds == false` | **proceeds** |

`impression` is recorded for analytics/monetization only; it is **never** a
precondition for export.

**Deferred (NOT V1, NOT in Admin config):** a stricter `require_when_online`
monetization experiment. Documented here only as a possible future study; it is
deliberately absent from the V1 Admin surface so no operator can accidentally
make report export depend on ad delivery.

## 6. Frequency contract — one ad opportunity per export request

An ad opportunity is created **at most once per export attempt**, and only when
**all** of:

1. `enable_report_ads` is effective for this install; **and**
2. the entitlement decision is a **fresh `VERIFIED_INACTIVE`** (§8); **and**
3. UMP reports `canRequestAds == true`; **and**
4. valid ad configuration exists for the platform/environment (§12); **and**
5. an ad is safely available within the preload budget (§9).

Repeated taps during the same export operation must **not** create additional ad
opportunities. A `failed_to_load` / `unavailable` outcome must **not** trigger an
immediate retry loop before the same export — the attempt proceeds to generation.

## 7. Export/ad state machine — single-flight, attempt-scoped

Each Export tap that is accepted mints a unique **`exportAttemptId`**. All ad and
generation work is keyed to it; results for a stale id are discarded.

```
idle
 └─(tap Export ⇒ mint exportAttemptId)→ resolvingEntitlement
        ├─ VERIFIED_ACTIVE | UNKNOWN_OR_STALE | flag off | no config | !canRequestAds → generating
        └─ VERIFIED_INACTIVE ⇒ ad opportunity → presentingAd   (≤ preload budget, §9)
                └─ any result state (§5) → generating   [exactly once]
generating  → delegates to the existing ReportGenerationController (unchanged)
 └→ sharing (ReportPreviewScreen)
      └→ completed
 error → failed → idle
```

Invariants:
- Export is **disabled whenever state ≠ `idle`** (driven by the state, not a
  widget-local bool). A second tap in `presentingAd`/`generating` is a no-op.
- **At most one ad opportunity per `exportAttemptId`**; no retry loop within an
  attempt.
- **At most one generation per `exportAttemptId`** — `controller.generate` is
  called exactly once, preserving today's `invalidate()` + single progress dialog.
- **Lifecycle:** if backgrounded during `presentingAd`, on resume the attempt
  resolves to `lifecycle_interrupted` (or the real result if delivered) and
  advances to `generating` **once**. If the process is killed nothing was
  generated, so a fresh tap starts a clean attempt with a new id.
- The share sheet is only reachable from `ReportPreviewScreen` after a successful
  `generating`, so multiple share sheets are structurally impossible.
- **The ad network never influences report correctness** — only whether an ad was
  displayed before the same, unchanged export ran.

## 8. Entitlement decision — **three states, not a boolean** (r3)

The gate never reduces entitlement to active/inactive. It resolves one of:

| Decision | Meaning | Ad? | Export |
|---|---|---|---|
| `VERIFIED_ACTIVE` | fresh server answer: entitlement active | **no ad** | export |
| `VERIFIED_INACTIVE` | **fresh** server answer: no active entitlement | **one ad opportunity** | export |
| `UNKNOWN_OR_STALE` | no fresh answer obtainable | **no ad** | export |

**An ad may be shown ONLY for `VERIFIED_INACTIVE`.** This protects a legitimately
entitled user whenever the entitlement authority cannot be reached — the failure
mode is "user sees no ad", never "entitled user is shown an ad".

### 8.1 Lookup failure ⇒ `UNKNOWN_OR_STALE` ⇒ no ad, export proceeds

Every one of these resolves to `UNKNOWN_OR_STALE` — the gate **never** infers
non-entitlement from a failure:

- Supabase unavailable / server temporarily unreachable
- auth refresh failure
- entitlement RPC timeout
- malformed or unparseable entitlement response
- app just resumed and the refresh has not completed yet
- signed-out / local-only, i.e. no server-backed authority (§8.4)

Outcome in all cases: **skip the ad opportunity for that export attempt and
generate the report.** A third-party or network failure can cause neither report
denial nor an accidental ad shown to a possibly-entitled user.

### 8.2 Freshness contract (r3)

The in-session cache holds `{ decision, ends_at, server_now, verified_at_monotonic }`.

- **TTL: 5 minutes (recommended).** Beyond it a cached answer is no longer fresh.
- **A stale `VERIFIED_INACTIVE` degrades to `UNKNOWN_OR_STALE`** — it never
  remains "inactive forever", so a user who earned an entitlement moments ago is
  not shown an ad on a stale negative.
- **`VERIFIED_ACTIVE` may be used until the earliest of:** its freshness
  deadline, the known server `ends_at` boundary, or session/account invalidation.
  Past any of those it degrades to `UNKNOWN_OR_STALE` (still no ad) until
  refreshed.
- **Only a fresh `VERIFIED_INACTIVE` may authorize an ad opportunity.**
- Refresh points: sign-in, app resume, entry to the report area. **Never on the
  export tap.** Aging within a session uses the monotonic clock; no claim is made
  that the device can prove server time indefinitely offline.

### 8.3 Session / account isolation (r3)

The cache is **keyed to the authenticated user id**. It is cleared **immediately**
on logout, account switch, account deletion, and any auth identity change; a
cache entry whose key ≠ the current user id is never read. One user's ad-free
state can never leak into another user's session.

### 8.4 Signed-out / local-only

Repository truth: the app models `SessionStatus {unknown, needsOnboarding,
authenticated, sessionExpired}` and the router redirects to sign-in on expiry, so
report export is normally reached inside an authenticated shell; a local-only
mode exists when Supabase is unconfigured. Either way the rule is the same and
safe: **if no server-backed entitlement authority can be established →
`UNKNOWN_OR_STALE` → skip the ad → export.** An ad is never shown merely because
authentication failed or was absent.

## 9. Preloading

- **Trigger:** when the report config/preview surface opens **and** the gate
  conditions in §6 (1–4) hold. Not at app startup.
- Keep **one** ready `InterstitialAd`; reload after it is consumed or expires.
- **Bounded wait:** at `presentingAd` the gate waits at most a small budget
  (recommend ≤ 2.5 s) for a ready ad; on expiry → `unavailable` → proceed. The
  user never waits on a third-party download.
- Load failures update only ad-availability state; they can never surface as a
  report error or block generation.

## 10. Server contract & time authority

The server returns `{ status, ends_at, server_now, verified_at }`; **the server
owns `ends_at`**. The client derives the three-state decision of §8 from it and
never computes or extends an expiry.

- **Within a session** the answer is aged with the **monotonic** clock — sound
  for a session, and explicitly **not** a durable proof of time across restarts.
- **No local persistence in V1** (§11). After a cold start with no refresh yet the
  decision is `UNKNOWN_OR_STALE` ⇒ no ad ⇒ export proceeds.
- **Clock tampering cannot extend authority:** the server owns `ends_at`, every
  refresh re-derives truth from `server_now`, and a monotonic delta is unaffected
  by wall-clock changes. Because the policy is fail-open and unknown⇒no-ad, the
  worst case of a stale local view is *fewer* ads, never a blocked export nor an
  unearned extension.
- Ledger/state model: [REFERRAL_REWARDS_SYSTEM.md §Entitlement state contract]
  (`entitlement_events` + `user_entitlement_state`).

## 11. Drift decision (**r2: stay on v31 — no bump**)

Re-evaluated after §10. With **fail-open**, a persisted entitlement cache has
**no correctness role**: an entitled user who is offline at cold start reaches the
same outcome (export succeeds) with or without it. The cache would buy only the
suppression of one failed ad attempt.

**Decision: remain on Drift v31. No `report_ad_entitlement` table, no v32.**
Entitlement state lives in an in-session Riverpod cache refreshed per §10.

Rationale: a schema bump plus three-allowlist registration plus an arch-guard pin
change is real risk and permanent surface, bought for a cosmetic gain; and
persisting a server grant locally creates a staleness/tamper surface for zero
correctness benefit. This honours "do not bump Drift just because an entitlement
exists server-side."

*If* a future phase proves the cold-start ad attempt is a real UX problem, the
table may be added then, and it must be specified as **last-known operational
cache metadata** — refetchable, excluded from the business backup (registered in
`BackupSnapshotBuilder.intentionallyExcluded`, `kOperationalOnlyTables`, and the
data-wipe `preserved` set), and **never reward authority**.

## 12. Consent: **Google UMP is the authority** (r2)

Qirsh does **not** define a competing ad-consent truth. There is **no**
`adConsentState` in `user_settings`. The existing `cloudConsentState` /
`aiConsentState` remain untouched and unrelated.

Required lifecycle:

```
app launch
 → MobileAds consent: requestConsentInfoUpdate(...)
 → if a form is required: load and show the UMP consent form
 → read canRequestAds
 → initialize the Mobile Ads SDK / begin preloading only if canRequestAds
```

- `canRequestAds == false` ⇒ **no ad request at all** ⇒ gate result `unavailable`
  ⇒ export proceeds (§5).
- **Privacy options entry point:** where UMP indicates one is required, expose it
  from Settings → Privacy ("Ad privacy options" / "خيارات خصوصية الإعلانات").
  This entry point **opens the UMP form**; it does not store a parallel Qirsh
  consent value.
- **Do not assume non-personalized ads imply no consent requirement.** Regional
  requirements may mandate a form regardless; UMP decides.

### 12.1 UMP is NOT consent for Qirsh's own analytics (r3)

Two independent authorities — never substitute one for the other:

| Authority | Governs |
|---|---|
| **Google UMP** (`canRequestAds`) | whether Google Mobile Ads may be **requested/personalized** |
| **Qirsh `cloudProcessingEnabled`** (`user_settings.cloud_processing_enabled`, `ConsentState`) | whether Qirsh emits **optional client-side product analytics** |

Repository truth: `cloudProcessingEnabled` is already the consent surface the
coupon analytics client gates on (`CouponAnalyticsClient` reads it fresh on every
send and fails closed while unset). **Report-ads and referral client analytics
reuse that same existing surface** — no new consent field is introduced.

- Consent OFF (or unset) ⇒ **zero optional Qirsh analytics**, while UMP/AdMob
  behaviour remains independently correct (an ad may still legitimately show if
  UMP permits it).
- `canRequestAds == true` never authorizes Qirsh analytics, and
  `cloudProcessingEnabled == true` never authorizes an ad request.
- **Server-authority records** (`referral_qualified`, `reward_granted`,
  entitlement events, Admin audit) are **operational/audit state, not optional
  client analytics**, and are therefore not gated by this consent.

## 13. ATT boundary (r2)

**ATT is not mandatory merely because AdMob is present.** V1 prefers advertising
that does not require IDFA/personalized tracking, so V1 plans **no ATT prompt and
no `NSUserTrackingUsageDescription`** — unless the actual SDK/config in force at
implementation time requires it, which must be verified against the SDK then.

If personalized/IDFA-based advertising is later enabled, it is a **separately
approved configuration** covering: ATT prompt + `NSUserTrackingUsageDescription`
+ UMP IDFA messaging together.

## 14. Effective enablement rule — one chain, **no server config table** (r3)

**`report_ads_config` is eliminated.** After removing `enabled` (r2), nothing
remained that needs server control in V1: the placement is fixed (Report Export),
the preload budget and show-timeout are client constants, and ad-unit/app IDs are
build-time environment configuration. Creating a table merely to justify a
migration is rejected (see [REFERRAL_REWARDS_SYSTEM.md §Migration plan] — **no
`0084`**).

Report Ads therefore needs **no server table of its own**. Its entire server
surface is: the `enable_report_ads` feature-flag row, and the shared
entitlement tables owned by the referral migration.

Exactly one precedence chain decides an ad:

```
show an ad for this export attempt
  ⇔ enable_report_ads is effective for this install     (rollout gate; §15)
  ∧ valid build-time ad configuration for platform+environment
  ∧ UMP canRequestAds == true
  ∧ entitlement decision == VERIFIED_INACTIVE            (fresh; §8)
  ∧ an ad is available within the preload budget
```

Any false term ⇒ no ad ⇒ **export proceeds**.

## 15. Kill-switch reality & **REQUIRED rollout hardening** (r3)

`enable_report_ads` is delivered by `FeatureFlagService`, which today
re-evaluates only after a **catalog sync + app restart** (flag-reading providers
are not invalidated post-sync — the C6/Coupons finding).

**Classification: SAME-SESSION FLAG REACTIVITY is REQUIRED ROLLOUT HARDENING
BEFORE `enable_report_ads = true` IN PRODUCTION.**

- It does **not** block server or Admin implementation, and it does not block
  building the client gate.
- It **must be implemented and tested before Report Ads are enabled for real
  users**, because a flag that needs an app restart is not an adequate incident
  kill-switch for a surface that displays third-party content in a running app.
- **Pausing the AdMob ad unit is an operational fallback only — not application
  correctness authority.** It is not a guaranteed instantaneous client kill
  switch (an already-preloaded ad may still present, and behaviour depends on the
  network), so the design must not depend on it.
- Until hardening lands, the honest statement is: a client-side AdMob placement
  **cannot** be instantly removed from an already-running process.

Referral server-side stop is stronger and immediate — see
[REFERRAL_REWARDS_SYSTEM.md §Server referral authority].

## 16. Native / platform requirements (documented, **not** changed)

All new; none exist today.

**iOS:** `google_mobile_ads` plugin; `Info.plist` `GADApplicationIdentifier`;
SKAdNetwork identifiers (SDK-provided list); UMP consent form support.
`NSUserTrackingUsageDescription` **only** under §13's later personalized-ads path.
Existing Google Sign-In URL scheme untouched.

**Android:** plugin dependency; `AndroidManifest.xml`
`com.google.android.gms.ads.APPLICATION_ID` meta-data; no new runtime permission
(uses existing `INTERNET`); the SDK's auto-merged `AD_ID` permission must be
reflected in the store privacy declaration.

**Both:** debug/test builds use Google **test ad units** + registered test device;
release uses production unit IDs from build-time configuration (§Admin spec
§Report Ads settings). Ad-unit IDs are environment configuration identifiers, not
Admin-editable business content and not server secrets.

## 17. Report correctness is untouched (hard boundary)

The gate decides *whether to proceed*; it never passes through, transforms, or
observes report data. Unchanged: Money precision, `ReportContentOptions` filters,
`privacyMode` masking, snapshot building, PDF rendering. Bytes are identical with
or without an ad — asserted by test (§19).

## 18. Analytics (r2 vocabulary — no reward terms)

| Event | Side |
|---|---|
| `report_export_requested` | client |
| `report_ad_load_requested` | client |
| `report_ad_impression` | client |
| `report_ad_dismissed` | client |
| `report_ad_load_failed` | client |
| `report_ad_show_failed` | client |
| `report_export_completed` | client |

Removed: `report_ad_completed`, `report_ad_reward_earned`. Privacy-minimal: no
report contents, no financial values, no ad payload. Fire-and-forget and gated on
**`cloudProcessingEnabled`** (§12.1) — fail-closed while unset — reusing the
existing coupon analytics contract.

**AdMob/Google remains authoritative for ad-network impressions, revenue and
network diagnostics.** These client events are product-funnel telemetry only and
must never be presented as, or reconciled against, an ad billing ledger. No
duplicate revenue accounting is built.

## 19. Test strategy (local)

Deterministic logic tests use an **injected fake `AdGateway`**; SDK/device tests
use **Google test ad units + registered test device**. **Production ads are never
requested or clicked in automated QA.**

- **A. fresh `VERIFIED_INACTIVE` → exactly one ad opportunity.**
- **B. stale `VERIFIED_INACTIVE` (past TTL) → NO ad** (degrades to
  `UNKNOWN_OR_STALE`), export proceeds.
- **C. entitlement lookup failure → NO ad** — each of: Supabase unavailable, auth
  refresh failure, RPC timeout, malformed response, resume-before-refresh.
- `VERIFIED_ACTIVE` → **no ad**, straight to `generating`.
- `VERIFIED_ACTIVE` past `ends_at` or past freshness → `UNKNOWN_OR_STALE` → no ad.
- **D. user switch / logout / account deletion clears the cache**; a cache entry
  keyed to another user id is never read (no cross-session leak).
- flag off / signed-out / local-only / `canRequestAds == false` / no ad config →
  ad-free path, **no ad request**.
- `displayed`→`dismissed` → proceeds.
- `failed_to_load` (no-fill), `failed_to_show`, `unavailable`, offline, load
  timeout → proceeds; correct analytics event each.
- **repeated tap** during `presentingAd`/`generating` → exactly one ad
  opportunity, one PDF, one share sheet (assert on `exportAttemptId`).
- failure does **not** loop into a second ad request before the same export.
- backgrounded during `presentingAd` → resume advances to `generating` once.
- **report bytes identical** with and without the ad path for the same
  `ReportRequest`.
- analytics failure never blocks or errors the export.
- entitlement: session state honored; **no local persistence** asserted (v31);
  device-clock change grants no extension.
- **O. product-analytics consent OFF/unset → zero optional Qirsh analytics
  emitted**, while UMP/AdMob behaviour remains independently correct (an ad may
  still show if UMP permits).
- **N. same-session flag reactivity** — test reserved for the rollout-hardening
  phase (§15); not a V1 client-gate test.

## 20. Physical-device QA (fold into the existing 9I/9V gate)

Real interstitial presentation using **test ad units in test mode only** (never a
production ad, never a click); foreground/background during the ad; UMP form
presentation where required; report export completes after dismissal; TestFlight
/ Play internal builds. iOS + Android. Evidence must explicitly record that
**test mode** was used.

## 21. Staging E2E

Ads are not server-backed; the staging-provable part is **entitlement → gate
bypass**: with an active entitlement the gate skips the ad; after expiry the ad
path returns. Use an **injected fake AdGateway**, never a live ad. Full plan in
[REFERRAL_REWARDS_SYSTEM.md §Staging E2E].

## 22. Release impact

Reopens Feature Freeze. New: `google_mobile_ads` dependency, iOS/Android ad
config, UMP consent lifecycle, `enable_report_ads` seed (false), the gate.
**No Drift bump (v31 retained).** No closed financial contract is touched.
