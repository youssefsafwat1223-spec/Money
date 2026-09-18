# V1 Real-Device / Cloud-Device QA — 2026-09-18

What can be executed from this machine today, what cannot, and exactly why.

**Nothing in this document is a claim of physical-device coverage.** Where a run
did not happen, it says so.

---

## 0. Environment, measured

| Check | Command | Result |
|---|---|---|
| BrowserStack credentials | `ls ~/.browserstack*`, `env \| grep -i browserstack` | **none** — no config file, no environment variable |
| Google Cloud CLI | `which gcloud` | **not installed** |
| Firebase CLI | `which firebase` | **not installed** |
| Apple code-signing identity | `security find-identity -v -p codesigning` | **0 valid identities** |

All three services are therefore **owner-blocked**, for three different reasons.
They are not one blocker and should not be reported as one.

---

## 1. Firebase Test Lab

| | |
|---|---|
| Android artifact | APK or AAB, plus an instrumentation APK for Espresso/Robo |
| iOS artifact | `.zip` of a **signed** `.xctestrun` build produced by `xcodebuild build-for-testing` |
| Auth | a Google account with a Firebase project and Blaze billing for anything beyond the free daily quota |
| Automatable from here | **no** — the CLI is absent and no Google account is authenticated |

**Android status: BLOCKED — no authenticated Google account.**
The APK itself is buildable from this tree; the blocker is purely the account.

**iOS status: BLOCKED — EB-004.** Test Lab's iOS path requires a *signed*
test build. With 0 signing identities there is nothing to upload. This is the
same boundary as the App Store submission, not an additional one.

**Owner action, minimal:** install the CLI (`brew install --cask google-cloud-sdk`),
`gcloud auth login`, `gcloud config set project <firebase-project>`, then the
Android run is one command against an APK this tree already builds.

## 2. BrowserStack App Automate

| | |
|---|---|
| Android artifact | APK, uploaded to `/app-automate/upload` |
| iOS artifact | **resigned IPA** — BrowserStack resigns, but needs a real IPA to start from |
| Auth | `BROWSERSTACK_USERNAME` + `BROWSERSTACK_ACCESS_KEY` |
| Automatable from here | **no** — no credentials present |

**Android status: BLOCKED — no credentials.**
**iOS status: BLOCKED — EB-004 (no IPA) *and* no credentials.** Two independent
blockers; clearing one does not clear the other.

A note on framework choice, since the brief asked: this app's existing device
coverage is `integration_test` driven through `flutter drive`, and that is what
the harnesses in `integration_test/` already are. Appium/XCUITest would mean
rewriting those journeys in a second framework. The right move when credentials
exist is to reuse the existing suites, not to introduce a parallel stack days
before a release.

## 3. BrowserStack App Live

Interactive, browser-driven, manual. **Not automatable by design** — it is a
human driving a real handset through a web session.

**Status: OWNER-MANUAL**, and blocked before that by the same missing
credentials and, for iOS, the same missing IPA.

---

## 4. What that leaves, and what was actually done

Physical-device evidence available from this machine: **none**, and none is
claimed.

What this programme does have, and what it is worth:

| Evidence | Reality |
|---|---|
| iOS Simulator, same-install process restarts | Real OS, real keychain, real SQLCipher, real `local_auth` pigeon channel — but a simulator, not a handset |
| The native iOS passcode sheet, photographed in both languages | A real OS-drawn view; the Simulator's, not a device's |
| 4,000+ unit/widget tests | Logic and composition; says nothing about a handset |

The gap physical devices would close — real biometrics, real SMS delivery,
real APNs, thermal/memory pressure, manufacturer skins — is **untested**, and is
recorded as untested in `V1_RELEASE_READINESS.md`.

## 5. Ordered owner actions

1. **EB-004 — Apple signing.** Unblocks: iOS Test Lab, App Automate iOS, App
   Live iOS, and the App Store archive itself. One action, four unblocks.
2. **BrowserStack credentials** in the environment. Unblocks Android App
   Automate immediately.
3. **Google Cloud SDK + `gcloud auth login`.** Unblocks Android Test Lab.

2 and 3 are independent of 1 and of each other, and either can proceed today.
