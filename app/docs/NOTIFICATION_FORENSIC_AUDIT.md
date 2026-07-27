# Notification Subsystem — Forensic Engineering Audit

Read-only review of the entire notification architecture for a 100k+ user
release. No fixes applied. Severity reflects runtime impact on the current
primary platform (iOS) with Android called out where it differs.

Method: full read of `local_notification_service.dart`, `notification_planner.dart`,
`notification_journey_service.dart`, `captured_message_processor.dart`,
`app_shell.dart` scheduling/handlers, `pending_notification_actions.dart`,
`capture_notification_content.dart`, the Android manifest, and the iOS
entitlements/AppDelegate.

---

## Phase 1 — Pipeline (dependency graph)

```
EVENT                         BUSINESS LOGIC                 SERVICE                         PLATFORM → OS → USER
─────                         ──────────────                 ───────                         ────────────────────
bank SMS (iOS Shortcut/       CapturedMessageProcessor       LocalNotificationService        flutter_local_notifications
  share / Android SMS)          / CaptureSyncService (relay)   .showReview / .showLight        → APNs alert / Android channel
manual add                    checkBudgetAlert               .showBudgetAlert
budget cross threshold        BudgetAlertPlanner
goal milestone crossed        NotificationPlanner.planGoal   .showGoalMilestone
bill/subscription due         NotificationPlanner.planBill   .schedulePlannedNotifications (zonedSchedule)
weekly report                 NotificationPlanner.planWeekly .schedulePlannedNotifications
streak idle                   _syncEngagementBody            .scheduleStreakReminder (zonedSchedule)
growth journey / campaign     NotificationJourneyService     .showMarketingNotification
achievement                   (ORPHANED — no caller)         .showAchievementNotification    ← never invoked in prod
tap / confirm / dismiss       _handleNotificationPayload /   CaptureRuntime / PendingNotificationActions → routed repo
                                _backgroundTapHandler
tracking                      NotificationLogService         → notification_logs (+ sync to Supabase)
```

Single dispatcher: `LocalNotificationService` (singleton) → `_show()` (immediate
via `plugin.show`) or `zonedSchedule` (deferred). Two capture-notification entry
points: the background isolate (`CapturedMessageProcessor.processCapturedMessage`)
and the foreground shell (`app_shell._showCapturedMessageNotification`).

---

## 🔴 CRITICAL

### C1 — Background dismiss/confirm resurrects the transaction via the server
**Root cause.** `LocalNotificationService._runBackgroundAction` (background
notification action, device often locked) does a raw
`DELETE FROM transactions WHERE id=? AND status='pending'` on its **own** DB
connection. It does **not** touch `ledger_sync_outbox`. Since SMS captures now
enqueue an outbox `create` on save (recent sync-completion change), the create
item **survives** the local delete. On the next sync, `LedgerPushService._pushCreate`
pushes from the outbox item's payload (not from the now-deleted local row) →
the **dismissed** transaction is created on Supabase, then re-imported by the
next pull → it **reappears** (as a confirmed transaction). `PendingNotificationActions`
replay can't help: it calls the routed repo delete, but `getById` returns null
(row already gone) so no tombstone is ever enqueued.
**Affected files:** `local_notification_service.dart:970-1011`,
`ledger_push_service.dart` (`_pushCreate`), `pending_notification_actions.dart`,
`app_shell.dart` (`_drainPendingNotificationActions`).
**Impact:** Ghost transactions — a user dismisses a capture, it comes back;
balances/reports wrong. **This is a regression introduced by making captures
enqueue** (before, nothing was on the server to resurrect).
**Reproducibility:** High — capture (review) → lock phone → dismiss from the
notification → wait for a sync cycle → transaction returns.
**Confidence:** 85% (mechanism traced; exact ordering of replay vs push both
lead to the same server state).
**Fix:** In `_runBackgroundAction`, also delete the matching `ledger_sync_outbox`
row (or mark a tombstone) so a dismissed capture never pushes; or make the
outbox push skip items whose local row no longer exists AND enqueue a delete.
**Complexity:** Medium.

