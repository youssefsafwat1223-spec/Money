# Upload Keystore Record

**Status: GENERATED, BACKED UP (partially), and LOCAL SIGNING VERIFIED — 2026-08-31.**

⛔ **No password, passphrase or base64 blob appears in this file.**
Fingerprints, subject, alias, dates and validity are public properties of the
certificate and are safe to record. Passwords are not, and never will be.

Metadata below was read with `keytool -list -v` **without supplying a password** —
JKS permits a certificate-only read (with an integrity warning). Nothing secret
was accessed, requested or logged.

## Identity

| Field | Value |
|---|---|
| Purpose | **Upload key** (Google holds the app signing key once Play App Signing is enrolled) |
| Package | `com.youssefsafwat.mali` |
| Keystore path | `~/qirsh-upload-keystore.jks` — **outside the repository** |
| File permissions | `600` (owner read/write only) |
| File size | 3,915 bytes |
| Alias | **`qirsh-upload`** |
| Entry type | `PrivateKeyEntry`, certificate chain length 1 (self-signed) |
| Key algorithm / size | **RSA, 4096-bit** |
| Signature algorithm | `SHA384withRSA` |
| Store type | **JKS** |
| Serial number | `fa41e7c6dc1dda9a` |
| Certificate version | 3 |

## Subject / Issuer

Self-signed, so subject and issuer are identical:

```
CN=youssef safwat, OU=qirsh, O=qirsh, L=saudi, ST=makkah, C=sa
```

These fields are baked into the certificate permanently and are visible to
anyone who inspects the APK. They cannot be changed without a new key.

## Validity

| | |
|---|---|
| Created | **2026-08-31** |
| Valid from | Mon 2026-08-31 03:27:10 EEST |
| Valid until | **Fri 2054-01-16 02:27:10 EET** |

~27 years. Correct: the key must outlive the app, because a key that expires
ends the ability to ship updates.

## Fingerprints

| Algorithm | Fingerprint |
|---|---|
| **SHA-1** | `82:C8:9D:D4:9C:98:D5:F0:05:56:E9:DF:7F:A5:63:C7:25:8D:BC:C0` |
| **SHA-256** | `87:7C:14:73:0D:29:B0:22:E5:86:44:DA:4A:E6:F5:FA:69:A1:09:8E:59:81:74:70:69:E0:37:77:93:85:87:11` |

SHA-1 is what Play Console displays for the upload certificate. SHA-256 is what
you compare against after any upload-key reset. Keep both.

Re-derive at any time (still no password needed):

```bash
/usr/local/Cellar/openjdk@17/17.0.20.1/bin/keytool \
  -list -v -keystore ~/qirsh-upload-keystore.jks -alias qirsh-upload
```

> `keytool` on `PATH` (`/usr/bin/keytool`) is a **non-functional macOS stub** —
> there is no system JDK. Use the Cellar path above. This is what silently
> defeated the first generation attempt.

## Backups

Original and two copies, all byte-identical and all proven to hold a usable key.

| # | Destination | Filesystem | Independence | sha256 vs original | cert SHA-1/256 | Mode |
|---|---|---|---|---|---|---|
| — | `~/qirsh-upload-keystore.jks` | APFS (`disk1s1`) | original | — | ✓ / ✓ | `600` |
| 1 | `~/Library/Mobile Documents/com~apple~CloudDocs/Qirsh-Signing/` | APFS → iCloud | **off-machine, different provider** | ✓ match | ✓ / ✓ | `600` |
| 2 | `/Volumes/shared/Qirsh-Signing/` | exFAT (`disk0s6`) | separate **physical** SSD, **same machine** | ✓ match | ✓ / ✓ | see note |

File sha256 (the container, not a secret):
`7b6422f10ea55d752fc9474d03618443e5bbdad2603995797cefdf889fc0441d`, 3,915 bytes.

Both copies were verified twice over: a byte checksum proves the file copied,
and `keytool -list -v` against each copy proves the key inside is still usable
and still the same certificate. A checksum alone would not catch a copy that is
intact but unreadable.

### ⚠️ Backup requirement is NOT yet complete

**Backup #1 (iCloud) is genuinely independent** — it survives loss, theft or
failure of this machine.

**Backup #2 is not.** `disk0` reports `Device Location: Internal`,
`Removable Media: Fixed`. It is a *different physical SSD*, so it survives a
disk failure — but it is inside the same computer. Theft, fire or loss of the
machine takes the original and backup #2 together.

Two further caveats on #2:

- exFAT is mounted `noowners`, so POSIX permissions are **not enforced**. The
  `chmod 600` there is cosmetic; anyone with access to the volume can read it.
- exFAT has no ownership model at all, so it cannot be relied on for
  confidentiality.

**What is still required:** one destination that is physically separate from
this machine — an external USB drive that is *disconnected after copying*, a
second cloud provider, or an encrypted attachment in a password manager. Until
that exists, a single event that destroys the laptop destroys two of three
copies, leaving only iCloud.

