# V1 External / Owner-Only Blockers

Only genuine owner-or-external actions belong here. Everything else is
engineering work and is tracked on the execution board.

Last reconciled: 2026-09-15.

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
