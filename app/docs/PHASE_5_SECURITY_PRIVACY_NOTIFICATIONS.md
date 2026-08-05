# Phase 5 — Security, Privacy, Notifications & Native Hardening

**Authoritative contract specification.** This document describes the **final
implemented** contracts for Phase 5, not the original intended plan. Where the
implementation is narrower than a value's aspirational goal, or is only provable
on hardware we do not yet have, that limitation is stated explicitly rather than
smoothed over.

- **Verdict:** `Phase 5 code complete — locally verified; signed-device, Android,
  APNs, store-policy, and live-PostgreSQL verification pending.`
- **Last updated:** 2026-08-05 (Batch 6 — documentation & verification only).
- **Deployment posture:** migrations 0068–0074 remain **undeployed**;
  `kServerRevisionCas = false`; migration 0070's engagement authority remains
  **inactive**. No code was changed in Batch 6.

> **Terminology honesty (applies throughout).** "Sent" = a provider (Apple APNs
> HTTP/2) *accepted* the request; it is **never** proof of display or delivery.
> Collapse IDs reduce duplicate *pending* banners; they are **not** strict
> delivery idempotency. "Eligible / awarded exactly-once" describes an
> **authoritative database mutation**, which is independent of whether the
> best-effort notification is delivered.

---

## 1. Implemented contracts

### A. Native-storage classification (iOS + shared containers)

Three storage backends are in play (`ios/Runner/SharedCaptureStore.swift`, with a
byte-identical copy in the Share Extension; the App Intent compiles into the
Runner target):

- **App Group `UserDefaults`** (`suiteName = group.com.youssefsafwat.mali`) —
  plaintext metadata.
- **Encrypted queue blob** (`pending_bank_messages_v2`) — AES-256-GCM sealed,
  stored inside the App Group.
- **Shared Keychain** (`SharedKeychain`, service
  `com.youssefsafwat.mali.sharedcapture`, `kSecClassGenericPassword`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never iCloud-synced).

| Value | Final storage | Encrypted? | Shared Keychain? | Retention | Purge on wipe? | X-process lock | Corruption behavior |
|---|---|---|---|---|---|---|---|
| Raw capture body / SMS text | `Payload.text` in `pending_bank_messages_v2` blob | **Yes** (AES-GCM) | No (key is) | Leased; removed on per-item ack | Yes | Yes (`withQueueLock`) | **Fail-closed** — undecryptable blob returns empty and is **not deleted** |
| Sender / senderName / senderId | same blob | **Yes** | No | same | Yes | Yes | Fail-closed |
| Capture payload ID | `Payload.id` (SHA-256 of text\|sender\|…) in blob **+** plaintext mirror `pending_bank_messages_latest_id` | Blob: yes / mirror: no (non-secret) | No | same | Yes | Yes | Fail-closed |
| **Device secret** (capture auth) | **Shared Keychain only** (`device_secret`) | Keychain-protected | **Yes** | Until identity change | **Yes** (invalidated on wipe) | n/a | Legacy `UserDefaults` value migrated in once, then deleted |
| **Queue encryption key** | **Shared Keychain only** (`capture_queue_key_v1`, AES-256) | Keychain-protected | **Yes** | Generated once on demand | **Yes** | n/a | Regenerated if absent |
| APNs token / environment | App Group `UserDefaults` **plaintext** | No | No | Install-level | **No** (install-level non-secret config) | Yes | n/a |
| Pending notification routes | App Group `UserDefaults` plaintext JSON | No | No | Cap **10**, drop-oldest | Yes | Yes (RMW under lock) | Reset if malformed |
| Notification logs | App Group `UserDefaults` plaintext JSON | No | No | Cap **200**, drop-oldest | Yes | Yes (RMW under lock) | Reset if malformed |
| Pending native actions | No separate iOS store — failed drains re-enqueue into the encrypted queue (`notifyHost:false`) | Yes (in queue) | No | Leased | Yes | Yes | Fail-closed |
| Acknowledgement / lease state | **Not a stored flag** — the lease *is* physical presence in the encrypted queue; peek is non-destructive, Dart acks by removing each id after its Drift import commits | Yes (in queue) | No | until ack | Yes | Yes | Fail-closed |
| Configuration metadata (`cloud_processing_enabled`, `install_id`, `backend_url`, `backend_anon_key`, `ai_consent_granted`) | App Group `UserDefaults` plaintext | No | No | Install-level | Preserved across purge | Yes | n/a |

**Cross-process locking:** `withQueueLock` takes `flock(LOCK_EX)` on
`pending_bank_messages.lock` in the App Group container; all queue/route/log
writes go through it. Degraded fallback: if the container/fd is unavailable it
runs **without** a lock (documented, functional-but-unsynchronized).

**Shared Keychain access group / App Identifier Prefix:** access group is
`$(AppIdentifierPrefix)com.youssefsafwat.mali.shared`. `Runner.entitlements`
declares **two** groups — the default `…mali` (kept so `flutter_secure_storage`
still reads the SQLCipher DB key) and `…mali.shared`; the Share Extension declares
only `…mali.shared`. `aps-environment` = `$(APS_ENVIRONMENT)`.

**Signed-device verification still pending (honest flags):**
1. **iOS App Group / queue-blob file-protection level is not set in code.** There
   is no `com.apple.developer.default-data-protection` entitlement and no explicit
   `NSFileProtection` on the plist/blob; they rely on the iOS default container
   protection. The **only** explicit `NSFileProtectionComplete` is on the managed
   **export** temp file (§D).
2. **Signed-device paths are simulator-unverifiable by design.** `accessGroup`
   returns `nil` when `AppIdentifierPrefix` can't resolve (unsigned build); items
   then fall back to the app's default Keychain (still Keychain, ThisDeviceOnly).
   Genuine cross-process app↔extension sharing of the one device secret and one
   queue key — and the App Group handoff under real provisioning — is only
   provable on a signed device (paid Apple Developer account, not yet available).

**Privacy-at-rest extras:** iOS backgrounding installs an opaque snapshot overlay;
Android sets `FLAG_SECURE`.

### B. Android persistence, backup & alarms

