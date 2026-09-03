# Qirsh — Privacy Policy

**Last updated: 2026-08-29**

Qirsh (قِرش) is a personal finance app that reads bank SMS on your device and
turns them into a private record of your spending.

This policy describes what the app actually does. It was written after the
privacy behaviour was audited and corrected, not before — several statements
that used to be aspirational are now enforced in code and covered by tests.

---

## 1. The short version

- **Your financial data lives on your device**, in a database encrypted with a
  key held in the device keychain.
- **Cloud sync is OFF by default.** With it off, no financial data leaves your
  device — this is enforced at every network call, not only in the settings UI.
- **The model that categorises your spending runs entirely on your device**, with
  no network access at all. Separately, if you turn on both cloud processing and
  AI assistance — two choices, both off by default — a sanitized copy of a bank
  message may be sent to an AI provider to help read it.
- **We do not sell your data.** There is no advertising profile built from your
  transactions.

---

## 2. What is processed on your device only

The following never leave your device unless you turn on cloud sync:

| Data | Why |
|---|---|
| Bank SMS / notification text | To extract the amount, merchant, date and account |
| Transactions, accounts, cards, balances | The core function of the app |
| Budgets, goals, subscriptions, plans | Planning features |
| Merchant→category learning | So your corrections apply to future transactions |

The local database is encrypted (SQLCipher). The encryption key is stored in the
iOS Keychain / Android Keystore and is not transmitted.

### On-device AI

Qirsh includes a merchant-understanding and category-prediction model. It runs
**entirely on your device** as part of the app, with **no network access at all**:

- it is not a cloud service, and there is no API key or provider behind it;
- no message text, merchant name or transaction is sent anywhere for it to work;
- it learns from **your corrections**, on your device, and that learning is never
  uploaded.

Because there is no network path, this holds regardless of your consent settings.
We disclose it here because it is a real model making real suggestions — not
because it transmits anything.

---

## 3. What is sent to the cloud, and only with your consent

Cloud features are **off by default**. Each of the following is gated
separately, and the gate is checked at the moment of sending — turning consent
off stops transmission immediately, not at the next app start.

| Category | Sent when enabled | Purpose |
|---|---|---|
| Financial sync | Accounts, transactions, budgets, goals, plans | Multi-device sync |
| Encrypted backup | An encrypted archive of your data | Restore after device loss |
| Bank mappings | Which bank a sender ID belongs to | Improve parsing for everyone |
| Smart Inbox | Messages awaiting your confirmation | Review across devices |
| Gamification | Achievement progress | Cross-device streaks |
| Telemetry | Notification delivery/open events | Reliability of capture |
| Diagnostics | Crash reports | Fixing crashes |

**Diagnostics fail closed:** when cloud/privacy consent is off, crash reporting
does not transmit — the report is dropped before it is assembled, not merely
scrubbed.

### Always allowed, and why

Two things are not consent-gated:

1. **Catalog updates** — parser rules, feature flags, and the force-update
   notice. These carry **no data about you** and are requested anonymously. They
   also deliver safety controls, so gating them would leave the most
   privacy-conscious users unable to receive a critical fix notice.
2. **Authentication**, when you choose to sign in.

---

## 4. Consent, and how it behaves

- Consent is **off by default**. Nothing about your finances is uploaded until
  you turn it on.
- **Revocation is immediate.** The check is performed at each transmission, so
  turning cloud off stops the next sync — including retries, background work,
  and startup reconciliation.
- **Across devices, the more restrictive setting wins.** Turning consent OFF on
  one device propagates as a revocation. Turning it ON does **not** silently
  grant consent on your other devices — you grant it on each device yourself.

---

## 5. Deleting your data

These are separate actions, deliberately:

### Stop uploading (revoke consent)
Settings → Privacy → turn off cloud sync. Transmission stops immediately. **Data
already in the cloud is not deleted** — revoking consent is not a deletion
request, and treating it as one would destroy your backup the moment you paused
syncing.

### Delete data from your device
Settings → Privacy → Delete local data. This wipes the encrypted local database.

### Delete data from the cloud
Settings → Privacy → Delete cloud data. This removes your server-side copy. It is
idempotent — running it twice is safe — and it reports what was removed.

### Delete your account entirely
Settings → Account → Delete account, which removes your cloud data and your
authentication record.

If you cannot access the app, email the address in §9 from the address on the
account and we will action the deletion.

---

## 6. Retention

| Data | Retained |
|---|---|
| Local data | Until you delete it or uninstall the app |
| Cloud financial data (transactions, accounts, budgets) | **No fixed expiry** — kept until you delete it or delete your account |
| Sanitized captured message text on our servers | **Deleted automatically after 30 days** |
| Duplicate-detection fingerprints | **Deleted automatically after 7 days** |
| Device identifiers used for capture | **No fixed expiry** — removed when you delete your account |
| Encrypted backups | Until replaced or deleted by you |
| Crash reports (if enabled) | Per the diagnostics provider's retention |

