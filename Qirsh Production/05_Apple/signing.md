# iOS Signing & Release Build

## Repository state — already correct, no action

`app/ios/Runner/Info.plist`:

- Bundle id and display name `قرش` set
- `ITSAppUsesNonExemptEncryption = false` — **a legal declaration**, see below
- Purpose strings present in Arabic: Camera, Face ID, Photo Library
- `SKAdNetworkItems` present; no IDFA/ATT requested in V1
- Google Sign-In URL scheme registered
- `NSLocationWhenInUseUsageDescription` deliberately **absent** — the permission
  was removed in Phase-7 Batch-4

`app/ios/Runner/Runner.entitlements`:

- `aps-environment` = `$(APS_ENVIRONMENT)` — build-setting driven
- Sign in with Apple
- App Group `group.com.youssefsafwat.mali`
- Two Keychain groups, **the app's own group first** — required, because
  `flutter_secure_storage` uses the default group and must keep reading the
  existing SQLCipher key. Reordering these breaks database access on upgrade.

## Export compliance — confirm before submitting

`ITSAppUsesNonExemptEncryption = false` avoids the per-submission prompt. Qirsh
uses SQLCipher; the exemption for standard encryption protecting the user's own
data normally applies.

**This is a legal declaration. Confirm it against Apple's current criteria
before you submit** rather than inheriting the answer from this file.

## Building

Preferred — Codemagic `ios-signed-release`, which runs the strict gate before
signing:

```bash
flutter build ipa --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon> \
  --dart-define=SENTRY_DSN=<optional> \
  --dart-define=LEGAL_BASE_URL=https://<host>
```

## Verifying

- Archive validates in Xcode Organizer
- The build number is unique and higher than any prior upload
- Both legal links open live pages **from inside the installed app**
