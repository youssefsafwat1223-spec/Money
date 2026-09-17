# V1 External / Owner-Only Blockers

Only genuine owner-or-external actions belong here. Everything else is
engineering work and is tracked on the execution board.

Last reconciled: 2026-09-16. Boundary re-validated 2026-09-17 after the
localization, Android, persistence and review work — see the re-validation
block below.

---

## STATUS: every engineering blocker is closed

**Two owner credentials remain. Nothing else stands between this repository and
a submittable build.**

Everything up to that boundary is done and verified:

| | |
|---|---|
| Version | `1.0.0+40`, matching in pubspec, the lockstep constant and the built artifact |
| Unsigned release build | Succeeds — validates the whole archive except the signature |
| `ios/ExportOptions.plist` | Written, lints clean, app-store-connect / team 5TWARK8A23 / automatic signing |
| Pre-archive preflight | `app/tool/preflight_archive.sh` — **PASS** |
| Edge Functions | The four fixed functions are **deployed** to `rjwphwsefnuotpbtuycf` and verified byte-identical |
| Privacy | Redaction proven **on the wire** against the deployed backend, all ten PII classes |
| Store metadata | Privacy labels, age rating, export compliance and reviewer notes written and ready to paste |
| Screenshots | 13 at 1320×2868, regenerable by one command |
| Tests | **4,003 Dart** · 355 Deno · 18 Swift · live wire probe — all green |

The only actions left are **EB-004** and **EB-005** below. Both are
authentication in the owner's identity; neither has an engineering substitute.

---

## Boundary re-validation — 2026-09-17

58 commits landed after the last reconcile, touching ~50 files under `lib/`.
Everything up to the signing boundary was re-run so the owner does not add a
certificate and then discover the build is broken.

| Check | Result |
|---|---|
| `flutter analyze` — `lib/`, `test/`, `integration_test/` | clean (the earlier gate covered `lib/` only) |
| Dart suite | **4,003 pass** |
| Unsigned release build, production defines | **✓ Built** `Runner.app` (60.5 MB) |
| `tool/preflight_archive.sh` | **PREFLIGHT PASS — safe to archive** |
| Version | `1.0.0+40`, matching pubspec, `kPubspecVersion` and the artifact |
| Bundle id | `com.youssefsafwat.mali` |
| `ios/ExportOptions.plist` | lints clean; app-store-connect / team `5TWARK8A23` / automatic |
| QA credentials in the artifact | none — `QA_EMAIL`, `QA_PASSWORD`, `QA_USER_ID`, `service_role`, owner email all absent |
| Zero-contact refs | absent (all three) |
| Production ref present | yes |
| ATS enforced / no ATT string | OK |

**The production defines file is `~/.qirsh-qa/demo_app_defines.json`** — it
carries only `SUPABASE_URL` (production ref) and `SUPABASE_ANON_KEY`, with no
QA credentials. `qa_run_defines.json` carries QA credentials and **must not**
be used for a release build; the preflight's `QA_EMAIL`-in-binary check exists
to catch exactly that mistake. The name "demo_app_defines" is misleading for a
production file and is worth renaming when convenient.

Building **without** `--dart-define-from-file` fails the preflight on two
lines (`SUPABASE_URL + ANON_KEY present`, `production project ref present`),
correctly: a release with no Supabase config fails closed at runtime. The
archive command in EB-004 below already includes the flag.

### Did the new English localization reach the release artifact?

Yes, and to the same degree Arabic does. Measured against the AOT binary,
searching both UTF-8 and UTF-16 (Dart stores non-ASCII strings as two-byte,
which is why a UTF-8-only search reports Arabic as 0% and is simply wrong):

| | Present in the release binary |
|---|---|
| Arabic ARB values | 1,012 / 1,175 (86%) |
| English ARB values | 1,030 / 1,201 (85%) |

Of the absences, **156 are missing in BOTH languages** — language-neutral
tree-shaking of getters unreachable from the release entry point. Only 21 are
asymmetric, split in both directions (15 English-only, 6 Arabic-only), which is
AOT string-pool storage rather than a localization gap.

**There is no English-specific gap in the release artifact.**

---