### C2 — Hardcoded `Asia/Riyadh` timezone for all scheduling
**Root cause.** `initialize()` calls
`tz.setLocalLocation(tz.getLocation('Asia/Riyadh'))`, and planning uses
`RiyadhTime.toRiyadh(...)`. Every `zonedSchedule` (streak 20:00, weekly 09:00 Sat,
bill reminders 10:00, quiet-hour deferrals) is computed in Riyadh time, not the
device's timezone.
**Affected files:** `local_notification_service.dart:131`,
`notification_planner.dart` (all `DateTime`/`nextAllowedRiyadh`), `app_shell.dart`
(`RiyadhTime.toRiyadh`).
**Affected entities:** streak, weekly report, bill/subscription reminders, quiet
hours.
**Impact:** Every scheduled notification fires at the wrong local time for any
user outside UTC+3 — e.g. the current Egypt (UTC+2) user gets them 1h off; Gulf
edge and further-away users worse. Quiet-hours are computed in the wrong zone, so
"do not disturb" is misaligned.
**Reproducibility:** 100% for non-Riyadh devices.
**Confidence:** 95%.
**Fix:** Use the device's local timezone (`flutter_timezone` to get the IANA name,
then `tz.setLocalLocation`) and schedule in device-local time; keep Riyadh only as
a fallback.
**Complexity:** Medium.

---

## 🟠 HIGH

### H1 — Android scheduled notifications silently fail on Android 13/14/15
**Root cause.** The manifest declares only `POST_NOTIFICATIONS` (+ `USE_BIOMETRIC`).
It is **missing `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`**, yet every schedule uses
`AndroidScheduleMode.exactAllowWhileIdle`. On Android 14+ (target 34) exact alarms
aren't granted by default → `zonedSchedule` throws `exact_alarms_not_permitted`,
which the `try/catch` swallows (recorded as "failed", no user-visible error).
**Affected files:** `android/app/src/main/AndroidManifest.xml`,
`local_notification_service.dart` (`scheduleStreakReminder`,
`schedulePlannedNotifications`, `_show` quiet-hour branch).
**Impact:** Streak, weekly report, bill/subscription reminders, and quiet-hour-
deferred alerts **never fire** on modern Android. (Immediate `plugin.show`
captures still work.) **CRITICAL if Android is a shipping target.**
**Reproducibility:** 100% on Android 14+.
**Confidence:** 90%.
**Fix:** Add the permission (or `USE_EXACT_ALARM` if eligible), request it at
runtime, or downgrade non-time-critical reminders to `inexactAllowWhileIdle`.
**Complexity:** Low (manifest) + Medium (runtime request UX).

### H2 — Android scheduled notifications lost after reboot
**Root cause.** Missing `RECEIVE_BOOT_COMPLETED` permission (and the plugin's
boot receiver) → the OS clears alarms on reboot and nothing reschedules until the
app is next opened.
**Impact:** After a phone restart, all pending reminders vanish until the user
reopens the app. (iOS persists scheduled local notifications across reboot, so
iOS is unaffected.)
**Reproducibility:** 100% on Android after reboot.
**Confidence:** 85%.
**Fix:** Add `RECEIVE_BOOT_COMPLETED` + the plugin's `ScheduledNotificationBootReceiver`.
**Complexity:** Low.

### H3 — Notification IDs not 32-bit-clamped → Android drop
**Root cause.** `showReviewNotification` (`id: transactionId.hashCode`),
`showBudgetAlert` fallback and `showAchievementNotification`
(`title.hashCode ^ body.hashCode`), and the growth-campaign path
(`campaign.id.hashCode`) pass raw Dart hashCodes. Dart `String.hashCode` can
exceed 2³¹; the Android plugin reads the id as a Java `Integer`, so a >32-bit id
throws (Long→Integer) and the notification is dropped. `showLightCaptureNotification`
*does* clamp (`.remainder(1 << 31)`), and the planner uses a 32-bit SHA-256 id —
so the codebase already knows this, but the fix wasn't applied consistently.
**Affected files:** `local_notification_service.dart:216,380,409`,
`notification_journey_service.dart:107`.
**Impact:** Some review/budget/achievement/campaign notifications silently fail on
Android depending on the hash value.
**Reproducibility:** Value-dependent (~50% of hashes exceed 2³¹).
**Confidence:** 75%.
**Fix:** Route every id through one canonical 32-bit generator (see Phase 4).
**Complexity:** Low.

### H4 — Financial PII exposed on the lock screen
**Root cause.** Capture notifications put the **amount + currency in the title**
and **amount/merchant/card in the body** (`capture_notification_content.dart`
`_amountLine`/`_detailsBlock`), and no channel sets
`visibility: VISIBILITY_PRIVATE/SECRET` (Android) nor any preview-hiding hint
(iOS). So transaction amounts and merchants render on the lock screen.
**Impact:** A locked, unattended phone leaks financial data (amounts, where the
user spends). For a finance app this is a privacy/compliance concern.
**Reproducibility:** 100% (default lock-screen preview settings).
**Confidence:** 90%.
**Fix:** Android channels `setVisibility(private)` + a redacted public version;
iOS keep sensitive detail out of title, rely on "hidden previews", consider
`interruptionLevel` and not surfacing the amount until unlocked.
**Complexity:** Low–Medium.

