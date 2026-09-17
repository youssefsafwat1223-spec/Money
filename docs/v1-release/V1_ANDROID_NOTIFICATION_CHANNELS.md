# Android notification channels — why the ids are language-suffixed

Audit item 17. Previously **NOT DONE**, with the note "Android keeps a
channel's name for the install's lifetime; re-localizing needs a new channel
ID. A deliberate decision, not a sweep." This is that decision, made.

## The constraint

Android stores a notification channel's **name** the first time the channel is
created and keeps it for the lifetime of the install. Passing a different name
with the same id on a later `notify()` is silently ignored — no error, no
warning, the old name simply stays.

Every Qirsh channel was created with an Arabic name. So a user running the app
in English saw this in Settings → Notifications:

| What they saw | What it should say |
|---|---|
| تأكيد العمليات | Confirm transactions |
| تنبيهات الميزانيات | Budget alerts |
| التذكير اليومي | Daily reminder |
| تذكير الفواتير | Bill reminders |

No amount of translating a Dart string changes this. The name is already in
the OS.

## The three options, and why this one

### 1. Delete the channel and recreate it with the new name — REJECTED

Android allows it (`deleteNotificationChannel` then create). It also discards
every per-channel setting the user made: importance, sound, vibration, and
**whether they muted it**.

Every existing install of Qirsh is Arabic. Renaming by deletion would silently
un-mute channels people deliberately turned off, for a cosmetic gain they did
not ask for. That is a worse outcome than a wrong-language label.

`android_notification_channels_test` asserts `deleteNotificationChannel` does
not appear, so this cannot be reintroduced as a quiet shortcut.

### 2. Language-neutral names — REJECTED

"Channel 1", or an untranslated brand-ish token. Makes the Settings list
useless in *both* languages rather than wrong in one. The whole point of a
channel is that a person can find it and turn it off.

### 3. Language-suffixed ids — SHIPPED

The **existing ids keep their existing Arabic names and are now the Arabic
channels**. English gets `<id>_en`.

```dart
String _channel(String base) =>
    notificationLanguage == 'en' ? '${base}_en' : base;
```

| Language | Channel id | Name |
|---|---|---|
| Arabic (unchanged) | `budget_alerts` | تنبيهات الميزانيات |
| English | `budget_alerts_en` | Budget alerts |

What this buys:

* **Existing installs are untouched.** Same ids, same names, every mute and
  importance preserved. There is no migration to get wrong.
* **English users get English names** from their first notification.
* **Switching language switches channel set**, and switching back restores
  that language's settings, because the other language's channels are *not*
  deleted.

What it costs: a user who switches language leaves an unused channel behind in
the system Settings list. That is the trade — an extra Settings row against
losing the user's own choices. The row is inert; the lost choice is not.

## What was NOT constrained, and was fixed immediately

**Action button labels are per-notification, not per-channel.** Android reads
them from each post. `تأكيد ✓` / `تجاهل` were always free to follow the
reader's language and simply did not. They now do.

**Channel descriptions** are stored with the name and carry the same
constraint; each language's channel carries its own description, and the test
fails on any description that is Arabic in every language.

## Channels covered

All nine: `capture_review`, `capture_light_v2`, `qirsh_growth`,
`budget_alerts`, `achievement_alerts`, `weekly_reports`, `daily_reminders`,
`bill_reminders`, `goal_milestones`.

## Evidence

`test/features/capture/android_notification_channels_test.dart`. It is a
source test, deliberately: the claims are about identifiers and about what the
code must **not** do, and neither is visible to a Dart widget test — there is
no Android channel registry in one, and the failure mode ("someone passes a
localized name with a stable id and assumes Android uses it") only manifests
on a real Android install.

It asserts:

| # | Assertion | What it prevents |
|---|---|---|
| 1 | every channel id keeps its existing value | an invisible migration that resets users' settings |
| 2 | no `AndroidNotificationDetails` bypasses `_channel()` | an Arabic-named channel shown to an English user |
| 3 | the channel-call count equals the notification-details count | a new notification type added without a language-aware id |
| 4 | the Arabic branch returns the id verbatim | migrating every existing install off its configured channels |
| 5 | action labels follow `notificationLanguage` | the one part that was never constrained regressing |
| 6 | `deleteNotificationChannel` does not appear | the rejected option returning as a shortcut |
| 7 | no `channelDescription` is Arabic in every language | a half-migration: English names, Arabic subtitles |

## What remains unproven

The channel NAME as rendered in the Android Settings list has not been read
off a screen. Verifying it requires installing in English, posting one
notification per channel, and opening Settings → Notifications → Qirsh — which
needs a human looking at a device. The id/name wiring is proven; the OS's
rendering of it is asserted from the documented Android contract, not
observed.
