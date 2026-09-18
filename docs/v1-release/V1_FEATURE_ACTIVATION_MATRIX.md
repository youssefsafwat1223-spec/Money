# V1 Feature Activation Matrix

Every feature flag, hidden route and dark capability, with an explicit V1
disposition. The proof audit recorded this as NOT PROVEN because no such
inventory existed — flag defaults were readable, but nobody had said which ones
V1 *intends*.

Measured against HEAD, 2026-09-16; §3a added 2026-09-17 at release closure.
Sources: `lib/data/catalog/feature_flag_service.dart`
(`_defaults`), `lib/core/router/app_router.dart`, `lib/data/sync/exact_transport_capability.dart`.

Classification: **ACTIVATE FOR V1** · **KEEP DISABLED — RELEASE REASON** · **EXTERNAL BLOCKED**

---

## 1. Feature flags — 24 keys

Defaults are the fallback when the remote catalogue says nothing. `getBool`
consults the remote cache first, so every one of these is remotely flippable
**without a new App Store review** — which is why the advertising rows matter to
the privacy label even while they ship off.

### Shipping ON

| Flag | Default | Disposition | Reason |
|---|---|---|---|
| `enable_goals` | `true` | **ACTIVATE FOR V1** | Core product surface; `/goals` is in the nav and the CRUD matrix covers all four operations |
| `enable_announcements` | `true` | **ACTIVATE FOR V1** | Carries the force-update kill switch. Disabling it would remove a safety control |
| `parser_engine_version` | `v1` | **ACTIVATE FOR V1** | The shipped parser. Not a toggle — a selector |
| `proof_parser_confidence_min` | `990` | **ACTIVATE FOR V1** | Threshold, not a feature. 0.990 is deliberately strict |

### Shipping OFF — monetisation

| Flag | Default | Disposition | Reason |
|---|---|---|---|
| `enable_coupons` | `false` | **KEEP DISABLED** | Charter forbids redesigning Coupons for V1; the catalogue is seeded but the surface is not part of the V1 story |
| `enable_offers_merchants` | `false` | **KEEP DISABLED** | Phase 1+ merchant catalogue, post-V1 |
| `enable_offers_personalization` | `false` | **KEEP DISABLED** | Asks for a local personalisation consent V1 does not need |
| `enable_affiliate_links` | `false` | **KEEP DISABLED** | **Owner constraint, explicit.** Tracked affiliate CTA path stays off |
| `enable_savings_claims` | `false` | **KEEP DISABLED** | A savings claim is a financial promise; not made in V1 |
| `enable_referrals` | `false` | **KEEP DISABLED** | Reward scope is real money; post-V1 |
| `enable_report_ads` | `false` | **KEEP DISABLED** | Report-export interstitial |
| `enable_banner_ads` | `false` | **KEEP DISABLED** | Master banner switch. **Remotely flippable**, so the privacy label declares advertising anyway — see `V1_APP_STORE_SUBMISSION.md` §2 |
| `enable_banner_transactions_list` | `false` | **KEEP DISABLED** | Per-placement switch for the ledger banner |

### Shipping OFF — financial cloud sync ("dark by contract")

Seven flags, one decision. V1 keeps money on the device.

| Flag | Default | Disposition | Reason |
|---|---|---|---|
| `ledger_dual_write` | `false` | **KEEP DISABLED** | Transport capability is `unknown`; a dual write would transmit money |
| `ledger_push_sync` | `false` | **KEEP DISABLED** | as above |
| `ledger_pull_sync` | `false` | **KEEP DISABLED** | A pull also WRITES locally |
| `planning_accounts_sync` | `false` | **KEEP DISABLED** | Accounts carry balances |
| `planning_budgets_sync` | `false` | **KEEP DISABLED** | |
| `planning_subscriptions_sync` | `false` | **KEEP DISABLED** | |
| `planning_goals_sync` | `false` | **KEEP DISABLED** | |
| `planning_plans_sync` | `false` | **KEEP DISABLED** | |
| `smart_inbox_pull_sync` | `false` | **KEEP DISABLED** | |

**Verified at runtime, not assumed.** `integration_test/queue_failclosed_egress_test.dart`
grants *both* consents, asserts all three transport capabilities are still
`unknown`, walks the money surfaces and requires that no financial table is
touched: **24 setup requests, 0 afterwards.**

### Shipping OFF — capture pipeline

