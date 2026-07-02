# Qirsh — iOS Backend-First SMS Processing: Architecture Plan

Status: **PHASE 1 VALIDATED — Phase 2 APNs implementation in progress.**
Date: 2026-07-03 · Branch: `feat/accounts-multicurrency`

---

## 1. Current flow summary (as inspected, not assumed)

**iOS (today):**
```
SMS → Shortcut Automation → App Intent source/target
    (BankMessageShortcuts target exists, but the appex is not embedded in Runner)
    → sanitize? NO → parse? rules-preview only (parser_rules.json)
    → enqueue payload to App Group (SharedCaptureStore, payloadId = SHA-256)
    → local preview notification (rules-based; useful but not the final engine result)
    → Darwin notification (wakes Flutter ONLY if app is alive)
App opens → drains App Group queue → full Dart engine (parser → AI fallback
    → categorizer → dedup) → Drift save → local detailed notification
```

**Backend (today):**
- `parse-sms`: AI-only (Gemini), anon-JWT, 20/day rate limit per install-hash,
  takes `sanitized_sms + install_id`, returns parsed JSON. **Saves nothing.**
- `enrich-merchant`, `bank-discovery`, `merchant-feedback`: category/discovery
  helpers. **No transactions table exists server-side. No push infrastructure.**
- Transactions currently NEVER leave the device except E2E-encrypted backups.

**The gap:** Flutter does not run in the background on iOS, so the detailed
processing (and its notification) waits until the app opens.

---

## 2. New backend-first flow

### App closed / background (consent ON, online)
```
SMS → Shortcut → App Intent
  1. payloadId = existing SHA-256 (reuse SharedCaptureStore.makePayloadID)
  2. sanitize SMS in Swift using sanitization rules ADDED to parser_rules.json
     (same cross-runtime contract pattern we already ship + test)
  3. POST process-ios-sms {payloadId, installId, deviceSecret, sanitizedText,
     sender, receivedAt, locale, source:"ios_shortcut", allowAi}
  4. ALWAYS also enqueue to App Group with status:"sent" (audit + fallback)
  5. On HTTP failure/timeout(8s): mark status:"pending", local fallback
     notification «قِرش رصد رسالة بنك / تم استلام رسالة بنك. افتح قِرش لمراجعتها.»
Backend:
  validate → idempotency check (payloadId PK) → re-sanitize → deterministic
  TS pass (executor of parser_rules.json + server bank_rules/sms_parsers
  catalog) → AI fallback iff allowAi && low confidence (reuse parse-sms
  internals) → categorize (merchant_keywords table) → duplicate fingerprint
  check → decide: processed | needs_review | duplicate → store row in NEW
  `processed_captures` table → return full result JSON with `notification`
  {title, body, type}
  6. App Intent schedules a Qirsh local notification from that exact returned
     `notification` object. No APNs, no push token, no foreground banner.
App later opens → sync processed_captures → import into Drift (source of
  truth) → ack → server row deleted → THEN drain App Group queue, skipping
  payloadIds already imported.
```

### App open / foreground (consent ON)
Identical intent behavior (always backend-first). In Phase 1 the app learns
the result only through the existing Darwin notification (when Flutter is
alive) or on next start/resume sync. No APNs and no foreground/in-app banner
are introduced in Phase 1. The transaction list/dashboard refresh after sync
is enough; a foreground banner can be a separate later UX decision.

### Consent OFF (either cloud processing or offline)
Exactly today's local flow: App Group enqueue + Darwin notify + Flutter
processes on open. Notification while closed:
- Phase 1 default: generic only «قِرش رصد رسالة بنك / افتح التطبيق لمراجعتها.»
  to avoid promising an amount/category before backend consent exists.
- Optional local preview can remain as a product choice because nothing leaves
  the device, but it is not part of the backend-result/no-mismatch guarantee.

### Source-of-truth invariant (preserves CLAUDE.md rule 1)
`processed_captures` is an **ephemeral relay queue, not a ledger**. Drift
remains the single source of truth; UI never reads the network. Rows are
deleted on device ack, with a 30-day TTL sweep as backstop.

---

## 3. Required iOS changes

