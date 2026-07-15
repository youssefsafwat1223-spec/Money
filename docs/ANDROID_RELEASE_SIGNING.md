# Android Release Signing — Owner Setup

**Status:** Required before any Play Store upload. `app/android/app/build.gradle.kts` now
refuses to produce a release artifact (`assembleRelease`, `bundleRelease`, `flutter build
apk|appbundle --release`) until this is done — it no longer silently signs release builds
with the debug key. Debug-mode `flutter run` (no `--release`) is unaffected.

This is a one-time setup that only the app owner should perform, because the keystore
generated here is a permanent credential: **losing it means losing the ability to ever
publish an update to the existing Play Store listing** — Google does not offer a recovery
path for a lost app-signing key on classic (non-Play App Signing) uploads. Treat it like a
root password, not a regular secret.

## 1. Generate the keystore (once)

```bash
keytool -genkeypair -v \
  -keystore mali-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias mali
```

`keytool` will prompt for a keystore password, a key password (can be the same value), and
your name/organization details (these appear in the certificate, not in the app itself —
any reasonable values are fine). Keep the `.jks` file itself **outside the git repository**.

## 2. Store and back it up

- Keep at least two independent copies of `mali-release.jks` (e.g., a password manager's
  file storage, plus an encrypted external drive or cloud vault you control) — do not rely
  on a single laptop.
- Store the keystore password and key password in the same password manager, clearly
  labeled (e.g., "Mali Android release keystore — password" / "— key password").
- Do not email the file or paste the passwords into chat/ticket systems.

## 3. Configure a local build

Copy the template and fill in your real values:

```bash
cd app/android
cp key.properties.example key.properties
```

Edit `key.properties`:

```properties
storePassword=<the keystore password from step 1>
keyPassword=<the key password from step 1>
keyAlias=mali
storeFile=/absolute/path/to/mali-release.jks
```

`key.properties` and `*.jks`/`*.keystore` are already gitignored (`app/android/.gitignore`) —
verify `git status` shows nothing new before committing anything else.

Build a signed release locally to confirm it works:

```bash
cd app
flutter build appbundle --release
```

If `key.properties` is missing or incomplete, this now fails immediately with a clear error
naming exactly what's missing, instead of silently signing with the debug key.

## 4. Configure Codemagic (CI)

Codemagic builds don't have `key.properties` (it's gitignored, so it never reaches the
build machine). Instead, set these as **encrypted environment variables** in the Codemagic
project settings — add them to the existing `supabase` variable group, or a new group, in
**Codemagic → Team settings/Project settings → Environment variables**:

| Variable | Value |
|---|---|
| `ANDROID_KEYSTORE_PATH` | Path to the keystore file *on the build machine* — see below |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore password from step 1 |
| `ANDROID_KEY_ALIAS` | `mali` |
| `ANDROID_KEY_PASSWORD` | The key password from step 1 |

`ANDROID_KEYSTORE_PATH` needs the file to actually exist on the runner. Codemagic supports
uploading an encrypted file (Project settings → encrypted file, not a plain env var) and
exposing its runtime path as an environment variable — point `ANDROID_KEYSTORE_PATH` at
that path. Do not paste the `.jks` file's contents into a plain-text environment variable.

No `codemagic.yaml` changes are needed for this — Gradle reads the four `ANDROID_KEYSTORE_*`
environment variables directly (see `app/android/app/build.gradle.kts`), the same way the
existing `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SENTRY_DSN` variables are already read via
`--dart-define`. Once these four are set, an Android build workflow can be added to
`codemagic.yaml` the same way the two iOS workflows already exist — that's a separate,
deliberate step, not something this change makes for you.

## 5. Verify the build and inspect the signed artifact

From `app/`:

```bash
# Debug build — always works, unaffected by any of this.
flutter build apk --debug

# Release build — requires key.properties (or the four env vars) to exist.
flutter build appbundle --release
```

**Expected success** (once `key.properties` is filled in from step 3): the build finishes
normally and prints something like:

```
✓ Built build/app/outputs/bundle/release/app-release.aab (XX.XMB)
```

**Expected failure** (if `key.properties`/env vars are missing or incomplete) — the build
stops immediately with:

```
No release signing configuration found for task 'bundleRelease'. Set
android/key.properties (see key.properties.example) or the
ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS /
ANDROID_KEY_PASSWORD environment variables before building a release
artifact. See docs/ANDROID_RELEASE_SIGNING.md for owner steps to generate,
store, and back up the keystore.
```

This is the intended behavior — it means the build refused to silently fall back to debug
signing (the original problem). `flutter build apk --debug` must still succeed either way;
if it doesn't, that's an unrelated build issue, not a signing-config issue.

To confirm a release artifact was actually signed with the real key (not debug):

```bash
# For an .aab:
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab

# For an .apk (needs Android SDK build-tools' apksigner on PATH):
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk

# Compare the printed SHA-256 certificate fingerprint against the keystore's own:
keytool -list -v -keystore mali-release.jks -alias mali
```

The two SHA-256 fingerprints must match. If the artifact's fingerprint matches Android's
well-known debug certificate fingerprint instead
(`SHA256: FA:C6:17:45:DC:09:...` — varies per machine's `~/.android/debug.keystore`, but
`keytool -list -v -keystore ~/.android/debug.keystore -storepass android` shows the local
one), the release build is still using debug signing and this setup did not take effect.

## 6. What NOT to do

- Do not commit `key.properties` or the `.jks` file.
- Do not generate a new keystore "to make the build pass" if this one is ever lost — a
  new keystore cannot update an app already published under the old one. If the keystore
  is genuinely lost, the only recovery is Google's app-signing key upgrade/reset process
  for accounts enrolled in Play App Signing (not applicable if you're not enrolled) —
  contact Play Console support before assuming this is unrecoverable.