The two automatic deletions run on a daily scheduled job. The rows with no fixed
expiry are exactly that — they do not expire on their own, and are removed when
you delete your account.

---

## 7. Third parties

| Provider | Receives | When |
|---|---|---|
| Supabase (hosting, database, auth) | Whatever you have consented to sync | Only with consent |
| Sentry (crash reporting) | Crash diagnostics | Only with consent |
| Google / Apple sign-in | Authentication only | Only if you sign in |
| AI provider (message reading) | Sanitized bank-message text | Only with **both** cloud processing and AI assistance on |

Each of these processes data **on our behalf**, under our instructions, to run
the service. None of them receives your data for their own purposes, and we do
not sell or share it for advertising.

**About the AI row.** The model that categorises your spending is on your device
and sends nothing (section 2). That is separate from *reading* a bank message: if
you enable cloud processing **and** AI assistance, a sanitized copy of the
message may be sent to an AI provider to help parse it. Both settings are off by
default, and turning off either one stops it.

---

## 8. Permissions

### Android — SMS access

Qirsh can read **incoming SMS** on Android to detect financial transactions
automatically. This is the app's core function: turning bank messages into your
spending record without you typing them in.

- The permission is **requested only after a disclosure screen** explaining what
  is accessed and why, and only when you explicitly agree.
- Granting the permission is **not** enough on its own. Automatic capture stays
  **off** until you separately turn it on in Settings.
- Incoming messages are **screened on your device before anything is stored**.
  A message that does not look like a financial transaction is discarded at that
  point and is never saved. The screening is designed to leave ordinary personal
  messages and verification codes behind, but it is a judgement based on the
  message's content and sender rather than a guarantee — occasionally a message
  may be kept that you would not have chosen to keep. Anything kept in error can
  be deleted in the app.
- Qirsh requests `RECEIVE_SMS` only. It does **not** request permission to read
  your existing inbox, send messages, or read MMS.
- You can turn automatic capture off in Qirsh, or revoke the permission in
  Android settings, at any time. Either stops it immediately.
- SMS content is never used for advertising, marketing, or profiling, and is
  never sold.

**Manual capture always works without this permission.** You can share a message
to Qirsh instead, and nothing about that path requires SMS access.

### iOS

**iOS gives no app permission to read your Messages, and Qirsh does not have
one.** It cannot open, search or browse your Messages history. It only ever sees
a message that you hand to it, in one of two ways:

- **Share to Qirsh** — you select a message and share its text to Qirsh.
- **A Shortcuts automation you set up yourself** — Qirsh provides a Shortcuts
  action ("Process Bank SMS"). If you build an automation that runs it, the
  Shortcut passes that message's text, sender and time to Qirsh. Qirsh receives
  only what your automation passes in, and the automation only runs on the
  messages you configured it for.

In both cases, Qirsh receives content only because you either shared it or
configured a Shortcut to pass it. Qirsh cannot independently open, search, or
browse your Messages history.

### Other permissions

- **Notifications** — to show you alerts Qirsh generates, such as budget
  warnings and reminders.
- **Biometrics** — to lock the app, if you enable it.

- **Photos and camera** — only if you choose a profile picture. Qirsh opens the
  picker when you tap to set one; it cannot browse your library otherwise.
- **Files** — only when you pick a backup file to restore.

Qirsh does not request location, contacts, or the microphone.

### Where captured messages are processed

**By default, captured message text is parsed entirely on your device and does
not leave it.**

If you turn on **cloud processing** — a separate setting, off by default — a
**sanitized** copy of the message is sent to Qirsh's servers to help parse it,
and is stored there. Sanitizing happens on your device before anything is sent,
and removes:

- full card numbers,
- phone numbers,
- account numbers,
- for transfers, the recipient's name.

Merchant names on purchases and masked card endings (`*1234`) are kept, because
they are needed to categorise the transaction.

If you additionally turn on **AI processing**, that sanitized text may be
processed by an AI provider. That is a third, separate consent.

So: with the default settings, message text stays on your device. If you enable
cloud processing, sanitized text does leave your device — we will not tell you
otherwise.

---

## 9. Contact

Questions, or a data request: **<CONTACT_EMAIL>**

---

## 10. Changes

Material changes will be announced in the app before taking effect. The "last
updated" date above always reflects the current version.

---

<!--
  DEPLOYMENT NOTE — not part of the published text.

  Before publishing:
    1. Replace <CONTACT_EMAIL> with a monitored address.
    2. Host at the URL configured in `app/lib/core/config/legal_urls.dart`.
       That host must resolve — the in-app Privacy screen links to it, and both
       app stores require a reachable privacy URL.

  This document describes behaviour verified in the 2026-08 audit:
  C-3 (consent enforced at every egress point, fail-closed),
  OD-13 (on-device model, no network path),
  OD-10 (revocation and cloud deletion are separate actions).
  If that behaviour changes, this text must change with it — a privacy policy
  that describes the software inaccurately is worse than none.
-->
