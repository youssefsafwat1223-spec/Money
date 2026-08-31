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

## Final per-category answers

| Play category | Collected | Optional | Shared | Purpose | Encrypted in transit | Deletion | Retention |
|---|---|---|---|---|---|---|---|
| **SMS or MMS** | **YES** | **Optional** — off by default | No | App functionality | Yes | In-app account deletion (cascade) | **30 days**, automatic |
| **Purchase history** | YES | Required | No | App functionality | Yes | Account deletion | Until deletion |
| **Other financial info** | YES | Required | No | App functionality | Yes | Account deletion | Until deletion |
| **User IDs** | YES | Required | No | App functionality, account management | Yes | Account deletion | Until deletion |
| **Device or other IDs** | YES | Required | No | App functionality, fraud prevention | Yes | Account deletion | Until deletion |
| **Diagnostics** | YES | Optional (Sentry) | No | Analytics, app functionality | Yes | Account deletion | Until deletion |

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

## Server retention — RESOLVED from migrations

Traced through `0012_ios_capture_pipeline.sql`, `0033_capture_pipeline_hardening.sql`,
`0072_backend_security_hardening.sql` and `0084_purge_user_data_restore.sql`.

| Item | Table | Retention | Trigger | Automatic | Removed by account deletion |
|---|---|---|---|---|---|
| Sanitized SMS text | `processed_captures.sanitized_text` | **30 days** | `created_at < NOW() - INTERVAL '30 days'` | **yes** — daily cron `15 3 * * *` | **yes**, by cascade |
| Sender + timestamp | `processed_captures.parsed` (JSONB) | **30 days** | same row | yes | yes, by cascade |
| Processed capture row | `processed_captures` | **30 days** | same | yes | yes, by cascade |
| Dedup fingerprint | `capture_fingerprints` | **7 days** | `seen_at < NOW() - INTERVAL '7 days'` | yes, same cron | yes, by cascade |
| Parsed transactions | `user_transactions` | **no TTL — until account deletion** | — | no | **yes**, explicit delete |
| Device / install identifiers | `capture_devices` | no TTL | — | no | **yes**, explicit delete |

### Two findings worth stating precisely

**Capture data expires on its own.** `run_prune_processed_captures()` deletes
capture rows after 30 days and fingerprints after 7, on a daily cron verified
active on production (`prune-processed-captures-daily`). Sanitized SMS text is
therefore **not** retained indefinitely, which is the answer Data Safety needs.

**Account deletion removes capture rows by cascade, not by direct delete.**
`purge_user_data` (migration `0084`) never names `processed_captures`. It does
not need to: both `processed_captures` and `capture_fingerprints` declare
`install_id_hash … REFERENCES capture_devices(install_id_hash) ON DELETE CASCADE`,
and the purge deletes `capture_devices` at line 137. `0084` documents the
ordering dependency explicitly — satellites keyed by install hash must resolve
*before* the device rows go.

Worth flagging as fragile: the coverage is implicit. Someone auditing
`purge_user_data` by reading its delete list would conclude capture data
survives account deletion. It does not — but only because of a foreign key
declared twelve migrations earlier. If that FK is ever changed to `ON DELETE SET
NULL` or dropped, deletion coverage breaks **silently**.

**Transaction data has no TTL** and is retained until the user deletes their
account. That is correct for a finance app — a ledger that expires would be a
defect — but it must be declared as such rather than implied.

Everything above is source-derived and is safe to attest to.
