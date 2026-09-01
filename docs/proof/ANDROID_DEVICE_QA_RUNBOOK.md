# Android physical-device QA runbook — Phases 6/8/9/10

**Status: PREPARED, NOT EXECUTED.** No Android device is attached to this
machine and `adb` is not installed. Nothing in this document has been run, and
no result here may be recorded as PASS without real-device evidence.

## Prerequisites (blocking)

| # | requirement | state |
|---|---|---|
| P1 | a physical Android device (Android 8+; ideally one Android 13+ for the runtime-notification permission and one Android 8–12) | **NOT AVAILABLE** |
| P2 | Android SDK platform-tools (`adb`) on PATH | **NOT INSTALLED** (`brew install --cask android-platform-tools`) |
| P3 | USB debugging enabled, device authorised | pending P1 |
| P4 | a real SIM able to receive bank SMS, **or** `adb emu sms send` on an emulator for the non-SIM cases | pending P1 |
| P5 | a device holding a **real v31 database** for the migration test — a fresh install cannot prove the upgrade | pending P1 |

> P5 matters more than it looks. Installing the new build on a clean device
> tests `CREATE TABLE`, not the 31 → 33 upgrade. The upgrade is the risky path,
> and it is only exercised on a device that already ran the old build with real
> data in it.

## Record for every run

```
device model / Android version / build number
app build (git SHA + flavour)
DB user_version BEFORE and AFTER first launch
timestamp, network state (online/airplane)
```

---

## A. Permissions (Phase 6 / capture)

| # | case | expected |
|---|---|---|
| A1 | fresh install → SMS permission prompt | disclosure shown BEFORE the system dialog, stating what is read and why |
| A2 | grant | capture starts; no crash |
| A3 | deny | app remains fully usable; manual entry unaffected; no repeated nagging |
| A4 | deny twice / "don't ask again" | in-app path routes to system Settings; no silent dead end |
| A5 | revoke `RECEIVE_SMS` while running | capture stops cleanly; no crash; no partial work item |
| A6 | Android 13+ notification permission denied | capture still works; review surfaces in-app instead |

## B. Capture and durability (Phase 8)

| # | case | expected |
|---|---|---|
| B1 | bank SMS while app FOREGROUND | work item created; `capture_uuid` primary key |
| B2 | same, app BACKGROUND | identical outcome |
| B3 | same, process KILLED (swipe away) | captured on next launch; no loss |
| B4 | **multipart SMS** (>160 chars, concatenated) | reassembled into ONE work item, not one per part |
| B5 | native→Drift handoff | Drift row COMMITTED before native ACK |
| B6 | **force-kill between commit and ACK** (`adb shell am force-stop` immediately after capture) | on relaunch the re-presented item RESOLVES the existing row — **exactly one work item, no duplicate transaction** |
| B7 | same SMS delivered twice | two work items only if two distinct capture UUIDs; identical fingerprint does **not** merge them |
| B8 | airplane mode capture | `offlinePending`; recovers on reconnect without duplicating |

> B6 is the single most important test in this document. It is the crash
> boundary the whole Phase-8 ordering contract exists to protect, and it cannot
> be verified anywhere but on a real device.

## C. Notifications (Phase 9)

| # | case | expected |
|---|---|---|
| C1 | pending notification appears | one row |
| C2 | resolves to proven/review | the SAME row updates — **does not stack** |
| C3 | **lock the device**, trigger capture | body shows **no amount, no merchant, no bank, no SMS text** |
| C4 | expand on lock screen | still no financial detail |
| C5 | tap action → app | routes through the domain layer; no direct DB write |
| C6 | **stale action**: leave notification, edit the transaction in-app, then tap the old notification | the edit WINS; the stale action does not overwrite it |
| C7 | tap twice quickly | idempotent; no duplicate transaction |
| C8 | transient states (pendingAi / offlinePending / retryableFailure) | **not** notified |

## D. Schema v33 (Phase 8 + Phase 9A)

| # | case | expected |
|---|---|---|
| D1 | launch new build on a device with a **real v31 DB** (P5) | both steps run once; `user_version` 31 → 33 |
| D2 | verify data intact | transactions, accounts, budgets all present and correct |
| D3 | restart after migration | no re-migration; `user_version` stays 32 |
| D4 | kill DURING first launch migration | rolls back atomically; app opens on 31; retries cleanly next launch |
| D5 | `capture_work_items` exists | table + indexes present |

## E. Privacy (Phase 6)

| # | case | expected |
|---|---|---|
| E1 | SMS containing a full PAN | `[CARD]` in anything transmitted/logged |
| E2 | SMS containing an IBAN | `[IBAN]` — the defect fixed this phase |
| E3 | SMS containing an OTP | `[OTP]`, cue-anchored |
| E4 | SMS where the amount looks like an OTP (`Purchase SAR 1234.00`) | amount **survives** |
| E5 | wipe / sign-out | `capture_work_items` emptied |
| E6 | backup + restore | work items **not** restored (excluded by design); transactions restored |

## F. Regression — unaffected paths

| # | case | expected |
|---|---|---|
| F1 | manual transaction entry | unchanged |
| F2 | share-sheet capture | unchanged |
| F3 | CSV/statement import | unchanged |
| F4 | shadow arm OFF (default) | **zero** proof-v1 requests in logs |

## Commands

```bash
brew install --cask android-platform-tools     # P2
adb devices                                    # confirm authorised

flutter run -d <device-id>                     # debug install
adb shell am force-stop com.youssefsafwat.mali # B6 / D4
adb logcat | grep -i "qirsh\|mali\|capture"    # observe

# schema check (debug builds only)
adb shell run-as com.youssefsafwat.mali \
  sqlite3 databases/<db> 'PRAGMA user_version;'
```

## Exit criteria

Every case A1–F4 recorded with device/OS/build and an actual observation.
**Any unexecuted case is UNKNOWN, never PASS.** B6, C3, C6 and D1 are
individually blocking for Phase 11.