## EB-004 — Distribution signing identity  🔴 **BLOCKING, OWNER-ONLY**

**What.** No code-signing identity and no provisioning profile exist on this
machine.

```
$ security find-identity -v -p codesigning
     0 valid identities found
$ ls ~/Library/MobileDevice/Provisioning\ Profiles/
(empty)
```

**Effect.** No archive can be signed, so no `.ipa` can be produced or validated.
This is the single blocking item between the current state and a submittable
build.

**Why it is owner-only.** A distribution certificate is issued to the owner's
Apple Developer account and its private key is the owner's credential. Nothing
an agent can generate substitutes for it.

**Exact owner action.**

1. Open Xcode → Settings → Accounts → add the Apple ID enrolled in the Apple
   Developer Program (team **5TWARK8A23**).
2. Select the team, then **Manage Certificates…** → **+** → **Apple
   Distribution**. Xcode creates the certificate and stores its private key in
   the login keychain.
3. Confirm:
   ```
   security find-identity -v -p codesigning     # expect >= 1 valid identity
   ```
4. Then, from `app/`:
   ```
   flutter build ipa --release \
     --export-options-plist=ios/ExportOptions.plist \
     --dart-define-from-file=<the production defines file>
   ```
   `ios/ExportOptions.plist` is already written, lints clean, and is set to
   `app-store-connect` / team `5TWARK8A23` / automatic signing / upload symbols.
   Automatic signing will create the three profiles needed (app, share
   extension, shortcuts extension) on first run.

**Everything up to this boundary is done.** The unsigned release build succeeds
at 1.0.0 (40) with the correct bundle identifier, which validates every part of
the archive except the signature itself.

---

## EB-005 — App Store Connect authentication  🔴 **BLOCKING, OWNER-ONLY**

**What.** No App Store Connect session and no App Store Connect API key are
available to this environment.

**Effect.** The app record, metadata, privacy labels, age rating, export
compliance answers, screenshots and reviewer notes cannot be entered or
uploaded, and no build can be submitted.

**Why it is owner-only.** It is authentication in the owner's identity, and the
privacy-label and export-compliance answers are legal declarations the owner
makes, not an agent.

**Exact owner action.** Either:

* **Manual** — sign in to App Store Connect, create the app record for
  `com.youssefsafwat.mali`, and paste from `V1_APP_STORE_SUBMISSION.md`, which
  holds the complete privacy-label table (§1), advertising disclosure (§2), age
  rating answers (§3), export compliance (§4) and reviewer notes (§5); or
* **API key** — App Store Connect → Users and Access → Integrations → App Store
  Connect API → generate a key with **App Manager** role, and place the `.p8`
  plus its Key ID and Issuer ID where the build can read them. That would let
  upload and metadata be automated on a later run. **Do not paste the `.p8`
  contents into a chat.**

**One decision only the owner can make:** which account Apple's reviewer signs in
with. The reviewer notes are written assuming credentials are supplied in the
App Review Information fields.

---

## EB-006 — Physical iPhone  🟡 NON-BLOCKING (charter-accepted)

Unchanged from EB-002 below. Production APNs delivery, real SIM SMS receipt and
background capture on a killed app are hardware-only and are never claimed from
Simulator evidence.

---

## EB-001 — Xcode 27.0 licence not accepted  ✅ RESOLVED 2026-09-15

**What.** The machine's Xcode was upgraded to **27.0** (build 27A266a). Its
licence has not been accepted. The last accepted version recorded by
`com.apple.dt.Xcode IDEXcodeVersionForAgreedToGMLicense` is **26.6**.

**Effect.** Every `xcrun` / `xcodebuild` invocation that resolves through
`/Applications/Xcode.app` fails with the licence error. That blocks, with no
workaround available to an agent:

| Capability | State |
|---|---|
| iOS Simulator (`xcrun simctl`) | **BLOCKED** — CommandLineTools ships no Simulator |
| iOS device/simulator builds | **BLOCKED** |
| `integration_test` on Simulator | **BLOCKED** |
| Release archive / IPA | **BLOCKED** |
| Screenshot capture from real UI | **BLOCKED** |
| Dart analyze / unit / widget tests | **WORKING** via the workaround below |
| git | **WORKING** via the workaround below |

