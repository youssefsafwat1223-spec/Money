# Qirsh — Android emulator QA

**2026-09-03.** Emulator evidence. **This is not physical-device evidence**, and
nothing here closes RB-5. The physical-device-only remainder is §5.

---

## 1. Environment

| | |
|---|---|
| AVD | `qirsh_qa`, Pixel-class default profile |
| System image | `system-images;android-33;google_apis;x86_64` |
| Android | **13 (API 33)**, `sdk_gphone64_x86_64` |
| Host | Intel Core i7-9750H, macOS 26.5.1, HVF acceleration |
| Mode | headless, `-gpu off -no-audio -no-boot-anim -no-snapshot`, 2.5–3 GB RAM |
| Build under test | `app-debug.apk`, **201 MB**, version **0.1.3+39** |
| AdMob app id in the artifact | `ca-app-pub-3940256099942544~…` — Google **TEST** publisher |

A physical **Xiaomi 2201117TG (Redmi Note 11S), Android 13, ar-EG, dual live
Orange EG SIM** was profiled earlier and is the right target for §5; it was
unavailable for this run.

---

## 2. The defect this QA existed to catch

**The Android app did not compile.** `OfferIntentStore.kt` and
`SharedContentRouter.kt` declared `package com.example.money_companion` — the
directory name — while every other Kotlin file and the `applicationId` use
`com.youssefsafwat.mali`. `MainActivity` could not resolve either class.

It had been broken since `564f1327` and **passed 12/12 canonical CI gates, 3537
Flutter tests, Deno, Node, admin, migration lint and every architecture guard**,
because nothing in this repository compiles the Android app.

Fixed in `7161ad04`, plus `android_source_integrity_test.dart` — a ~1s static
guard asserting one package across all Kotlin sources, that it equals the
`applicationId`, that every class `MainActivity` names resolves, and that every
`android:name=".Foo"` in the manifest has a source. Proven non-vacuous:
reintroducing the bug produces 3 failures.

**Build now verified: `✓ Built app-debug.apk` (exit 0).**

---

## 3. Results

Every negative below was made non-vacuous: SMS arrival was independently
confirmed in the **radio** log buffer (`GsmInboundSmsHandler … EVENT_NEW_SMS` /
`EVENT_BROADCAST_SMS`) before asserting "not captured".

