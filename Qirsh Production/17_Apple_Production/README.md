# 17 — Apple Production Configuration

Canonical record of Apple identifiers, capabilities and signing state.
Complements [`../05_Apple/`](../05_Apple/), which holds the portal walkthroughs.

**Audited 2026-08-31 against source, not against documentation.**
Nothing was created, revoked or changed in any Apple portal.

> ⚠️ **Superseded in part.** A later audit found that most of the portal setup
> **already exists** — App IDs, App Group, capabilities, distribution profiles
> valid to 2027-06-29, and a distribution `.p12`. The "what to create" list
> below is therefore largely a "what to verify" list.
> **Read [`portal_audit.md`](portal_audit.md) first.**

---

## What the source actually requires

Read from `Runner.entitlements`, `ShareBankMessage.entitlements`,
`Runner.xcodeproj/project.pbxproj` and `pubspec.yaml`.

### Three bundle identifiers, not one

| Target | Bundle ID | Needs its own App ID + profile |
|---|---|---|
| Runner (app) | `com.youssefsafwat.mali` | **yes** |
| ShareBankMessage (share extension) | `com.youssefsafwat.mali.ShareBankMessage` | **yes** |
| RunnerTests | `com.youssefsafwat.mali.RunnerTests` | no — test target, never distributed |

⚠️ **The share extension is easy to miss.** It ships inside the app, has its own
entitlements, and needs its own App ID and provisioning profile. A distribution
build fails late if only the main App ID was registered.

`BankMessageShortcuts/` is source compiled into the app (App Intents), **not** a
separate target — no App ID needed. Verified: no `PRODUCT_BUNDLE_IDENTIFIER` for it.

### Capabilities — per target

**`com.youssefsafwat.mali`** (from `Runner.entitlements`):

| Capability | Entitlement | Value |
|---|---|---|
| Push Notifications | `aps-environment` | `$(APS_ENVIRONMENT)` → `development` on Debug/Profile, **`production` on Release** |
| Sign in with Apple | `com.apple.developer.applesignin` | `Default` |
| App Groups | `com.apple.security.application-groups` | `group.com.youssefsafwat.mali` |
| Keychain Sharing | `keychain-access-groups` | `$(AppIdentifierPrefix)com.youssefsafwat.mali` **and** `…mali.shared` |

**`com.youssefsafwat.mali.ShareBankMessage`**:

| Capability | Value |
|---|---|
| App Groups | `group.com.youssefsafwat.mali` |
| Keychain Sharing | `$(AppIdentifierPrefix)com.youssefsafwat.mali.shared` |

The extension has **no** push and **no** Sign in with Apple — correctly scoped.

The keychain group ordering in `Runner.entitlements` is load-bearing: the app's
own group must stay **first**, because `flutter_secure_storage` uses the default
group and holds the existing SQLCipher database key. Reordering would orphan it.

### Verified identifiers

| Identifier | Claimed | Verified in source |
|---|---|---|
| Bundle ID | `com.youssefsafwat.mali` | ✅ `applicationId`, `PRODUCT_BUNDLE_IDENTIFIER`, `namespace` |
| App Group | `group.com.youssefsafwat.mali` | ✅ both entitlements files; only App Group string in the tree |
| Team ID | — | ✅ `DEVELOPMENT_TEAM = 5TWARK8A23` in the project |

---

## ⚠️ Two claimed identifiers are NOT confirmed by source

### Sign in with Apple Services ID `com.youssefsafwat.mali.signin`

**Not referenced anywhere in source.** And on the evidence, it may not be needed:

`supabase_auth_service.dart` uses `SignInWithApple.getAppleIDCredential(...)` and
exchanges the token with `signInWithIdToken(provider: OAuthProvider.apple)`. That
is the **native** flow. There is no `signInWithOAuth`, no `redirectTo`, and no
`webAuthenticationOptions`. A Services ID is required for the **web/Android**
Apple flow, not the native iOS one — Supabase's Apple provider takes the
**Bundle ID** as the client ID for native token exchange.

### App redirect `com.youssefsafwat.mali://login-callback`

**Not registered in `Info.plist`.** The only `CFBundleURLSchemes` entry is the
Google reversed-client-id scheme. Consistent with the native flow: nothing
redirects back into the app, so no custom scheme is required.

