# Mali — Owner Release Checklist

One-time, owner-only actions remaining before this branch can ship. Full detail for each item
is in the referenced doc; this file is the checklist, not the explanation.

## 1. Android keystore setup
- [ ] `keytool -genkeypair -v -keystore mali-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias mali`
- [ ] Store the `.jks` in 2+ independent secure locations; store both passwords in a password manager
- [ ] `cd app/android && cp key.properties.example key.properties` and fill in real values
- [ ] Confirm `git status` shows nothing new (`key.properties`/`*.jks` are gitignored)
- Full detail: `docs/ANDROID_RELEASE_SIGNING.md`

## 2. Android build verification
- [ ] `flutter build apk --debug` → succeeds (unaffected by signing config)
- [ ] `flutter build appbundle --release` → succeeds once `key.properties` is filled in; fails with a named error if not
- [ ] `keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab` → SHA-256 fingerprint matches `keytool -list -v -keystore mali-release.jks -alias mali`

## 3. Deno verification
- [ ] `deno check` on all modified/new Edge Function files (see final closure report for the exact file list)
- [ ] `deno test supabase/functions/` → all tests pass, including `catalog-delta/index_test.ts` (8 cases)

## 4. SENTRY_DSN in Codemagic
- [ ] Add `SENTRY_DSN` to the `supabase` variable group in Codemagic project settings (code side already wired in both workflows)

## 5. Google Sign-In nonce setting
- [ ] Confirm "Skip nonce checks" is enabled on the **production** Supabase project (Authentication → Providers → Google)

## 6. iOS extension provisioning profiles
- [ ] Confirm provisioning profiles exist for `BankMessageShortcuts` and `ShareBankMessage` in App Store Connect / Codemagic before running `ios-signed-release`

## 7. Final app display-name decision
- [ ] Decide "Mali" vs "قرش" as the shipped store/home-screen name
- [ ] Update `CFBundleDisplayName`/`CFBundleName` (iOS `Info.plist`) and `android:label` (`AndroidManifest.xml`) to match

## 8. Real-device manual QA
- [ ] B1 shared-device regression: sign out as User A, sign in as User B, restore a backup → confirm zero of A's data appears in B's account
- [ ] Bill reminder and goal milestone notifications fire correctly, no duplicate/missing IDs
- [ ] SMS/notification capture flow end-to-end on a real iPhone
- [ ] Account deletion request → cancel → re-request flow in Settings

## 9. TestFlight / internal-testing steps
- [ ] Run `ios-unsigned-sideload` (or signed, once §6 is done) via Codemagic
- [ ] Distribute to a small internal group first — not a public TestFlight link
- [ ] Confirm crash reporting arrives in Sentry (validates §4 actually took effect)
- [ ] Only proceed to a wider TestFlight/Play Store internal track after §8 passes

## 10. Final GO/NO-GO sign-off
- [ ] All items 1–9 above are checked
- [ ] Sign-off recorded here: ______________________  Date: __________