- **Synchronous native queue writes.** `DurableCaptureQueue` persists to
  `SharedPreferences(mali_capture_queue_v1, MODE_PRIVATE)` using
  `edit().putString(...).commit()` — **synchronous `commit()`, never `apply()`** —
  and returns the durability boolean. `enqueue` returns `true` only when durably
  committed; bounded `MAX_ITEMS = 200`, drop-oldest; `purge()`/`acknowledge()`
  also `commit()`.
- **peek → Drift commit → acknowledgement (acked only AFTER Drift commit).**
  `peekJson()` is non-destructive; the Dart driver imports each message into Drift
  (`ingestUseCase.fromCapturedMessage`) and only then calls
  `acknowledgeSharedMessage`. On exception the item is **not** acked and stays
  queued; on auth error the remainder stays leased.
- **Replay / idempotency.** `enqueue` is idempotent by stable `id` **and** by
  `(text+source)`; `acknowledge` removes exactly the id and `commit()`s. A second
  layer in Dart (`markPayloadImported`/`isPayloadImported`) acks+skips an
  already-imported redelivery. Malformed JSON store → removed + reset to empty
  (never crash).
- **Timestamp authority + malformed/legacy policy.** Authority is the **native
  epoch** `receivedAtEpochMs` (SMS: `timestampMillis` guarded `> 0`, else
  `System.currentTimeMillis()`). The ISO string is a legacy/display fallback;
  legacy items carry epoch `0`. Dart `resolveCapturedReceivedAt`: `epochMs > 0`
  wins → else `DateTime.tryParse(iso)` → else **`null`, never `now`**; the single
  documented last-resort fallback is owned by `AddTransactionUseCase`.
- **Platform backup + device-transfer exclusion.** `AndroidManifest.xml` sets
  `allowBackup="false"` **and** `fullBackupContent="false"` (the Keystore-bound
  SQLCipher DB, capture queue, and secrets would restore incoherent). **Honest
  flag:** there is **no** `android:dataExtractionRules` / backup-rules XML — the
  Android-12+ device-transfer exclusion rests on those two attributes only; the
  explicit `dataExtractionRules` ruleset does not exist.
- **Exact vs inexact alarms.** All scheduling uses
  `AndroidScheduleMode.inexactAllowWhileIdle`. The manifest **deliberately does
  not** request `USE_EXACT_ALARM`/`SCHEDULE_EXACT_ALARM` (Play-policy restricted),
  so there is no permission to remove and no exact→inexact runtime fallback —
  inexact is the permanent design (never throws, needs no runtime grant, so a
  reminder is never silently lost).
- **Reboot / timezone.** `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBoot`
  `Receiver` (BOOT_COMPLETED / MY_PACKAGE_REPLACED / QUICKBOOT) reschedules after
  reboot. Timezone correctness relies on tz-based `zonedSchedule` over `tz.local`
  (device IANA zone, fallback Asia/Riyadh). **Honest flag:** no dedicated
  `TIMEZONE_CHANGED` receiver exists.
- **Shipping-build note:** Android SMS auto-capture (`RECEIVE_SMS` +
  `SmsCaptureReceiver`) is **commented out** in the Play-safe default build; the
  receiver/queue/settings code exists and is wired but does not run there.

**External-only for B:** release compilation, native receiver process-death
replay, on-device `timestampMillis`, reboot restoration, inexact delivery,
timezone changes, and Play exact-alarm policy confirmation.

### C. Telemetry & diagnostics

- **Metrics ingestion is allowlist-bound.** The client's `MetricsClient.logEvent`
  calls the `record_metric` RPC (never a raw insert); no-ops when unconfigured or
  signed-out; swallows all errors. The event-key allowlist is a **server-side
  constant** — `ARRAY['app_open']` — and non-allowlisted / oversized keys are
  **silently dropped**; per-user daily quota 1000; `auth.uid()` identity;
  no PII stored. (There is no Dart-side allowlist; the boundary is server-side.)
- **Sentry telemetry boundary (outbound).** `beforeSend` + `beforeBreadcrumb`
  (`TelemetrySanitizer`) drop all free-form text: exception messages, `threads`,
  `breadcrumbs`, `request`, and `user` (replaced with `id:'[redacted]'`); keep
  only allowlisted `tags`/`extra`/context blocks + the exception **class name** +
  stack frames with local `vars` stripped. `sendDefaultPii=false`,
  `tracesSampleRate=0`, `attachScreenshot=false`.
- **Prohibited sensitive fields.** `PrivacyRedactor.redactText` regex-redacts
  paths, emails, JWTs/bearer/apikey secrets, monetary amounts, account/card/phone
  digit runs, and long opaque IDs. Open-vocabulary values (merchant names, bank
  sender IDs) that a regex cannot catch cause the whole free-text field to be
  **dropped**, not redacted in place; nested non-scalar values collapse to
  `[redacted]`.
- **Structured error codes.** `TelemetryError(code, module, operation, retryable)`
  with a fixed `TelemetryCodes` vocabulary (sync/storage/database/export/logo/
  notification). Only the stable `code` (or class name) reaches telemetry.
- **Debug-log redaction.** `Diag.installRedactingSink()` rewires the global
  `debugPrint` so **every** line (any call site or plugin) is redacted and bounded
  to 240 chars, in **debug and release**. `Diag.log`/`Diag.error` route through the
  same redaction.
- **Diagnostic retention.** No app-side diagnostic store/buffer exists —
  diagnostics are ephemeral (platform log only, 240-char bound). **Honest flag:**
  there is no numeric client-side diagnostic-retention policy because logs are not
  persisted by the app.
- **Native Sentry parity limitation.** The Dart `beforeSend`/`beforeBreadcrumb`
  boundary does **not** run on crashes captured by the native iOS/Android SDKs.
  Mitigation: `enableAutoNativeBreadcrumbs=false` and the architecture (financial
  data lives in Dart / the encrypted DB, not native crash payloads). Full native
  scrubbing parity is an explicit **external** residual.
- **Privacy canary tests.** `telemetry_privacy_test.dart` injects one canary per
  sensitive class through message/cause/stack-vars/breadcrumb/tag/context/extra/
  URL/db-error and asserts none survives the serialized wire event;
  `diagnostics_test.dart` asserts the installed sink strips amounts/card/JWT/email
  and bounds length.

