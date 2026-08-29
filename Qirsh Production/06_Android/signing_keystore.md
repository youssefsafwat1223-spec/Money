# Android Signing & Keystore

## Generate

```bash
keytool -genkeypair -v -keystore mali-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias mali
```

Answer the prompts; the distinguished name is not user-visible.

## ⚠️ Losing this file ends the app's life on Play

If you lose `mali-release.jks` or its passwords, **you can never update the app
again.** You would publish a new listing under a new package name and abandon
every install, review and rating.

**Before continuing, back it up in two independent places:**
1. Password manager (file attachment + both passwords)
2. Encrypted offline copy — different physical location

Enrolling in **Play App Signing** reduces the blast radius: Google holds the
*app* signing key and this becomes your *upload* key, which Google can help
reset. It does not remove the need for backups.

## Configure locally

```bash
cp app/android/key.properties.example app/android/key.properties
```

```properties
storePassword=<your store password>
keyPassword=<your key password>
keyAlias=mali
storeFile=/absolute/path/to/mali-release.jks
```

```bash
git status     # MUST show nothing new
```

Both `key.properties` and `*.jks` are gitignored. If either appears, stop and
fix `.gitignore` before committing anything.

CI alternative: `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.

## How Gradle consumes it — already correct

`app/android/app/build.gradle.kts`, verified by 10 tests in
`app/test/architecture/android_release_signing_test.dart`:

- Reads `key.properties` **or** the four environment variables
- **Release never falls back to the debug key.** Without a signing config,
  `signingConfig` stays null and every `assemble*Release` / `bundle*Release` /
  `package*Release` task fails with a named error. This guard exists because a
  debug-signed upload was rejected once.
- AdMob app id is shape-validated against `^ca-app-pub-[0-9]{16}~[0-9]{10}$` —
  the exact regex the SDK enforces in `MobileAdsInitProvider` at *process
  start*, where no Dart guard could catch a typo. Malformed **fails the build**;
  absent warns and ships with ads off.

## Build and verify

```bash
cd app
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... \
  --dart-define=LEGAL_BASE_URL=https://<host>

keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
keytool -list -v -keystore mali-release.jks -alias mali
# the SHA-256 fingerprints must match
```

## Known sandbox limitation

The Android release build cannot complete in the current development sandbox:
Gradle's JVM TLS handshake to `dl.google.com` is terminated, while `curl` to the
same URL returns 200. Plugin resolution succeeded, so the pinning is correct —
this is environmental. Build on your own machine or in Codemagic.