**Why it is owner-only.** `xcodebuild -license` requires **root** (`sudo`) *and*
is the acceptance of a legal agreement in the owner's identity. This charter
names both as owner-only.

**Risk if unresolved.** No Simulator QA, no visual acceptance, no release
archive, no App Store submission. The V1 release candidate **cannot be
completed** without it. Every other workstream continues meanwhile.

**Exact owner action.**
```
sudo xcodebuild -license accept
```
(or `sudo xcodebuild -license` and page to the end to accept). Then confirm:
```
xcrun simctl list runtimes    # must list an iOS runtime, not the licence error
```

**Resolved.** The owner accepted the licence. Verified: `xcrun simctl` lists the
iOS 26.5 runtime and the iPhone 17 family; `flutter build ios --simulator
--debug` produces `Runner.app`; it installs, launches and screenshots. The
`DEVELOPER_DIR`/shim workaround has been retired from `~/.qirsh-qa/env.sh` —
keeping it would have hidden the Simulator, which CommandLineTools does not
ship. Only the two account-rename settings (`PUB_CACHE`, `TMPDIR`) remain.

---

## EB-002 — Physical iPhone unavailable  🟡 NON-BLOCKING (charter-accepted)

Charter directs the Simulator as the primary lab and forbids blocking on the
device. Genuinely hardware-only proof (production APNs delivery, real SIM SMS
receipt, real background/killed-app capture) is recorded as hardware-dependent
and is **not** claimed from Simulator evidence.

---

## EB-003 — Google Play  🟢 DEFERRED BY OWNER

Publication postponed for budget reasons. Not a V1 blocker. Android source and
build compatibility are kept healthy; no Play submission work is performed.

---

## Machine-configuration defects repaired by engineering (NOT owner-blocking)

These were discovered during Phase 1 and fixed locally. They are recorded so the
owner can make them permanent; none blocks the release.

| # | Defect | Evidence | Local repair |
|---|---|---|---|
| 1 | `PUB_CACHE` points at a dead volume | `~/.zshrc:10` → `/Volumes/shared/flutter-cache/pub-cache`; `/Volumes/shared` absent | `PUB_CACHE=$HOME/.pub-cache` |
| 2 | `TMPDIR` points at the machine's **old home** | inherited `/Users/youssef/tmp-flutter`; `/Users/youssef` does not exist (account renamed to `luciq`) | `TMPDIR=$HOME/tmp-flutter` |
| 3 | Flutter does not propagate `DEVELOPER_DIR` to native-asset build hooks | `objective_c-9.4.1/hook/build.dart:192` `Iterable.first` on empty `xcrun` output | `xcrun` shim at `~/.qirsh-qa/shim/xcrun` |
| 4 | `intl` pinned below what the SDK requires | Flutter 3.47.3's `flutter_localizations` needs `intl ^0.20.3`; pubspec pinned `0.20.2` | pubspec bumped to `^0.20.3` |

Owner may make 1 and 2 permanent by correcting `~/.zshrc`. 3 disappears once
EB-001 is resolved. 4 is a committed repository fix.


---

## Explicitly NOT owner blockers

Recorded here because they were previously written up in a way that read like
release blockers. They are post-V1 hardening; the reasoning is in
`V1_SECURITY_CLASSIFICATION.md`.

| Item | Why it is not a blocker |
|---|---|
| Certificate pinning | Apple does not require it and warns against deploying it unnecessarily. ATS is enforced with **zero** exceptions, there is no cleartext anywhere, capture text is redacted before it leaves, and the financial ledger does not cross the network at all in V1 |
| Jailbreak / debugger detection | Not an App Store requirement and no Apple API exists for it. Every implementation is heuristic and locks legitimate users out. The data it would defend is the device owner's own |
| App Attest / DeviceCheck | The principled fix for `register-device`'s root cause, but the exploitable path is already closed and rate limits bound the rest |
| WCAG contrast "10/10 routes" | A false-positive-dominated automated result. Measured directly: white on the navy headers is **13.36:1**, body text **17.74:1**. The two genuine defects (`textMuted` in both themes) are fixed and locked by `test/core/theme/contrast_test.dart` |
