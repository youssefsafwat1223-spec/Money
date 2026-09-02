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
(`test/architecture/egress_inventory_test.dart`).

> **CORRECTED 2026-09-02.** This line previously read "12 gated, 1 exempt, **0
> open**". That was false when written or became false shortly after: the
> inventory today records **6 exempt and 3 OPEN findings**. This document is
> destined for a Google Play Data Safety submission, so a stale privacy count in
> it is not a documentation nit — it is an inaccurate regulatory declaration.
>
> The three OPEN findings, stated plainly:
> 1. `record_metric` — product telemetry with **no client-side consent gate**.
>    Mitigated server-side: owner-bound, key-allowlisted, rate-limited, and it
>    carries an event key plus a coarse dimension, never user data.
> 2. `set_default_account` in the accounts backfill — gated on transport
>    capability rather than on consent, unlike its sibling push/pull services.
> 3. `SupabaseEngagementRecorder` — declared but never instantiated, so nothing
>    reaches the network today.
>
> None of the three transmits SMS content, transaction amounts, merchants or
> balances. The declaration below is accurate about SMS handling; this note
> exists so the "0 open" claim is not carried into a submission.

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

## Final per-category answers — with evidence

### The decisive fact

`ConsentAuthority.decide()` makes `cloudProcessingEnabled` the **master gate for
every egress class carrying user data**:

```dart
case EgressClass.financialSync:
case EgressClass.profileAndSettings:
case EgressClass.backup:
case EgressClass.senderBankMappings:
case EgressClass.smartInbox:
case EgressClass.gamification:
case EgressClass.telemetry:
case EgressClass.diagnostics:
  return cloud;                       // ← all of it
case EgressClass.aiProcessing:
  return cloud && settings.aiConsentGranted;
```

Only `catalog` and `auth` are ungated. And the default is off:

```sql
cloud_processing_enabled INTEGER NOT NULL DEFAULT 0
```
```dart
bool get cloudProcessingEnabled => cloudConsentState == ConsentState.accepted;
```

The app is a local-first expense tracker — Drift is the source of truth and the
app is fully usable with cloud consent never granted. So under Play's test
(*can all users decline this collection and still use the app?*) almost
everything is **Optional**.

The earlier draft marked financial data "Required". That was wrong: it confused
"required once you have enabled cloud sync" with "required to use the app".

| Play category | Collected | Optional/Required | Evidence |
|---|---|---|---|
| **SMS or MMS** | YES | **Optional** | `cloudProcessingEnabled` gate + the auto-capture opt-in; two independent offs |
| **Purchase history** | YES | **Optional** | `EgressClass.financialSync → return cloud`; default 0 |
| **Other financial info** | YES | **Optional** | same gate |
| **Device or other IDs** | YES | **Optional** | install id/device secret are only sent on capture calls, which are behind the same gate |
| **Diagnostics** | YES | **Optional** | `EgressClass.diagnostics → return cloud`, plus Sentry needs its own DSN |
| **User IDs** | YES | **REQUIRED** | `EgressClass.auth` returns `true` **ungated**, and the router forces a non-guest user to a **mandatory sign-in** screen. No guest option is offered in onboarding. |

**`User IDs` is the only genuinely required category**, and only because sign-in
is mandatory. Everything else can be declined for the app's lifetime.

### Sharing — per recipient

Play defines *sharing* as transfer to a **third party**, and excludes transfers
to a **service provider** processing solely on the developer's behalf.

| Recipient | Relationship | Own purposes? | Data Safety |
|---|---|---|---|
| Qirsh backend (Supabase) | **first party** — our own infrastructure | no | **not shared** |
| Sentry | **service provider** — crash diagnostics on our behalf | no | **not shared** |
| Google / Apple sign-in | authentication provider; the user initiates it | no | **not shared** — user-initiated authentication |
| **AI provider (Gemini)** | **service provider** — parsing on our behalf | no | **not shared** |

**Not shared for every recipient — but not because "SDK transfers don't count".**
Each is either our own infrastructure or a processor acting under our
instructions for our purposes. If any of them were ever permitted to use the data
for their own purposes — model training, analytics, advertising — the answer for
that recipient would become **Shared: YES**, and the money-management exception
would be at risk.

### ⛔ PRE-PRODUCTION GATE — provider verification

**Shared: NO depends entirely on the service-provider exception holding.** Before
enabling **any** production AI provider or diagnostics provider, verify against
that provider's current terms — not a memory of them — that it:

1. **processes data only on Qirsh's behalf**, under our instructions;
2. has **no independent-purpose use** of the submitted content — no resale, no
   advertising, no product improvement for its own benefit;
3. **does not train on submitted Qirsh user content**, unless that is separately
   disclosed in the privacy policy and reflected as **Shared: YES** in Data
   Safety.

If any of the three fails, the exception does not apply and that recipient's row
becomes **Shared: YES**. Declaring **NO** while a provider trains on user
financial messages would be a false attestation on a form Google audits — and
for a money-management app relying on a restricted-permission exception, that is
the kind of finding that costs the exception itself.

Applies to: the AI provider (Gemini) and Sentry. Record the date and the terms
version checked, next to the row.

⚠️ The AI provider is the one to watch. `process-ios-sms`, `bank-discovery` and
`parse-sms` all reference Gemini, gated server-side on `allowAi`, which the
client forwards from `aiConsentGranted`. **`GEMINI_API_KEY` is not currently set
on production**, so no call can be made today — but the code path exists, and the
Data Safety answer must describe the design, not a transient config state. Before
enabling it, confirm the provider's terms bar training on submitted content;
if they do not, this row changes.

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