The `.jks` is itself a password-protected container, so storing it in iCloud is
acceptable practice — but the store password must live somewhere else entirely.

### Password storage

Passwords are in a password manager, **never** in this repository, never in
`key.properties` backups, and never alongside the keystore. A backup containing
both the key and its password is one compromise, not two.

## Play App Signing

| Item | State |
|---|---|
| Enrolled | **NO** — no Play Console app record yet |
| App signing key holder | Google, once enrolled |
| Upload key | this keystore |

Enrolment happens at app-record creation and is effectively irreversible. Enrol:
it turns a lost upload key from fatal into a reset request.

## LOCAL SIGNING VERIFICATION — CLOSED

`./gradlew signingReport` — **BUILD SUCCESSFUL**. The Release variant resolves
to the production upload key:

| | |
|---|---|
| Store | `/Users/youssef/qirsh-upload-keystore.jks` |
| Alias | **`qirsh-upload`** |
| SHA-1 | `82:C8:9D:D4:9C:98:D5:F0:05:56:E9:DF:7F:A5:63:C7:25:8D:BC:C0` ✓ matches |
| SHA-256 | `87:7C:14:73:0D:29:B0:22:E5:86:44:DA:4A:E6:F5:FA:69:A1:09:8E:59:81:74:70:69:E0:37:77:93:85:87:11` ✓ matches |
| Debug fallback | **NO** — Release uses the upload certificate, not the debug key |

That last row is the point of the exercise. A release silently signed with the
debug key is what got a real Play upload rejected once; the report proves the
Release variant is on the intended certificate.

`app/android/key.properties` — written, mode `600`, **gitignored** (confirmed by
`git check-ignore`, absent from `git status`, untracked). All four keys present
and non-empty. The two non-secret values are exactly
`storeFile=/Users/youssef/qirsh-upload-keystore.jks` and `keyAlias=qirsh-upload`.
The two passwords were never read, hashed, measured or logged.

## Verification status

- [x] File exists, outside the repository
- [x] Permissions `600` — was `644` (world-readable) at creation, tightened
- [x] Alias `qirsh-upload` present, `PrivateKeyEntry`
- [x] RSA 4096, validity to 2054
- [x] SHA-1 and SHA-256 recorded
- [x] `git check-ignore`: `key.properties`, `*.jks`, `*.keystore` all ignored
- [x] 0 keystore-shaped files tracked; 0 `.jks` anywhere in the working tree
- [x] **`app/android/key.properties` written**, mode `600`, gitignored
- [x] **`./gradlew signingReport` resolves the release config to `qirsh-upload`**
- [x] Backup #1 — iCloud Drive, checksum + fingerprint verified
- [~] Backup #2 — `/Volumes/shared`, **supplemental only**; same machine
- [ ] **Second genuinely off-machine backup — STILL PENDING**

## ⚠️ OUTSTANDING before any signed release build

### 1. `ADMOB_APP_ID_ANDROID` is not set

`signingReport` warned that a Release build would carry **Google's sample AdMob
application ID**. Confirmed: the variable is unset in the environment, and
`admobAppIdFor(isRelease = true)` falls back to the sample id when nothing is
supplied.

That fallback is deliberate and safe — it keeps the manifest valid so the SDK
does not crash at process start, while `ReportAdsBuildConfig` reports
"not configured" so no ad is ever requested. **It is not a defect.** But a
signed release shipped in that state serves no ads and declares a sample
publisher, so it must be resolved first.

**Not fixed here, by instruction.** Belongs to the final production
configuration / Codemagic pass — [`../15_Codemagic/README.md`](../15_Codemagic/README.md),
detail in [`../13_AdMob/build_configuration.md`](../13_AdMob/build_configuration.md).

### 2. Java 17 must be resolved explicitly on this machine

There is no system JDK, and `/usr/bin/keytool` is a non-functional stub. Gradle
needs Java 17 named explicitly:

```bash
JAVA_HOME=/usr/local/Cellar/openjdk@17/17.0.20.1 \
PATH="/usr/local/Cellar/openjdk@17/17.0.20.1/bin:$PATH" \
./gradlew signingReport
```

`openjdk@17` is keg-only, so it is not on `PATH` by default. **Shell
configuration has deliberately not been modified globally** — that needs
separate approval. Until then, every Gradle invocation on this machine needs the
prefix above.

## Note: JKS vs PKCS12

`keytool` warns that JKS is a proprietary format and suggests migrating to
PKCS12. **Do not migrate now.** JKS works with Gradle and Play, and converting
rewrites the file — which would invalidate any backup taken beforehand and risks
the key for no release benefit. If you ever convert, do it before backups exist,
and re-verify the fingerprints afterwards: they must be **identical**, since the
certificate is unchanged by a container format change.
