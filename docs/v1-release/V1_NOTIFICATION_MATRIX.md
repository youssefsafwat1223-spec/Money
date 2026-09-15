# V1 Notification Matrix

Every notification the product can emit, with what proves it. Measured against
HEAD on 2026-09-15.

## 1. Inventory

`NotificationType` carries ten values. Four are scheduled locally through
`NotificationPlanner`; the rest are event-driven.

| Type | Trigger | Scheduled? | Id | Preference | Evidence |
|---|---|---|---|---|---|
| `dailyReminder` | 22:00 device-local, daily | yes | fixed `91002` | `dailyReminder` (default ON) | `test/domain/daily_reminder_test.dart` — 9 cases |
| `weeklyReport` | Saturday 09:00 device-local | yes | fixed `91001` | `weeklyReport` | `test/domain/notification_planner_test.dart` |
| `subscriptionReminder` | day before a bill is due, 10:00 | yes | derived `[92000, 992000)` | `subscriptionReminder` | `notification_planner_test`, `notification_stable_id_test` |
| `goalMilestone` | crossing 25/50/75/100% | on event | derived `[1000000, 1900000)` | `goalMilestone` | `notification_planner_test` |
| `captureReview` | a capture needs confirmation | on event | derived | `captureReview` | `capture_notification_authority_test`, `capture_notification_content_test` |
| `captureLight` | a capture was auto-confirmed | on event | derived | `captureLight` | as above |
| `budgetWarning` | 80% of a budget | on event | derived | `budgetWarning` | `notification_planner_test` |
| `budgetOver` | budget exceeded | on event | derived | `budgetOver` | `notification_planner_test` |
| `achievements` | an achievement unlocks | on event | derived from the achievement key | `achievements` | `notification_stable_id_test` |
| `marketing` | announcements / campaigns | on event | derived | `marketing` | `notification_log_service_test` |
| ~~`streakReminder`~~ | **RETIRED in V1** | — | `88008`, cancellation handle only | removed | `test/architecture/streak_reminder_retired_test.dart` |

## 2. The V1 changes

### Daily reminder at 22:00 — VERIFIED

The app had no daily reminder of its own to retime. `cron-daily-reminders` is
retired server-side (`supabase/functions/cron-daily-reminders/index.ts` returns
`{status:'retired', authority:'local_scheduled_reminders'}`) and its own comment
names the local streak reminder at 20:00 as the authority. So the 20:00 streak
nudge WAS the daily reminder; V1 retires it and adds a real one at 22:00.

Proven: fires at 22:00 and not 20:00; never scheduled into the past; exactly
22:00 counts as passed so it cannot double-fire; the setting disables it; quiet
hours defer it rather than delivering inside them; the id is stable across
re-plans so rescheduling replaces rather than stacks; sign-out cancels it; it
appears in the normal scheduled sweep; the preference defaults ON for installs
predating the field.

### No stale schedule from the old time — VERIFIED

Deleting a scheduler does not unschedule anything: the OS keeps what it holds.
`cancelRetiredStreakReminder()` runs on every planning cycle, and `88008` stays
in `isManagedReminderId` so sign-out clears it too. An architecture test blocks
any production file from scheduling it again.

## 3. What is NOT proven, and why

| Claim | Status |
|---|---|
| Real APNs delivery to a physical device | **BLOCKED — hardware only.** Simulator cannot receive production push. Never claimed from Simulator evidence. |
| OS-level delivery at 22:00 wall-clock | **BLOCKED — hardware/time.** What is proven is the scheduled instant the planner computes. |
| Tap routing from a delivered notification | **TESTED WITH MOCKS** — `background_notification_action_test.dart` drives the payload handler directly; the OS tap itself is device-only. |
| Timezone change / DST while a reminder is pending | **UNVERIFIED.** The planner computes in device-local time each cycle, so a re-plan corrects it, but nothing asserts behaviour across an actual zone change. |
| Permission-denied behaviour | **TESTED WITH MOCKS** — the plugin fails naturally in a bare test VM, which the logging pipeline records as created→failed. |

`BLOCKED` is not `PASS`. These stay open against the physical-device matrix.

## 4. Privacy

`redactedContentFor` returns a generic title and body per type, so a lock-screen
preview never carries a merchant or an amount. Covered by
`test/features/capture/notification_privacy_test.dart`. The retired streak
entry was removed from that switch along with the feature.
