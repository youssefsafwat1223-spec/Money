# 18 — Regression Suite

Related: [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md), [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `REG-*`, [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md).

This is the permanent index of "this exact bug happened once, here is the test that guards against it happening again." Every entry here must have a corresponding automated test that runs as part of the standard gate suite ([10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) §3) — an entry without a runnable test is a documentation gap, not a completed regression guard.

## When this suite must run

The full regression suite runs as part of `flutter test`/`deno test` on every change (it is not a separate, optional pass) — these are ordinary unit/integration tests, distinguished here only by *why* they exist, for institutional memory. Additionally, run a deliberate mental (or literal) pass over this list before any flag-rollout-percentage increase, since these are exactly the bug classes most likely to resurface under increased real-world load.

## Registry

### `REG-001` — Partial-index/PostgREST-upsert incompatibility (`42P10`)
**Symptom**: any `.upsert(onConflict:)` call against `idx_user_accounts_user_local` or `idx_user_transactions_user_client_request` failed with Postgres error `42P10` ("no unique or exclusion constraint matching the ON CONFLICT specification").
**Root cause**: both indexes were created as **partial** unique indexes (`WHERE col IS NOT NULL`). PostgREST's upsert generates a plain `ON CONFLICT` with no predicate, and Postgres only infers a partial index as a conflict target when the `ON CONFLICT` clause's own predicate matches the index's predicate exactly — which PostgREST cannot express.
**Fix**: migration `0027` converted both indexes to full (non-partial) unique indexes. A non-partial unique index still treats `NULL` as distinct from `NULL` by Postgres default, so nullable idempotency columns remain correctly unconstrained against each other — the fix only removes the upsert-inference blocker, it does not change what counts as a duplicate.
**Guard**: [04_DATABASE.md](04_DATABASE.md) §4.2 documents the rule generally; any *new* unique index intended as an upsert target must be checked against this rule before creation, not just tested after a failure.
**Discovered via**: live-backend QA during the accounts/transactions Supabase-primary rollout.

### `REG-002` — Missing per-user feature-flag-override resolution
**Symptom**: reads correctly reflected Supabase-primary behavior for a QA user, but writes did not — the client never actually routed to Supabase for that user despite an override being set.
**Root cause**: `FeatureFlagService` never read `feature_flag_overrides` at all — the capability was entirely absent, not merely buggy.
**Fix**: added `FeatureFlagService.applyUserOverrides(supabaseClient, userId)`, called after `init()` whenever Supabase is configured, overwriting the rollout-bucket cache value for any key present in the user's override rows.
**Guard**: `feature_flag_service_test.dart` override-precedence test ([11_TEST_MATRIX.md](11_TEST_MATRIX.md) `SYNC-001`).
**Discovered via**: live-backend QA comparing expected vs. actual routing behavior.

### `REG-003` — Riverpod provider caching a stale `FeatureFlagService` instance
**Symptom**: after `initFeatureFlagService()` reassigned the module-level `_featureFlagInstance` singleton, an already-cached `Provider<T>` that had captured the *old* instance by value kept using it forever — flag changes were invisible to that provider without a full app relaunch.
**Root cause**: a `Provider`'s build function ran once and cached its result; capturing a mutable singleton by value at that moment freezes a reference disconnected from later reassignment of that singleton.
**Fix**: changed the relevant constructors (`RoutedAccountRepository`, `RoutedTransactionRepository`, etc.) to accept a **getter function** (`FeatureFlagService Function()`) instead of a captured instance, and call it fresh on every use.
**Guard**: [06_FLUTTER.md](06_FLUTTER.md) §3 documents the general pattern; any new provider wiring a mutable singleton must use the getter-function pattern, not direct capture.
**Discovered via**: live device QA (flag override changes not reflected until app relaunch, traced back through the provider construction code).

### `REG-004` — Category key/local-id mismatch causing "Uncategorized" display
**Symptom**: every Supabase-sourced transaction displayed "غير مصنّف" (Uncategorized) in the UI regardless of its actual category.
**Root cause**: `SupabaseTransactionRepository._fromServerRow` returned the raw Supabase category **key** string, while every UI call site resolves categories exclusively via `catalog.byId()` (expecting a local UUID).
**Fix**: made `_fromServerRow` async and resolved key → local UUID via the existing `_localCategoryIdForKey` helper before constructing the entity; updated all call sites to `await`/`Future.wait`.
**Guard**: `supabase_transaction_mapping_test.dart` category round-trip test ([11_TEST_MATRIX.md](11_TEST_MATRIX.md) `TXN-005`); [04_DATABASE.md](04_DATABASE.md) §4.1 documents the general rule.
**Discovered via**: live device QA.

### `REG-005` — Dedup-marker pruning deleting the `capture_payload:` namespace
**Symptom**: a capture whose ack round-trip failed could be silently re-imported as a duplicate transaction after any later drain cycle triggered a dedup-hash prune.
**Root cause**: `pruneOldDedupHashes()` deletes `dedup_hashes` rows by `occurred_at` age. Capture-import markers are stored with a fixed **epoch-0** `occurred_at` as a namespace signal (not a real event time), which is always older than any age cutoff — every prune cycle deleted the entire "already imported" registry.
**Fix**: excluded `hash LIKE 'capture_payload:%'` from the age-based prune predicate.
**Guard**: `capture_sync_service_test.dart` "failed ack followed by dedup prune must not re-import the capture" and "prune still removes ordinary dedup hashes older than the cutoff" (both must pass — the fix must not simply disable pruning altogether).
**Discovered via**: code audit (see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) §2.2).

