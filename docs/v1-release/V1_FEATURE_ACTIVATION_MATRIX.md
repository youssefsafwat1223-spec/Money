# V1 Feature Activation Matrix

Every feature flag, hidden route and dark capability, with an explicit V1
disposition. The proof audit recorded this as NOT PROVEN because no such
inventory existed — flag defaults were readable, but nobody had said which ones
V1 *intends*.

Measured against HEAD, 2026-09-16. Sources: `lib/data/catalog/feature_flag_service.dart`
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
