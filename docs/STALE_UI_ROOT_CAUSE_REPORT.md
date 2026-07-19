# Root-Cause Report: UI Not Updating Immediately After Data Changes

Investigation-only. No code was modified. No commits were created.

## A. Executive Summary

The app's reactivity is centered on one mechanism: `dbRevisionProvider`
(`lib/core/di/app_providers.dart:111`), a `StreamProvider<int>` that ticks
whenever the shared `AppDatabase` instance sees a write (`db.tableUpdates()`
or `db.manualRevisionStream`). Nearly every read provider (`dashboardDataProvider`,
`transactionsListProvider`, `accountsProvider`, `budgetsViewProvider`,
`goalsListProvider`, etc.) does `ref.watch(dbRevisionProvider)` as its first
line, so in the common case — a mutation made from a screen that's currently
open, awaited normally — the mechanism works correctly and the UI updates
immediately.

The staleness reports trace to three concrete gaps, not a broken core
mechanism:

1. **Background notification actions write through a second, disconnected
   `AppDatabase` instance** and only reconcile through the normal (reactive)
   repository path once, at app cold-start. Resuming a merely-backgrounded
   app does not re-run that reconciliation. — **primary suspect**
2. **Supabase-primary mirror writes silently swallow failures** — if the
   local cache write after a successful server write throws, the revision
   counter never ticks and the error is never surfaced.
3. **Not every read provider auto-refreshes on re-navigation.** Some are
   `autoDispose` (rebuild fresh every time they're watched again) and some
   are plain, persistent providers (only refresh via `dbRevisionProvider` or
   explicit `ref.invalidate`). Users get inconsistent results from
   "navigate away and back" depending on which screen they left.

No Supabase Realtime subscription exists anywhere in the app — all
reactivity is client-write-driven, so any change that doesn't go through the
app's own write path (e.g. a second device, a server-side trigger) will
never appear without a manual refresh. This is a design gap worth noting but
is not what the user is describing (single-device, own actions).

## B. The Core Mechanism (confirmed working as designed)

`lib/core/di/app_providers.dart:107-127`

```dart
final dbRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final tableSub = db.tableUpdates().listen((_) => tick());
  final manualSub = db.manualRevisionStream.listen((_) => tick());
  ...
});
```

`lib/data/db/app_database.dart` overrides `customInsert`, `customUpdate`,
and `customStatement` (the app does **not** use Drift's generated
`Table`/`into()` API at all — `allTables` returns `const []`; every read and
write in the codebase is raw SQL via `customSelect`/`customInsert`/
`customUpdate`/`customStatement`). Every `customInsert`/`customUpdate` call
unconditionally bumps `_manualRevisionController`; `customStatement` bumps it
whenever the SQL text starts with `INSERT`/`UPDATE`/`DELETE`/`REPLACE`.

Both `DriftTransactionRepository` (drift_transaction_repository.dart) and
`SupabaseTransactionRepository`'s local-cache mirror (`_mirrorUpsertRow`,
`_mirrorDeleteByServerId` in supabase_transaction_repository.dart) go through
these same overridden methods, so both write paths correctly bump the
revision counter *when they succeed*.

Confirmed watchers of `dbRevisionProvider` (broad, consistent coverage):
`dashboardDataProvider`, `transactionsListProvider`, `billsViewProvider`,
`accountsProvider`, `baseCurrencyProvider`, `suspectedDuplicatesProvider`,
`smartInboxItemsProvider`, plus providers in `plans_providers.dart`,
`settings_providers.dart`, `goals_providers.dart`,
`achievements_providers.dart`, `cards_providers.dart`,
`subscriptions_providers.dart`, `reports_providers.dart`,
`budgets_providers.dart`. Mutation call sites checked
(`manual_transaction_sheet.dart`, `transaction_details_screen.dart`,
`transactions_screen.dart`) all correctly `await` the repository call before
popping/navigating, so there's no obvious fire-and-forget race in the normal
UI mutation flow.

**Conclusion:** the mechanism itself is sound and broadly wired. The bugs
are in paths that write to the database *without going through this live
instance*, and in error handling that lets a failed mirror write pass
silently.

## C. Root Cause #1 (primary suspect): background notification actions use a separate `AppDatabase` connection, reconciled only once at cold start

**File:** `lib/features/capture/services/local_notification_service.dart:714-751`

The Confirm/Dismiss quick actions on a transaction notification are handled
by `_backgroundTapHandler`, a genuine `@pragma('vm:entry-point')` background
isolate callback (fires when the app is backgrounded or terminated):

