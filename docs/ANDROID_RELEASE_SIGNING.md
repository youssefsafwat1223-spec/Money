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

## 4. Configure Codemagic (CI) — the canonical release path

Codemagic never sees `key.properties` (it is gitignored), so the upload keystore is
**materialised on the runner from an encrypted secret**. This is the single canonical
mechanism — Codemagic's native `android_signing` integration is deliberately NOT used, so
there is only ever one signing path to reason about.

Set these in **Codemagic → Environment variables**, group `google_play`, all marked
**secure**:

| Variable | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | The upload keystore (`.jks`) base64-encoded — `base64 -i upload-keystore.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias (e.g. `mali`) |
| `ANDROID_KEY_PASSWORD` | Key password |

`ANDROID_KEYSTORE_PATH` is **not** stored anywhere. The `Materialise upload keystore`
step in `codemagic.yaml` decodes the secret into `$CM_BUILD_DIR/upload-keystore.jks`
(the ephemeral build workspace — never the repository, never a fixed machine path),
`chmod 600`s it, exports the path via `$CM_ENV` for Gradle, and a later step shreds it.
No secret value is ever echoed; only the path is logged.

If any of the four inputs is missing the step **fails immediately** rather than letting the
build continue — a release signed with the debug key is exactly the failure this design
exists to prevent.

### Google Play App Signing — which key is which

| Key | Held by | Used for |
|---|---|---|
| **App signing key** | **Google Play** (Play App Signing) | Signing what users actually install. Never leaves Google. |
| **Upload key** | You / CI secret store | Signing the AAB you upload. This is the key materialised above. |

Everything in this document concerns the **upload key**. If the upload key is lost or
compromised you can request an upload-key reset in Play Console and continue shipping —
losing the *app signing* key is unrecoverable, which is why Play holds it.

### Key custody and rotation posture

- Store the keystore and its passwords in a real secret manager (and the CI secret store);
  never in Git, never in a shared doc, never in chat.
- Keep an offline escrow copy of the upload keystore in at least one place you control.
- Record who owns the alias and the passwords, so rotation is not blocked on one person.
- Rotation: generate a new upload key → request an upload-key reset in Play Console →
  replace `ANDROID_KEYSTORE_BASE64` + credentials in CI. No app update is required for
  users, because Play re-signs with the unchanged app signing key.

### Certificate fingerprints (needed later, not now)

Google Sign-In / Firebase-style integrations key off SHA-1/SHA-256 certificate
fingerprints, and Android release Google Sign-In will need them:

- the **upload** certificate fingerprint (from your keystore), and
- the **Play App Signing** certificate fingerprint (shown in Play Console once the app is
  enrolled).

Both must be registered for the release build to authenticate. **Do not invent these
values** — they do not exist until the real keys do.

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
