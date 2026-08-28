# Qirsh — Privacy Policy

**Last updated: 2026-08-29**

Qirsh (قِرش) is a personal finance app that reads bank SMS and notification
messages on your device and turns them into a private record of your spending.

This policy describes what the app actually does. It was written after the
privacy behaviour was audited and corrected, not before — several statements
that used to be aspirational are now enforced in code and covered by tests.

---

## 1. The short version

- **Your financial data lives on your device**, in a database encrypted with a
  key held in the device keychain.
- **Cloud sync is OFF by default.** With it off, no financial data leaves your
  device — this is enforced at every network call, not only in the settings UI.
- **The AI runs entirely on your device.** No message text is sent to any AI
  provider, ours or anyone else's.
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
| Cloud financial data | Until you delete it or delete your account |
| Encrypted backups | Until replaced or deleted by you |
| Relay records for captured messages | Swept automatically after 30 days |
| Crash reports (if enabled) | Per the diagnostics provider's retention |

---

## 7. Third parties

| Provider | Receives | When |
|---|---|---|
| Supabase (hosting, database, auth) | Whatever you have consented to sync | Only with consent |
| Sentry (crash reporting) | Crash diagnostics | Only with consent |
| Google / Apple sign-in | Authentication only | Only if you sign in |
| **AI providers** | **Nothing.** There are none. | Never |

The AI row is stated explicitly because "this app has AI" usually implies a third
party receives your text. In Qirsh it does not: the model is on your device.

---

## 8. Permissions

- **Notification access** — to read bank notifications for capture. This is the
  core function; messages are processed on-device.
- **Biometrics** — to lock the app, if you enable it.

Qirsh does not request location, contacts, photos, or the microphone.

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
