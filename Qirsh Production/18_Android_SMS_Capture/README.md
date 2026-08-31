# 18 — Android Automatic SMS Capture

**Owner decision, 2026-08-31: automatic financial-SMS capture is a REQUIRED
core feature of Android V1.** The earlier "Play-safe, share-only" position is
revoked.

| | |
|---|---|
| Play policy basis | **SMS-based money management** |
| Permission declared | **`RECEIVE_SMS` only** |
| Implementation | **complete** |
| Prominent disclosure | **implemented** |
| Legal disclosure (privacy policy §8) | **LIVE** — deployed to `https://qirsh.site/privacy` and `/en/privacy`, 2026-08-31 |
| Data Safety draft | **READY — NOT submitted** |
| Play Permissions Declaration | **draft ready — NOT submitted** |
| **Google Play approval** | **PENDING — do not publish to production without it** |
| Physical-device SMS QA | **PENDING** — matrix below |

---

## Why `RECEIVE_SMS` alone

`READ_SMS` is deliberately **not** declared. The receiver reads broadcast
intents (`SMS_RECEIVED_ACTION` → `getMessagesFromIntent`) and never touches
`content://sms`. Asking for inbox history the app never reads would enlarge the
declaration, weaken the "minimum necessary" argument, and invite questions we
have no feature to answer. `SEND_SMS`, `WRITE_SMS`, `RECEIVE_MMS` and
`RECEIVE_WAP_PUSH` are likewise absent — no feature needs them.

Asserted by test, over the **comment-stripped** manifest. That detail matters:
the permission sat commented out for months while a naive `grep` reported it as
present.

## The two-key lock

A granted permission is **not** consent.

```
RECEIVE_SMS granted   AND   CaptureSettings.autoCaptureEnabled == true
```

Both are required before a single message is read. The opt-in defaults to
`false`, is set only by an explicit user action after the disclosure, and is
reset on identity change so one user's consent is never inherited by the next.

`isAutoCaptureEnabled()` re-checks the OS permission on **every** call, so
revoking it in system settings stops capture immediately without the app being
involved.

## Disclosure → request ordering

Play requires the disclosure *immediately before* the system dialog. A dialog
shown first is a violation even if the user then grants it.

The ordering is **structural, not conventional**:

```dart
Future<SmsPermissionResult> requestAndEnable({
  required Future<bool> Function() showDisclosure,
})
```

The disclosure is a required parameter. There is no path through this method
that reaches `requestPermissions` without it returning `true`, and declining
returns before the request is made.

The disclosure asks for one thing only — no cloud sync, analytics or marketing
consent is bundled, because bundling is what makes a disclosure invalid.

## Privacy prefilter

Non-financial messages are dropped **in `onReceive`, before anything is
stored**. They never enter the durable queue, never persist, never leave the
device.

The rule is sender-aware:

| Sender | Rule | Why |
|---|---|---|
| Alphanumeric (`AlRajhiBank`, `stc pay`) | amount **OR** keyword | only businesses can send from a sender ID; a missed bank SMS is a silently absent transaction the user cannot correct |
| Numeric (`+9665…`) or absent | amount **AND** keyword | this is where personal messages come from |

That asymmetry fixes a real false positive: under the old flat
`amount OR keyword` rule, a friend texting *"bring your card"* was retained on
the word "card" alone. An absent sender takes the strict path — missing evidence
must not buy the loose rule.

One-time codes are dropped regardless of sender. Banks send OTPs from the same
sender ID as real alerts, and the app has no reason to hold credentials.

**The prefilter is not a parser.** It decides retention only; the authoritative
parse stays in the Dart engine. A test asserts no extraction symbols appear in
the receiver, because a second parser here would drift from the real one and be
invisible when it did.

## Known gaps — read before submitting

**No Kotlin unit tests.** The project has no JVM or instrumentation test source
set for Android, so the filter is covered by structural assertions over the
source rather than by executing it. Those catch a revert to `amount OR keyword`
but cannot prove behaviour on a real message. Closing this means adding JUnit
and a Gradle test task.

**Dedup: PROVEN ON CURRENT HEAD.** `DurableCaptureQueue` assigns a fresh `UUID`
per receipt and has no content hash, so the guarantee comes from downstream, and
it is proven by tests that are **not** owned by the active session:

- `test/domain/duplicate_transaction_detector_test.dart` — 12 cases, including
  same text + same transaction timestamp
- `test/features/capture/closed_app_capture_durability_test.dart` — *"idempotent:
  crash after commit before ack → replay creates no duplicate"* and *"duplicate
  Shortcut execution of the same payload imports once"*

**27 passed on this HEAD.**

> ### ⛔ RELEASE GATE — re-run dedup after the parser session lands
>
> The outcome is produced by `AddTransactionUseCase`, and
> `add_transaction_usecase.dart` is being refactored right now by another
> session (extracting `capture_commit_decision.dart`). The proof above is
> current, not permanent.
>
> **Before any signed release build**, re-run:
>
> ```bash
> cd app && flutter test \
>   test/domain/duplicate_transaction_detector_test.dart \
>   test/features/capture/closed_app_capture_durability_test.dart \
>   test/features/capture/ingest_captured_message_usecase_test.dart
> ```
>
> A refactor that changes when `AddTransactionOutcome.duplicate` is returned
> would break idempotency **silently** — the capture still imports, just twice.

**Queue overflow is silent.** The cap is 200 with drop-oldest. If the Dart drain
stalls, the oldest captures are discarded with no signal. Not redesigned here —
flagged deliberately.

**Closed-app delivery is not yet verified on a device.** The receiver is
manifest-declared, which is the condition for the OS to start it with the
process dead, but that is an argument, not evidence. It needs the device QA
matrix below.

## Device QA matrix — required before submission

| Scenario | Expected |
|---|---|
| App foreground | captured |
| App background | captured |
| **Process not running** | captured — the case that justifies a manifest receiver |
| After reboot, before first launch | captured |
| Permission denied | share capture still works; automatic stays off |
| "Don't ask again" | Settings route offered, not a dead button |
| Permission revoked while enabled | capture stops on the next message |
| Personal SMS from a phone number containing "card" | **not retained** |
| Bank SMS from a sender ID | retained |
| OTP from a bank sender ID | **not retained** |
| Multipart bank SMS | reassembled into one capture |

## Files

| File | Change |
|---|---|
| `MainActivity.kt` | runtime request + `onRequestPermissionsResult` + status JSON |
| `SmsCaptureReceiver.kt` | sender-aware prefilter, OTP rejection |
| `AndroidManifest.xml` | `RECEIVE_SMS` + receiver restored |
| `native_capture_bridge.dart` | `SmsPermissionStatus` / `SmsPermissionResult` |
| `android_sms_capture_service.dart` | `requestAndEnable`, disable, settings route |
| `sms_capture_disclosure.dart` | the disclosure UI |
| `docs/legal/PRIVACY_POLICY.md` | §8 rewritten |
| `android_sms_permission_test.dart` | 27 tests |

No parser or fetch file was touched.