```dart
@pragma('vm:entry-point')
static void _backgroundTapHandler(NotificationResponse response) { ... }

static Future<void> _runBackgroundAction(String transactionId, {required bool confirm}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await PendingNotificationActions.record(transactionId, confirm: confirm);
  final AppDatabase db;
  try {
    db = await AppDatabase.open();   // <-- a brand-new, separate connection
  } catch (_) {
    return;
  }
  ...
  await db.customUpdate("UPDATE transactions SET status = 'confirmed' ...");
```

This is a **different `AppDatabase` object**, in a different isolate, than
the one the foreground app's `appDatabaseProvider` wraps. Its
`_manualRevisionController` and `db.tableUpdates()` stream have no
subscribers in the foreground app — the foreground `dbRevisionProvider`
cannot see this write at all, even though it lands in the same physical
SQLite file.

The code is self-aware of this: the comment at line 727-732 explains the
local write is "cosmetic" and the source of truth is a replay recorded via
`PendingNotificationActions.record(...)`, intended to be re-applied "on
first open" through the normal (reactive) routed repository.

That replay only happens here:

**File:** `lib/features/app/app_shell.dart:143`, inside `initState`'s
`addPostFrameCallback`:

```dart
await _drainPendingNotificationActions();
```

This runs **once**, when `AppShell` is first mounted (cold start / first
navigation into the shell). There is **no `WidgetsBindingObserver` /
`didChangeAppLifecycleState` listener anywhere in `app_shell.dart`** that
re-runs `_drainPendingNotificationActions()` — or invalidates any data
provider — when the app resumes from the background without a full process
restart.

**Concrete failure scenario:**
1. App is backgrounded (not killed) — `AppShell` stays alive in memory.
2. A transaction notification arrives; user taps "Confirm" from the lock
   screen / notification shade.
3. `_backgroundTapHandler` opens its own `AppDatabase`, updates the row
   locally, records a pending action.
4. User reopens the app (resume, not relaunch). `AppShell.initState` does
   **not** re-run — the widget was never disposed.
5. The foreground `dashboardDataProvider` / `transactionsListProvider`
   still hold whatever they last computed; `dbRevisionProvider` never
   ticked because the write happened on a different connection.
6. The transaction shows as "pending" in the UI until the user forces a
   refresh (pull-to-refresh on dashboard, or navigates to a screen backed
   by an `autoDispose` provider that happens to force a fresh read), or
   fully kills and reopens the app (new process → `AppShell.initState`
   runs again → drain + explicit `ref.invalidate` calls at lines 191-199).

This matches the reported symptom almost exactly: "navigate away, reopen a
screen, or manually refresh" are all workarounds that happen to force a
fresh read through the *live* connection; a plain app resume does not.

**Recommended fix:** add a `WidgetsBindingObserver` to `AppShell` (or reuse
an existing one if present elsewhere) that calls
`_drainPendingNotificationActions()` plus the same `ref.invalidate(...)`
batch already used at lines 191-199 / 344-380 whenever
`AppLifecycleState.resumed` fires. This is the single highest-leverage fix
for the reported symptom.

## D. Root Cause #2: Supabase-primary mirror-write failures are swallowed silently

**File:** `lib/data/repositories/supabase_transaction_repository.dart:1269-1357`

`_mirrorUpsertRow` and `_mirrorDeleteByServerId` run after a **successful**
Supabase write, to keep the local cache (and thus `dbRevisionProvider`) in
sync:

```dart
Future<void> _mirrorUpsertRow({...}) async {
  try {
    ...
    await _db.customStatement('INSERT INTO transactions(...) ...');
    await clearFinancialCacheDirty(_db, transactionsCacheEntityType);
  } catch (e) {
    await markFinancialCacheDirty(_db, transactionsCacheEntityType, e);
  }
}
```

If the local INSERT throws (FK violation, missing category mapping, locked
database, disk error, etc.), the exception is caught, the cache is marked
"dirty," and **the function returns normally**. The outer `saveTransaction`
/ `confirm` / `updateTransaction` call also returns normally (it already has
the server row and constructs the return entity from it), so:

- The calling UI sees success and shows a confirmation / pops the sheet.
- The local cache was never updated, so `dbRevisionProvider` never ticks.
- The dashboard/list screens keep showing pre-mutation data until something
  else triggers a refresh, or until `financialCacheRepairServiceProvider`
  (referenced at `app_providers.dart:234-247` and invoked via
  `_repairDirtyFinancialCaches()` in `app_shell.dart:138`) repairs it — which,
  like the notification-action drain, currently only runs at the same
  cold-start `addPostFrameCallback`, not on resume.

