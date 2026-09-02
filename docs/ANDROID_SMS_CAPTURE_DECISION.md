# Android SMS Capture Decision

**Status: ENABLED and reachable. Publication gated on Google Play approval.**

This document previously said the opposite — "intentionally disabled for MVP",
"`AndroidManifest.xml` does not declare `READ_SMS`, `RECEIVE_SMS`, or an SMS
broadcast receiver". All three claims became false when automatic capture was
implemented, and the document was never revised. It is superseded by the owner
decision of 2026-08-31 recorded in
`Qirsh Production/18_Android_SMS_Capture/README.md`: automatic financial-SMS
capture is a **required core feature of Android V1**, and the earlier
"Play-safe, share-only" position is **revoked**.

## What the build actually contains

| | |
|---|---|
| `RECEIVE_SMS` | **declared**, unconditionally (`AndroidManifest.xml`) |
| `READ_SMS` / `SEND_SMS` / `WRITE_SMS` / `RECEIVE_MMS` / `RECEIVE_WAP_PUSH` | **absent** — the receiver reads broadcast intents and never touches `content://sms` |
| `SmsCaptureReceiver` | **registered**, `android:permission="android.permission.BROADCAST_SMS"` so only the OS can deliver to it |
| Prominent disclosure | **implemented** and shown immediately before the system dialog |
| User opt-in | **implemented** — Settings → «رصد العمليات» → automatic bank-SMS capture |
| Privacy policy §8 | **LIVE** at `qirsh.site/privacy` and `/en/privacy` |
| Play permissions declaration | **draft ready, NOT submitted** |
| Google Play approval | **PENDING — do not publish without it** |
| Physical-device SMS QA | **PENDING** |

## The two-key lock

A granted permission is not consent:

```
RECEIVE_SMS granted   AND   CaptureSettings.autoCaptureEnabled == true
```

`SmsCaptureReceiver.onReceive` returns before touching the intent unless the
opt-in is true. The opt-in defaults to false, is set only by an explicit user
action after the disclosure, and is reset on identity change so one user's
consent is never inherited by the next. Revoking the OS permission fails capture
closed on the next check.

## What was missing until 2026-09-02

The native receiver, the permission state machine, the Dart facade and the
disclosure widget were all complete and tested — and **nothing called them**.
There was no UI through which a user could turn the feature on, while the app
shipped the restricted permission and a live receiver anyway.

That is the failure mode Play's core-functionality test exists to catch, and it
also meant the Settings screen told users «لا يقرأ … رسائل SMS من النظام» ("does
not read system SMS") while the binary declared the opposite intent. Both are
fixed: the toggle exists, the copy is accurate, and
`test/features/capture/android_sms_permission_test.dart` now contains a
reachability group that fails if either the service or the disclosure ever loses
its last production caller.

## Still required before publishing

1. Physical-device QA — the matrix in
   `Qirsh Production/18_Android_SMS_Capture/device_qa_plan.md`. No Android
   device has ever been attached to this machine.
2. Submit the Play permissions declaration and the Data Safety form (both
   drafted, neither submitted).
3. Reconcile the declaration draft's "no SMS text reaches an AI provider" claim
   with the Data Safety draft's optional sanitized-text path and the live
   privacy policy's optional cloud/AI section, so all three say the same thing.
4. Google Play approval.
