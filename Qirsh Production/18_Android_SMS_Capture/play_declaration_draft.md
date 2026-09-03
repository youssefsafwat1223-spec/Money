# Play Permissions Declaration — DRAFT

**NOT SUBMITTED. Approval status: PENDING.**
Do not claim Play readiness until Google approves this.

> **Rewritten 2026-09-03.** §2 and §3 previously said "Message parsing happens
> entirely on the device. No message text is sent to any AI provider", and §3
> presented that as a rendering of the shipped disclosure. Both were false: the
> app ships an optional, doubly-consented sanitized cloud/AI path, and the live
> privacy policy and the Data Safety draft both describe it. A declaration that
> contradicts the privacy policy attached to the same submission reads as
> misrepresentation, which is a removal risk rather than a rejection risk.
> Corrected against source; §3 is now the verbatim shipped text.

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

> Incoming messages are screened **on the device** before anything is stored.
> Only messages showing evidence of a financial transaction are retained.
> Personal messages and one-time passcodes are discarded at that point and are
> never written to storage, transmitted, or logged.
>
> **By default, parsing happens entirely on the device and no message content
> leaves it.** Cloud processing and AI assistance are two separate switches,
> **both off by default**.
>
> If the user turns on **both**, a **sanitized copy** of a financial message is
> sent to Qirsh's backend and may be processed by an AI provider acting solely
> as Qirsh's service provider, for the sole purpose of parsing that same
> financial message into the user's transaction record. Removed on the device
> **before** transmission: full card numbers, account numbers, IBANs, phone
> numbers, one-time passcodes, and — for transfers — the recipient's name.
> Merchant names on purchases are retained because they are what the
> categorisation is for. The sanitized copy is retained for **30 days** and then
> purged automatically.
>
> SMS data is never used for advertising, marketing, profiling, or to improve
> any other product, is never sold, and is never shared for any purpose other
> than providing this feature.

## 3. Prominent disclosure

Shown immediately before the system permission dialog, on a dedicated screen
asking for this and nothing else. This is the **verbatim English of the shipped
strings** (`smsDisclosure*` in `app/lib/l10n/app_en.arb`); Arabic is the
shipped default and is the source of truth:

> **Reading bank messages automatically**
>
> To record your expenses automatically, Qirsh needs permission to read incoming
> messages on your device.
>
> • Qirsh scans incoming messages to identify financial transactions
>   (purchase, transfer, withdrawal, deposit).
> • Non-financial messages — personal messages and verification codes — are
>   ignored and not stored.
> • Parsing happens on your device by default. If you enable cloud processing, a
>   sanitized copy — without card, account or phone numbers — is sent to Qirsh's
>   servers.
> • Cloud sync is off by default; if you turn it on, that is a separate consent
>   from this permission.
> • You can turn automatic reading off in Qirsh settings, or revoke the
>   permission in device settings, at any time.
>
> [ Not now ]   [ Agree, request permission ]

Declining does not request the permission. Dismissing counts as declining — the
ordering is structural: `AndroidSmsCaptureService.requestAndEnable` takes the
disclosure as a callback and has no code path reaching the system dialog without
it returning true.

## 4. User control

- Permission is requested only after an explicit affirmative action.
- Granting is not sufficient — a separate in-app toggle, off by default, must
  also be enabled.
- Revoking in system settings stops capture immediately.
- Denial leaves the app fully usable: messages can be shared to Qirsh manually,
  which needs no permission.

## 5. Review video — script

The reviewer must be able to see, without reading code, that the permission is
requested correctly and that the feature is real. Record on a physical device
once RB-5 hardware is available; an emulator recording is acceptable only if the
device matrix is otherwise complete.

1. **Fresh install, first launch.** Show Settings → app info → Permissions:
   SMS **not granted**.
2. **Settings → «رصد العمليات».** Show the automatic-capture toggle **off**.
3. **Tap it.** The disclosure screen appears **before any system dialog**. Read
   it on camera, including the line about the optional sanitized cloud copy.
4. **Tap "Not now".** Show that **no system dialog appeared** and the toggle is
   still off. *(This is the step reviewers check hardest.)*
5. **Tap the toggle again, accept the disclosure.** The Android dialog appears.
   **Deny** it. Show the toggle still off and the app fully usable.
6. **Tap again, accept, grant.** Show the toggle now on.
7. **Send a bank-style SMS.** Show the transaction appearing automatically.
8. **Send a personal SMS containing the word "card"** and **an OTP message**.
   Show that **nothing** is captured.
9. **Send a multipart (>160 char) bank SMS.** Show it captured **once**, with
   the text whole.
10. **Revoke SMS in system settings.** Return to the app; show capture has
    stopped and the toggle reads as blocked.
11. **Show the share-to-Qirsh path still working** with the permission revoked —
    the feature degrades, the app does not.
12. **Privacy screen.** Show cloud processing and AI assistance **both off by
    default**, and state on camera that with cloud off nothing is transmitted.

Steps 4, 8 and 10 are the ones the reviewer is looking for. Step 12 matters
because the declaration discloses the optional AI path — show it is genuinely
off by default.

## 6. Attachments

- Privacy policy: `https://qirsh.site/privacy` — live, and must describe **both**
  SMS access and the optional sanitized AI path. The source is corrected;
  **the live site must be regenerated and redeployed before submitting**, because
  the published copy still contains the "and notification messages" claim.
- Store listing describing automatic SMS capture as a core feature — and **not**
  mentioning notification access, which the app does not have.
- The review video above.
- Data Safety answers consistent with this declaration
  (`data_safety_draft.md`).
