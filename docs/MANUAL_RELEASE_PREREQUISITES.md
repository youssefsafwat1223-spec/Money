# MANUAL RELEASE PREREQUISITES — Qirsh / قِرش

**R9 output. Nothing here has been released, uploaded, published, or configured on production.**

This is the register of **external / account-side** prerequisites — the things no amount of code work
can close, because they live in Apple's, Google's, or a DNS provider's console. The engineering side is
tracked separately in `docs/FINAL_RELEASE_READINESS.md`; the production execution runbook is
`docs/PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md`.

| | |
|---|---|
| Prepared | 2026-08-23 |
| Bundle / package id | `com.youssefsafwat.mali` (identical on both platforms) |
| App version | `0.1.3+39` |
| iOS display name | **قرش** |
| Signing team in use | `5TWARK8A23` |

**No secret values appear in this document** — no private keys, passwords, client secrets, or key
material. Availability is recorded as AVAILABLE / MISSING only.

### Status vocabulary

| Status | Meaning |
|---|---|
| **READY** | Verified present, nothing to do |
| **NEEDS_USER_ACTION** | Only you can do it (console, account, purchase, domain) |
| **NEEDS_ACCOUNT_ACCESS** | Blocked until account access/role is confirmed |
| **NEEDS_VALUE** | Code path exists; the identifier/secret itself is missing |
| **BLOCKED_BY_ENVIRONMENT** | Hardware/toolchain unavailable here |
| **DEFER_UNTIL_UPLOAD** | Legitimately only doable at upload time |
| **CREATE_AT_AUTHORIZED_RELEASE_PREP** | Deliberately not created early (minimise credential lifetime) |
| **NOT_APPLICABLE** | Does not apply to this release |

---

## 0. The one hard blocker found in R9

> **The app ships a privacy-policy link to a domain that does not exist.**
>
> `app/lib/features/settings/privacy_screen.dart:25,27` opens
> `https://mali.youssefsafwat.com/privacy` and `/terms`. DNS returns **NXDOMAIN** for
> `mali.youssefsafwat.com` *and* for `youssefsafwat.com` (verified while the internet was otherwise
> reachable). So this is two problems at once:
>
> 1. **Store blocker** — Apple and Google both require a *working, public* privacy-policy URL.
> 2. **Live product defect** — the in-app Privacy screen currently opens a dead link.
>
> Everything else in this register is ordinary account setup. This one needs a decision (register the
> domain, or host the policy elsewhere and change the two URLs).

---

## 1. Apple

| Item | Status | Note |
|---|---|---|
| Apple Developer Program membership | **NEEDS_ACCOUNT_ACCESS** | Signing works with team `5TWARK8A23`, which implies an active paid team; renewal/role not verifiable from here |
| App ID `com.youssefsafwat.mali` | **SOURCE_READY / NEEDS_ACCOUNT_ACCESS** | Bundle id is set in all three targets |
| Capability: App Groups `group.com.youssefsafwat.mali` | **SOURCE_READY** | In both Runner and ShareBankMessage entitlements |
| Capability: Push Notifications | **SOURCE_READY** | `aps-environment` is build-variable driven |
| Capability: Sign in with Apple | **SOURCE_READY** | `com.apple.developer.applesignin` present |
| **iOS Distribution certificate** | **NEEDS_USER_ACTION** | ⚠️ **Zero distribution identities in this keychain** — only two `Apple Development` certs. This is why the local archive succeeds but export fails |
| Provisioning — Runner (App Store) | **NEEDS_USER_ACTION** | Depends on the distribution certificate |
| Provisioning — ShareBankMessage (App Store) | **NEEDS_USER_ACTION** | The extension needs its own App Store profile |
| App Store Connect app record | **NEEDS_USER_ACTION** | Not created |

**Distribution signing model — pick ONE (§5).** The repository is already shaped for **A**:
Release pins no identity, `CODE_SIGN_STYLE = Automatic`, and Codemagic requests
`distribution_type: app_store` with `xcode-project use-profiles`. Recommended: **A — managed/automatic
signing via the CI's Apple API key**, so no distribution private key ever lands on a laptop or in Git.
Option B (manually managed cert + profile) is only worth it if you must sign outside CI. **Do not run
both.**

