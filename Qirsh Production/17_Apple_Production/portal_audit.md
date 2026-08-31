# Apple Portal — Pre-Mutation Audit

**Audited 2026-08-31 from local evidence. No portal action taken.**

## ⏸ APPLE PORTAL KEY RECONCILIATION: DEFERRED — awaiting owner/client 2FA access

Portal sign-in needs a 2FA code sent to the client's device, and the client is
unavailable. No further login is to be attempted and no additional verification
codes requested.

**Everything below derived from local files remains valid** — signed provisioning
profiles are authoritative about what the portal contained when they were
issued. But **portal state today is UNVERIFIED**: an identifier or capability
could have been changed or removed since July 2026, and nothing here can detect
that.

Specifically UNVERIFIED until the owner is available:

- whether both App IDs still exist with the recorded capabilities
- whether the App Group is still assigned to both
- **which of the four `AuthKey_*.p8` files is the APNs key** and which are App
  Store Connect API keys — not determinable locally, the filename pattern is
  identical for both
- whether the distribution certificate is still valid and unrevoked
- whether an App Store Connect record exists

The four `.p8` and two `.p12` files in `~/Downloads` are **left exactly where
they are** — not moved, not deleted, not opened.

## The headline: most of this already exists

The earlier audit said "no certificates, no profiles, nothing configured". That
was accurate about **installed** artifacts and wrong about what exists.
`~/Downloads` holds a full set of Apple artifacts from **June–July 2026**:
distribution profiles, a distribution `.p12`, and four `AuthKey_*.p8` files.

Provisioning profiles are signed plists, so their metadata is authoritative
evidence of what the portal contained when they were issued. Decoded below —
public fields only; no private key was opened.

### Already registered in the portal

| Item | Evidence | State |
|---|---|---|
| Team | `5TWARK8A23`, TeamName **"Albaraa Alshehri"** | active |
| App ID `com.youssefsafwat.mali` | AppIDName `XC com youssefsafwat mali` | **registered** |
| App ID `com.youssefsafwat.mali.ShareBankMessage` | AppIDName `XC com youssefsafwat mali ShareBankMessage` | **registered** |
| App Group `group.com.youssefsafwat.mali` | in both profiles' entitlements | **registered and assigned to both** |
| Sign in with Apple | `com.apple.developer.applesignin = [Default]` on main | **enabled** |
| Push, production | `aps-environment = production` on main | **enabled** |
| Keychain Sharing | `keychain-access-groups = [5TWARK8A23.*, com.apple.token]` | **enabled** (wildcard covers `…mali` and `…mali.shared`) |
| TestFlight | `beta-reports-active = true` | ready |
| Distribution certificate | profiles embed developer certificates; `mali_distribution.p12` present | **exists**, not installed |

**App Store profiles**, both valid until **2027-06-29**:

- `Mali App Store Main` → `5TWARK8A23.com.youssefsafwat.mali` (created 2026-07-03)
- `Mali App Store Share` → `5TWARK8A23.com.youssefsafwat.mali.ShareBankMessage` (created 2026-06-30)

### Not installed on this machine

| Item | State |
|---|---|
| `~/Library/MobileDevice/Provisioning Profiles` | **absent** — no profile installed |
| Apple **Distribution** identity in keychain | **0** |
| Apple **Development** identities in keychain | 2 — `youssefsafwat1223@gmail.com (X7FVP6AP99)`, `Albaraa Alshehri (H62JFX7P85)` |

So the portal is largely configured; **this machine is not**.

---

## Required capability matrix, verified against entitlements

Source of truth: `Runner/Runner.entitlements`, `ShareBankMessage/ShareBankMessage.entitlements`.
Only these two exist, and only these two are wired via `CODE_SIGN_ENTITLEMENTS`.

### `com.youssefsafwat.mali` (main app)

