# V1 App Store Submission Package

Everything that can be prepared without the owner's App Store Connect session,
prepared. Each section is either **ready to paste**, or names the exact owner
action and why no one else can take it.

Version: **1.0.0 (40)**. Bundle id `com.youssefsafwat.mali`, team `5TWARK8A23`.

---

## 1. Privacy labels — ready to enter

Derived from `ios/Runner/PrivacyInfo.xcprivacy` and from what the code actually
does, not from what the listing would prefer. App Store Connect asks these
questions in this order.

**Do you or your third-party partners collect data from this app?** — **Yes.**

| Data type | Linked to identity | Used for tracking | Purpose | Why |
|---|---|---|---|---|
| Financial Info → Other Financial Info | Yes | No | App Functionality | Transactions, balances and budgets sync to the app's own backend when cloud processing is enabled |
| Contact Info → Email Address | Yes | No | App Functionality | Account identity (email or Apple/Google sign-in) |
| Contact Info → Name | Yes | No | App Functionality | Profile display name |
| Contact Info → Phone Number | Yes | No | App Functionality | Optional profile field |
| Identifiers → Device ID | Yes | No | App Functionality | Install identifier that binds captures to a device |
| Diagnostics → Crash Data | **No** | No | App Functionality | Sentry, consent-gated and scrubbed before send |
| Identifiers → Device ID *(second entry)* | **No** | **No** | **Third-Party Advertising** | Google Mobile Ads — see §2 |
| Usage Data → Product Interaction | **No** | **No** | **Third-Party Advertising** | Google Mobile Ads — see §2 |

**Tracking: declare NO.** Every ad request is non-personalized
(`nonPersonalizedAds: true` plus the legacy `npa` extra at both request sites),
there is no `NSUserTrackingUsageDescription`, no ATT call anywhere, and
`NSPrivacyTracking` is `false` with no tracking domains. A guard enforces this:
`app/test/architecture/report_ads_guards_test.dart` fails if any `AdRequest`
becomes personalized or if an ATT string appears.

## 2. Advertising disclosure — the part that needs care

`google_mobile_ads` 9.0.0 is linked into the binary, with
`GADApplicationIdentifier` and `SKAdNetworkItems` in Info.plist.

Both banner flags (`enable_banner_ads`, `enable_banner_transactions_list`) ship
**OFF**. They are remote flags, so the shipped binary can serve ads without a
new review — which is exactly why the label must declare advertising anyway. A
label that omits it and is later contradicted by a flag flip is the bad outcome.

Turning personalized ads on later is **not** a flag flip. It needs an
`NSUserTrackingUsageDescription`, an ATT request before the ad request,
`NSPrivacyTracking` set true, and the tracking domains listed. Flipping
`nonPersonalizedAds` alone would make the shipped manifest untrue, and the
guard above will fail the build.

## 3. Age rating — ready to answer

All "None"/"No" except:

* **Unrestricted Web Access** — **No.** The app opens no arbitrary browser; the
  only external links are the privacy policy and terms.
* **Gambling** — **No.**
* **Contests** — **No.**

Suggested rating outcome: **4+**.

## 4. Export compliance — ready to answer

* **Does your app use encryption?** — **Yes.**
* **Does it qualify for an exemption?** — **Yes.** The app uses HTTPS/TLS and
  Apple-provided cryptography, plus SQLCipher for *local* database encryption at
  rest. That is standard encryption in a financial app, not a bespoke algorithm.
  The usual `ITSAppUsesNonExemptEncryption = false` declaration applies.
* Owner decision to confirm, since a wrong answer here is a legal statement
  rather than an engineering one: if uncertain, answer the questionnaire in App
  Store Connect rather than hard-coding the Info.plist key.

## 5. Reviewer notes — ready to paste

> Qirsh is an Arabic-first personal finance app for the Saudi and Egyptian
> markets. The interface is Arabic; the listing declares Arabic only.
>
> **Signing in.** Email/password, Sign in with Apple, and Google are all
> supported. Demo credentials are supplied in the App Review Information fields.
>
> **What to expect on first launch.** A short intro, then a guided tour on the
> dashboard ("How to use Qirsh" is also permanently available from Settings).
> The account we supply is pre-populated so the dashboard, reports and budgets
> are not empty.
>
> **SMS capture.** The app can read bank SMS to create transactions, but this is
> entirely optional and off until granted. On iOS it works through a Shortcut
> and a Share Extension — the app never reads messages by itself. Nothing is
> required for review; the app is fully usable with manual entry.
>
> **Cloud and AI.** Both are off by default and gated behind explicit in-app
> consent. With them off, the app is fully functional and keeps everything on
> the device. Bank message text sent for AI parsing is redacted first: card
> numbers, IBANs, phone numbers, account numbers and one-time codes are removed
> on-device before it leaves, and again on the server.
>
> **Ads.** The Google Mobile Ads SDK is present but ad placements are disabled
> in this build. Any ad request the app makes is non-personalized, and the app
> shows no ATT prompt.
>
> **Deleting an account.** Settings → account → delete. It is in-app and
> immediate, and the local financial database is wiped on sign-out.

## 6. What is genuinely owner-only

| Item | Why no one else can do it |
|---|---|
| App Store Connect entry of §1–§5 | Requires the owner's Apple ID session |
| Review account credentials | The owner chooses which account to expose |
| Distribution certificate + provisioning profile | `security find-identity -v -p codesigning` reports **0 valid identities** on this machine and there are no provisioning profiles installed. Signing needs the owner's Apple Developer account |
| Support URL / marketing URL | The owner's domain |
| Pricing and availability | Commercial decision |

Everything else in this document is done.

## 7. Screenshots

13 captures at 1320×2868 (6.9"), regenerable by one command — see
`V1_VISUAL_EVIDENCE.md`. App Store Connect also accepts a 6.5" set; the 6.9"
set satisfies the current requirement on its own.