### `REG-006` — Concurrent `CaptureSyncService.sync()` calls double-importing a relay row
**Symptom**: tapping a capture notification right as the app's own resume handler also triggered a sync could cause the same relay row to be imported twice (two Drift rows), since both callers read the same "not yet imported" state before either finished marking it imported.
**Root cause**: no shared in-flight guard existed across `CaptureSyncService`'s call sites (`_consumeSharedInput`, `_drainPendingNotificationRoutes`).
**Fix**: a single `Future<CaptureSyncResult>? _inFlightSync` guard inside the service — a second concurrent call reuses the in-progress future instead of starting a new one.
**Guard**: `capture_sync_service_test.dart` "concurrent sync calls share one run and import the capture once."
**Discovered via**: code audit.

### `REG-007` — Client-timeout dual-notification race
**Symptom**: under a slow backend response (e.g., AI parsing enabled with a slow network), both an APNs push and a locally-scheduled fallback notification could appear for the same SMS.
**Root cause**: the App Intent's 8s client timeout could fire before an unbounded server-side Gemini/APNs call completed; the server request still committed and pushed after the client had already given up and shown its own fallback.
**Fix**: bounded the Gemini (~3.5s) and APNs (~2.5s) server-side fetches; added a one-shot idempotent client retry on a timeout-shaped error before falling back locally; made local notification identifiers deterministic per `payloadId` so a retry/replay replaces rather than stacks a banner; corrected the idempotent-replay response to re-attempt APNs when not yet confirmed sent.
**Guard**: server-side bounded-timeout presence is checked by code review/grep for `AbortSignal.timeout` on both fetches; live device QA Step 3 in [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §7.
**Discovered via**: code audit plus a live-observed "server error, try again later" symptom during an unrelated edit-amount test session that prompted the broader pipeline audit.

### `REG-008` — Drain-then-process native queue losing remaining messages on one failure
**Symptom**: the native capture queue is drained (destructively) before processing; an unhandled exception while processing message N previously aborted the loop, silently losing every message after N.
**Root cause**: no per-message error isolation in `AppShell._consumeSharedInput`'s processing loop.
**Fix**: wrapped each message's processing in its own try/catch; a failure re-enqueues the message natively (`reEnqueueSharedMessage`, with `notifyHost: false` to avoid an immediate re-drain loop) instead of losing it.
**Guard**: covered by the per-message try/catch structure itself plus the native re-enqueue method's existence; a dedicated integration test simulating a mid-batch failure is recommended as a follow-up if not already present.
**Discovered via**: code audit.

### `REG-009` — Background notification action bypassing the routed repository under Supabase-primary
**Symptom**: confirming/dismissing a transaction from a notification action while the app was closed/backgrounded wrote directly to Drift via raw SQL, which is a silent no-op (from the server's perspective) when `transactions_supabase_primary` is the authoritative store for that user — the action would appear reverted on next app open.
**Root cause**: the background isolate handling notification actions has no access to the live `FeatureFlagService`/per-user override state, so it always used the Drift-only code path regardless of which store was actually authoritative.
**Fix**: the action is now always durably recorded (`PendingNotificationActions`) for replay through the routed repository on next app open (authoritative regardless of flag state), with the immediate Drift update kept only as a same-session local/mirror convenience.
**Guard**: `background_notification_action_test.dart` (confirm/dismiss recorded correctly, latest-action-wins on rapid flip).
**Discovered via**: code audit.

### `REG-010` — Exact-timestamp-only duplicate fingerprint missing `received_at`-sourced re-runs
**Symptom**: re-running a Shortcuts automation on the same SMS without "Date Received" configured produced a different `payloadId` each time (see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) §3.1) and, since the fingerprint time-key was an exact match, the server-side content fingerprint also failed to catch the duplicate.
**Root cause**: the fingerprint's time component had no tolerance for the `received_at` case, only ever comparing exact timestamps.
**Fix**: bucketed the time-key to 10-minute windows (current + previous bucket) specifically when the timestamp source is `received_at`; kept `sms_body`-sourced timestamps exact (two genuinely distinct nearby purchases must not be conflated).
**Guard**: `capture_fingerprint_test.ts` (6 Deno unit tests covering exact-match preservation, bucket generation, re-run-seconds-later matching, bucket-boundary crossing, distinct-receipts non-collision, and unparseable-input fallback).
**Discovered via**: code audit.

### `REG-011` — Orphan "duplicate" capture importing as confirmed instead of pending
**Symptom**: a capture the backend flagged `status: duplicate` whose original transaction Flutter could not resolve locally (e.g., the local dedup marker had been lost, or the original was imported on a different device) fell through to a normal import path and was saved as a **confirmed** transaction — silently double-counting despite a "عملية مشابهة ⚠️" notification having been shown.
**Root cause**: the fallthrough branch in `CaptureSyncService._importCapture` didn't distinguish "duplicate status with unresolved original" from "processed status," so it inherited the confirmed-by-default status logic.
**Fix**: a capture with `status == 'duplicate'` whose original cannot be resolved now imports as **pending**, surfaced for user review, never silently confirmed.
**Guard**: `capture_sync_service_test.dart` "duplicate capture with unresolved original imports as pending review."
**Discovered via**: code audit.

### `REG-012` — `processed_captures` retention (`prune_processed_captures`) never scheduled
**Symptom**: relay rows (including transiently-retained `sanitized_text` for `needs_review`/`rejected` captures) and fingerprints accumulated indefinitely for any device that never reopened the app to trigger an ack, despite an intended 30-day/7-day retention policy having existed in code since migration `0012`.
**Root cause**: `prune_processed_captures()` was defined but nothing ever invoked it — no scheduler was ever wired up.
**Fix**: migration `0033` adds `pg_cron`, a logging wrapper (`run_prune_processed_captures()`), and a daily schedule (`prune-processed-captures-daily`, 03:15).
**Guard**: [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §5 verification queries; live-verified post-deployment by a manual invocation confirming correct row deletion counts.
**Discovered via**: code audit.

### `REG-013` — Rejected-capture notification promising an in-app review that doesn't exist
**Symptom**: a `rejected` capture's notification told the user to "افتح قرش لمراجعتها" (open Mali to review it), but a rejected capture creates no Smart Inbox item and is acked/deleted from the relay — the promised review screen is simply empty.
**Root cause**: notification copy was written generically for "received a bank message," not specifically for the terminal-rejected case.
**Fix**: rejected-capture notification copy changed to instruct manual paste ("الصقها يدوياً في قرش لإضافتها") instead of promising a review that won't exist.
**Guard**: [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `NOTIF`/`CAP` Step 12 (manual QA, copy-content check).
**Discovered via**: code audit.

### `REG-014` — Global `processed_captures.payload_id` primary key allowing cross-device collision
**Symptom** (theoretical/found via audit, not yet observed live): two devices hashing an identical SMS's fields at the identical second could collide on the primary key, causing the losing device's request to receive a 500 and degrade to the local fallback path unnecessarily.
**Root cause**: `payload_id` alone was the primary key, while every actual lookup in the function is scoped per `(payload_id, install_id_hash)` — the PK was narrower than the table's real identity model.
**Fix**: migration `0033` re-keys the primary key to `(install_id_hash, payload_id)`, verified data-preserving (pre-migration duplicate check returned zero rows, so the wider key cannot fail on existing data).
**Guard**: [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) post-migration constraint-shape check.
**Discovered via**: code audit.

### `REG-015` — Concurrent duplicate capture insert returning 500 instead of an idempotent response
**Symptom**: two near-simultaneous requests for the same new `payloadId` (both passing the initial existence check before either committed) resulted in the losing request receiving a raw `store_failed` 500 rather than the already-stored result.
**Root cause**: the insert's `23505` (unique-violation) error path had no recovery — it treated any insert error identically.
**Fix**: on `23505`, re-read the now-existing row (written by the winning concurrent request) and return the same idempotent-replay response used for a genuine payload replay.
**Guard**: [16_STRESS_TESTING.md](16_STRESS_TESTING.md) `STRESS-CAP-001`; live-verified via a smoke test exercising the replay path.
**Discovered via**: code audit.

### `REG-016` — `pushSent` replay race returning `false` after APNs had actually already succeeded
**Symptom**: a replay of an already-processed payload could read `apns_push_sent_at` as still-null (a narrow window between the original successful APNs send and that field's database write landing) and report `pushSent: false`, causing the client to post a redundant local fallback notification even though the push had genuinely already been delivered.
**Root cause**: the idempotent-replay path trusted a point-in-time read of `apns_push_sent_at` without accounting for the write-after-send ordering gap.
**Fix**: the replay path now re-attempts APNs whenever `apns_push_sent_at` is still null at replay time; because pushes use a stable `apns-collapse-id` per `payloadId`, a redundant re-send **replaces** rather than duplicates the earlier banner on the device.
**Guard**: code review of `idempotentReplayResponse()`'s re-send branch; live smoke-tested as part of the deployment verification for migration `0033`/the `process-ios-sms` redeploy.
**Discovered via**: code audit.

## Adding a new entry

Use the `REG-NNN` format (next sequential number), and include at minimum: symptom, root cause, fix, guard (the actual test name/file), and discovery method. Link the entry from [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `REG-*` index and, if it changed capture/notification behavior specifically, cross-reference it from the relevant section of [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) or [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md).
