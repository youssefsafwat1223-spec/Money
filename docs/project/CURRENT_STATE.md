# Qirsh — current state

**As of 2026-09-02, branch `feat/phase1-data-integrity`.** Written against
source, not against previous reports. Where an older document and the code
disagree, the code wins and this file says so.

This is the authoritative entry point. Read it before touching anything.

---

## Release readiness: **ENGINEERING COMPLETE**

Not BETA READY, and nowhere near PRODUCTION READY. The distinction that matters:
**every executable engineering task is done; nothing has been validated on real
hardware, against a real network, or against a real production database.**

What blocks a stronger label, in order:

1. **No physical device has ever been attached to this machine.** Not Android,
   not iOS. SMS receipt, push delivery, background execution, share extensions,
   App Groups, banner rendering and permission behaviour are all unverified on
   hardware. Simulator/emulator evidence does not exist either.
2. **The production migration ledger is unknowable from this repository.** See
   §Backend below — the repo contradicts itself and the Management API returns
   403 for this account.
3. **Google Play approval for `RECEIVE_SMS` is pending**, and the declaration
   has not been submitted.
4. **No affiliate network is contracted**; coupons/affiliate/savings run against
   a fixture adapter.
5. **No AdMob production ad units exist**; banners and the interstitial resolve
   to null in a release build by design.

---

## Scale

| | |
|---|---|
| Flutter app | ~125k lines `lib/`, ~80k lines `test/`, 430 test files |
| Features | 27 directories under `app/lib/features/` |
| Drift schema | **v35** (forward-only) |
| Supabase migrations | **0001…0098**, 41 rollback files, lint PASS |
| Edge Functions | 28 |
| Admin panel | Next.js, 12 route groups |
| Localization | `app_ar.arb` / `app_en.arb`, Arabic is the template |

---

## The three subsystems that exist but are not wired

Verified today by grepping every construction site in `lib/`.

**1. Proof-Carrying decision engine — implemented, tested, NOT integrated.**
`lib/engine/proof/*` and `lib/domain/capture/proof_apply_authority.dart` have
**zero production callers**; the only construction anywhere is a test helper.
Drift v33 was bumped for this work, so leaving it dormant costs nothing and
removing it would discard a verified asset. `docs/proof/PHASE11_ACTIVATION_PACK.md`
described enabling it at 1% via a remote flag — that is impossible with no call
site, and the pack now carries a correction banner. **Activation is an
integration change, not a flag flip.** Both reviewers: ship dormant, recorded.

`CaptureCommitDecision` is the part of that track that DID land live —
`add_transaction_usecase.dart:750,957`.

**2. Affiliate click gateway — implemented, tested, NOT wired.**
`AffiliateClickGateway` has no provider and no caller; `prepare-affiliate-click`
has no client caller. The coupon CTA today opens the validated HTTPS merchant
URL directly and untracked, which works. `enable_affiliate_links` is OFF and no
network is contracted. Both reviewers: leave unwired until a network exists,
because wiring a remotely-gated egress path now adds accidental-activation risk
for zero present benefit.

**3. `SupabaseEngagementRecorder` — declared, never instantiated.** Recorded as
an OPEN egress finding so the consent obligation is visible before the first
caller appears.

---

## What was fixed on 2026-09-02

**Android automatic SMS capture was unreachable.** The manifest declared
`RECEIVE_SMS`, `SmsCaptureReceiver` was registered and `BROADCAST_SMS`-protected,
the Kotlin permission state machine was complete, the Dart facade
(`AndroidSmsCaptureService`) and the prominent disclosure widget both existed —
and **nothing in the app called any of it**. There was no path by which a user
could switch the feature on.

That is a release blocker on three independent grounds: Google Play requires a
declared restricted permission to enable core functionality a reviewer can
exercise; the privacy policy was **already live** telling users the app captures
bank SMS; and the Settings screen simultaneously told users in Arabic that Qirsh
does **not** read system SMS.

Fixed: a Settings toggle in «رصد العمليات», Android-only and hidden unless the
build declares the permission, rendering from the **platform capability
snapshot** rather than a cached boolean so a permission revoked outside the app
cannot leave it stuck ON. Turning it on routes through `requestAndEnable`, which
structurally cannot reach the system dialog without the disclosure returning
true. Permanent denial offers the system-settings route, which is the only way
out of "don't ask again". The false Settings copy was replaced with localized
copy that describes what actually happens.

Also fixed in the same pass:
- The permission round trip is now **bounded**. `MainActivity`'s pending result
  is an activity-instance field; if the activity is recreated while the system
  dialog is up, the Dart future never completed and the toggle would spin
  forever. On timeout it now re-reads the platform's own capability snapshot
  rather than guessing.
- `SmsCaptureReceiver`'s KDoc claimed `RECEIVE_SMS` sat behind a build-level
  manifest placeholder so a share-only build could omit it. **No such
  placeholder exists** — `build.gradle.kts` defines only `admobAppId`. A comment
  describing a safety mechanism that was never built is worse than no comment.
