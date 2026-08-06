# Mali — Database Process-Access Inventory (MALI-069n, Batch-4 closure #4)

**Question:** can the Drift/SQLCipher database (`money_companion.sqlite`) be opened
from more than one OS process at a time? This determines whether the lease/liveness
layer needs cross-process fencing (Contract A) or single-process coordination
(Contract B).

**Answer: Contract B — exactly one OS process (the Flutter host app process) can
ever open the database.** Every separate-process target is pure-native and only
reads/writes App Group / SharedPreferences *staging*; none loads a Flutter engine,
so none can load the `sqlite3mc`/Drift Dart plugin.

## Inventory

| Executable / target | Same OS process as app? | Separate OS process? | Opens SQLCipher DB? | How it stages / admits |
|---|---|---|---|---|
| **iOS Runner** (app) | — (is the app process) | no | **YES** (Dart, main isolate) | bootstrap `AppDatabase.open`; holds the process liveness lock |
| **iOS ShareBankMessage** (`com.apple.product-type.app-extension`) | no | **yes** | **NO** | pure-native Swift; `SharedCaptureStore` → `UserDefaults(suiteName: group.com.youssefsafwat.mali)` FIFO queue + shared Keychain. Doc: "Flutter drains the FIFO queue when the host app is active." |
| **iOS BankMessageShortcuts** (App Intents) | runs via system | yes (intent process) | **NO** | pure-native Swift; `BankMessageShortcuts.swift:345` — "intentionally avoids Flutter APIs. App extensions should stay [native]"; reads the Flutter-bundled `parser_rules.json` **asset file**, writes to the App Group. |
| **Android MainActivity** | — (is the app process) | no | **YES** (Dart, main isolate) | bootstrap `AppDatabase.open` |
| **Android `ActionBroadcastReceiver`** (notification actions) | **yes** (no `android:process`) | no | YES, but as a **same-process background isolate** | `flutter_local_notifications` background `FlutterEngine` in the app process → `_runBackgroundAction` → `openSecondary` |
| **Android `ScheduledNotificationReceiver` / boot receiver** | yes (no `android:process`) | no | no | schedule/reschedule only |
| **Android `SmsCaptureReceiver`** | yes (no `android:process`) | no | no (commented out; Play-safe build declares no SMS) | would stage to SharedPreferences `mali_capture_queue_v1` |
| **`NativeDatabase.createBackgroundConnection`** | yes | no | YES (the DB's own Drift background isolate) | Drift-internal, **same OS process** |
| **capture-import isolate** (`captured_message_processor`, `sms_background_handler` `@pragma('vm:entry-point')`) | **yes** | no | YES — **same-process background isolate** | drains the App Group / SharedPreferences staging queue, `openSecondary` |
| **notification-action isolate** (`_backgroundTapHandler`) | **yes** | no | YES — **same-process background isolate** | `openSecondary` |
| **restore/reset** (Batch 5, not yet built) | yes | no | YES (main isolate) | `runFileExclusiveMaintenance` |
| **test executables** | n/a | n/a | in-memory / temp files | — |

## Evidence

- **No native code opens SQLite/SQLCipher.** A repo-wide grep of `ios/` and
  `android/` for `sqlite|sqlcipher|sqlite3mc|.sqlite|GRDB|FMDB` in
  `*.swift/*.m/*.kt/*.java` returns **nothing**. The DB is opened only from Dart.
- **`sqlite3mc` is a Dart/Flutter `drift` plugin** (`pubspec.yaml`), loadable only
  inside a Flutter engine → only in the host app process.
- **iOS extensions run no Flutter engine.** No `FlutterEngine` /
  `FlutterViewController` / `GeneratedPluginRegistrant` in `ShareBankMessage` or
  `BankMessageShortcuts`; they use `UserDefaults(suiteName:)` + the shared Keychain
  and a bundled asset file only.
- **Android declares no separate process.** `AndroidManifest.xml` has **no**
  `android:process` on any component; the notification `ActionBroadcastReceiver`
  and all receivers run in the default app process (background isolate, same OS
  process). `SmsCaptureReceiver` is commented out (Play-safe build).
- Only three Dart DB-open sites exist: `bootstrap_runner` (`AppDatabase.open`,
  main), and `captured_message_processor` + `local_notification_service`
  (`AppDatabase.openSecondary`, same-process background isolates).

## Consequence for the liveness layer (Contract B)

1. **Enforce the invariant.** A contract test asserts no separate-process target
   (iOS extension, Android receiver source) imports Drift / `app_database` / opens
   the DB. Future regressions fail the gate.
2. **Reaping authority is NOT heartbeat/mtime.** Within the single live process,
   an isolate whose lease persists (a blocked/paused isolate, or one stuck in a
   long SQLite call) is treated as **live** — maintenance waits and returns a
   **typed bounded timeout**, never reaps. A stopped heartbeat is never proof that
   an isolate's connection has closed.
3. **Stale-file recovery happens only at process start**, gated by a
   **process-lifetime OS advisory lock**: a starting process that acquires the
   exclusive lock has proof that prior instances ended (and, under Contract B, that
   no other process is opening the DB), so it may clear leftover records from
   **ended** instances (identified by a different owner pid — pids are unique among
   live processes). Same-pid live leases are never cleared.
4. **Records are immutable + atomic.** The authoritative lease/intent record is
   created with `O_EXCL`, contains only opaque protocol data (fencing token, owner
   pid, instance token), and is never rewritten; any diagnostic heartbeat lives in
   a **separate** file updated by temp-write + atomic rename. Empty/malformed
   authoritative state is treated as live/unknown, never as permission to delete.