### D. Temporary exports & third parties

- **Managed export store** (`ManagedExportStore`) owns the lifecycle for every
  export temp file (report PDF / CSV / full-data package), shared app-wide via a
  provider.
- **Opaque filenames.** On-disk name is `<uuidV4>.<ext>`; the friendly share name
  is carried separately and used only in the share sheet. A test asserts financial
  data never appears on disk.
- **Private directory + iOS file protection.** Files live in a dedicated
  `mali_exports` subdir of the app temp area; each payload + `.meta.json` sidecar
  passes through `ExportFileProtector` → native `mali/export_protection` channel →
  `NSFileProtectionComplete` + backup-exclusion on iOS (Android no-op: FBE +
  `allowBackup=false`).
- **Startup + resume cleanup / bounded lease.** Bootstrap `sweep()` (no age)
  deletes **everything** in the managed dir (fresh process ⇒ no in-flight share);
  app-resume `sweep(olderThan: 6h)` reclaims leased files; `defaultLease = 6h`.
- **Cancellation/failure.** `dispose()` deletes file + sidecar, idempotent, never
  throws, retries up to 3×; callers dispose in `finally` on success/cancel/failure
  because the share sheet can't distinguish them. Corrupt sidecar → treated as
  epoch-0 so a leased sweep still reclaims it.
- **No full-ledger clipboard fallback.** On share failure the full-ledger/package
  path surfaces the error and asks to retry — the clipboard fallback (and the dead
  `data_export.dart`) was removed. Remaining `Clipboard` uses are unrelated
  (recovery code, support email, coupon code, inbound paste).
- **Merchant / logo consent gate.** `remoteMerchantLogosAllowedProvider` fails
  **closed** (`false` while loading/errored/unset). The **exact identifier that
  leaves the device is a known public domain** (from a hardcoded merchant→domain
  map), never the raw merchant string, and only to build a `logo.dev` URL or use an
  admin-catalog `logoUrl` — and only when cloud-processing consent is ON.
  Data-minimization ladder: bundled offline SVG (always) → remote logo (consented)
  → offline letter mark (denied). Consent OFF ⇒ zero outbound requests. **Honest
  note:** the domain is 1:1 with the recognized merchant, so it does reveal which
  merchant is being viewed — which is precisely why it is consent-gated.

### E. AI endpoint security matrix

**Gateway note:** only `purge-scheduled-deletions` and
`process-notification-retries` set `verify_jwt = false`; all others rely on the
Supabase platform default `verify_jwt = true` (a valid apikey/JWT — including the
public anon key — passes the gateway) and then perform their own identity
resolution. Shared helpers: `_shared/ai_endpoint.ts` (typed error envelope,
`resolveVerifiedIdentity`, `consentError`, bounded `readJsonBody`,
`fetchWithTimeout`, `claim/completeIdempotency`, `safeLog`) and
`_shared/capture_auth.ts` (`verifyDevice`, `timingSafeEqual`, `installHash`,
rate-limit RPC).

| Function | Authoritative identity | Consent (fail-closed?) | Rate limit | Payload cap | Idempotency | Typed errors | Upstream timeout | Logging |
|---|---|---|---|---|---|---|---|---|
| **parse-sms** | device secret **or** user JWT (install_id alone → `authentication_required`) | `ai`, **fail-closed** | 500/day/identity | body ≤8 KB, sms ≤2000 | 0071 claim/complete (hash only, optional) | Yes (errors) | Gemini 12 s | None; re-sanitizes; only a hash persisted |
| **bank-discovery** | device secret or user JWT | `ai`, fail-closed | 50/day | body ≤8 KB, sms ≤1200–2000, sender ≤64 | None *(flag)* | **Mixed** — legacy `200 {error}` on AI-result failure *(flag)* | Gemini 12 s | `safeLog` sender **hash** + length only; PII guard |
| **enrich-merchant** | device secret or user JWT | **`cloud`**, fail-closed | 200/day | body ≤4 KB, name ≤200 | 0071 claim/complete (hash) | Yes | Places 8 s | Never echoes merchant/upstream error |
| **set-device-consent** | **device secret only** (user JWT rejected) | n/a — *is* the consent write path | 200/day | body ≤2 KB | Absolute update (naturally idempotent) | Yes | n/a | None |
| **process-ios-sms** | device secret via `verifyDevice` (no user-JWT path) | **server-owned `ai_consent_granted`** (fail-closed); `allowAi` is compat-only and cannot override OFF; revoked blocks AI | 300/day/install | **bounded body (16 KB) via `readBoundedJsonBody`** + SMS ≤2000 / sender ≤64 | `processed_captures` existence + 23505 convergence | Legacy `{error}` codes | Gemini 3.5 s | Metadata only (no raw sms/sender/merchant); persists `sanitized_text` for review rows (storage) |
| **register-device** | `install_id` only (unauth bootstrap — *issues* the secret) | n/a | 20/day/installHash | no byte cap | Upsert on installHash; rotates secret each call | Legacy | n/a | None; returns the issued secret |
| **merchant-feedback** | **RETIRED** — Bearer required else 401; gateway also guards | n/a | n/a | n/a | n/a | Explicit **410** `{retired, replacement:'enrich-merchant'}` (not a silent 200) | n/a | None |
| **evaluate-gamification** | **service-role Bearer only** (constant-time compare) → 403 | n/a (webhook) | n/a | raw (trusted webhook) | **`award_gamification_for_transaction` RPC — atomic exactly-once** (see §J) | Plain `Forbidden`/`OK` | APNs (helper) | No sensitive content |

**catalog/workers (auth model, brief):** `catalog-delta`/`catalog-versions`/
`catalog-announcements`/`catalog-campaigns` — public GET, service/anon DB client,
no per-caller identity, serve only active/validated public rows;
`catalog-flags` — public GET with optional user JWT for per-user flags;
`parser-test` — admin-only (Bearer + `admin_users` allowlist, 403 otherwise).

