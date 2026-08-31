# Play Data Safety — DRAFT (semantically reconciled)

**NOT SUBMITTED.** Must match the shipped manifest and the live privacy policy
exactly — Google cross-checks all three, and Data Safety answers are attested.

> **Play's definition:** data is *collected* when it is **transmitted off the
> device**. On-device access and local storage are **not** collection. The first
> draft of this file said "SMS = collected" without applying that test; this
> version derives every answer from the code path.

---

## Off-device data map — derived from source

Traced through `capture_sync_service.dart` → `capture_backend_client.dart`, and
cross-checked against the egress inventory
(`test/architecture/egress_inventory_test.dart`: 12 gated, 1 exempt, 0 open).

| Item | On device | Stored locally | Sent off-device | Gate | Retained by backend | Shared |
|---|---|---|---|---|---|---|
| **Raw SMS body** | yes | yes (encrypted) | **never** | — | no | no |
| **Sanitized SMS text** | yes | — | **yes** | `cloudProcessingEnabled` **OFF by default** | **yes** — `processed_captures.parsed.rawMessage` | no |
| **SMS sender** | yes | yes | **yes** | same gate | yes | no |
| **SMS timestamp** | yes | yes | **yes** | same gate | yes | no |
| **Prefilter result** | yes | — | never (a drop leaves no record) | — | no | no |
| **Parsed transaction** | yes | yes | **yes** | `EgressClass.financialSync` — consent + capability | yes | no |
| **Account / bank / category** | yes | yes | **yes** | `financialSync` / `senderBankMappings` | yes | no |
| **Install ID + device secret** | yes | yes | **yes** | required for any capture call | yes | no |
| **Notification delivery/open events** | yes | yes | **yes** | `EgressClass.telemetry` | yes | no |
| **Merchant keywords** | yes | yes | not wired | `EgressClass.aiProcessing` | n/a | no |
| **Encrypted backup** | yes | yes | **yes** | `EgressClass.backup`, user-initiated | yes | no |

### What sanitization removes before transmission

`SmsSanitizer.sanitize()` runs **on-device, before the payload is built**, and
strips: full 16-digit card numbers, Saudi/Egyptian/international phone numbers,
10–20 digit account numbers, and — for transfers — the beneficiary name after
`إلى:` / `To:`, because that is a third party's name.

Masked forms (`*1234`) and merchant names on purchases are deliberately kept:
the merchant is a business entity, not personal data, and the category engine
needs it.

The server persists this value verbatim, which is exactly why sanitization is
on-device and not server-side.

---

## Is SMS "collected"? **YES — but optional.**

The honest answer is conditional, and Play has a field for exactly that:

- **Cloud processing OFF (the default):** nothing derived from SMS leaves the
  device. Under Play's definition this is **not collection**.
- **Cloud processing ON (explicit, separate consent):** sanitized message text,
  sender and timestamp are transmitted and retained. That **is** collection.

Because a shipped configuration exists in which it is transmitted, it must be
declared as collected — with **"Users can choose whether this data is
collected" = YES**.

Declaring it unconditionally collected would overstate the default. Declaring it
not collected would be false for consenting users. The optional flag is the only
accurate answer.

---

## Play categories

| Play category | Declare | Data | Purpose | Optional | Shared |
|---|---|---|---|---|---|
| **SMS or MMS** | **Yes** | sanitized message text, sender, timestamp | App functionality | **Yes** | No |
| **Other financial info** | Yes | parsed transactions, accounts, balances | App functionality | No | No |
| **Purchase history** | Yes | merchant/amount/date of captured purchases | App functionality | No | No |
| **User IDs** | Yes | account id, install id | App functionality, account management | No | No |
| **Device or other IDs** | Yes | install id, device secret | App functionality, fraud prevention | No | No |
| **Diagnostics** | Yes | crash reports, capture delivery/open telemetry | Analytics, app functionality | Yes (Sentry optional) | No |

### Not collected

Location · Contacts · Photos/videos · Audio · Health · Calendar · Browsing
history · **SMS inbox history** (`READ_SMS` is not declared, and the app cannot
read messages that arrived before capture was enabled).

---

## Security practices

- **Encrypted in transit** — yes, HTTPS throughout.
- **Encrypted at rest on device** — SQLCipher, key in the Android Keystore.
- **Users can request deletion** — yes, the app has an account-deletion path.
- **Data can be deleted from the device** — yes.
- **Independent security review** — no.

## Answers that must stay true

| Question | Answer | Why it must not drift |
|---|---|---|
| Shared with third parties? | **No** | sharing would void the money-management exception |
| Used for advertising or marketing? | **No** | ads exist but are never targeted from transaction data |
| Used for profiling? | **No** | stated in the privacy policy |
| Is SMS collection optional? | **Yes** | off by default and separately consented |
| Is raw, unsanitized SMS ever transmitted? | **No** | sanitization is on-device, before the payload is built |

---

## PENDING — not provable without files owned by another session

The exact **server-side retention window** for `processed_captures` was not
traced: it runs through Edge Functions and migrations rather than client code.
The client sends it; how long the backend keeps it is a separate question and
must be confirmed before submitting, because Data Safety asks about retention.

Everything above is client-side evidence and is safe to attest to as written.