**Recommended fix:** at minimum, log this failure path (currently fully
silent even in debug builds) so it's diagnosable; consider also having
`_repairDirtyFinancialCaches()` run on `AppLifecycleState.resumed` (same fix
as Root Cause #1 covers this for free), and/or having the mirror failure
trigger a manual `dbRevisionProvider` bump once the repair succeeds — it
already does, via `_notifyManualRevision()` inside `customStatement`, so
fixing the resume-trigger gap fixes this too.

## E. Root Cause #3: inconsistent "does re-navigation refresh this screen?" behavior

- `transactionsListProvider` is `AutoDisposeAsyncNotifierProvider`
  (`transactions_providers.dart:192`) — when the Transactions screen is
  popped and its last listener goes away, Riverpod disposes it; navigating
  back forces a brand-new `build()` that reads current DB state directly,
  independent of whether `dbRevisionProvider` ticked in the meantime. This
  is why "leaving and reopening a screen" often appears to "fix" staleness
  for the transactions list specifically.
- `dashboardDataProvider` is a **plain** `FutureProvider`
  (`dashboard_providers.dart:292`), not `autoDispose`. It is never disposed
  while the app is running, so switching dashboard tabs and back does
  **not** force a re-read — it only updates via `dbRevisionProvider` ticking
  or an explicit `ref.invalidate(dashboardDataProvider)` (the dashboard's
  `RefreshIndicator` at `dashboard_screen.dart:110` does exactly this — its
  presence is itself evidence the team already hit this gap and added a
  manual escape hatch rather than fixing the underlying trigger).

This isn't a bug in isolation, but it means user-reported "reopening a
screen fixes it" is unreliable and screen-dependent, which matches the
"sometimes" qualifier in the reported symptom.

## F. Areas investigated and ruled out

- **Riverpod wiring / read-vs-watch:** `DashboardScreen` and
  `TransactionsScreen` are both `ConsumerWidget`s using `ref.watch(...)` at
  the top of `build()` — correct reactive pattern, not a widget-level bug.
- **Mutation call sites racing navigation:** `manual_transaction_sheet.dart`,
  `transaction_details_screen.dart`, `transactions_screen.dart` all `await`
  the repository call before popping/navigating. No fire-and-forget found.
- **Foreground SMS capture (iOS Shortcut relay):**
  `NativeCaptureBridge.setPendingMessagesHandler` in `app_shell.dart:106-109`
  is a live callback registered once but invoked by native code on every
  incoming message while the app is running; it calls
  `_consumeSharedInput()` which goes through the same live
  `captureSyncServiceProvider` / `appDatabaseProvider` — correctly wired,
  not a source of staleness.
- **`sms_background_handler.dart`'s `@pragma('vm:entry-point')`:** this
  handler is a no-op stub (`return;`) — not currently doing any DB work, so
  not a contributor despite superficially looking like another
  cross-isolate write path.
- **Drift's built-in `tableUpdates()` reactivity:** irrelevant in practice —
  the app never uses Drift's generated `Table`/`into()`/`update()` API
  (`allTables` is `const []`); everything is raw SQL through the manually
  overridden `customInsert`/`customUpdate`/`customStatement`, which is where
  the actual (working) revision-bump logic lives.
- **Supabase Realtime:** not used anywhere (`grep` for `RealtimeChannel`/
  `.channel(` found nothing). Not a regression — it was never implemented —
  but worth flagging as a real limitation if multi-device or server-driven
  updates are ever expected to appear live.

## Recommended Fix Priority

1. **(High impact, low risk)** Add an `AppLifecycleState.resumed` handler in
   `AppShell` that re-runs `_drainPendingNotificationActions()`,
   `_repairDirtyFinancialCaches()`, and the same provider-invalidate batch
   already used elsewhere in that file. Fixes Root Causes #1 and #2 for the
   "resumed from background" case, which is almost certainly the majority
   of real-world staleness reports (users background the app constantly;
   full kill-and-relaunch is rare).
2. **(Medium impact, low risk)** Log (don't just swallow)
   `_mirrorUpsertRow`/`_mirrorDeleteByServerId` failures so future
   occurrences are diagnosable instead of silent.
3. **(Low impact, informational)** Document which list/detail providers are
   `autoDispose` vs persistent, so future screens are built consistently —
   or standardize on one pattern for financial-data providers.