**Migration 0071** adds `capture_devices.ai_consent_granted /
cloud_processing_enabled / revoked_at` (default **FALSE** = fail-closed) plus the
`ai_request_idempotency` table (RLS deny-all) and its locked-down RPCs
(`claim/complete/prune_ai_idempotency`, revoked from anon/authenticated).
`parse-sms`/`enrich-merchant` use the idempotency RPCs;
`bank-discovery`/`set-device-consent` use the consent columns only.

**Consent propagation (client → server).** `set-device-consent` writes booleans to
the verified `capture_devices` row; consent is **never** a per-request
caller-supplied boolean on the hardened endpoints. `syncBackendState()` dispatches
per platform: **iOS** `syncNativeState()` mirrors consent after obtaining the
verified `deviceSecret` (re-runs on toggle → immediate revocation); **Android**
`_syncAndroidConsentState()` registers a device only once the user opts into
cloud/AI, then mirrors consent. Both are best-effort and fail closed; a
purely-local user never gets a server row. Caller-selected install IDs are never
authoritative — `resolveVerifiedIdentity` derives the owner key server-side from a
verified device secret or a real user JWT.

**Residual notes for E:**
1. **`process-ios-sms` — HARDENED (closure correction).** AI is now gated by the
   **server-owned `ai_consent_granted`** record; `allowAi` is compatibility
   metadata only and can never override a server OFF; a revoked credential blocks
   AI on the next request; the read fails closed (also safe while 0071 is
   undeployed). The body is read through `readBoundedJsonBody` (16 KB ceiling,
   does not trust Content-Length, UTF-8-byte-aware), with bounded SMS/sender/
   payload lengths and a strict `schema_version`. All gates (body → schema →
   device auth → ownership → consent → quota → idempotency) precede any Gemini
   call. The idempotency replay is checked before the quota bump by design (a
   lost-response retry must not consume quota); both still precede Gemini.
2. **Consent-default asymmetry (unchanged, noted):** the *device* path is
   strictly fail-closed (0071 default FALSE); a *user-JWT* caller with an existing
   `user_settings` row defaults consent **ON** (only a missing row is OFF).
   Confirm intended in staging.
3. **`bank-discovery`** returns a legacy `200 {error}` on AI-result failure rather
   than the typed envelope (auth/consent/rate/payload paths do use it) — a minor
   consistency note, outside the 060n identity/consent boundary.

### F. Notification authority matrix

**Two cross-cutting facts.** (1) **APNs is iOS-only** — every server push is Apple
HTTP/2; there is **no Android/FCM server push**, so Android is local-only for
every type. (2) **Every notification type now has exactly one authority contract**
(Phase-5 closure correction). Capture-review, budgets, goals, and achievements use
an explicit **local-primary / server-fallback** model — the server pushes only
when no device has been active recently (`anyDeviceRecentlyActive`). Bills,
streaks, and weekly reports are **local-scheduled-authority only** (the redundant
server cron push was retired — a scheduled local notification fires via the OS
even when the app is idle, so `anyDeviceRecentlyActive` cannot coordinate it). No
type generates an independent local **and** server notification for the same
business event.

| Type | Active authority | Fallback | Stable event ID | Dedup / reconciliation | Prefs / quiet hours | Privacy | Multi-device |
|---|---|---|---|---|---|---|---|
| **Capture review** | iOS Shortcut path → server APNs; Android/Share/relay → local | Local fires iff native did **not** (`shouldShowLocalReview`: false when `sent`/imported/`!ownerValid`); a **lost** APNs response still fires local | `notificationEventId('review', txnId)` (SHA-256 of type+key, **not** text) | id-collapse; server durable idempotency via `source_payload_id` + `apns_push_sent_at` | `captureReview`; **quiet hours bypassed** (time-sensitive) | redacted generic content; channel `private`; no balance | server fans out to all devices |
| **Transaction review** | *Not a distinct type* — same as capture review | — | — | — | — | — | — |
| **Capture "light"** (confirmed/dup/unprocessable) | local only | none | `notificationEventId('captureLight', stableId)` — `stableId` = txn id **or** an immutable content fingerprint, **never display text** | id-collapse | `captureLight`; quiet hours bypassed | redacted | local per device |
| **Budgets** | **local primary**, server fallback | server pushes only if **no device active in 6 h** (`anyDeviceRecentlyActive`); watermark still advances | `budgetAlertNotificationId(budgetId, periodStart, bucket)` SHA-256 — `notifId` now **required** (no text-hash fallback) | tier buckets 75/90/100 %; server fires only on new higher tier / +10 % | `budgetWarning`/`budgetOver`; local reschedules past quiet hours; server coarse country→UTC offset | redacted; channel `private` | server fans out |
| **Bills / subscriptions** | **local scheduled only** (server cron push **RETIRED**) | none — the OS fires the schedule even when the app is idle | `billReminderNotificationId(bill.id)` SHA-256 `[92000,992000)` | id = f(bill.id): edit keeps id (OS replaces); delete → dropped from set → capacity planner cancels stale | `subscriptionReminder` + `reminderOn`; quiet-hours shift | redacted; channel default | local per device |
| **Goals** | **local primary**, server fallback | server pushes only when **no device active in 6 h** (`anyDeviceRecentlyActive`); durable watermark still advances | `goalMilestoneNotificationId(goalId)` (local) + stable server collapse id `goal:<goalId>:<milestone>` | crossed-once (`last_notified_saved_amount`) | `goalMilestone` + quiet hours (`isPushAllowed`); redacted content in privacy mode | redacted | server fans out |
| **Weekly reports** | **local scheduled only** (Sat 09:00, id `91001`) | none | constant `91001` | single fixed id; re-planned each cycle | `weeklyReport`; `nextAllowedRiyadh` | redacted | local per device only |
| **Streaks** | **local scheduled only** (20:00, id `88008`; server cron push **RETIRED**) | none | fixed `88008` | cancelled if active today / pref off | `streakReminder` (local gate) | redacted | local per device |
| **Achievements** | **local primary** (gamification sync on pull), server fallback | server pushes only when **no device active in 6 h**; gated by the full policy | `achievementNotificationId(key)` (local) + stable server collapse id `gamification:<txnId>` | first post-sign-in pull suppressed (no history replay) | `achievements` per-type + quiet hours + lock-screen privacy — **now enforced server-side** in `evaluate-gamification` (`isPushAllowed`/`hideLockScreenContent`) | redacted | server fans out |
| **Sync / conflict** | **Not a user notification** — silent data reconciliation + DB status-monotonicity guard only | — | — | — | — | — | — |
| **Backup / security** | **Not implemented** — no backup/security/login/new-device notification exists | — | — | — | — | — | — |