- A **reachability guard** in `test/features/capture/android_sms_permission_test.dart`
  fails if the service or the disclosure ever loses its last production caller.
  Twenty correctness tests existed for this feature and none of them noticed it
  was unreachable.

---

## Feature flags — every one, and its default

Seeded ON: `enable_goals`, `enable_announcements`, `parser_engine_version='v1'`.

**Everything else is OFF and fails closed**: `enable_coupons`,
`enable_referrals`, `enable_report_ads`, `enable_banner_ads`,
`enable_banner_transactions_list`, `enable_offers_merchants`,
`enable_offers_personalization`, `enable_affiliate_links`,
`enable_savings_claims`, `ledger_dual_write`, `ledger_pull_sync`,
`ledger_push_sync`, `smart_inbox_pull_sync`, `capture_direct_ledger_write`, and
all five `planning_*_sync` flags.

**Read that list carefully: all cloud synchronisation of financial data is
dark.** The app is local-first by default and every sync path ships disabled.

---

## Database

Drift **v35**, additive and **forward-only**. A v34 binary cannot open a v35
database (`UnsupportedDatabaseVersionException`), so recovery is a feature flag,
the kill switch, a hotfix or a forward migration — **never shipping an older
build**.

Version history that matters: v32/v33 Proof, v34 coupons merchant catalog +
coupon economics, v35 affiliate click receipts + local savings ledger.

Every executable pin is correct at 35 (three Node contract tests, one
architecture test). Older prose in `docs/FINAL_RELEASE_READINESS.md` (v31),
`docs/proof/PHASE11_ACTIVATION_PACK.md` (v32) and
`app/docs/PHASE_7_MALI_034_CLOSURE.md` (29) is historical; the first now carries
a staleness banner.

Backup, wipe and restore coverage are enforced by guards that fail when a new
table is classified in neither set.

---

## Backend

98 migrations, dense and gapless, rollback coverage complete from 0084, lint
PASS.

**The deployed state is contradictory and cannot be resolved from here.**
`0072_backend_security_hardening.sql:5` says "DEPLOYED … 0001-0092 applied and
ledger-verified on production". `0084_purge_user_data_restore.sql:4` says
"SOURCE-ONLY. NOT APPLIED TO ANY PROJECT." 0084 ≤ 0092; both cannot be true.
`supabase migration list --linked` returns **403** ("Your account does not have
the necessary privileges"), so the real ledger is unreadable with the present
credentials. Linked project ref is `rjwphwsefnuotpbtuycf`.

**Treat every migration from 0084 upward as UNVERIFIED until someone with
dashboard access reads the ledger.** 0093–0098 are certainly source-only.

Edge Functions: 28 exist and type-check. `affiliate-sync`,
`prepare-affiliate-click`, `affiliate-click-status` and `affiliate-postback`
have never run against the live project.

---

## Security and privacy

**No committed secrets.** A scan of every tracked file for JWTs, `sk-`/`AIza`
keys and PEM blocks found only PEM *header string literals* inside
`_shared/apns.ts` parsing code. `key.properties` and `.env*` are gitignored;
only `.example` files are tracked.

`app/android/key.properties` exists **on disk** (gitignored, never committed)
from the August signing work. It makes
`test/architecture/android_release_signing_test.dart` fail, because that guard
scans the filesystem while its name says "committed". Left failing deliberately:
weakening a key-material guard to make a suite green is a bad trade.

Egress inventory is enforced by an architecture test with three **OPEN
findings**, recorded rather than hidden:
1. `record_metric` has no consent gate (owner-bound, allowlisted, rate-limited
   server-side; sends a key plus a coarse dimension). Migration `0098` finally
   allowlists the ad keys, which had been silently dropped since R4.
2. `set_default_account` in `accounts_backfill_service` gates on **transport**
   capability rather than consent, while its sibling push/pull services in the
   same pipeline are consent-gated. An inconsistency in one path.
3. `SupabaseEngagementRecorder` is unwired, so nothing reaches the network.

---

## Ads

One interstitial (report export) and one banner (transactions list). Both behind
flags seeded OFF, both non-personalized (`nonPersonalizedAds: true`), no ATT
prompt and no `NSUserTrackingUsageDescription` by deliberate decision. UMP is the
sole consent authority. Ad-free entitlement is server-authoritative and
three-state: any uncertainty means no ad.

Native plumbing is complete and guarded on both platforms; a release build
without injected production IDs resolves null and serves nothing, and Gradle
**fails the build** on a malformed or test-publisher app id.

Not done, external: production ad units, `app-ads.txt` (absent; Google has
required it for newly configured apps since January 2025), the full
`SKAdNetworkItems` list (one entry today), and the console refresh interval the
banner design relies on.

---

## Where to look next

- `FEATURE_MATRIX.md` — what is implemented vs wired vs tested vs deployed.
- `RELEASE_BLOCKERS.md` — what actually stops a release.
- `EXTERNAL_REQUIREMENTS.md` — every account, credential and device needed.
- `DECISIONS.md` — decisions taken and why, including the reversed ones.
- `REVIEW_LOG.md` — what Fable and Codex reviewed, and where they disagreed.