> No certificate or private key was generated in R9 — that needs your account confirmation, and the
> key should be created where it will live (CI/Keychain), never pasted anywhere.

---

## 2. App Store Connect record — inputs needed (no upload)

| Field | Status |
|---|---|
| App name | **NEEDS_USER_ACTION** — "Qirsh" / "قِرش" not yet confirmed as the store name |
| Primary language | **NEEDS_USER_ACTION** — Arabic expected (app is Arabic-first) |
| Bundle ID | **READY** — `com.youssefsafwat.mali` |
| SKU | **NEEDS_USER_ACTION** — any internal string |
| Category | **NEEDS_USER_ACTION** — Finance expected |
| Age rating questionnaire | **NEEDS_USER_ACTION** |
| **Privacy policy URL** | **NEEDS_USER_ACTION** — see §0, currently NXDOMAIN |
| Support URL | **NEEDS_USER_ACTION** — none exists |
| Marketing URL | **NOT_APPLICABLE** unless wanted |
| App Privacy answers | **NEEDS_USER_ACTION** — must declare financial data; identifiers only if ads are ever enabled |
| Account-deletion disclosure | **CODE READY** (§8) — the disclosure text is still yours to write |
| Financial-data disclosure | **NEEDS_USER_ACTION** |
| Ads disclosure | **NOT_APPLICABLE for v1** — `enable_report_ads` ships **false** |
| Sign in with Apple review info | **NEEDS_USER_ACTION** |
| Reviewer demo account | **NEEDS_USER_ACTION** — ⚠️ reviewers cannot receive real bank SMS; supply credentials **and** a manual-paste walkthrough, or review will fail on "cannot test core feature" |

Marketing copy is deliberately **not** drafted here — it is a product decision, and inventing it would
mean shipping words nobody approved.

---

## 3. Google Play

| Item | Status |
|---|---|
| Play Developer account (one-off fee) | **NEEDS_ACCOUNT_ACCESS** |
| App record for `com.youssefsafwat.mali` | **NEEDS_USER_ACTION** |
| App name / default language | **NEEDS_USER_ACTION** |
| App vs game, free vs paid, category | **NEEDS_USER_ACTION** — App / Free / Finance expected |
| Store listing + contact details | **NEEDS_USER_ACTION** |
| **Privacy policy URL** | **NEEDS_USER_ACTION** — same §0 blocker |
| Data Safety form | **NEEDS_USER_ACTION** — financial data; no ads identifiers while flag-off |
| Ads declaration | **"No ads" for v1** — revisit only when `enable_report_ads` is enabled |
| Content rating questionnaire | **NEEDS_USER_ACTION** |
| Target audience | **NEEDS_USER_ACTION** — adults; not child-directed |
| Financial-features declaration | **NEEDS_USER_ACTION** — Qirsh tracks personal finances but is **not** a bank/lender/payments app; answer accordingly |
| **Account-deletion URL** | **NEEDS_USER_ACTION** — Play requires a *web* deletion request URL, blocked by §0 |
| Internal testing track | **NEEDS_USER_ACTION** |

**Do not upload the R8B QA-signed AAB.** It was signed with a throwaway QA key that has since been
destroyed; uploading it would permanently bind the wrong upload certificate to the app.

---

## 4. Play App Signing & the real upload key

| Item | Status |
|---|---|
| Play App Signing enrolment | **NEEDS_USER_ACTION** — Play holds the **app signing key** |
| **Real upload key** | **CREATE_AT_AUTHORIZED_RELEASE_PREP** |
| Upload certificate SHA-1/SHA-256 | **NEEDS_VALUE** — does not exist until the key does |
| Play App Signing certificate SHA-1/SHA-256 | **NEEDS_VALUE** — issued by Play after enrolment |
| CI secrets (`ANDROID_KEYSTORE_BASE64` + 3) | **NEEDS_VALUE** — pipeline consumes them already (A2 EXECUTION_VERIFIED) |

**The QA key from R8B must never be reused** — it was deliberately ephemeral, labelled
`QIRSH QA SIGNING ONLY - NOT PLAY UPLOAD KEY`, and destroyed. **The Android debug key must never be
used either.** Generation procedure is in `docs/ANDROID_RELEASE_SIGNING.md` §1–§4: strong password,
dedicated alias, long validity (25+ years), stored in a secret manager, escrowed offline, base64 into
CI as a protected variable, never committed.