**Sign-out cleanup (all managed reminders):** `cancelScheduledReminders()` cancels
bills `[92000,992000)`, weekly `91001`, streak `88008`; `PendingNotification`
`Actions.clear()` deletes the background-action file. Capture authority suppresses
when `ownerValid=false`.

### G. Notification delivery terminology

- **Client lifecycle events:** `created → queued → sent → failed / opened`
  (`recordOpened` is idempotent). Channels: `local_ios`, `local_android`,
  `ios_shortcut_local`, `apns`.
- **Server/DB state model** (`notification_logs.status`): `pending / queued / sent
  / opened / failed`, timestamps per state, **monotonic** via a trigger
  (regressive writes silently keep current status).
- **States actually observable:** created/pending, queued, sent, failed, opened,
  plus a **locally-presented** notion (recorded as `sent` on a local channel + an
  in-app inbox row). There is **no** `eligible`, `scheduled`, `attempted`,
  `accepted`, `cancelled`, or `expired` status in the model — use these words only
  descriptively, not as if they were tracked.
- **Confirmations (both hold in code):** APNs acceptance is **not** treated as
  delivered/displayed (`sent` = "Apple's API accepted the request"); collapse IDs
  are banner-replacement only, **not** strict idempotency (durable dedup is
  `source_payload_id` / `apns_push_sent_at`).
- **Retry model:** transient APNs failures (429/500/503) enqueue a durable
  `notification_retry_queue` row (max 5 attempts), drained by
  `process-notification-retries` with `claim_notification_retries` (FOR UPDATE SKIP
  LOCKED); non-transient (`BadDeviceToken`/410) → exhausted immediately.

### H. iOS & Android scheduling

- **iOS pending-capacity planner** (`NotificationCapacityPlanner`): iOS silently
  drops past ~64 pending; internal `capacity=60`, `reservedForImmediate=8` →
  window budget 52 (headroom so immediate/high-priority alerts always fit).
  Priority: `subscriptionReminder=3`, `weeklyReport=1` (dropped first); ties break
  by nearest-due. Past-due filtered out; managed pending that fall out of the
  window are cancelled. `schedulePlannedNotifications` reads the **live** pending
  set, restricts to managed ids, cancels stale, schedules survivors, then
  **verifies the actual pending set** (safe count) rather than assuming
  acceptance. Distant recurrences roll forward at replenish.
- **Android:** exact-alarm permissions **not declared** (Play-restricted);
  every schedule is `inexactAllowWhileIdle` (never throws, no runtime grant).
  Reboot: `RECEIVE_BOOT_COMPLETED` + boot receiver reschedules. Timezone: tz-based
  `zonedSchedule` over device IANA zone (fallback Asia/Riyadh; no dedicated
  timezone-change receiver). Edit reuses the business-key id (OS replaces); delete
  drops it → capacity planner cancels the stale pending. Sign-out cancels all
  managed ids. Action buttons route via `ActionBroadcastReceiver` to the
  background isolate, with persisted replay when the DB is locked.
- **External-only for H:** iOS live 64-limit behavior; Android on-device reboot /
  timezone / inexact delivery; Play exact-alarm policy confirmation.

### I. Backend security model

Migration **0072** (undeployed) + the SD inventory:

- **SECURITY DEFINER inventory outcome:** migration-lint checks **20** SD
  functions; all are locked down. A precise per-function audit found exactly two
  missing a fixed `search_path` — dead `handle_new_user()` (dropped) and
  `prune_processed_captures()` (recreated `SET search_path = public` + re-locked);
  all others already had one.
- **Fixed `search_path`** is required on every SD function (search-path-injection
  surface removed).
- **Grants / PUBLIC revocation:** privileged RPCs `REVOKE ALL … FROM PUBLIC, anon`
  (and `authenticated` where not owner-facing) and `GRANT EXECUTE … TO
  service_role` (or `authenticated` for the owner-bound `record_metric`).
- **RLS ownership:** owner policies `user_id = auth.uid()`; `service_role` bypasses
  RLS by design (the sole authoritative writer for server-owned aggregates).
- **Metrics:** the `with check (true)` free-for-all authenticated insert is
  **removed** + INSERT revoked; the owner-bound `record_metric` RPC (allowlist,
  length bounds, atomic per-user daily quota via deny-all `metrics_rate_limits`,
  no PII) is the only path; the client routes through it.
- **Purge/retention:** `purge_user_data` extended (FK-safe order) to cover AI
  idempotency (by owner_key), engagement events, metrics-quota rows, and the
  gamification award ledger.
- **merchant-feedback retirement:** the anonymous no-op is retired — requires a
  Bearer token and returns 410 → `enrich-merchant`.
- **Administrative/worker authority:** `parser-test` admin-allowlisted; pg_cron
  workers (`prune_*`, reminders, purge) are service-role only.

### J. Gamification authority (the eight distinct layers)

| # | Layer | Authority | State |
|---|---|---|---|
| 1 | **Local Drift projection** (`xp_levels`/`streaks`/`achievements` local tables) | client-owned **optimistic projection** | active |
| 2 | **Local engagement-event outbox** | client-owned; bounded submit (retry→dead-letter, projection preserves progress) | **active** (production/submission) |
| 3 | **Migration-0070 event authority** (`record_engagement_event` RPC + `user_engagement_events`) | server-authoritative, idempotent, owner-from-`auth.uid()` | **unavailable/inactive while undeployed** (RPC 404s) |
| 4 | **Legacy transaction award authority** (`evaluate-gamification` webhook) | server (service-role) | **active — the sole live award path** |
| 5 | **Authoritative Supabase aggregate tables** (`user_xp_levels`/`user_streaks`/`user_achievements`) | server (service-role) writes; clients **read-only** after 0073 | active |
| 6 | **Award idempotency ledger** (`gamification_awarded_transactions`) | server only (deny-all RLS) | active |
| 7 | **Notification eligibility** (recorded with the award) | server, in the award transaction | active |
| 8 | **External provider delivery** (APNs) | best-effort, after commit, stable collapse id | active |

