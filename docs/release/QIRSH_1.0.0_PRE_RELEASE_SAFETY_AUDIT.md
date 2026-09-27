# Qirsh 1.0.0 — Pre-Release Safety Audit

This is a **release record**, not an audit. It states what was reviewed, what was
found, what was fixed, and what has not yet been verified. The evidence is
reproduced exactly as reported by the completed audit pass; nothing here is a new
claim.

## Release candidate

| | |
|---|---|
| Version | 1.0.0 |
| Build AUDITED | 41 |
| Current release-candidate build | **42** |
| Release branch | `release/ios-1.0.0-build41` |
| Date | 2026-09-27 |
| **Audited code HEAD** | `b744e2de1afd724ed713c45bb0622d0c594f5aaa` (`b744e2de`) |
| **Release-candidate code HEAD** | `3c45079688f61235dd73167d4c61456774d15de0` (`3c450796`) |
| Release record commit (first) | `351c2ad92d7e0658cd1aff3532dff28399ac2c61` |

`b744e2de` is the **production-code snapshot the 15-part audit was performed
against**, and it is the scope of every status in this record. It does not contain
this document, and it does not contain the post-audit changes.

The release candidate has since moved on: see
[Post-audit release changes](#post-audit-release-changes) for the ITMS-90683 fix
and the build bump to 42. **The audit was not re-run against the current HEAD**,
and these two values must never be conflated when reproducing the evidence — a
documentation correction or a post-audit fix advances the candidate HEAD and
leaves the audited HEAD exactly where it is.

## Executive summary

- **15 audit areas reviewed** (16 including Audit 3A).
- **No outstanding P0.** One P0 existed and was fixed before this pass; it is
  now regression-locked by three independent suites.
- **No P1.**
- **One P2**, a defence-in-depth finding. Not reachable as a user-facing bug
  today. Deliberately **not** fixed in this release — see
  [Tracked hardening / future risk](#tracked-hardening--future-risk).
- **Audits 11 and 14 are PARTIAL.** Their static halves pass. Their live
  validation remains **BLOCKED** on credentials for an authorized validation
  project. They are **not** fully passed and must not be recorded as such.
- **No production data was modified** at any point during the audit.
- **No TestFlight upload was performed** during the audit. No feature flags were
  changed. No production Supabase policies were altered.

## Previously fixed critical defects

These three landed before the audit pass and are recorded here because the audit
exists largely to prove they are closed and to stop them recurring.

Two were **genuine reachable defects** — `ac622970` (which caused real user data
loss) and `e542b450` (the lifecycle window that made it destructive). The third,
`5efdf846`, was **invariant hardening, not a reachable bug**; it is grouped here
because it guards the same class of outcome, and its entry says so explicitly.

### `ac622970` — ownership transition: purge before wipe

**The destructive loop.** The iOS Keychain survives app deletion; the Drift
database does not. After a reinstall the Keychain still held
`local_data_owner_uid` for the previous session while the database was new, so
bootstrap saw an ownership mismatch and ran a transition.

That transition **wiped first**, then called a native method channel to purge
App Group residue. Under the UIScene lifecycle the channel was not yet
registered, so the call raised `MissingPluginException`. The code treated that as
a failed purge and returned **without clearing or claiming the owner marker** —
so the next launch saw the identical mismatch and wiped again.

The result was permanent: every launch destroyed the user's financial data, with
no crash and no error screen. It explained every reported symptom — amounts
reset to zero on each open, settings appearing to survive, the user still signed
in, and the welcome notification re-firing every launch. Fresh installs took a
different branch, which is why QA never saw it.

The fix reorders the sequence to **invalidate → purge → (if purge fails, STOP:
do not wipe, do not claim) → wipe → claim**, so data is never destroyed by a
transition that cannot finish recording itself.

### `5efdf846` — DB key-store invariant hardening (defence in depth)

**This was not a reachable production defect, and no user data was lost through
it.** It is recorded here as invariant hardening, alongside the two genuine
fixes, because it concerns the same class of catastrophic outcome.

**Why the outcome would be catastrophic.** Minting a replacement encryption key
for an existing encrypted database is unrecoverable. It does not fail loudly: the
database opens onto nothing, and the only key that could have decrypted the real
data has been overwritten. "Could not read the key" is **not** "no key exists",
and any code that collapses the two converts a transient Keychain failure into
permanent data loss.

**What the shipped app actually did.** The audit confirmed the
`AppDatabase.open` path was **already fail-closed** before this commit:

- Keychain read exceptions **propagated** — they were never caught and never
  treated as absence;
- the existing-database-plus-missing-key state **already raised**
  `LocalDatabaseKeyUnavailableException` via `_resolveKeyStateOrThrow`;
- **no existing user was proven to have lost data through this key path.**

**What `5efdf846` hardened.** Four structural weaknesses, none of them
individually reachable in the shipped flow:

- the safety invariant lived in the **caller** rather than inside
  `readOrCreateKey` itself, so it held only for callers that remembered to
  classify the key state first;
- a **new direct call site, or a reordered startup flow**, could therefore have
  bypassed it without touching the guard or failing any test;
- **concurrent callers could race** key creation;
- the `absent` / `readError` / `invalid` states were **not represented
  distinctly** enough for a caller to tell an unreadable key from a missing one.

The fix moves the invariant to where the key is minted: read outcomes are
explicitly typed (`found` / `absent` / `readError` / `invalid`), the
database-existence probe is a **required constructor parameter** so no call site
can skip it, and minting is single-flight. The guarantee now holds wherever the
store is used rather than only on the path that remembered to check.

### `e542b450` — UIScene / native channel registration + per-controller rebind

Registration happened only from `applicationDidBecomeActive` /
`sceneDidBecomeActive`, both of which fire after the engine is already running
Dart — the window that made `ac622970` destructive.
`didFinishLaunchingWithOptions` cannot do it either: under UIScene it runs before
any scene connects, so `rootFlutterViewController()` is nil and the call is a
silent no-op. Registration moved to `scene(_:willConnectTo:)`, the earliest
deterministic point. The companion fix makes idempotency mean *"already
registered against the current Flutter engine/controller"* rather than *"a
channel object exists somewhere"*, so a scene reconnect rebinds instead of
stranding the app on a dead messenger.

## Audit status table

| Audit | Status | Evidence | Commit | Remaining verification |
|---|---|---|---|---|
| 1 — All destructive operations | PROVEN SAFE | 18 destructive sites enumerated and classified by why each is safe; exact counts so a new statement in an audited file also fails | `b744e2de` | — |
| 2 — Install / reinstall / Keychain / restore matrix | PROVEN SAFE | 10 tests; convergence proven from every starting combination of the four independently-lived stores | `3ae9ebb7` | Physical-device reinstall pass |
| 3 — UIScene / Flutter native channel lifecycle | BUG FOUND + FIXED + TESTED | Registration moved to `scene(_:willConnectTo:)`; 12 architecture tests | `e542b450` | Scene-connect timing on physical iPhone |
| 3A — Scene reconnect / stale messenger safety | BUG FOUND + FIXED + TESTED | Per-controller identity rebind; weak controller reference; old handler cleared before rebind | `e542b450` | Scene reconnect, if reproducible on device |
| 4 — App Group + share extension concurrency | PROVEN SAFE | All 11 queue mutations under `flock(LOCK_EX)` on an App Group file — a genuine cross-process lock | `599c3b2b` | Live flock contention with the extension running |
| 5 — SQLite engine / WAL safety | PROVEN SAFE | Runtime engine measured at 3.53.2, past the 3.51.3 WAL-reset fix; guard pins it | `a05f029b` | — |
| 6 — Drift migrations: every supported version | PROVEN SAFE | 14 tests; populated money carried through 31–37 and the pre-31 compatibility path; crash-replay; static no-destructive-step guard | `965ea77a` | — |
| 7 — Crash injection / transaction ordering | BUG-CLASS CLOSED + TESTED | Add and delete were covered; **edit** was the gap and is now atomic-verified with the failure injected after the row is rewritten | `e943ed04` | — |
| 8 — Outbox / idempotency / sync replay | PROVEN SAFE — one P2 defence-in-depth finding | `SyncGate` generation admission, `OwnershipGuard` admission tokens, wipe-on-transition, revision CAS, bounded backoff, dead-lettering | `62c9485e` (wipe leg) | See P2 |
| 9 — Auth / session concurrency | PROVEN SAFE | Scenarios A–J, including simultaneous `auth_required` failures resolving to exactly one recovery transition with no redirect storm | — (pre-existing) | — |
| 10 — Cross-account local data isolation | PROVEN SAFE | Real `DataWipeService` against a real database through the real `AppSession` transition; residue checked by querying tables, not by trusting the list | `62c9485e` | Physical-device A→B pass |
| 11 — Supabase security / RLS | **PARTIAL — STATIC PASS / LIVE BLOCKED** | Static: owner-table grants, `SECURITY DEFINER` search_path, service-role privilege manifest, backend hardening contract | — | Live A/B token isolation — see below |
| 12 — Background / process death | PROVEN SAFE | Real `Process.start` kill mid-transaction; crash-after-commit-before-ack replay creates no duplicate; lease recovery for dead pids | — (pre-existing) | — |
| 13 — Backup / restore | PROVEN SAFE | ~30 suites; restore is transactional with fault hooks at every boundary and an in-transaction `foreign_key_check`; wrong-account restore refused (H-23); owner marker never leaves the device | — (pre-existing) | — |
| 14 — Account delete / soft delete / resurrection | **PARTIAL — STATIC PASS / LIVE BLOCKED** | Static: order-aware `purge_user_data` superset invariant — each successive definition must delete from a superset of the previous one's tables | — | Live purge/idempotency/concurrency — see below |
| 15 — Financial invariants | PROVEN SAFE | Canonical totals equal across headline, views, budget and report; multi-currency never summed under one label; excluded accounts handled per scope | — (pre-existing) | — |

## P0 / P1 / P2

### P0 — none outstanding

One P0 existed in this cycle and is fixed: the **ownership destructive loop**
described under `ac622970`. It is now regression-locked from three independent
directions — Audit 2 (state matrix and convergence), Audit 7 (write atomicity)
and Audit 10 (real wipe through the real transition).

### P1 — none

### P2 — `ledger_sync_outbox` lacks an owner column

**The finding.** Queued outbox rows carry no `user_id` / owner column.

**Why it is not currently reachable.** The invariant *"user A's queued rows can
never upload as user B"* is enforced today by two mechanisms, both proven:

1. **Wipe on ownership transition** — the A→B transition empties
   `ledger_sync_outbox` and `planning_sync_outbox` before B is admitted.
   Verified in `62c9485e` by querying the tables after a real transition.
2. **`SyncGate` generation admission** — the gate bumps its generation on
   sign-out, owner change, and same-UID relogin, so a run captured under the old
   generation is refused. Background jobs additionally carry an
   `AdmissionToken` (owner UID + rotating generation) revalidated at every
   commit and acknowledgement boundary.

**The residual risk.** `LedgerPushService.push()` does **not** independently
enforce owner identity. It gates on consent, the push flag, and a non-null auth
user, then drains every pending row and sends it under the *current* user id.
The ownership protection lives in the caller (`app_shell`) and in the wipe, not
in the service or the row. A future push caller added outside that path — a new
background entry point, a widget, a scheduled task — would bypass the generation
gate silently, and nothing in the row itself would stop the upload.

**Decision for 1.0.0: do not fix now.** No schema migration is being made for
this release. A migration to add and backfill an owner column touches the
financial write path and every push/pull service, which is not a change to make
against a release candidate for a risk that is not currently reachable.

## Tracked hardening / future risk

| Item | Risk | Proposed treatment | Trigger |
|---|---|---|---|
| `ledger_sync_outbox` / `planning_sync_outbox` have no owner column | A new push call site could bypass `SyncGate` generation admission and upload a previous owner's queued rows | Either add an owner column written at enqueue and asserted at push, **or** move the admission check inside `LedgerPushService.push()` so the service is safe regardless of caller | **Before any new caller of `push()` is added**, or in the first release after 1.0.0 — whichever comes first |

## Supabase blocked verification

**89 Supabase tests self-skip when credentials are absent.** They are written and
committed; they have not been executed.

They require an **AUTHORIZED VALIDATION PROJECT — never production, never
evidence staging**, with the relevant migrations applied:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

> Values must never be printed, committed, or pasted into chat. The
> `service_role` key must exist server-side only and must never reach the app or
> any build.

### Remaining live checks — Audit 11

- [ ] `USER_A` / `USER_B` RLS isolation — A must not read or write B's rows
- [ ] `anon` probes against every user-private table
- [ ] Coupons RLS

### Remaining live checks — Audit 14

- [ ] `purge_user_data` completeness — every row for the target user, nothing else
- [ ] `request_account_deletion` idempotency — does not push the clock forward
- [ ] Concurrent last-account deletion serialises correctly
- [ ] Storage prefix erasure — every backup object a deleted account owns

### STATIC PASS ≠ LIVE PASS

The static analysis proves the **SQL definitions and grants** are correct as
written, and — for Audit 14 — that no migration has silently regressed the purge
by copying an older function body. It proves nothing about the **deployed**
project: whether the migrations are actually applied, whether RLS is enabled on
the live tables, or how the database behaves under two real tokens. Audits 11
and 14 must be recorded as PARTIAL until the checks above are executed and their
results appended to this record.

## Device verification checklist

To be executed on a **physical iPhone**, not a simulator.

- [ ] UIScene scene-connect timing — registration completes at
      `scene(_:willConnectTo:)`, before Dart bootstrap calls the channel
- [ ] First native purge call timing — no `MissingPluginException` at startup
- [ ] Ownership transition after a **stale Keychain owner** (the `ac622970`
      condition) resolves once and then stays inert
- [ ] Reinstall / old-owner scenario — delete the app, reinstall, sign in as the
      same user; no wipe occurs
- [ ] **No repeated financial wipe** — create data, force-quit, relaunch five
      times; amounts persist every time
- [ ] Native capture channel availability across cold start, resume, and
      background return
- [ ] Scene reconnect, if reproducible on device — channel rebinds to the new
      controller
- [ ] Cross-process App Group `flock` contention — capture arriving via the
      extension while the host app is draining the queue; no message lost or
      double-imported
- [ ] Cold-start banner timeout behaviour — cold start measured at ~20s versus
      ~0.5s warm; confirm the timeout path degrades gracefully

## Quality gates

| Gate | Result |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **4277 passed, 2 skipped, 0 failed** |
| Supabase node contract tests | **228 passed, 89 skipped, 0 failed** |
| `tools/ci_gates.sh` (strict) | **13/13 mandatory passed** |

The 89 Supabase skips are exactly the live-credential cases listed above. The 2
Flutter skips are pre-existing.

### Local environment issue — must be checked in CI

The strict gate initially reported **3 failures**: `analyze`, `flutter test
(bulk)`, and `flutter test (crypto serialized)`.

**These were environmental, not code failures.** This machine has
`PUB_CACHE=/Volumes/shared`, which points at an unavailable volume, so
`flutter pub get` failed with
`Creation failed, path = '/Volumes/shared' (OS Error: Permission denied, errno = 13)`
and those three gates never ran at all. Re-running with `PUB_CACHE` unset
produced **13/13 PASS**. The same three suites also pass when invoked directly
(`0 issues`; `4277 passed`).

**Release action:** verify Codemagic does **not** inherit the same invalid
`PUB_CACHE` value. A build environment carrying it would report the same three
failures — or, worse, appear to skip them — for reasons unrelated to the code.

## Audit commits

### This audit pass — 6 commits, each isolated

| Commit | What it does |
|---|---|
| `3ae9ebb7` | Pins the install / reinstall / Keychain / restore matrix. Proves convergence from every starting combination of the four stores whose lifetimes differ, which is the gap the P0 lived in. |
| `965ea77a` | Carries populated money through every supported schema version to 38, plus crash-replay and a static guard that fails if a future migration stops being additive. |
| `62c9485e` | Proves B inherits nothing of A's by driving the real wipe service through the real ownership transition and querying every table, rather than trusting the wipe list. |
| `e943ed04` | Closes the edit-atomicity gap: an edit and its outbox row must commit or roll back together, with the failure injected after the row is rewritten. |
| `599c3b2b` | Pins the cross-process `flock` on the shared capture queue, with brace-tracked block extents so a mutation added just after a lock block is still caught. |
| `b744e2de` | Replaces the destructive-operation *scanner* with an enumerated, classified inventory of all 18 sites, at exact counts. |

### Earlier safety commits

| Commit | What it does |
|---|---|
| `ac622970` | Ownership transition reordered to purge before wipe; never destroys data it cannot finish claiming. Fixes the destructive loop. |
| `5efdf846` | Defence in depth, **not a reachable defect** — the shipped open path was already fail-closed. Moves the no-mint-over-an-existing-database invariant inside the key store: typed read outcomes, a required existence probe, single-flight minting. |
| `e542b450` | Registers the capture channel at scene connect and rebinds it per controller, closing both the startup window and the reconnect hole. |
| `a05f029b` | Pins the runtime SQLite engine past the WAL-reset fix. |

## Mutation testing

**39 new tests were added in this pass, and every one was mutation-checked.** A
test that cannot fail is not evidence, so each was run against a deliberately
broken version of the code it guards and confirmed to fail with a message that
names the actual defect.

Mutants killed included:

- **A one-minor-unit financial drift** injected into a compatibility backfill —
  caught by all 13 migration data cases, proving they assert money and not merely
  row counts
- **A dropped wipe-list table** (`sync_cursors`) — failed two isolation tests and
  named the exact surviving row
- **A non-transactional edit** — failed with *"the edit was applied without its
  outbox row"*
- **An unlocked read-modify-write** added anywhere in the Swift capture store —
  failed with the byte offset that escaped the lock
- **An unlisted destructive operation** added to a file outside the inventory —
  failed and named the file
- **The wipe-before-purge regression** (the original P0 ordering) — failed the
  ownership-transition order tests
- **The stale-messenger registration regression** — a bare nil-check instead of
  per-controller identity failed the lifecycle guards

## Release decision gates

### CODE SAFETY GATE

**PASS**, subject to the explicitly listed blocked, live and device verification
above.

This gate covers the code and its regression evidence. It is **not** a statement
that the app is ready for the App Store, and it does not stand in for the device
checklist or the live backend verification.

### BEFORE BUILD 42

1. Verify the Codemagic `PUB_CACHE` environment — confirm it does not carry
   `/Volumes/shared` or any other unavailable path
2. Resolve the Apple **ITMS-90683** location-privacy warning
   (missing purpose string in `Info.plist`)
3. Bump build 41 → 42 (version stays 1.0.0)
4. Re-run the strict CI gate and confirm 13/13
5. Create the signed TestFlight build
6. Execute the physical-device checklist above
7. Complete the Supabase validation-project tests once credentials are available,
   and append the results to this record

### BEFORE APP STORE REVIEW

All release-blocking device checks must pass, and any required live backend
verification must be **recorded** — not assumed, and not inferred from the static
passes. Audits 11 and 14 remain PARTIAL until then.

## Post-audit release changes

Everything above was audited against **`b744e2de`**. This section records what
changed *after* that snapshot, so the audit's scope stays honest: the 15-part
red-team pass did **not** run against the commits below, and nothing here
re-opened or re-ran it.

| | |
|---|---|
| Original audited code HEAD | `b744e2de` — unchanged, and the scope of every status above |
| Release-candidate code HEAD | `3c450796` — the build-42 bump |
| ITMS-90683 fix | `5f570064` |
| Build-number bump | `3c450796` |
| This section | committed with the bump; the hash below was filled in by a follow-up documentation-only commit, since a commit cannot contain its own hash |

### Why `flutter_timezone` was removed

Apple accepted build 41 but reported **ITMS-90683** — a missing
`NSLocationWhenInUseUsageDescription` in `Runner.app`.

The audit traced it to exactly one place: `flutter_timezone`'s iOS public header
opens with `#import <CoreLocation/CoreLocation.h>`, and
`GeneratedPluginRegistrant.m` pulls that header into Runner's own compilation
unit. The import is unused — the plugin's implementation is Swift and reads the
zone from Foundation — and it is **still present upstream in 5.1.0**, so
upgrading was not a remedy. Nothing else in the dependency tree referenced
location: no location package, no `CoreLocation` reference across 2044 Pods
files, no `CoreLocation.framework` load command, and no `CLLocationManager`
symbol in the built binary.

Adding the purpose string was rejected on its own merits, not only because it
would have been misleading: `ios_privacy_manifest_test` already asserts all four
`NSLocation*` keys stay absent (MALI-043), since an unjustified permission is a
review risk. Declaring one would have turned `flutter test` red.

So the dependency was dropped and its single call site — `getLocalTimezone()`,
used to schedule local notifications in the user's own zone — replaced with a
`mali/device_timezone` method channel: `TimeZone.current.identifier` on iOS,
`TimeZone.getDefault().id` on Android. Foundation and `java.util` only; no
location, no permission.

### The lifecycle defect found during review of the fix

**The first implementation of that channel was wrong, and the review caught it.**
It mirrored the simpler `nativeGlassChannel` pattern and so carried all three
defects Audit 3A had just closed on the capture channel:

- it registered only from `didFinishLaunchingWithOptions` (where
  `rootFlutterViewController()` is nil under UIScene, so the call silently
  no-ops) and `applicationDidBecomeActive` — both **after** Dart is running;
- it guarded on `deviceTimezoneChannel == nil`, the bare nil-check that no-ops on
  a scene reconnect and strands the channel on a dead messenger;
- it tracked no controller identity at all.

This was not theoretical. Dart reaches the channel from
`LocalNotificationService.initialize()`, which bootstrap runs at
`notifications_init` — **the same pre-first-frame window** in which the capture
purge once got `MissingPluginException` and, with the ownership ordering of the
time, cost users their financial data (`ac622970`).

The consequence would have been quieter than that but still wrong: an ordinary
cold-start race would have pinned the user to the `Asia/Riyadh` fallback for the
whole session, firing every scheduled notification at the wrong local time, with
nothing to indicate why.

### The hardened final implementation

- registers from **`scene(_:willConnectTo:)`**, the earliest deterministic
  UIScene point, and from `sceneDidBecomeActive` as defence in depth;
- **idempotent against the CURRENT `FlutterViewController`**, not against "a
  channel object exists", so a scene reconnect rebinds;
- the old handler is cleared with `setMethodCallHandler(nil)` **before** the new
  channel is constructed, so exactly one handler is installed;
- the tracked controller is a **`weak`** reference, so a deallocated controller
  reads back nil and forces a correct rebind;
- no force unwraps on the registration path;
- a **bounded retry for `MissingPluginException` only** — 5 attempts × 100 ms,
  400 ms worst case before first frame. A `PlatformException` is the handler
  having run and refused and is **not** retried; `null` stays `null`.

It remains a **separate** channel from `money_companion/native_capture`
deliberately — that one carries the per-controller rebind logic and was the path
a data-loss defect ran through — but separate no longer means weaker.

Scheduling behaviour is otherwise unchanged: a reported zone becomes `tz.local`;
`null`, an exhausted budget, a real native failure or a zone the tz database does
not know all still fall back to `Asia/Riyadh`, so schedules never break.

### Mutation evidence

20 new tests (12 behavioural + 8 architecture guards). Four mutations, each
killed, with the baseline confirmed green before and after:

| Mutation | Result |
|---|---|
| Revert to the bare `deviceTimezoneChannel == nil` guard | KILLED |
| Drop the `scene(_:willConnectTo:)` registration | KILLED |
| Make the controller reference strong instead of `weak` | KILLED |
| Remove the bounded retry (`channelRetries = 1`) | KILLED |

The guards also assert that **no `CoreLocation` import can return to
`AppDelegate.swift`** — so the fix cannot reintroduce the defect it fixes.

### Final results at the release candidate

| Check | Result |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **4297 passed, 2 skipped, 0 failed** |
| Focused timezone / privacy / lifecycle tests | **40 passed** |
| `tools/ci_gates.sh` (strict) | **13/13 mandatory passed** |
| Clean iOS Release build | ✓ `Runner.app`, 60.1 MB |
| Android compile | ✓ channel present in dex, 0 `flutter_timezone` entries |

Final `Runner.app` inspection:

| Criterion | Result |
|---|---|
| `flutter_timezone.framework` | **0** |
| `CoreLocation.framework` load commands | **0** |
| `CLLocationManager` / `CLGeocoder` / `CLPlacemark` | **0** |
| `NSLocation*` keys — Runner | **0** |
| `NSLocation*` keys — ShareBankMessage | **0** |
| `mali/device_timezone` present | **yes** |
| Runner version / build | **1.0.0 (42)** |
| ShareBankMessage version / build | **1.0.0 (42)** |

Both targets take their version from `$(FLUTTER_BUILD_NAME)` /
`$(FLUTTER_BUILD_NUMBER)`, so the single `pubspec.yaml` bump propagates to the
app and the extension together — verified in the built plists rather than assumed.

### Notes on the build itself

The first clean build attempt **failed**, and not because of the code:
`flutter clean` had wiped the cached `libsqlite3mc.arm64.ios.dylib` (the
SQLCipher native library) and the re-download from GitHub release assets was
interrupted mid-stream — `HttpException: Connection closed while receiving data`.
A subsequent fully clean build (fresh `pod install`, wiped DerivedData) succeeded
in 99 s. Worth knowing before a CI run is blamed on a code change.

### What this section does NOT change

- Audits **11** and **14** remain **PARTIAL — STATIC PASS / LIVE BLOCKED**. No
  live Supabase verification was performed here.
- The **physical-device checklist is still entirely unchecked**, and this fix
  adds to it: the scene-reconnect rebind for the new channel is guarded by
  source-shape assertions, not by execution on hardware.
- ITMS-90683 itself is **not confirmed resolved**. The reference is gone from the
  binary, which removes the only trigger the audit could find, but confirmation
  comes only from the next App Store Connect upload.
- The **P2** (`ledger_sync_outbox` has no owner column) is untouched and still
  tracked.
- No TestFlight upload has been performed.


---

*Record compiled 2026-09-27 against audited code HEAD `b744e2de` on branch
`release/ios-1.0.0-build41`. This document is tracked separately from the code it
describes — first committed as `351c2ad9`, documentation only. No code was
modified while writing or correcting it, and no secrets are contained in it.*
