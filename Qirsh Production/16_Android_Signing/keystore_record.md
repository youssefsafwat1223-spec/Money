# Upload Keystore Record

**Status: GENERATED and VERIFIED — 2026-08-31.**

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

## Backups — ⚠️ NOT YET DONE

Two **independent** copies. Two folders on the same disk is one copy.

| # | Location (description — never a live secret) | Encrypted | Test-restored | Date |
|---|---|---|---|---|
| 1 | _to be filled_ | | | |
| 2 | _to be filled_ | | | |

Store the two passwords in a password manager, **separately** from the keystore
file. A backup containing both is a single point of compromise.

**Until both backups exist, this key is a single point of failure.** Before Play
App Signing enrolment it is not yet recoverable by Google.

## Play App Signing

| Item | State |
|---|---|
| Enrolled | **NO** — no Play Console app record yet |
| App signing key holder | Google, once enrolled |
| Upload key | this keystore |

Enrolment happens at app-record creation and is effectively irreversible. Enrol:
it turns a lost upload key from fatal into a reset request.

## Verification status

- [x] File exists, outside the repository
- [x] Permissions `600` — was `644` (world-readable) at creation, tightened
- [x] Alias `qirsh-upload` present, `PrivateKeyEntry`
- [x] RSA 4096, validity to 2054
- [x] SHA-1 and SHA-256 recorded
- [x] `git check-ignore`: `key.properties`, `*.jks`, `*.keystore` all ignored
- [x] 0 keystore-shaped files tracked; 0 `.jks` anywhere in the working tree
- [ ] `app/android/key.properties` written — **owner action**
- [ ] Two independent backups — **owner action**
- [ ] `./gradlew signingReport` resolves the release config

## Note: JKS vs PKCS12

`keytool` warns that JKS is a proprietary format and suggests migrating to
PKCS12. **Do not migrate now.** JKS works with Gradle and Play, and converting
rewrites the file — which would invalidate any backup taken beforehand and risks
the key for no release benefit. If you ever convert, do it before backups exist,
and re-verify the fingerprints afterwards: they must be **identical**, since the
certificate is unchanged by a container format change.