| Capability | Entitlement | Value | Portal |
|---|---|---|---|
| Push Notifications | `aps-environment` | `$(APS_ENVIRONMENT)` → **`production` on Release** | ✅ enabled |
| Sign in with Apple | `com.apple.developer.applesignin` | `[Default]` | ✅ enabled |
| App Groups | `com.apple.security.application-groups` | `group.com.youssefsafwat.mali` | ✅ enabled |
| Keychain Sharing | `keychain-access-groups` | `$(AppIdentifierPrefix)com.youssefsafwat.mali`, `…mali.shared` | ✅ via `5TWARK8A23.*` |

The keychain group **ordering is load-bearing**: the app's own group must stay
first, because `flutter_secure_storage` uses the default group and holds the
SQLCipher database key. Reordering orphans it.

### `com.youssefsafwat.mali.ShareBankMessage` (share extension)

| Capability | Value | Portal |
|---|---|---|
| App Groups | `group.com.youssefsafwat.mali` | ✅ enabled |
| Keychain Sharing | `$(AppIdentifierPrefix)com.youssefsafwat.mali.shared` | ✅ via wildcard |
| Push Notifications | **not present** — correctly not required | n/a |
| Sign in with Apple | **not present** — correctly not required | n/a |

Source confirms the expectation rather than contradicting it.

### App Group assignment

`group.com.youssefsafwat.mali` must be assigned to **both** App IDs. Both
profiles already carry it. The identifier is hardcoded in
`SharedCaptureStore.swift` (`appGroupIdentifier`) in **two byte-identical
copies** — Runner and ShareBankMessage — so app and extension agree.

### Native targets

Three: `Runner` (application), `ShareBankMessage` (app-extension), `RunnerTests`
(unit-test — never distributed, needs no App ID).

⚠️ **`BankMessageShortcuts` is NOT a native target.** It is Swift source compiled
into the app. Older documentation claims a `BankMessageShortcuts.entitlements`
file exists — **it does not**. Only two entitlements files exist on disk.

---

## Orphaned App ID

`Mali_App_Store_Shortcuts*.mobileprovision` →
`5TWARK8A23.com.youssefsafwat.mali.BankMessageShortcuts`, valid to 2027-06-29.

That App ID was registered when Shortcuts was a separate extension target. It no
longer is. The App ID is **orphaned** — harmless, but it should not be included
in any distribution build, and `app/tools/verify_ios_packaging.sh` already
requires exactly `ShareBankMessage.appex` and forbids others. Leave it; deleting
portal identifiers is irreversible and buys nothing.

---

## APNs

| Question | Answer |
|---|---|
| Does a `.p8` exist locally? | **Yes — four**, all in `~/Downloads`, 257 bytes each |
| Key IDs (from filenames) | `5WYM5H69FN`, `G47FD68782`, `8H2HC86WD3`, `2P69UZ8XLJ` |
| Any key ID documented? | **No** — 0 files in this repository mention any of them |
| Is production push entitlement correct? | **Yes** — `APS_ENVIRONMENT = production` on Release, `development` on Debug/Profile |
| `APNS_BUNDLE_ID` | `com.youssefsafwat.mali` — confirmed in `supabase/functions/_shared/apns_test.ts` |

⚠️ **`AuthKey_<KEYID>.p8` is the filename pattern for BOTH APNs auth keys and App
Store Connect API keys.** Four exist and none is documented, so **which is which
cannot be determined locally** — only the portal knows. Do not guess: feeding an
App Store Connect key to APNs produces authentication failures that look like a
push-delivery bug.

**Owner action:** in the portal under **Certificates, Identifiers & Profiles →
Keys**, list the keys and record, for each: Key ID, key type (APNs vs App Store
Connect), and creation date. Then match against the four files. If an APNs key
already exists, **no new key is needed** — reuse it.

If a new one is required: Keys → **+** → enable **Apple Push Notifications
service (APNs)** → Continue → Register → Download. **The `.p8` downloads exactly
once and cannot be re-downloaded.** Back it up like the Android keystore: two
independent locations, one off-machine.

