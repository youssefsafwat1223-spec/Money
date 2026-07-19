# Notification Pipeline Audit

Investigation-only. No code was modified. No commits were created.

## Executive Summary

The app sends notifications through two independent paths — **local notifications**
scheduled entirely on-device (`flutter_local_notifications`), and **one real remote-push
path** (APNs, sent server-side from the `process-ios-sms` Edge Function after an iOS
Shortcut relays a captured bank SMS). Both paths work today, but **there is no
production-grade tracking system**: no `notification_logs` table, no unified
Pending→Queued→Sent→Delivered→Opened→Failed state machine, no retry-count field, no
open/tap event ever reported back to the server, and no Sentry wiring in the
notification code specifically. Failure visibility is a patchwork of `debugPrint`
(stripped in release), two ad-hoc status columns on an unrelated table, and a local,
unsynced JSON blob capped at 80 entries.

**Notifications can and do silently fail today without being detectable** — see
section 6.

## 1. Current Architecture

### 1.1 Notification creation

Two origins:
- **Client-scheduled** (`lib/features/capture/services/local_notification_service.dart`):
  budget alerts, achievement badges, streak reminders, weekly report reminders, bill
  reminders, goal milestones, marketing/journey campaigns, and the capture
  review/light notifications shown right after a transaction is captured in-app. All
  of these are created and shown/scheduled by the Flutter app itself, calling
  `flutter_local_notifications`' `_plugin.show()` / `_plugin.zonedSchedule()`.
- **Server-created, server-sent** (`supabase/functions/process-ios-sms/index.ts`):
  when an iOS Shortcut relays a captured bank SMS to the backend, the Edge Function
  parses it, builds a notification payload (title/body), and — if the device has a
  registered APNs token — sends it directly via Apple's APNs HTTP/2 API
  (`supabase/functions/_shared/apns.ts`), independent of whether the app is running.

### 1.2 Queueing

- **No formal queue anywhere.** The Edge Function send is synchronous and inline
  inside the SMS-processing request (`process-ios-sms/index.ts`, calls
  `sendApnsIfPossible()` directly in the same request that parses the SMS).
- The only queue-like structures are recovery buffers, not send queues:
  - `PendingNotificationActions` (Dart, file-based) — Confirm/Dismiss actions that
    failed to apply from a locked-device background tap; replayed on next app open.
  - `SharedCaptureStore`'s `pending_bank_messages_v2` (iOS native, App Group
    UserDefaults) — captured SMS payloads awaiting backend send/retry, with a
    `pending`/`pendingSend`/`sent`/`failed` status field per payload.
  - `pending_notification_routes_v1` (iOS native) — notification taps waiting for
    Flutter to consume them, capped at 10, rotated on overflow.

### 1.3 Scheduling

- Local notifications: `_plugin.zonedSchedule()` with Asia/Riyadh timezone data,
  quiet-hours logic (`_isQuietHour`/`_nextAllowedDate`), and explicit ID ranges to
  cancel/replace previously scheduled ones (`schedulePlannedNotifications`).
- No server-side scheduler for push: no pg_cron job sends notifications. The only
  pg_cron job found (`supabase/migrations/0033_capture_pipeline_hardening.sql`,
  `prune-processed-captures-daily`, 03:15 UTC) is data retention cleanup, unrelated to
  sending.

### 1.4 Sending

- Local: `FlutterLocalNotificationsPlugin.show()`/`zonedSchedule()` — OS-level,
  fire-and-forget from Dart's perspective; the plugin call either returns or throws,
  there's no further confirmation.
- Remote: `process-ios-sms/index.ts` → `_shared/apns.ts` — builds a JWT (ES256,
  cached ~20 min), POSTs to `api.push.apple.com` or `api.sandbox.push.apple.com`
  depending on the token's registered environment. This is the **only** real
  server-triggered push in the app.

### 1.5 Delivery tracking

- **APNs gives no delivery confirmation via the HTTP/2 API** (this is a protocol
  limitation, not a gap in this app specifically — Apple doesn't tell senders when a
  device actually receives a push).
- What the app *does* record: `processed_captures.apns_push_sent_at` (timestamp of a
  successful POST to Apple) and `processed_captures.apns_push_error` (the error
  string on failure, e.g. `apns_400_BadDeviceToken`). This is "did we hand it to
  Apple," not "did the device receive it."
