# Apple Developer Configuration

Every step here is `[!] [EXTERNAL]` — Youssef, in Apple's console.

## 1. Membership
<https://developer.apple.com/programs/> — $99/yr.
**Record the Team ID** (10 characters, top-right of the developer portal).

## 2. App IDs — three of them

Certificates, Identifiers & Profiles → **Identifiers** → **+** → App IDs → App

| Bundle ID | For |
|---|---|
| `com.youssefsafwat.mali` | the app |
| `com.youssefsafwat.mali.BankMessageShortcuts` | Shortcuts extension |
| `com.youssefsafwat.mali.ShareBankMessage` | Share extension |

> The extension App IDs are easy to forget and fail the **signed build**, late
> and confusingly. Create all three now.

### Capabilities — all four required by shipped code

| Capability | Why | Evidence |
|---|---|---|
| Push Notifications | budget and capture alerts | `aps-environment` in `Runner.entitlements` |
| Sign in with Apple | auth provider | `com.apple.developer.applesignin` |
| App Groups | app ↔ extension handoff | `group.com.youssefsafwat.mali` |
| Keychain Sharing | shared device secret + capture queue key | two groups in entitlements |

Both extensions need **App Groups** and **Keychain Sharing** too.

## 3. App Group

Identifiers → **App Groups** → **+** → `group.com.youssefsafwat.mali`

Must match `Runner.entitlements` exactly. A mismatch breaks capture handoff at
runtime with no build error.

## 4. Distribution certificate

Certificates → **+** → **Apple Distribution**. Download and keep it in Keychain
Access. Codemagic can manage this for you.

## 5. Provisioning profiles

Profiles → **+** → **App Store** → one for **each** of the three App IDs.

## Verification

- Three App IDs listed, each showing the expected capabilities
- App Group exists and matches the entitlements string
- Three App Store profiles, all "Active"
- Team ID recorded for `APNS_TEAM_ID` and the Apple auth provider