Secrets later needed by Edge Functions (**deferred** — Functions deployment is
blocked on the Supabase 403): `APNS_KEY_ID`, `APNS_TEAM_ID` (= `5TWARK8A23`),
`APNS_BUNDLE_ID` (= `com.youssefsafwat.mali`), `APNS_PRIVATE_KEY` (the `.p8`
contents — **never** in this repository).

---

## Distribution signing strategy

**Recommendation: explicit App Store provisioning profiles, not Xcode automatic
signing.**

Xcode automatic signing is convenient locally and wrong for this project:

1. **Codemagic cannot use it.** CI has no Apple ID session; it needs an explicit
   `.p12` plus profiles, or an App Store Connect API key. `codemagic.yaml`
   already declares `ios_signing` with `distribution_type: app_store`.
2. **Automatic signing silently regenerates profiles**, which can change the
   capability set and produce a build that differs from the one you validated.
3. **Two targets must stay in lockstep.** App and extension share an App Group;
   automatic signing manages them independently and can drift.
4. **Valid profiles already exist** to 2027-06-29 — reuse beats regenerate.

The project is currently `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY =
"Apple Development"`, empty `PROVISIONING_PROFILE_SPECIFIER` — a development
configuration. That is fine for local debug; release signing will come from CI
with explicit profiles, so **no project change is needed now**.

---

## App Store Connect record

Not created. Values to confirm before creating one:

| Field | Value | Source |
|---|---|---|
| Bundle ID | `com.youssefsafwat.mali` | verified in source |
| Platform | iOS | — |
| Primary language | **OWNER DECISION** — Arabic is the app's first language; the store listing language is separate | not in source |
| App name | **OWNER DECISION** — "Qirsh" / "قِرش" both in use; App Store names must be unique | brand is `Qirsh`/`قِرش` |
| SKU | **OWNER DECISION** — suggestion `qirsh-ios-001`; internal only, never shown, immutable | not defined |
| Category | **OWNER DECISION** — Finance is the obvious fit but is not stated anywhere in the repo | not in source |
| Privacy policy URL | `https://qirsh.site/privacy` | live, verified 200 |
| Support URL | `https://qirsh.site/support` | live, verified 200 |

Marked OWNER DECISION rather than invented. App name and SKU are effectively
permanent.

---

## Recommended portal order

Each step is owner-executed and needs Apple ID + 2FA.

1. **Verify membership is active** for team `5TWARK8A23`. Everything else fails
   without it, and the profiles expire 2027-06-29 regardless.
2. **Confirm both App IDs still exist** with the capability set above. The
   profiles prove they existed in July; confirm nothing was removed.
3. **Confirm the App Group** exists and is assigned to both.
4. **Keys → list, and identify the four `.p8` files.** Record which is APNs.
5. **Locate or re-create the distribution certificate.** `mali_distribution.p12`
   exists but is not installed and needs its password.
6. **Download the two current profiles** (Main, Share) rather than regenerating.
7. **Create the App Store Connect record** once name/SKU/category are decided.

### Irreversible / high consequence

| Action | Why |
|---|---|
| Downloading an APNs `.p8` | one download only, ever |
| Revoking a certificate | invalidates every profile built on it |
| Deleting an App ID | cannot be recreated with the same identifier if the app shipped |
| App Store Connect **SKU** | permanent once set |
| App Store Connect **app name** | changeable, but subject to review and uniqueness |
| Play App Signing enrolment (Android) | out of scope here, listed because it is the same class |

Steps 1–4 and 6 are read/verify or low-risk. Step 5 may involve certificate
creation, which is the first genuinely consequential one.

---

## Must never be committed

The APNs `.p8`, any `.p12`, `.cer` or `.mobileprovision`, the App Store Connect
API key, any Apple ID or app-specific password.

**Note:** `~/Downloads` currently holds four `.p8` files and two `.p12` files —
private key material sitting in an unencrypted, frequently-synced folder. Move
them to secure storage. They are outside the repository, so git is not at risk,
but the exposure is real.