| # | Test | Result | Evidence |
|---|---|---|---|
| 1 | Clean install | **PASS** | `pm install` Success; package present |
| 2 | Cold start | **PASS** | full bootstrap chain to `done — session=needsOnboarding` |
| 3 | Fresh DB create (SQLCipher + Drift) | **PASS** | `database_open` ok; `money_companion.sqlite` created |
| 4 | Catalog seed incl. new merchant tables | **PASS** | `seeded merchant_aliases (0)` — the 2026-09-02 metadata fix running on-device |
| 5 | `RECEIVE_SMS` default state | **PASS** | `granted=false` on clean install |
| 6 | Auto-capture opt-in default | **PASS** | no `mali_capture_settings_v1.xml` → false |
| 7 | SMS with permission **denied** | **PASS** | delivered, **not captured** |
| 8 | SMS with permission granted, **opt-in off** | **PASS** | delivered, **not captured** — permission is not consent |
| 9 | SMS with **both keys on**, app **not running** | **PASS** | `Start proc … for broadcast {…/.SmsCaptureReceiver}` → captured |
| 10 | Capture payload correctness | **PASS** | text, `sender:"4455"`, `source:"sms"`, **SMS timestamp** (not device time), UUID |
| 11 | Non-financial SMS (chat) | **PASS** | dropped |
| 12 | OTP / verification code | **PASS** | dropped |
| 13 | Spam with link | **PASS** | dropped |
| 14 | **Multipart** SMS (231 chars) | **PASS** | **one** entry, text reassembled in order |
| 15 | Durable queue survives full device restart | **PASS** | 3 capture + 2 offer items and both keys persisted |
| 16 | **Force Stop** suppression | **PASS** | `stopped=true` withheld a delivered SMS; launching cleared to `stopped=false` |
| 17 | Share-to-Qirsh, bank text | **PASS** | capture queue +1 |
| 18 | **Merchant URL never enters the financial queue** | **PASS** | offer store +1, capture queue **unchanged** |
| 19 | Offer URL sanitization | **PASS** | `?utm_source=…&sid=…#frag` stripped; `www.` folded to `noon.com` |
| 20 | Offline (airplane mode) | **PASS** | app launches and bootstraps; no crash |
| 21 | AdMob test-unit safety | **PASS** | TEST app id in the artifact — a QA build cannot serve production ads |
| 22 | Permission minimalism | **PASS** | only `RECEIVE_SMS`; `READ_SMS`/`SEND_SMS`/`WRITE_SMS`/`RECEIVE_MMS`/`RECEIVE_WAP_PUSH`/`READ_PHONE_STATE` all **absent** |
| 23 | Native → Drift handoff | **BLOCKED** | drain handler registers in `app_shell.dart:187`; AppShell only mounts when authenticated. Needs real Google/Apple sign-in |
| 24 | Arabic RTL on emulator | **NOT RUN** | `setprop persist.sys.locale` repeatedly crashed `system_server`. Covered by widget tests that pump `ar`; the physical device is natively ar-EG |
| 25 | v33→v34→v35 upgrade on-device | **NOT RUN** | needs seeded pre-upgrade databases; fresh-create path verified (#3) |
| 26 | Backup / restore / wipe | **BLOCKED** | authenticated-only, same as #23 |

**Also found: `ACCESS_ADSERVICES_AD_ID`** is auto-merged into the artifact by the
AdMob SDK. It must be reflected in the Play Data Safety declaration.

---

## 4. One observed SMS loss — reviewed, no change

Android discarded **1 of 10** inbound SMS broadcasts:

```
W BroadcastQueue: Receiver during timeout of BroadcastRecord{… SMS_RECEIVED} : …SmsCaptureReceiver
I am_broadcast_discard_app: […SMS_RECEIVED, 1, …SmsCaptureReceiver…]
```

Emulator state: **1.89 GB used of 2.01 GB (119 MB free)**. The app process was
being lowmemory-killed between messages, so each SMS required a cold process
start, and one exhausted the ~10s broadcast budget before `onReceive` ran.

Both reviewers independently returned **B — change nothing**, with the same
mechanism: `goAsync()` defers `finishReceiver()` but does **not** reset or extend
that same deadline, and the loss happened during process start, before receiver
code executed. `onReceive` is already a prefs read, string work and one durable
`commit()`; adding `goAsync()` would introduce a leaked-`PendingResult` ANR class
to protect against a failure mode the receiver does not have.

Recorded as a **real-device risk to watch on low-RAM hardware**, not a defect.
The levers that would actually address it are release-build cold-start cost and —
only if field telemetry ever justified the Play-policy cost — `READ_SMS` inbox
reconciliation, which is deliberately not declared.

---

## 5. PHYSICAL-DEVICE-ONLY — cannot be closed on an emulator

RB-5 stays **OPEN** until these are done on real hardware.

1. **Real carrier/bank SMS** in the actual formats of Saudi/Egyptian banks —
   emulator injection uses text I authored, which cannot validate real templates.
2. **OEM lifecycle.** Xiaomi MIUI has its own autostart permission and
   aggressive background-process killing; a manifest receiver's real-world
   survival is an OEM question an AOSP emulator cannot answer.
3. **Doze / app-standby** buckets over hours.
4. **Real APNs/FCM** push delivery.
5. **Dual-SIM** routing (the physical device has two live SIMs).
6. **Permission revocation via the real Settings app** while running.
7. **Lock-screen notification rendering** and the privacy-safe content rule.
8. **AdMob banner/interstitial rendering** with production units, including the
   platform-view-over-sheet bleed check.
9. **Performance and jank** on real hardware — the emulator is software-rendered
   and tells you nothing here.
10. **Cold-start timing** for the release build, which is what determines whether
    §4's broadcast-window risk is real in the field.
11. **v33→v34→v35 migration on a populated real database.**
12. Everything gated behind authentication: native→Drift handoff, Smart Inbox,
    backup/restore, deletion/wipe.

---

## 6. Emulator stability note

The emulator's `system_server` crashed three times during this run, and
`setprop persist.sys.locale` reliably killed it. That is an artifact of a
software-rendered, memory-constrained AOSP image running a 201 MB debug APK —
not a Qirsh signal. It is recorded so a future session does not mistake it for
one.