> **Do not describe the engagement client as "fully dormant."** Precisely: local
> event **production/submission code = active**; migration-0070 **server
> processing authority = unavailable/inactive while undeployed**; **legacy award
> authority = active**.

**Authoritative-vs-projected:** layers 5/6/7 (Supabase) are authoritative;
layers 1/2 (Drift) are a local optimistic projection reconciled by pull. After
0073, normal authenticated clients **cannot write** the authoritative aggregates
(owner insert/update policies dropped; INSERT/UPDATE/DELETE revoked; SELECT kept);
the client is verified pull-only, so there is no bootstrap-write dependency.

**Final atomic RPC contract (migration 0074 — `award_gamification_for`
`_transaction`, SECURITY DEFINER, fixed `search_path`, service_role-only):** in
**one PostgreSQL transaction** it (a) **verifies ownership** (the transaction must
belong to the target user — caller identity not trusted), (b) **claims** the
stable idempotency key (`ON CONFLICT DO NOTHING`), (c) if already claimed
**returns the stored canonical result** (replay reconstructs the same outcome),
(d) applies the **XP/level** mutation, (e) computes the **canonical achievement
result**, (f) records **notification eligibility** atomically with the award, and
(g) returns the canonical result. Because claim + award share one transaction, a
crash rolls the claim back with the award (no lost/partial award); concurrent
workers serialize on the claim row lock (exactly-once). **Notification eligibility
is exactly-once with the award; provider delivery is best-effort/at-least-once
after commit, keyed by a stable `gamification:<txnId>` collapse id** — a send
failure never rolls back or re-awards.

**Activation gate (engagement authority, layer 3):** before migration 0070's
authority may go live, **all** must hold — migrations deployed and verified;
0070 concurrency/security tests green under real Postgres; the client event
authority enabled; **and the overlapping legacy award authority (layer 4) disabled
in the same release/change** (else a transaction would be double-awarded). Until
then 0070 stays inactive and layer 4 remains the sole award path.

---

## 2. Phase-5 finding reconciliation

Statuses use exactly: `Closed — locally verified` · `Code complete — locally
verified; external verification pending` · `Not closed — exact remaining code
defect`. No physical-device, live-Postgres, APNs, or store-policy check is marked
complete without evidence.

| Finding | Original defect | Root cause | Remediation | Commits | Tests | Locally verified | External acceptance criteria | Final status |
|---|---|---|---|---|---|---|---|---|
| **MALI-031** | Secrets in plaintext `UserDefaults`; capture queue plaintext | No shared-Keychain / at-rest encryption | Device secret + queue key → shared Keychain; queue AES-GCM; corrupt fail-closed no-delete; secret invalidated on wipe | `30b4f3fc` | iOS sim build + `xcodebuild test` 6/6 (encryption/secret/purge) | Encryption, purge, corruption-fail-closed | Shared-Keychain cross-process app↔extension under real provisioning + entitlement | Code complete — locally verified; external verification pending |
| **MALI-032** | Free-form text could ride Sentry events | No outbound allowlist | `beforeSend`+`beforeBreadcrumb` allowlist; class-name+stripped frames only; native auto-breadcrumbs off | `bff0f1d8` | Canary tests (every sensitive class) | No canary survives serialized event | Native-SDK crash scrubbing parity | Code complete — locally verified; external verification pending |
| **MALI-033** | Android Auto Backup would restore incoherent Keystore-bound data | `allowBackup` default on | `allowBackup=false` + `fullBackupContent=false` | `5c88417c` | `android_backup_policy_test` (manifest static) | Manifest attributes set | On-device restore-attempt exclusion; (no `dataExtractionRules` XML — flagged) | Code complete — locally verified; external verification pending |
| **MALI-060n** | AI/paid endpoints trusted caller install_id | No server-verified identity/consent/idempotency | `_shared/ai_endpoint.ts`: verified identity, fail-closed consent, per-identity rate limit, typed errors, bounded bodies, upstream timeouts, 0071 idempotency; `set-device-consent`. **Closure:** `process-ios-sms` brought onto the same boundary — server-owned consent (`allowAi` compat-only), `readBoundedJsonBody` cap, schema/length limits, gate ordering before Gemini | `b6c990f8`/`9bf26554`/`2aa29d60`/`3316c154`/`8dd5f1b1` + closure | deno shape + `readBoundedJsonBody` unit tests + static ordering + credential-gated real-backend gates | Identity/consent/limit/idempotency shape; process-ios-sms bounded/consent-gated (verified) | Live migration apply + RPC concurrency + Android consent-push + live `process-ios-sms` consent under 0071 | Code complete — locally verified; external verification pending |
| **MALI-061n** | Notification identity off mutable display text/hashCode | Unstable ids; dual budget authority; capture double-fire; uncoordinated goal/streak/bill/achievement paths; text-derived captureLight/budget ids | Stable business-key ids; budget local-primary/server-fallback; `CaptureNotificationAuthority`. **Closure:** goals+achievements coordinated (server fallback via `anyDeviceRecentlyActive`), streak/bill server cron **retired** (local scheduled sole authority), captureLight id from a generated-before-notify stable key, budget `notifId` required (no text-hash fallback) | `1e217ce3`/`5b2c771b`/`c3ffc673` + closure | 5 capture-authority tests + stable-id tests + coordinated-fallback static contracts | Single authority per type; no "may duplicate"; display-text-independent ids | Live two-path device delivery; live two-device fallback timing | Code complete — locally verified; external verification pending |
| **MALI-065n** | Export temp files world-legible / clipboard leak | No managed lifecycle | `ManagedExportStore`: opaque names, private dir, iOS file-protection, startup+lease sweep, no clipboard fallback | `2d1072f6` | 9 filesystem tests + iOS sim build | Names/sweep/dispose/no-clipboard | Device file-protection + backup-exclusion attributes | Code complete — locally verified; external verification pending |
| **MALI-068n** | Non-durable native queue; receiver-time timestamps; exact alarms | apply-not-commit; `now` stamping; exact-alarm policy | Synchronous `commit()`; peek≠ack; epoch timestamp authority; inexact alarms; nullable receivedAt | `5c88417c`/`30b4f3fc`/`8337202e`/`d72e5785` | Dart/manifest contract + file-backed lease tests | Durability, lease, timestamp resolution | Android compile, receiver process-death replay, alarm delivery, reboot | Code complete — locally verified; external verification pending |
| **MALI-071n** | Merchant logos leaked merchant identity unconditionally | No consent gate | Consent-gated (fail-closed) domain-only logo ladder; no prefetch | `08e7ca0d` | 4 widget tests (no `Image` with consent off) | Zero requests when consent off | — (fully local-verifiable) | **Closed — locally verified** |
| **MALI-075n** | SD search_path gaps; metrics free-for-all insert; purge gaps | Missing hardening | 0072: SD search_path fix; owner-bound `record_metric`; purge coverage | `0010b037`/`4e927db5`/`975af849` | 11 backend contract tests | Migration shape | Live RLS/RPC/quota/purge under real Postgres | Code complete — locally verified; external verification pending |
| **MALI-019** | No server preference enforcement; lock-screen leak; title logged; gamification push ungated | Missing privacy contract; `evaluate-gamification` bypassed the policy | Server per-type + quiet-hours policy; lock-screen redaction; log-leak fix; sign-out reminder-cancel. **Closure:** `evaluate-gamification` now routes the post-award push through `loadNotificationPolicy`/`isPushAllowed('achievement')` + quiet hours + `hideLockScreenContent` redaction + device eligibility + coordinated fallback | `224394fd`/`f7cbe727` + closure | Redaction + reconciliation + quiet-hours tests + gamification-policy deno tests + static contract | Achievement push gated by prefs/quiet-hours/privacy server-side | Device lock-screen render; server quiet-hours is coarse country→UTC | Code complete — locally verified; external verification pending |
| **MALI-024** | Client could forge XP; award not crash-safe | Owner aggregate-writes; claim+award non-atomic | 0073 read-only aggregates; 0074 single-transaction exactly-once award | `9fdd30e7`/`c4f2aea0`/`ae1f967b` | Contract + credential-gated concurrency/replay/ownership | Read-only shape, atomic award structure | Live RLS + award-RPC concurrency; migration 0070 stays inactive | Code complete — locally verified; external verification pending |
| **MALI-025** | iOS 64-pending overflow silently drops | No capacity planner | `NotificationCapacityPlanner` (reserve, priority, rolling window, verify pending) | `9128589e` | 5 planner tests | Planner logic | On-device 64-limit behavior | Code complete — locally verified; external verification pending |
| **MALI-044** | Dead anonymous no-op endpoint (fake success) | Never-implemented TODO | Retired: Bearer + 410 → `enrich-merchant` | `6ddd5aaa` | Contract test | 410 + auth shape | Live deployment + endpoint authorization | Code complete — locally verified; external verification pending |
| **MALI-039** (P5 portion) | `debugPrint` leaks in release; unsanitized logs | No central sink | Global redacting `debugPrint` sink + `Diag` API; length-bound | `0010b037` | `diagnostics_test.dart` | Redaction + bound (debug & release) | — (locally verifiable) | Code complete — locally verified; external verification pending |