- Local notifications have no delivery tracking at all — `_show()` calls
  `_recordHistory()` right after `_plugin.show()`/`zonedSchedule()` succeeds, which is
  "we told the OS to show/schedule it," not confirmation of anything further.

### 1.6 Open tracking

- **Never reported to the backend, on either platform path.**
- iOS native: a tap on a push is captured in `SharedCaptureStore`'s
  `pending_notification_routes_v1` (App Group UserDefaults, capped at 10 entries) and
  handed to Flutter via the `pendingNotificationRouteAvailable` method-channel
  callback purely to route the user to the right screen. Nothing about the tap is
  ever sent anywhere.
- Local notifications: `LocalNotificationService._handleNotificationPayload()`
  dispatches the tap to `CaptureRuntime` for in-app routing (open a confirm sheet,
  navigate, apply a quick action) — again, routing only, no "opened" event recorded
  anywhere durable, local or remote.

### 1.7 Failure handling

- Client (Dart): `_show()` and friends do **not** wrap `_plugin.show()`/
  `zonedSchedule()` in a try/catch. An exception propagates to the caller. Several
  callers invoke the journey/campaign evaluation via `unawaited(...)`
  (`app_shell.dart`), so a thrown exception there becomes an **unhandled async
  error** — likely picked up by Sentry's zone (Sentry is initialized app-wide in
  `main.dart`), but with no notification-specific context attached (no "this was a
  budget-alert send for user X" tagging).
- Client (iOS native, Shortcuts path): `BankMessageShortcuts.swift` uses `try?` around
  `UNUserNotificationCenter.current().add(notifRequest)` in at least two places (the
  backend-response path and the on-device-parser fallback path) — a failed local
  notification schedule is **silently swallowed**, no log, no retry, no user-visible
  error, even though the underlying transaction was still recorded.
- Server: `process-ios-sms/index.ts` catches APNs send failures and writes the reason
  to `apns_push_error`, plus a structured console log line (`capture_apns_failed`).
  That's the extent of it — no alerting, no retry, no dashboard.

### 1.8 Retry logic

- Server: `process-ios-sms` has exactly one retry path — the *App Intent's* client
  side retries once on a timeout-shaped network error
  (`BankMessageShortcuts.swift`, `processBackend()`), not the push send itself. A
  failed APNs send (e.g. expired token, malformed payload) is **never retried** —
  the row just sits with `apns_push_error` set.
- Local notifications: no retry concept applies (they either show or throw).

### 1.9 APNs

Fully described above (1.1, 1.4, 1.7, 1.8). Token lifecycle:
`AppDelegate.swift` obtains the device token → stored in the App Group
(`SharedCaptureStore.setApnsToken`) and pushed to Flutter over the
`money_companion/native_capture` method channel →
`CaptureDeviceRegistrationService.syncApnsToken()` → Edge Function
`register-push-token` → stored on `capture_devices.apns_token` /
`apns_environment` / `token_updated_at`. Registration failures
(`didFailToRegisterForRemoteNotificationsWithError`) are logged to UserDefaults and
reported back to Flutter via an `apnsRegistrationFailed` callback — this specific
failure mode **is** visible, unlike most others in this pipeline.

### 1.10 Android notifications

- `flutter_local_notifications` is configured for Android (channels for review,
  light-capture, marketing, budget, achievements, streak, weekly report, bill
  reminder, goal milestone — all in `local_notification_service.dart`), and
  `POST_NOTIFICATIONS` is declared in `AndroidManifest.xml`.
- **No Firebase Cloud Messaging, no remote push capability of any kind on Android.**
  `pubspec.yaml` has no `firebase_messaging` dependency. Everything an Android user
  receives is a locally-scheduled notification triggered while the app itself runs
  (foreground or a background isolate the app controls) — there is no equivalent to
  the iOS Shortcut → Edge Function → APNs path for Android. This is a platform gap,
  not just a tracking gap: Android users get no server-triggered "your bank SMS was
  captured" push at all today, only local reminders.

### 1.11 Supabase Edge Functions (16 total, confirmed)

Notification-relevant: `register-push-token`, `register-device`, `process-ios-sms`
(the actual sender), `link-capture-device`, `unlink-capture-device`. Not
notification-related: the `catalog-*` functions, `parser-test`, `parse-sms`,
`sync-captures`, `enrich-merchant`, `bank-discovery`, `merchant-feedback`,
`purge-scheduled-deletions`. (CLAUDE.md's Supabase setup section only documents the
`catalog-*` + `parser-test` functions — the capture/push functions exist and are
deployed but aren't listed there.)

### 1.12 iOS Shortcuts / App Intents

`ios/BankMessageShortcuts/BankMessageShortcuts.swift` — `PostBankStatusIntent`
(iOS 16+, background-eligible on iOS 26+). Posts the SMS to `process-ios-sms`; if the
backend didn't already send a push (e.g. cloud processing disabled, or the send
failed), the Shortcut extension itself schedules a **local** notification on-device
as a fallback, using either the backend's returned title/body or an on-device regex
parser (`PreviewParser`) if the backend call fails outright. This fallback path is
exactly where the silent `try?` failures in 1.7 live.

### 1.13 Background processing

- `sms_background_handler.dart` (`@pragma('vm:entry-point')`) is a **no-op stub**
  (`return;`) — not currently doing anything.
- `LocalNotificationService._backgroundTapHandler` (also `@pragma('vm:entry-point')`)
  handles Confirm/Dismiss notification actions tapped while the app is closed —
  opens a *second*, independent `AppDatabase` connection to apply a best-effort local
  update, and durably records the action via `PendingNotificationActions` for replay
  on next app open (this exact mechanism, and its interaction with app resume, was
  the subject of the separate stale-UI investigation/fix in
  `docs/STALE_UI_ROOT_CAUSE_REPORT.md`).
- On the native iOS side, there is **no**
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` and **no**
  `UNNotificationServiceExtension` — a silent/background push cannot currently wake
  the app or mutate a payload before display. Every push the app sends today is a
  standard alert push shown by the OS; nothing runs app code in response to it unless
  the user taps it.

## 2. Does a notification tracking system exist today?

**No — not a production-grade one.** What exists is three disconnected, partial
fragments:

1. `NotificationInboxState.history` (`lib/domain/entities/engagement_entities.dart`) —
   a client-local, unsynced JSON array (max 80 entries) inside user settings, with
   only `id`, `kind`, `title`, `body`, `sentAt`, `route`. No status, no
   delivered/opened timestamps, no failure reason, no retry count. Writing to it is
   itself wrapped in a silently-swallowed try/catch.
2. `processed_captures.apns_push_sent_at` / `apns_push_error`
   (Postgres, `supabase/migrations/0013_ios_capture_apns.sql`) — two columns bolted
   onto the SMS-processing table, not a notification-log table, and only covers the
   one server-push path (nothing for local notifications, nothing for Android).
3. `SharedCaptureStore`'s local queues (iOS native, App Group UserDefaults) — capture
   payload status and notification-route history, entirely on-device, never
   synchronized to the backend.

None of the three has a shared schema, a shared ID space, or a shared status
vocabulary. There is no single place — in the app, in Postgres, or in the admin
panel — where you could currently answer "how many notifications did we send this
week, how many were delivered, how many were opened, and what failed."

## 3. Can notifications silently fail today without being detectable?

**Yes**, in every layer:

- **iOS native (Shortcuts fallback path):** `try?` around
  `UNUserNotificationCenter.add(notifRequest)` in `BankMessageShortcuts.swift` — a
  failed local-notification schedule produces no log, no retry, no user-visible
  error. The underlying transaction is still saved, so the user simply never finds
  out a notification was supposed to appear.
- **iOS native (regex parser):** `try? NSRegularExpression(pattern:)` — a broken
  parser rule silently falls back to a generic notification with no error surfaced
  anywhere.
- **Dart client:** `_show()`/`showMarketingNotification()`/etc. don't catch
  `_plugin.show()`/`zonedSchedule()` exceptions; several call sites are
  `unawaited(...)`, turning a thrown exception into an unhandled async error with no
  notification-specific Sentry context (if it's captured by Sentry's zone at all —
  not verified end-to-end in this audit).
- **Dart client (history log):** `_recordHistory()`'s own failure is caught and
  discarded by design ("السجل ثانوي" — "the log is secondary") — so even the one
  local record of "we sent this" can silently not happen.
- **Server:** a failed APNs send is logged to `apns_push_error` and a console line,
  but nothing polls or alerts on that column — an expired token, a revoked
  certificate, or a malformed payload would fail forever, invisibly, until someone
  manually queries the table.
- **Everywhere:** there's no delivery or open confirmation loop at all, so even a
  "successfully sent" push has no way to prove a human ever saw it.

## 4. Proposed Production-Grade Notification Logging Architecture

This is a proposal only — nothing below has been implemented.

### 4.1 `notification_logs` table (Postgres)

```sql
create table notification_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  install_id text not null,
  notification_type text not null,        -- 'capture_review','capture_light','budget_alert',
                                            -- 'achievement','streak','weekly_report','bill_reminder',
                                            -- 'goal_milestone','marketing','journey','apns_push', ...
  channel text not null,                   -- 'local_ios','local_android','apns'
  status text not null default 'pending',  -- pending | queued | sent | delivered | opened | failed
  payload jsonb not null default '{}',     -- title/body/route/transactionId etc. (no raw SMS text)
  related_entity_type text,                -- 'transaction','budget','goal', ...
  related_entity_id text,
  error_reason text,
  retry_count int not null default 0,
  device_platform text,                    -- 'ios' | 'android'
  apns_environment text,                   -- 'sandbox' | 'production', when channel = 'apns'
  created_at timestamptz not null default now(),
  queued_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,                -- best-effort; APNs has no delivery receipt, so this
                                            -- stays null for 'apns' unless a future feedback
                                            -- mechanism is added (e.g. a delivered-receipt push type)
  opened_at timestamptz,
  failed_at timestamptz
);

