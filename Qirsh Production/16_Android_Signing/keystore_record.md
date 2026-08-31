# Upload Keystore Record

**Status: NOT YET GENERATED.** Fill this in immediately after generation.

⛔ **No password, passphrase or base64 blob ever goes in this file.**
Fingerprints, alias, dates and validity are public certificate properties and
are safe to record. Passwords are not.

## Identity

| Field | Value |
|---|---|
| Purpose | **Upload key** (Google holds the app signing key via Play App Signing) |
| Package | `com.youssefsafwat.mali` |
| Keystore filename | _to be filled_ |
| Alias | _to be filled_ |
| Key algorithm / size | _to be filled — expect RSA 4096_ |
| Created (UTC) | _to be filled_ |
| Valid until | _to be filled_ |
| Store type | _to be filled — expect JKS_ |

## Fingerprints

Obtain with (does not print any password):

```bash
keytool -list -v -keystore <PATH> -alias <ALIAS>
```

| Algorithm | Fingerprint |
|---|---|
| SHA-1 | _to be filled_ |
| SHA-256 | _to be filled_ |

SHA-1 is what Play Console shows for the upload certificate; SHA-256 is what
you compare against after any key reset. Record both.

## Backup locations

Two **independent** copies — different media or providers. Two folders on the
same disk is one copy.

| # | Location (description, not a path to a live secret) | Encrypted | Verified restorable | Date |
|---|---|---|---|---|
| 1 | _to be filled_ | | | |
| 2 | _to be filled_ | | | |

Passwords are stored **separately** from the keystore file, in a password
manager. A backup that contains both is a single point of compromise.

## Play App Signing

| Item | State |
|---|---|
| Enrolled | **NO** — no Play Console app record exists yet |
| App signing key holder | Google (once enrolled) |
| Upload key | this keystore |

Enrolment happens when the app record is created and is effectively
irreversible. Enrol — it makes a lost upload key recoverable instead of fatal.

## Verification after generation

- [ ] `keytool -list -v` succeeds and matches the values above
- [ ] `app/android/key.properties` written and **not** shown by `git status`
- [ ] `./gradlew signingReport` (from `app/android`) resolves the release config
- [ ] both backups exist and at least one has been test-restored
- [ ] passwords stored in a password manager, separately from the file