| Flag | Default | Disposition | Reason |
|---|---|---|---|
| `enable_proof_autocommit` | `false` | **KEEP DISABLED** | **Owner constraint, explicit.** A capture must not post itself to the ledger without review |
| `capture_direct_ledger_write` | `false` | **KEEP DISABLED** | Same boundary from the other side |

## 2. Dark capabilities — not flags

| Capability | Value at HEAD | Disposition | Reason |
|---|---|---|---|
| `exactPushTransportCapability` | `unknown` | **KEEP DISABLED** | Hard-coded. Returning `verifiedExact` needs a live exactness proof against PostgREST, which V1 does not have |
| `exactPullTransportCapability` | `unknown` | **KEEP DISABLED** | as above |
| `planningServerCurrencyCapability` | `unknown` | **KEEP DISABLED** | Migration 0077 **is deployed** (verified: 0001-0099 applied, zero drift), so this is blocked by the missing exactness proof and not by schema |

`weakerCapability` resolves any pair to the more restrictive value, so a single
`unknown` keeps the whole path parked. These are not flipped to make a gate
green.

## 3. Hidden routes

| Route | Visibility | Disposition | Reason |
|---|---|---|---|
| `/design` | `if (kDebugMode)` only | **KEEP DISABLED** | Design-system gallery. Absent from release builds — the sweep's one `ErrorWidget` was on this route in a debug build, and a profile build correctly served "Page Not Found" |
| `/welcome`, `/onboarding/*` | Reachable only without a session | **ACTIVATE FOR V1** | Real first-run flow; covered by the destructive phase, which reaches them the only way a user can |
| `/backup` | Permanent redirect to `/data-transfer` | **KEEP DISABLED — V1 RELEASE REASON** | An alias so an old deep link does not 404. It builds nothing, and nothing in the app links to it. See §3a |
| `/backup/restore` | Offered from Data Transfer when a pre-V1 cloud backup exists | **ACTIVATE FOR V1** | The one live cloud surface: restore only, for people who enabled backup in an earlier build. Walked in both languages |

## 3a. Unshipped screens — present in the binary, unreachable by design

Two screens compile and ship but have **no navigation entry point anywhere**.
This is an owner decision recorded at release closure, not an oversight.

| Screen | Disposition | Reason |
|---|---|---|
| `BackupScreen` | **KEEP DISABLED — V1 RELEASE REASON** | See below |
| `FoundationHomeScreen` | **KEEP DISABLED — legacy** | Zero reachable references anywhere in `lib/`. Not resurrected for V1 |

### `BackupScreen` — why it stays unreachable

It is the only place cloud backup can be **turned on**. Reaching it would:

* **expand V1 scope** at release closure;
* introduce a **reviewer-visible cloud feature** into an App Store submission
  that does not otherwise make one;
* do so immediately after the consent and discovery behaviour behind it was
  hardened — `hasRemoteBackup()` could not see the backups the app itself
  wrote, and the enable path bypassed the cloud-consent gate. Both are fixed,
  neither has runtime soak.

What a V1 user keeps: **local export and import**, which is the backup story
V1 actually ships, and which is tested end to end — CSV and ZIP written to
disk and read back through `inspectFile`, plus a real applied import verified
row by row. Restore from a pre-V1 cloud backup also remains available via
`/backup/restore`.

### What "unreachable" is NOT

It is **not a security control**. The screen is one route away from returning,
and whoever adds that route will not re-derive the consent argument. So the
code behind it stays correct regardless:

* `BackupScreen` goes through `RemoteBackupController`, where the cloud-consent
  gate lives — never `backupServiceProvider.enable()` directly;
* the live backup-existence probe on the Data Transfer screen is gated on
  `EgressClass.backup`;
* `RemoteBackupController` denies when built with no consent function at all.

### Not deleted

Removal is not required for release safety, and the implementation is the
starting point for whenever the owner does ship it. Four review findings in
this unreachable code are recorded in `V1_FINAL_REVIEWS.md` (A4–A6) rather
than fixed, for the same reason: changing unreachable code carries risk
without benefit.

### Enforced, not just asserted

`test/features/unshipped_surfaces_test.dart` fails if either screen gains a
reference, if `/backup` stops being a redirect, if anything links to it, if
either surface enters the V1 route denominator, or if the consent gates are
removed. Every other test in the suite asks whether code *works*; the property
here is that it is **not reachable at all**, which nothing else would notice.