No Phase-5 finding is `In progress`; none is `Not closed` (no known remaining
*code* defect within Phase-5 scope). The four production-code defects surfaced by
this document's own honesty — the ungated gamification push (MALI-019), the
uncoordinated goal/streak/bill/achievement paths and two text-derived ids
(MALI-061n), and the `process-ios-sms` caller-authorized-AI / unbounded-body tail
(MALI-060n) — were **fixed** in the Phase-5 closure correction, not deferred. They
were inside the scope of MALI-019/061n/060n and are now coordinated, stable-id'd,
and consent/limit-gated respectively, with tests.

---

## 3. Migration & activation inventory

All migrations are additive, backward-compatible, guard-created (idempotent
re-apply), and **undeployed**. They apply strictly in order.

| Mig | Purpose | Depends on | Capability / activation gate | Deploy status | Required staging tests | Rollback / forward-recovery | Safe while undeployed? |
|---|---|---|---|---|---|---|---|
| **0068** | Entity revision CAS (server optimistic concurrency) | existing per-table RLS | Client CAS stays OFF until `kServerRevisionCas=true` **and** 0068 verified in staging | Undeployed | Cross-user CAS conflict; monotonic revision | Drop `revision` + trigger restores prior shape | **Yes** — client CAS gated OFF |
| **0069** | Sender-mapping keyset pagination + tombstones | `sender_bank_mappings` | Client already tolerant; activates on deploy | Undeployed | Keyset paging, tombstone propagation | Drop `deleted_at` + trigger + index | **Yes** — safe while 0068 OFF |
| **0070** | Engagement-event authority (`record_engagement_event`) | (independent) | **Must NOT activate while legacy award (layer 4) active** — deploy + disable legacy in the same change | Undeployed | Concurrency/security (owner from `auth.uid()`, idempotent, reject unknown/unsupported) | Drop RPC + table; Edge award path unaffected | **Yes** — client submit 404s, bounded retry |
| **0071** | AI consent columns + idempotency ledger | `capture_devices` | Endpoints already reference RPCs; activates on deploy | Undeployed | Identity/consent/idempotency concurrency | Drop columns + ledger + RPCs | **Yes** — endpoints degrade to local on 404 |
| **0072** | Backend/metrics/purge/SD hardening | metrics, capture, purge targets | Activates on deploy | Undeployed | RLS, metrics quota, SD grants, purge isolation | `OR REPLACE`/`IF EXISTS` re-runnable | **Yes** |
| **0073** | Gamification aggregate read-only authority | 0056/0062 | Activates on deploy | Undeployed | Forged-write denial (RLS) | Re-add owner policies + grants | **Yes** — client is pull-only |
| **0074** | Atomic legacy award RPC + result columns | **0073** (ledger table) | Activates on deploy; edge already calls the RPC | Undeployed | Award concurrency, replay, ownership | Drop RPC + columns | **Yes** — must deploy **with/after 0073** |