| File | Change |
|---|---|
| `BankMessageShortcuts.swift` | Add `BackendCaptureClient` (URLSession, 8s timeout, no retry — fallback instead). perform(): consent flag from App Group → sanitize → POST → enqueue with status → local notification from backend result or generic fallback. Still returns only `.result()`, no UI, no app open, no Flutter, no direct AI. |
| `SharedCaptureStore.swift` (×3 copies) | Payload gains `deliveryStatus: sent/pending` + `sentAt`. Keys for `cloud_processing_enabled`, `device_secret`, `backend_url`, public Supabase `anon_key`, and `install_id` in App Group defaults (written by Flutter via existing `money_companion/native_capture` channel). |
| `AppDelegate.swift` | No APNs work in Phase 1. Add only native-capture channel methods needed to write/read App Group backend flags and keep the existing Darwin wake path. |
| Notification permission denied | unchanged behavior: enqueue still happens; only the banner is lost. |

Constraint checklist honored: no Swift full-parser (sanitizer = rules-file
regexes, same contract mechanism as the preview), no AI from Swift, no
dialogs, `perform()` returns bare `.result()`.

## 4. Required Flutter changes

1. **Consent setting** `cloudProcessingEnabled` (new user_settings column,
   default **false**) + onboarding phase copy update + settings toggle with the
   three required sentences (sanitized text to secure backend / sensitive
   numbers sanitized before AI / can disable anytime). `aiConsentGranted`
   stays as the AI sub-gate (sent as `allowAi`).
2. **Device registration service**: on consent enable → `register-device`
   edge call → stores `deviceSecret` (returned once) + pushes it, `installId`,
   backend URL, public Supabase anon key, and the consent flag into App Group
   via new channel methods.
   The secret is a relay-only credential: it can read/write only
   `processed_captures` for the hashed install id, never user ledger data.
3. **Sync service** (`CaptureSyncService`): pull processed_captures →
   map to `TransactionEntity`/Smart Inbox item → write Drift (recording
   payloadId in dedup store) → ack after Drift commit → trigger UI refresh.
   Runs on: app start, resume, and Darwin wake. If ack fails after commit, the
   next sync sees the same row and skips by payloadId before retrying ack.
4. **Drain ordering change** in `app_shell._consumeSharedInput`: sync FIRST,
   then drain queue skipping already-imported payloadIds; `pending` entries
   process locally exactly as today (existing engine path untouched).

Android flow, Share Extension, existing engine, Smart Inbox, notification
service, onboarding routing: **untouched code paths** (drain still works
identically for any `pending`/legacy payloads and for consent-off users).

## 5. Required backend/Supabase changes

**New migration `0012_ios_capture_pipeline.sql`:**
- `capture_devices` (install_id_hash PK, device_secret_hash, platform,
  user_id nullable, created_at, last_seen_at) + RLS off / service-role only.
- `processed_captures` (payload_id text PK, install_id_hash, status
  processed|needs_review|duplicate|rejected, parsed jsonb {amount, currency,
  type, merchant, category, confidence, duplicateStatus, occurredAt, last4},
  notification jsonb {title, body, type}, sanitized_text text NULL — kept only
  when status=needs_review to let the app show context, else null, created_at,
  synced_at) + TTL cleanup function.
- `capture_fingerprints` (install_id_hash, fingerprint, seen_at) for
  transaction-field duplicate detection (amount+currency+minute-bucket+last4),
  pruned > 7 days.
- reuse `ai_rate_limits` pattern: new counters for capture calls
  (suggested 300/day/install) separate from AI calls (existing 20/day).

**New edge functions:**
- `register-device`: issues device_secret (random 32B, stored hashed),
  binds optional auth user. It must not grant access to any ledger data.
- `process-ios-sms`: the pipeline described in §2. Deterministic pass =
  TypeScript executor of `parser_rules.json` (file copied into the function
  at deploy; a Deno test runs the SAME embedded examples so all three
  runtimes share one contract) **plus** the server `sms_parsers` catalog
  regexes where sender matches. AI fallback reuses parse-sms's Gemini code
  (extracted to `_shared/` module). Categorization: merchant_keywords lookup
  (same table enrich-merchant writes). Response exactly per spec (status,
  ids, notificationTitle/Body, parsed fields).
- `sync-captures`: auth = installId+deviceSecret; returns unsynced rows;
  `ack` deletes rows only after the app has committed the result to Drift.

