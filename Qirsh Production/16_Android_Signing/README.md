# 16 — Android Production Signing

Canonical record for the Android upload key and Play App Signing.
Supersedes the signing portion of [`../06_Android/signing_keystore.md`](../06_Android/signing_keystore.md),
which stays for Play Console/store detail.

**Audited 2026-08-31. Nothing generated. No keystore exists yet.**

---

## Current state — audited, not assumed

| Item | State |
|---|---|
| `applicationId` | **`com.youssefsafwat.mali`** — matches the target exactly |
| `namespace` | `com.youssefsafwat.mali` |
| Production keystore | **DOES NOT EXIST** — none under `app/android`, none in `$HOME` |
| `android/key.properties` | **ABSENT** (`key.properties.example` present) |
| Signing env vars set locally | none |
| Play App Signing | **not enrolled** — no Play Console app record yet |
| Keystore files tracked in git | **0** |
| Debug keystore | `~/.android/debug.keystore` present — development only, never ships |

### Could a release build accidentally be debug-signed? **NO.**

This is the question worth answering carefully, because a debug-signed upload was
rejected once before. `app/android/app/build.gradle.kts` fails closed:

```kotlin
if (!hasReleaseSigningConfig) {
    tasks.configureEach {
        val releaseTask = (name.startsWith("assemble") || name.startsWith("bundle") ||
                           name.startsWith("package")) && name.contains("Release")
        if (releaseTask) doFirst { throw GradleException("No release signing configuration…") }
    }
}
```

`signingConfig` is left **null** rather than falling back to debug, and every
`assemble*Release` / `bundle*Release` / `package*Release` task throws a named
error first. `flutter run` (debug) is unaffected. 10 tests in
`app/test/architecture/android_release_signing_test.dart` enforce this.

So the current state is *safe but unbuildable* for release — which is correct.

### How the signing values are resolved

`releaseSigningValue(envName, propertyName)` — **environment first, then
`key.properties`**:

| Env var (CI) | `key.properties` key |
|---|---|
| `ANDROID_KEYSTORE_PATH` | `storeFile` |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` |
| `ANDROID_KEY_ALIAS` | `keyAlias` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` |

All four must be non-blank or `hasReleaseSigningConfig` is false. There is no
partial-configuration state.

### .gitignore coverage — verified with `git check-ignore`

`app/android/.gitignore` lines 12–14:

```
key.properties
**/*.keystore
**/*.jks
```

Confirmed ignored: `key.properties`, `app/upload-keystore.jks`,
`upload-keystore.jks`. **0** keystore-shaped files are tracked.

---

## Upload key vs Play App Signing — the distinction that matters

| | Upload key | App signing key |
|---|---|---|
| Who holds it | **you** | **Google**, if you enrol in Play App Signing |
| What it does | signs the AAB you upload | signs the APKs delivered to devices |
| If lost | **recoverable** — Google can reset it | **catastrophic** if you hold it and lose it |

**Enrol in Play App Signing.** It converts losing your key from "the app is dead
on Play" into "request an upload key reset". Enrolment happens at app creation
in Play Console and is effectively irreversible, so decide before creating the
record.

The key generated below is therefore an **upload key**. Google will hold the
app signing key.

---

## ⛔ STOP — human inputs required before generating

I will not invent any of these, and none may be committed:

| Input | Notes |
|---|---|
| **Keystore password** | strong, unique, stored in a password manager |
| **Key password** | may differ from the store password; store both |
| **Key alias** | suggestion: `qirsh-upload` — your choice, and it is permanent |
| **CN** (name) | e.g. `Youssef Safwat` |
| **OU / O** | organisational unit / organisation, or blank |
| **L / ST / C** | city / state / two-letter country code, e.g. `EG` |

The distinguished-name fields are baked into the certificate and are visible to
anyone who inspects it. They cannot be changed later without a new key.

### The command (to be run interactively, by you)

```bash
keytool -genkeypair -v \
  -keystore ~/qirsh-upload-keystore.jks \
  -alias <YOUR_ALIAS> \
  -keyalg RSA -keysize 4096 \
  -validity 10000 \
  -storetype JKS
```

`-validity 10000` (~27 years) is deliberate: Play requires the key to outlive the
app, and a key that expires ends your ability to ship updates.

Generate it **outside the repository** — `~/` , not `app/android/`. The gitignore
covers the repo paths, but a key that is never inside the working tree cannot be
committed by an errant `git add -A`.

---

## After generation — required, in order

1. **Record the fingerprints** (no passwords):
   ```bash
   keytool -list -v -keystore ~/qirsh-upload-keystore.jks -alias <ALIAS>
   ```
   Capture SHA-1, SHA-256, alias, creation date, validity, key algorithm/size
   into [`keystore_record.md`](keystore_record.md).

2. **Two independent backups**, on different media/providers — e.g. an encrypted
   password-manager attachment plus an offline encrypted volume. Not two folders
   on the same disk. Store the passwords separately from the keystore file.

3. **Write `app/android/key.properties`** from `key.properties.example`. It is
   gitignored; confirm with `git status` that it does not appear.

4. **Verify the signing config resolves** without building a release artifact —
   `./gradlew signingReport` in `app/android`.

5. Later, for Codemagic: base64 the keystore and inject it as
   `ANDROID_KEYSTORE_BASE64` plus the three secret values. **Deferred** to the
   consolidated pass — see [`../15_Codemagic/README.md`](../15_Codemagic/README.md).

---

## Must NEVER be committed

- the `.jks` file
- `key.properties`
- any of the three passwords, in any file, including this one
- the base64 encoding of the keystore

**Never in this repository, in any form.** Fingerprints, alias, dates and
validity are safe to record — they are public properties of the certificate.