create index idx_notification_logs_user_status on notification_logs(user_id, status);
create index idx_notification_logs_type_created on notification_logs(notification_type, created_at desc);
create index idx_notification_logs_install on notification_logs(install_id);
```

### 4.2 Status lifecycle

`pending` → `queued` → `sent` → `opened` (with `delivered` as an optional
intermediate state only reachable where a platform actually confirms delivery) → or
→ `failed` from any pre-`sent` state, with `retry_count` incremented on each attempt
and `error_reason` set on the terminal failure.

### 4.3 Where each stage would be written

| Stage | Local notifications (Dart) | Server push (Edge Function) |
|---|---|---|
| pending/created | Right before calling `_plugin.show/zonedSchedule`, insert a row with a client-generated log id | On receiving a capture that will produce a notification, before calling `sendApnsIfPossible` |
| sent | After `_plugin.show/zonedSchedule` returns without throwing | After the APNs POST returns 2xx (mirrors today's `apns_push_sent_at`, but in the shared table) |
| failed | In a **new** try/catch around the plugin call (currently missing) | Existing `apns_push_error` catch, additionally writing to `notification_logs` |
| opened | New: `_handleNotificationPayload`/native tap handlers make one lightweight authenticated call to a new `record-notification-open` Edge Function (or a batched sync, given intermittent connectivity) with the log id | Same endpoint, called from the client on tap — delivery itself has no platform-level confirmation, so "opened" is the earliest real signal for a push |

### 4.4 Client-side plumbing

- `LocalNotificationService` gains a required `logId` on every call and wraps every
  `_plugin.show()`/`zonedSchedule()` in try/catch, writing `sent`/`failed` locally
  (Drift, synced opportunistically) rather than swallowing.
- The Shortcuts extension's two `try?` sites get replaced with `do/catch` that at
  minimum persist a failure into `SharedCaptureStore` (it already has the
  infrastructure — `failureReason` fields exist, just aren't populated for these two
  cases) and, ideally, POST a failure event to a lightweight endpoint next time the
  network is available.
- Tap/open handling (`_handleNotificationPayload`, native tap routing) fires a
  fire-and-forget "opened" call, non-blocking, never gating navigation on it.

### 4.5 Analytics support

With a single `notification_logs` table, funnel queries (`sent → opened` rate by
`notification_type`, by day, by platform) become plain SQL, and the admin panel
(`admin/`, which currently has no notification UI at all) can add a
`/notifications` page mirroring the existing `/flags`/`/announcements` pattern.

### 4.6 What this does *not* solve

- APNs still gives no delivery receipt — `delivered_at` is inherently best-effort
  and will likely stay null for the `apns` channel unless a future silent/background
  push + client callback pattern is added specifically to close that gap.
- Android still has no remote-push channel at all; `notification_logs` would only
  ever see `channel = 'local_android'` rows for that platform until FCM (or
  equivalent) is added — a schema addition doesn't add the missing capability.

## 5. Scope Note

This audit is investigation-only, per the request. Nothing in sections 1–3 was
changed. Section 4 is a proposal for the user to review and prioritize — no schema,
migration, Edge Function, or client code for it has been written.