**Why not run the full Dart engine server-side?** The parser core is pure
Dart (portable via `dart compile js`), but the categorizer is coupled to
Drift DAOs — porting is a real project. Phase-1 uses the rules-contract +
catalog + AI pipeline above; **notification ⇄ transaction can never mismatch
because both are generated from the single backend result**. Cross-platform
parser parity (iOS-backend vs Android-local) is tracked by running the same
`parser_rules.json` examples in Deno tests, and a later spike (Phase 4,
optional) evaluates dart2js-compiling the engine core into the function.

## 6. APNs/push stance

Phase 1 deliberately does **not** use APNs, Push Notifications capability,
remote notification tokens, or foreground banners. The immediate notification
is a native local notification scheduled by the App Intent from the exact
backend response that is also written to `processed_captures`.

APNs can be revisited later only if we explicitly decide that background server
delivery is worth the signing/profile complexity. It is not required for the
accepted Phase 1 goal.

## 7. Consent & privacy changes

- New explicit **cloud processing** opt-in (default OFF) — onboarding AI
  phase becomes a two-line consent (cloud processing + AI fallback) with the
  spec's三 sentences; settings toggle mirrors it; disabling wipes
  device_secret server-side (`unregister`).
- Only **sanitized** text ever leaves the device (Swift sanitizes; server
  re-sanitizes — defense in depth, pattern already exists in parse-sms).
- Server retention: parsed rows deleted on ack / 30-day TTL;
  `sanitized_text` stored only for needs_review rows; raw SMS never stored;
  failures logged without message bodies (lengths + hashes only).
- Consent OFF ⇒ zero network calls from the intent (hard guarantee, flag read
  from App Group before any URLSession is created).

## 8. Offline / failure fallback

