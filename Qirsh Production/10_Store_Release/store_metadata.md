# Store Metadata

## Shared

| Field | Value |
|---|---|
| App name | Qirsh / قرش |
| Category | Finance |
| Primary language | Arabic |
| Privacy policy | `https://<host>/privacy` |
| Terms | `https://<host>/terms` |
| Support contact | your support address |

## Screenshots

Real device, realistic Arabic data.

**Never screenshot real bank messages, real account numbers, or a real person's
name.** Use seeded demo data.

| Store | Required |
|---|---|
| App Store | 6.7" and 6.5" iPhone |
| Play | phone; tablet optional; feature graphic 1024×500; icon 512×512 |

## Description — what to lead with

Qirsh reads incoming bank **SMS** on the device to build a private spending
record.

> **CORRECTED 2026-09-03.** This previously said "bank SMS **and
> notifications**". Qirsh has **never** had notification access — there is no
> `NotificationListenerService` and no `BIND_NOTIFICATION_LISTENER_SERVICE`, and
> `android_sms_permission_test.dart` asserts their absence precisely because the
> documentation claimed one for months. Claiming it in store-facing copy would
> describe a second restricted permission the app does not request, and the
> in-app trust notice tells users the opposite ("it does not read bank app
> notifications").

The differentiators worth stating:

- works offline; financial data stays on the device in an encrypted database
- cloud sync is **optional and off by default**
- the AI classifier runs **on the device** — no message text is sent anywhere
- Arabic-first, built for Gulf and Egyptian bank formats

Do not claim end-to-end encryption. The app does local-database encryption; the
policy says exactly that and the store listing must not overreach.

## Review notes — both stores

Reviewers cannot receive real bank SMS. Provide:
- a demo account
- how to trigger a capture manually (paste/share a sample message)
- a plain explanation that **automatic incoming bank-SMS capture** is the app's
  core function (Android only; `RECEIVE_SMS`, never `READ_SMS`). Notification
  access is NOT used and must not be mentioned.

## Age rating

No objectionable content. Finance category, general audience.