Deliberately **not** generated in R9 (§22): an upload key created months early is exposure with no
benefit. Create it when release prep is actually authorised.

---

## 5. AdMob

Report ads ship **OFF** (`enable_report_ads = false / 0%`), so none of this blocks a first release.
The build plumbing is READY and fails closed without values.

| Item | Status |
|---|---|
| AdMob account | **NEEDS_ACCOUNT_ACCESS** |
| iOS app record | **NEEDS_USER_ACTION** |
| `ADMOB_APP_ID_IOS` | **MISSING** |
| `ADMOB_INTERSTITIAL_IOS` (Standard Interstitial) | **MISSING** |
| Android app record | **NEEDS_USER_ACTION** |
| `ADMOB_APP_ID_ANDROID` | **MISSING** |
| `ADMOB_INTERSTITIAL_ANDROID` (Standard Interstitial) | **MISSING** |
| UMP Privacy & Messaging / GDPR-EEA-UK message | **NEEDS_USER_ACTION** |
| Consent provider/vendor list | **NEEDS_USER_ACTION** |
| Privacy-policy linkage in the UMP message | **NEEDS_USER_ACTION** — blocked by §0 |

**Create Standard Interstitial units only.** No Rewarded, no Rewarded Interstitial — the codebase
contains no rewarded types and guards enforce that. **UMP remains the sole ads-consent authority**; no
ATT / IDFA is requested, and none should be added unless a personalised-ads strategy is deliberately
adopted.

---

## 6. Auth

| Item | Status |
|---|---|
| Google iOS OAuth client | **SOURCE_READY** — an explicit iOS client id is compiled in and its reversed id is the `CFBundleURLSchemes` entry |
| Google provider on **production** Supabase | **NEEDS_USER_ACTION** — untouched in R9 |
| **Skip nonce checks** for Google | **NEEDS_USER_ACTION** — ⚠️ mandatory; the native SDK hashes its own nonce. Omitting it is exactly the R6 staging failure (generic Arabic sign-in error) |
| Android Google client + SHA-1/SHA-256 | **NEEDS_VALUE** — needs the upload **and** Play App Signing certificates (§4) |
| Apple provider on production Supabase | **NEEDS_USER_ACTION** |
| Apple Services/App ID relationship | **NEEDS_USER_ACTION** |
| Apple key id / team id / `.p8` custody | **NEEDS_USER_ACTION** — key contents never leave the secret manager |
| Apple client secret rotation | **NEEDS_USER_ACTION** — it is a JWT that expires (~6 months); assign an owner **and a calendar reminder**, because expiry presents as sudden Apple-only sign-in failure |

No production Auth setting was read or changed in R9.

---

## 7. APNs

| Secret | Availability |
|---|---|
| `APNS_KEY_ID` | **MISSING** |
| `APNS_TEAM_ID` | **MISSING** (team is `5TWARK8A23`; the secret itself is unset) |
| `APNS_BUNDLE_ID` | **NEEDS_VALUE** — must be exactly `com.youssefsafwat.mali`, sent verbatim as `apns-topic` |
| `APNS_PRIVATE_KEY` (`.p8`) | **MISSING** — **CREATE_AT_AUTHORIZED_RELEASE_PREP** |

Not set in R9, by instruction. The `.p8` downloads **once** — escrow it immediately. Absent all four,
`sendCapturePush()` returns `apns_not_configured` and the pipeline degrades without breaking.

---

## 8. Privacy policy, deletion, and data disclosures

| Item | Status |
|---|---|
| Public privacy-policy URL | **NEEDS_USER_ACTION** — ⚠️ **NXDOMAIN**, see §0 |
| Policy content coverage | **NEEDS_USER_ACTION** — must cover financial data, cloud sync, SMS/capture, AI processing (Gemini), retention, deletion, referrals, ads/UMP, analytics, backups |
| Terms URL | **NEEDS_USER_ACTION** — same dead domain |
| In-app account deletion | **CODE READY** — `privacy_screen.dart` ("حذف الحساب وكل بياناتي") → `account_deletion_service.dart`, with a cancellation path |
| Server-side purge | **CODE READY** — `purge_user_data()` + `purge-scheduled-deletions` on a 30-day policy (migrations 0042/0065), cron `30 3 * * *` |
| Public deletion-request URL | **NEEDS_USER_ACTION** — a **store metadata** requirement distinct from the code support above; blocked by §0 |