| Scenario | Behavior |
|---|---|
| POST timeout / 5xx / no network | payload status=pending in App Group; generic fallback notification; Flutter engine processes on next open (today's path) |
| POST 2xx | status=sent; App Intent shows local notification from the response; next sync imports the same row |
| Backend processed but local notification permission denied | sync on next open still imports it; only the banner is lost |
| Sent but sync later misses it (row TTL'd) | queue entries with status=sent older than 24h are re-processed locally through the dedup gate — worst case a duplicate check, never data loss |
| Rate-limited (429) | treated as failure → pending fallback |

## 9. Idempotency & duplicate prevention (3 layers)

1. **payloadId** (existing SHA-256 over text+sender+source+receivedAt —
   unchanged algorithm): PK of processed_captures; repeated POSTs return the
   stored result (true idempotency, safe Shortcut re-runs).
2. **Relay vs local drain**: sync imports record payloadId into Drift dedup
   store → drain skips them; `sent` entries skipped unless stale (>24h).
3. **Transaction-field dedup**: backend fingerprint table (7-day window)
   marks suspicious_duplicate before notification; Flutter's existing
   `DuplicateTransactionDetector` still runs at import for cross-source
   protection (share-extension vs shortcut, manual paste, etc.).

## 10. Testing plan

- **Deno tests** (`supabase/functions/tests/`): idempotency (same payloadId
  twice → one row, same response), consent flags, rate limit, sanitizer,
  deterministic pass over the SAME parser_rules.json embedded examples
  (three-runtime contract), duplicate fingerprint, needs_review threshold,
  and notification response payload.
- **Dart**: sanitization-rules mirror tests (extend existing
  shared_preview_parser_test pattern); CaptureSyncService import/ack/dedup
  tests with fake HTTP; drain-ordering test (sent vs pending vs imported);
  consent gating tests.
- **Swift**: `xcodebuild -target BankMessageShortcuts` + `swiftc -typecheck`
  (as done today); manual device matrix below.
- **Manual device matrix**: app killed / background / foreground ×
  online / airplane × consent on/off × duplicate SMS re-run; local
  notification permission allowed/denied.
- Existing gates every phase: `flutter analyze`, `flutter test` (399),
  full Android + share-extension regression by running existing capture tests.

## 11. Risks & limitations

1. **Privacy model shift** — first time transaction-derived data (sanitized)
   touches the server. Mitigated: opt-in default-off, sanitize-twice,
   ephemeral relay + TTL, needs explicit user approval of this plan.
2. **Local notification permission** — if the user denied Qirsh notifications,
   the backend result still syncs and saves later, but no immediate banner can
   be shown. Settings must make the test notification and permission status
   obvious.
3. **Backend result parity** — backend TS and local Dart are still separate
   implementations. The no-mismatch guarantee is between the local
   notification and the imported Drift transaction on the backend path because
   both use the same backend row; Android/local fallback still uses Dart.
4. **Parser divergence** (backend TS vs local Dart engine) — bounded by the
   shared rules contract + AI fallback; long-term unification spike optional.
   Mismatch between *notification and saved transaction* is impossible by
   construction (single result powers both).
5. **App Intent execution limits** — extension gets seconds, not minutes;
   8s network budget + guaranteed local enqueue means worst case degrades to
   today's behavior, never loses data.
6. **Shortcuts automation reliability** remains an iOS-level dependency
   (unchanged from today).
7. **Guest accounts** — supported via installId+deviceSecret auth; if a guest
   reinstalls, the relay rows orphan until TTL (acceptable).
8. **Device secret storage** — App Group defaults are readable by the app and
   its extensions, which is enough for Phase 1 because the secret cannot access
   ledger data. If we later want stronger storage, move it to a shared Keychain
   access group, but that adds signing/profile work.
9. **Cost** — Gemini calls now also triggered from backend path; same 20/day
   AI cap enforced server-side; capture calls capped at 300/day.

## 12. Step-by-step implementation order

## 13. Phase 2 — APNs push notifications for backend captures

Phase 2 keeps every Phase 1 invariant:
- Drift remains the source of truth.
- `processed_captures` remains relay-only.
- Cloud processing stays opt-in and OFF by default.
- Cloud OFF never calls backend/APNs.
- Local fallback remains intact.
- No foreground banner/in-app toast work is included; that is Phase 3.

### Target flow

```
SMS → Shortcut → App Intent → process-ios-sms
Backend:
  process + store processed_captures relay row
  if capture_devices has APNs token:
    send APNs alert using the same notification title/body
    mark push_sent_at on the relay row
  else:
    return pushSent:false so the App Intent keeps Phase 1 local notification
User taps APNs:
  Runner captures payloadId/notificationType/source
  Flutter starts/resumes
  sync-captures imports into Drift and ack/deletes relay row
  route to transaction detail when available
  otherwise route to Smart Inbox/transactions review fallback
```

### Exact files to touch

**Docs**
- `docs/IOS_BACKEND_FIRST_PLAN.md` — add this Phase 2 implementation plan.

**Database**
- `supabase/migrations/0013_ios_capture_apns.sql`
  - `capture_devices.apns_token`
  - `capture_devices.apns_environment` (`sandbox` or `production`)
  - `capture_devices.token_updated_at`
  - `processed_captures.apns_push_sent_at`
  - `processed_captures.apns_push_error`

**Backend**
- `supabase/functions/register-push-token/index.ts`
  - authenticated by `installId + deviceSecret`
  - stores token/environment on `capture_devices`
- `supabase/functions/process-ios-sms/index.ts`
  - after storing the relay row, send APNs if a token exists
  - do not fail capture processing when APNs fails
  - return `pushSent` so the App Intent can avoid duplicate local banners
  - repeated same `payloadId` returns existing capture and does not push again
- `supabase/functions/_shared/apns.ts`
  - APNs token-auth sender using Supabase secrets:
    `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY`

**iOS native**
- `app/ios/Runner/AppDelegate.swift`
  - add remote notification registration and APNs token callbacks
  - expose native channel methods:
    `registerForRemoteNotifications`, `getApnsToken`,
    `consumePendingNotificationRoutes`
  - capture notification taps and store pending route payloads until Flutter is ready
- `app/ios/Runner/SharedCaptureStore.swift`
  - store APNs token/environment and pending notification route payloads in App Group
- `app/ios/Runner/Runner.entitlements`
  - add `aps-environment`
- `app/ios/Runner.xcodeproj/project.pbxproj`
  - ensure Runner entitlements are used for Debug/Profile/Release.

**Flutter**
- `app/lib/features/capture/services/native_capture_bridge.dart`
  - add APNs methods and token update callback plumbing
- `app/lib/features/capture/services/capture_backend_client.dart`
  - add `registerPushToken`
- `app/lib/features/capture/services/capture_device_registration_service.dart`
  - register APNs token after cloud/device registration
  - sync token on start/resume and token callback
- `app/lib/features/capture/services/capture_sync_service.dart`
  - expose payload-to-transaction lookup for tap routing
- `app/lib/features/app/app_shell.dart`
  - drain pending APNs tap payloads on start/resume
  - sync first, then route to transaction detail or Smart Inbox fallback

### Apple Developer setup required

The user must provide/configure:
- APNs Auth Key `.p8`
- Key ID (`APNS_KEY_ID`)
- Team ID (`APNS_TEAM_ID`)
- Bundle ID (`APNS_BUNDLE_ID`, expected `com.youssefsafwat.mali`)
- Private key as Supabase secret `APNS_PRIVATE_KEY`
- Enable Push Notifications capability for the main app identifier.

Environment:
- Debug/development provisioning uses APNs sandbox.
- TestFlight/App Store use APNs production.
- The app sends `apns_environment` with the token so the backend chooses the right APNs host.

### Validation checklist

- `flutter analyze`
- `flutter test`
- `xcodebuild` Runner and BankMessageShortcuts
- `git diff --check`
- deploy/apply migration 0013 and deploy updated functions
- iPhone test:
  - notifications allowed
  - Cloud OFF still local-only
  - Cloud ON + AI OFF sends backend capture and APNs push
  - tapping push opens Qirsh, syncs, imports, acks, then routes
  - duplicate same `payloadId` does not send duplicate push
  - APNs failure does not fail processing or relay storage

**Phase 1 — pipeline core, no push:**
1. Migration 0012 (tables above) + `register-device` + `process-ios-sms`
   (deterministic+AI+categorize+dedup+store, returns full response with
   notification object) + `sync-captures` + Deno tests.
2. `parser_rules.json`: add `sanitizationPatterns`; Dart mirror + tests.
3. Flutter: consent setting + channel methods writing App Group flags +
   device registration + `sync-captures` client + drain reordering + dedup.
4. Swift: BackendCaptureClient + status-tagged enqueue + fallback
   notifications; validation: xcodebuild, analyze, test; debug logs on.

**Phase 1 expected file scope:**
- Backend: `supabase/migrations/0012_ios_capture_pipeline.sql`,
  `supabase/functions/register-device/index.ts`,
  `supabase/functions/process-ios-sms/index.ts`,
  `supabase/functions/process-ios-sms/parser_rules.json`,
  `supabase/functions/sync-captures/index.ts`,
  `supabase/functions/_shared/capture_auth.ts`,
  `supabase/functions/_shared/capture_http.ts`,
  `supabase/functions/_shared/sms_sanitizer.ts`.
- Flutter: `app/lib/domain/entities/supporting_entities.dart`,
  `app/lib/data/db/app_database.dart`,
  `app/lib/data/repositories/drift_repository_support.dart`,
  `app/lib/data/repositories/drift_user_settings_repository.dart`,
  `app/lib/features/capture/services/native_capture_bridge.dart`,
  `app/lib/features/capture/services/capture_backend_client.dart`,
  `app/lib/features/capture/services/capture_device_registration_service.dart`,
  `app/lib/features/capture/services/capture_sync_service.dart`,
  `app/lib/features/app/app_shell.dart`,
  `app/lib/core/di/app_providers.dart`,
  `app/lib/features/settings/settings_screen.dart`,
  `app/assets/catalog/parser_rules.json`,
  `app/lib/engine/parser/shared_preview_parser.dart`,
  `app/test/engine/shared_preview_parser_test.dart`,
  `app/test/features/capture/capture_sync_service_test.dart`,
  `app/test/features/capture/capture_device_registration_service_test.dart`.
- iOS: `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`,
  `app/ios/BankMessageShortcuts/SharedCaptureStore.swift`,
  `app/ios/Runner/SharedCaptureStore.swift`,
  `app/ios/ShareBankMessage/SharedCaptureStore.swift`,
  `app/ios/Runner/AppDelegate.swift`.

**Phase 2 — hardening:** rate limits final, TTL sweep, privacy copy polish,
log scrubbing, docs (CLAUDE.md update), full manual matrix, remove debug logs.

**Phase 3 (optional UX):** foreground in-app banner/tap routing if we want it
later. This is not part of Phase 1.

**Phase 4 (optional spike):** dart2js engine core in the edge function for
full parser parity.

After each phase: changed-files list + risk notes + all gates green.