---

## 🟡 MEDIUM

### M1 — Duplicate light-capture notifications (non-idempotent id)
`showLightCaptureNotification` keys on `DateTime.now()...` — not the
transaction/payload. If the same capture is notified from both the background
processor and the foreground relay path (or re-surfaced), the two notifications
**don't collapse** (unlike the review path, which keys on `transactionId.hashCode`).
Confidence 70%. Fix: key light captures on the payload/transaction id. Complexity: Low.

### M2 — Achievement notifications are dead code
`showAchievementNotification` is never called in production (only a test) —
gamification moved to Supabase edge functions and the local trigger was never
wired. The channel/method exist but users never receive achievement alerts.
Confidence 90%. Fix: wire it to the gamification result or remove it. Complexity: Low.

### M3 — Bill vs goal notification-id ranges overlap
`billReminderNotificationId` → `[92000, 992000)`, `goalMilestoneNotificationId`
→ `[93000, 993000)`. The overlap `[93000, 992000)` allows a delivered goal
milestone and a bill reminder to share an id and replace each other. Low
probability but unbounded as bills+goals grow. Confidence 80%. Fix: disjoint
bases/ranges. Complexity: Low.

### M4 — iOS `aps-environment` is a build variable
Entitlement is `$(APS_ENVIRONMENT)`. If the release build doesn't resolve it to
`production`, APNs push (the iOS capture delivery path) fails silently in
production/TestFlight. Needs build-config verification. Confidence 60% (config
not visible here). Fix: confirm xcconfig sets `production` for Release.
Complexity: Low (verify).

### M5 — Every shown notification writes inbox history → DB churn
`_show` → `_recordHistory` writes `user_settings.inboxState` for every
non-marketing notification. Each write ticks `dbRevisionProvider` (see the
separate flicker finding), so a burst of captures compounds UI reloads.
Confidence 70%. Fix: batch/skip history writes or exclude from the revision
signal. Complexity: Medium.

### M6 — No silent-push background mode (iOS)
Info.plist has no `UIBackgroundModes: remote-notification`. If any capture path
relies on a silent (content-available) push to process in the background, it
won't wake the app. If delivery is purely user-visible APNs alerts, this is moot.
Confidence 55% (design-dependent). Fix: add the mode only if silent push is used.
Complexity: Low.

---

## 🟢 LOW

- **L1** `schedulePlannedNotifications` cancels every pending id in `[92000, 992000)`
  before re-planning. Only bill reminders currently schedule into that range, so
  it's safe today, but any future scheduled type landing there would be wiped.
- **L2** `title.hashCode ^ body.hashCode` collides for two notifications with
  identical text (achievements/budget fallback) — one silently replaces the other.
- **L3** Stale comment at `app_shell.dart:~730` says streak/weekly/bill "stopped
  firing entirely" although the code directly below schedules them — misleading
  for maintainers.
- **L4** Streak (`88008`) and weekly (`91001`) use constant ids — correct for a
  single device, but two installs of the same account can't be distinguished
  (not an issue for local notifications).

---

## What's solid (challenge / balance)

- **Tracking pipeline is robust**: created→sent/failed→opened, best-effort, never
  blocks or crashes the show path; payload decode is defensive.
- **Review notification id is idempotent** per transaction (re-show replaces, no dup).
- **Planner uses SHA-256** (deterministic, version-stable) for bill/goal ids —
  the right call; the gap is that `LocalNotificationService` didn't adopt it
  everywhere (H3).
- **Marketing has real dedup**: 24h cooldown + journey-sent flags +
  once-per-user/max-impressions/cooldown for campaigns → no spam.
- **Background actions are durable**: recorded for replay so a locked-device
  action isn't lost (the flaw is the outbox interaction in C1, not the replay).
- **Quiet-hours deferral** exists and capture notifications correctly bypass it.

---

## Production-readiness verdict (100k users)

Blockers before a broad release: **C1** (ghost transactions), **C2** (wrong-time
scheduling for all non-Riyadh users), **H4** (lock-screen PII). If Android ships:
**H1/H2/H3** are hard blockers (scheduled notifications broken/lost/dropped).
The capture *alert* path (immediate `plugin.show`) is sound on iOS; the
scheduled/reminder and background-action paths are where the risk concentrates.