The distinction matters: deletion is **implemented**; what is missing is the **public URL** the stores
require. Do not claim policy coverage the product does not actually implement.

---

## 9. Store assets

Repo has brand/icon source (`assets/brand/*_1024.png`, `assets/logo`). No store screenshots or
listing metadata exist (no `fastlane/`, no `metadata/`).

| Asset | Status |
|---|---|
| iOS app icon | **AVAILABLE** (1024 source present) |
| iOS screenshots (required device classes) | **NEEDS_CREATION** |
| iOS description / subtitle / promo | **NEEDS_CREATION** |
| Android app icon | **AVAILABLE** |
| Android phone screenshots | **NEEDS_CREATION** |
| Android feature graphic (1024×500) | **NEEDS_CREATION** |
| Android short + full description | **NEEDS_CREATION** |

Screenshots can be captured from the iOS simulator — note the iOS 26.5 runtime was **deleted** to make
room for the Android toolchain (see `FINAL_RELEASE_READINESS.md` §20.2); reinstall it when you get to
assets.

---

## 10. Android SMS policy (decision, not a blocker)

Automatic SMS capture is **NOT_RELEASE_ENABLED**: manifest-disabled in source with no enable UI.

- **Option A — ship without automatic SMS** (share-to-app + manual paste). **Recommended for v1**: no
  restricted-permission review, no policy risk, and it is the shipping behaviour that has actually been
  built and tested.
- **Option B — pursue the Play restricted SMS permission declaration.** Requires a declaration form,
  prominent in-app disclosure, and re-enabling the manifest entries — a separate project.

This is **not** a blocker for a first release under Option A. Nothing was enabled in R9.

---

## 11. Environment / CI status (carried forward, unchanged)

| Item | Status |
|---|---|
| Android physical device | **BLOCKED_BY_ENVIRONMENT** — no device, no emulator image |
| Remote CI execution | **PENDING_PUSH** — the Android compile gate is configured but has never run remotely |
| iOS simulator runtime | Deleted to free disk; reinstall only when needed |

**After the first authorised push, the expectation is:** GitHub Actions runs `tools/ci_gates.sh`;
Codemagic `backend-and-quality-gates` runs migration lint → Deno tests → admin lint/build → Flutter
analyze+test → **Android debug compile gate** (JDK 17, NDK 28.2.13676358, vendored `file_picker`
resolved from `third_party/`). The first remote run is the real proof of the gate; expect a possible
adjustment around `java: 17` / `sdkmanager` availability on the Codemagic image.

---

## 12. Ownership matrix (names only)

| Asset | Owner / kind |
|---|---|
| Apple Developer account | HUMAN OWNER — team `5TWARK8A23` |
| App Store Connect | HUMAN OWNER |
| Google Play Console | HUMAN OWNER — account not yet confirmed |
| AdMob | HUMAN OWNER — deferred while ads are off |
| Supabase production project | HUMAN OWNER |
| Domain / privacy hosting | HUMAN OWNER — **does not currently exist** |
| APNs auth key (`.p8`) | SECURE CREDENTIAL — secret manager + offline escrow |
| Apple auth key (`.p8`) | SECURE CREDENTIAL |
| Android upload keystore + passwords | SECURE CREDENTIAL — secret manager + offline escrow |
| CI secret store (Codemagic groups) | SECURE CREDENTIAL |

No password, email, client secret or key material belongs in this file.

---

## 13. What must NOT happen yet

- ❌ Upload any build to App Store Connect or Play (including the R8B QA AAB — its key is destroyed)
- ❌ Submit for review
- ❌ Apply production migrations / deploy production Edge Functions / set production secrets
- ❌ Configure production Auth providers
- ❌ Flip `enable_report_ads`, `enable_referrals`, or `enable_coupons`
- ❌ Request production ads
- ❌ Create the real upload key or APNs key before authorised release prep