### But there is a real question behind this

`auth_screen.dart` renders `_appleButton(c)` **unconditionally** — no
`Platform.isIOS` gate and no `dart:io` import. `SignInWithApple.getAppleIDCredential`
without `webAuthenticationOptions` cannot complete on Android.

So exactly one of these is true, and it decides the Apple configuration:

| If | Then |
|---|---|
| **A — Apple sign-in is iOS-only** (intended) | the button should be platform-gated in source. **No Services ID, no callback URL, no scheme needed.** |
| **B — Apple sign-in must work on Android** | you need the Services ID `com.youssefsafwat.mali.signin`, the Supabase callback `https://rjwphwsefnuotpbtuycf.supabase.co/auth/v1/callback` registered as a Return URL, **and** source changes to pass `webAuthenticationOptions`. |

**This is a product decision, not a signing one.** It is out of scope for this
audit and was not changed. Resolve it before configuring the Apple provider,
because A and B need different portal setup. Under A, the button showing on
Android is a UI defect worth fixing regardless.

---

## Current signing state

| Item | State |
|---|---|
| Team ID in project | `5TWARK8A23` (TeamName "Albaraa Alshehri") |
| Code sign style | **Automatic** — fine for local debug; release signs in CI |
| Code sign identity | `Apple Development` |
| Provisioning profile specifier | empty |
| Distribution certificate **installed** | **no** — 0 Apple Distribution identities in the keychain |
| Distribution certificate **exists** | **yes** — `~/Downloads/mali_distribution.p12` |
| Provisioning profiles **installed** | **no** — `~/Library/MobileDevice/Provisioning Profiles` absent |
| Provisioning profiles **exist** | **yes** — App Store Main + Share, valid to 2027-06-29 |
| APNs auth key | **four `AuthKey_*.p8` in `~/Downloads`**; which is APNs is not determinable locally |

The portal is largely configured; **this machine is not**. Detail and evidence:
[`portal_audit.md`](portal_audit.md).

`APS_ENVIRONMENT` is already `production` on the Release configuration — correct
and needs no change.

---

## Required human actions — portal only, I cannot do these

All require Apple ID authentication and 2FA. **Do not paste Apple credentials,
private keys or the `.p8` into chat.**

1. **Confirm the Apple Developer Program membership is active** for team
   `5TWARK8A23` ($99/yr). Everything below fails without it.
2. **Register App IDs** — `com.youssefsafwat.mali` and
   `com.youssefsafwat.mali.ShareBankMessage`.
3. **Register the App Group** `group.com.youssefsafwat.mali`, assigned to both.
4. **Enable capabilities on the main App ID**: Push Notifications, Sign in with
   Apple, App Groups, Keychain Sharing. Extension: App Groups + Keychain Sharing.
5. **Create an APNs Auth Key (`.p8`)** — Keys → **+** → Apple Push Notifications
   service. Record the **Key ID** and **Team ID**; the `.p8` downloads **once**
   and cannot be re-downloaded. Back it up like the Android keystore.
6. **Create a Distribution certificate** and **App Store provisioning profiles**
   for both bundle IDs.
7. **Decide A or B above**, then configure the Supabase Apple provider
   accordingly.
8. **Create the App Store Connect app record** (name, SKU, primary language,
   bundle ID).

### Order matters

App IDs → App Group → capabilities → certificate → profiles. A profile created
before a capability is enabled does not carry it, and the build fails at signing
with a message that does not name the missing capability.

---

## What must later go into Codemagic — DEFERRED

Recorded here so the consolidated pass has the list;
see [`../15_Codemagic/README.md`](../15_Codemagic/README.md).

| Item | Secret |
|---|---|
| Distribution certificate (`.p12`) + its password | **yes** |
| App Store provisioning profiles (both bundle IDs) | yes |
| App Store Connect API key (`.p8`) + Key ID + Issuer ID | **yes** |
| APNs key ID / Team ID | not secret; the `.p8` **is** |

## Must NEVER be committed

- the APNs `.p8`
- any `.p12`, `.cer`, `.mobileprovision`
- the App Store Connect API key
- any Apple ID password or app-specific password

Safe to record here: Team ID, bundle IDs, App Group, Key IDs, capability lists.