**Explicitly recorded:** all migrations remain **undeployed**;
`kServerRevisionCas = false`; migration 0070 **must not** be activated while the
overlapping legacy authority is active; **0073 and 0074 deploy together or in the
verified dependency order** (0074 extends 0073's table); **no migration
deployment is part of this closure batch.**

---

## 4. External verification checklist

One deduplicated list, grouped by environment. Phase-3/4 device checks are not
repeated here — see `PHASE_3_SYNC_CLOSURE.md` and
`PHASE_4_FINANCIAL_SEMANTICS.md`.

### Signed iOS device (paid Apple Developer account)
- [ ] Shared Keychain access group `…mali.shared` resolves under a real
      provisioning profile + `keychain-access-groups` entitlement.
- [ ] App Identifier Prefix resolves; host app + Share Extension + App Intent
      share the **one** device secret and **one** queue-encryption key.
- [ ] Runner / Share Extension / App Intent cross-process **encrypted** queue
      access works under code-signing.
- [ ] `NSFileProtectionComplete` on the managed export temp file + sidecar;
      confirm the App Group plist/queue container protection level (not set in
      code — verify OS default is acceptable, or add an explicit entitlement).
- [ ] Export files excluded from iCloud/device backup.
- [ ] Lock-screen redaction renders generic content for every notification type.
- [ ] iOS pending-notification capacity behavior at the ~64 limit.
- [ ] APNs push + local fallback both deliver; capture single-authority holds on a
      lost APNs response.
- [ ] Notification route/log queues clear on sign-out.

### Android toolchain / device
- [ ] Release compilation.
- [ ] Native receiver process-death → durable queue replay (peek≠ack; crash after
      Drift commit is idempotent).
- [ ] `timestampMillis` authority for real SMS; legacy/malformed → documented
      fallback (never `now`).
- [ ] Backup/device-transfer exclusion via `allowBackup=false` +
      `fullBackupContent=false` (no `dataExtractionRules` XML — confirm this is
      sufficient on Android 12+ transfer).
- [ ] Reboot restoration of scheduled reminders.
- [ ] Inexact-alarm delivery within tolerance.
- [ ] Timezone changes (no dedicated receiver — confirm tz-based reschedule).
- [ ] Consent push after opt-in (Android registration path).
- [ ] Sign-out cancels all managed reminder ids.
- [ ] Play Console exact-alarm policy confirmation (no exact-alarm perms declared).

### Supabase staging / PostgreSQL
- [ ] Migration apply from baseline **through 0074**, clean install **and**
      upgrade.
- [ ] RLS cross-user tests (no user reads/writes another's rows).
- [ ] SECURITY DEFINER grants (no PUBLIC/anon execute on privileged RPCs).
- [ ] `record_metric` per-user daily quota + allowlist under load.
- [ ] `purge_user_data` isolation (only the target user's rows, FK-safe).
- [ ] AI identity/consent/idempotency concurrency (no double-pay on retry).
- [ ] Gamification **forged-write denial** (authenticated cannot write aggregates).
- [ ] **Atomic award concurrency** (two workers → award once).
- [ ] **Response-loss retry** reconstructs the same canonical result.
- [ ] Notification-eligibility uniqueness (no duplicate eligibility row).

### Multi-device
- [ ] Notification fallback-coordination timing under real two-device use: the
      server suppresses budgets/goals/achievements when a device was active in the
      last 6 h (`anyDeviceRecentlyActive`); confirm the window is well-tuned and
      that streak/bill (local-scheduled only, server cron retired) never double-fire.
- [ ] Capture deduplication across devices.
- [ ] Ownership / sign-out isolation.
- [ ] Preference & privacy propagation across devices.

---

## 6. Architectural guardrails (permanent) + enforcing tests

| Guardrail | Enforcing test(s) |
|---|---|
| Secrets never in plaintext `UserDefaults` | `SharedCaptureStore` behavioral tests (iOS `xcodebuild test`); Keychain migration path |
| Shared queues use encryption + cross-process locking | iOS encryption/lease tests; `withQueueLock` path |
| Native queue items are not acked before Drift commit | `capture_sync_service_test`; file-backed native-queue lease test (peek≠ack) |
| Telemetry is allowlist-based | `telemetry_privacy_test.dart`; `backend_hardening_contract_test` (record_metric allowlist) |
| Financial/user content never enters logs | `telemetry_privacy_test.dart`, `diagnostics_test.dart`, `notification_privacy_test.dart` |
| Temporary exports have a bounded lifetime | `managed_export_store_test.dart` (startup/lease sweep, dispose) |
| Merchant identity not sent without consent | `brand_mark` widget tests (no `Image` with consent off) |
| Caller-selected install IDs are never authoritative | `ai_endpoint` verified-identity path; contract assertions |
| Server consent is authoritative (fail-closed) | 0071 defaults + `consentError`; contract tests |
| Notification events have one authority contract | `capture_notification_authority_test.dart` |
| Lock-screen redaction is centralized | `notification_privacy_test.dart` |
| Normal clients cannot write gamification aggregates | `backend_hardening_contract_test` (0073) + `gamification_authority_node_test` (credential-gated RLS) |
| Authoritative awards are transactionally idempotent | `backend_hardening_contract_test` (0074 shape) + `gamification_authority_node_test` (concurrency/replay/ownership) |
| PUBLIC cannot execute privileged RPCs | migration-lint SD lockdown (20 SD functions) + contract grants |
| Direct arbitrary metrics inserts are denied | `backend_hardening_contract_test` (policy removal + RPC routing) |
| Purge covers every identity/token/idempotency table added in Phase 5 | `backend_hardening_contract_test` (purge coverage) |

---

## 8. Phase-5 closure verdict

**`Phase 5 code complete — locally verified; signed-device, Android, APNs,
store-policy, and live-PostgreSQL verification pending.`**

This is not a claim that the remediation **program** is complete: Phases 6–9,
MALI-026, live external validation, and the remaining audit findings are
outstanding. The final completion signal remains **forbidden**.