### Not counted as shipping screens

Neither appears in the bilingual walk's route list, which is the denominator
every localization and direction figure is reported against. The V1 route
count is **19**, and it contains no unreachable surface.

## 3b. Language selection — activated 2026-09-18

| Capability | Disposition | Reason |
|---|---|---|
| Settings → Language (العربية / English) | **ACTIVATE FOR V1** | Closes a V1 contract requirement that was shipping unreachable |

This is a **closure, not an addition**. The product contract has been Arabic
(MSA) **+ English** throughout, and the English localization was complete —
1,619 ARB keys in both languages, every route walked in both, seven
English-affecting defects found and fixed during the visual pass.

What was missing was the door. `user_settings.language` is created as `'ar'`,
and `SaveLanguageUseCase` — the only code in `lib/` that writes it — had **zero
callers**. No control in Settings, no onboarding step, no migration, nothing
seeding from the device locale. Every V1 user ran in Arabic permanently, and the
English half of the product was impossible to reach from inside the app. The
bilingual walks reached it by writing `settings.language` directly, which is not
a path a user has.

| Property | State |
|---|---|
| Default for new users | **`'ar'`, unchanged.** The row is still created Arabic; nothing about the default policy moved |
| Write path | `SaveLanguageUseCase` → `user_settings.language`. The app's own, and still the only one |
| Reactivity | `localeProvider` watches `userSettingsProvider`; choosing re-renders copy, direction, pickers and the material delegates without a restart |
| Persistence | Survives process termination and relaunch on the same install — proven, not asserted; see `V1_LANGUAGE_PERSISTENCE_INVESTIGATION.md` |
| Cold-start unlock prompt | Follows the persisted language. `LockPromptLanguage` mirrors the column into the keychain at every write, because the gate composes its prompt before the database can be opened |

Consequence worth stating: with English reachable, the cold-start prompt defect
that was previously *unreachable* becomes real, which is why it was fixed in the
same change rather than deferred.

The same consequence reached one more surface, and it was closed with it.
`notification_journey_service.dart` composed **growth-campaign** notifications
from `titleAr`/`bodyAr` unconditionally — in the banner and in the in-app
history entry beside it — so an English user would have been notified in Arabic
and found the record of it in Arabic too. (The journey notifications were
already bilingual; only the server-authored campaign half was not.) It had been
exempt from the Arabic-only guard because there was nowhere context-free to
make the choice and because English was unreachable anyway. Both reasons
expired on the same day.

The rule now lives once, in `core/i18n/bilingual_copy.dart`, with no
`BuildContext`: the banners reach it through a thin adapter, and the service
reaches it from `user_settings.language`, which it already had open. The
Android channel name is set from the same value, so English copy cannot arrive
inside a channel called «رسائل ونصائح قرش». Redaction is untouched — it happens
below this, in `_show`, and was already language-aware.

## 4. Deferred infrastructure

| Item | Disposition | Reason |
|---|---|---|
| Migration 0100 | **KEEP DISABLED** | **Owner decision, explicit.** Deferred |
| `sync-captures` claim-on-link (N14) | **KEEP DISABLED** | Needs a `capture_devices.linked_at` column; belongs with 0100 |
| Google Play publication | **EXTERNAL BLOCKED** | Owner deferred for budget. Android source health is maintained; no Play work performed |
| Certificate pinning, jailbreak detection, App Attest | **KEEP DISABLED** | Post-V1 hardening; reasoning in `V1_SECURITY_CLASSIFICATION.md` |

## 5. Contract check against the master prompt

| Master-prompt requirement | Shipping state | Consistent? |
|---|---|---|
| Financial cloud sync stays dark | 9 sync flags off, 3 capabilities `unknown`, runtime-verified | **Yes** |
| `enable_affiliate_links` OFF | `false` | **Yes** |
| `enable_proof_autocommit` OFF | `false` | **Yes** |
| Coupons not redesigned | `enable_coupons: false`; no Coupons work performed | **Yes** |
| Migration 0100 deferred | Absent from the repo; remote is at 0099 | **Yes** |
| Google Play deferred | No Play work performed | **Yes** |
| Five required product changes active | Smoking category, streak retired, annual presets, 22:00 reminder, guidance — all shipping ON | **Yes** |

No flag is ON that the charter says should be off, and no charter-required
feature is behind a disabled flag.
