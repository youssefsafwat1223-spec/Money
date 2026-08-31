# Play Permissions Declaration — DRAFT

**NOT SUBMITTED. Approval status: PENDING.**
Do not claim Play readiness until Google approves this.

Permission: `android.permission.RECEIVE_SMS`
Exception claimed: **SMS-based money management**
Package: `com.youssefsafwat.mali`

---

## 1. Core functionality justification

> Qirsh is a personal finance app whose core purpose is automatic expense
> tracking. It reads incoming bank SMS on the device to detect financial
> transactions — purchases, transfers, withdrawals and deposits — and turns them
> into the user's own private spending record.
>
> This is not a secondary convenience. Automatic capture from bank messages is
> the primary function of the app: without it the user must enter every
> transaction by hand, which is the problem Qirsh exists to solve.
>
> Qirsh requests `RECEIVE_SMS` only. It does not request `READ_SMS` — it never
> reads the message inbox or history, only messages arriving while the feature
> is enabled. It does not send, write, or modify messages.

## 2. Data handling

> Incoming messages are filtered on the device before anything is stored. Only
> messages that show evidence of a financial transaction are retained. Personal
> messages and one-time passcodes are discarded immediately and never written to
> storage, transmitted, or logged.
>
> Message parsing happens entirely on the device. No message text is sent to any
> AI provider.
>
> Cloud sync is off by default and is a separate, explicit user choice. It syncs
> transaction records, not raw message text.
>
> SMS data is never used for advertising, marketing, or profiling, and is never
> sold or shared with third parties.

## 3. Prominent disclosure

Shown immediately before the system permission dialog, on a dedicated screen
asking for this and nothing else. English rendering of the shipped Arabic text:

> **Reading bank messages automatically**
>
> To record your expenses automatically, Qirsh needs permission to read incoming
> messages on your device.
>
> • Qirsh scans incoming messages to identify financial transactions
>   (purchase, transfer, withdrawal, deposit).
> • Non-financial messages — personal messages and verification codes — are
>   ignored and not stored.
> • Analysis happens on your device. No message text is sent to any AI provider.
> • Cloud sync is off by default; enabling it is a separate consent from this
>   permission.
> • You can turn automatic reading off in Qirsh settings, or revoke the
>   permission in device settings, at any time.
>
> [ Not now ]   [ Agree, request permission ]

Declining does not request the permission. Dismissing counts as declining.

## 4. User control

- Permission is requested only after an explicit affirmative action.
- Granting is not sufficient — a separate in-app toggle, off by default, must
  also be enabled.
- Revoking in system settings stops capture immediately.
- Denial leaves the app fully usable: messages can be shared to Qirsh manually,
  which needs no permission.

## 5. Review video — script

1. Fresh install, first launch. Show that no SMS permission has been granted.
2. Settings → automatic capture. Show the toggle **off**.
3. Tap it. **The disclosure screen appears before any system dialog.** Read it
   on camera.
4. Tap "Agree, request permission". The Android dialog appears. Grant it.
5. Show the toggle now on.
6. Send a test bank-style SMS. Show the transaction appearing automatically.
7. Send a personal SMS containing the word "card". Show that **nothing** is
   captured.
8. Revoke the permission in system settings. Return to the app and show capture
   has stopped.
9. Show the share-to-Qirsh path still working with the permission revoked.

Steps 3, 7 and 8 are the ones the reviewer is looking for.

## 6. Attachments

- Privacy policy: `https://qirsh.site/privacy` — must be **live and describing
  SMS access** before submitting.
- Store listing describing automatic SMS capture as a core feature.
- The review video above.
