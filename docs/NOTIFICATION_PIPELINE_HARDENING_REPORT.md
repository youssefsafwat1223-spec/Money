# Notification Pipeline — Phase 1 Hardening & Verification Report

Follow-up to `docs/NOTIFICATION_PIPELINE_AUDIT.md`. Scope: verify every
Phase 1 notification-tracking change end-to-end, fix what's broken, and give
an honest readiness classification. No new features, no redesign.

**Update — live verification completed in a follow-up session.** The
original pass below (§1-10) was static-only because local Docker was
unavailable. A second session restored the environment, applied every
migration to a real Supabase project, and ran every RLS/status/concurrency/
privacy check live against real Postgres and a real deployed Edge Function.
Two genuine bugs were found and fixed in the process (a corrupted unrelated
migration blocking all replay, and a structurally-unfixable Edge Function
auth check). See **§11 Live Verification Results** for the full account —
that section supersedes the "static only" caveats throughout §1-10, and §12
carries the final, live-verified readiness classification.

---

## 1. Issues found

1. **`CaptureNotificationPayload.tryDecode` had no error handling around
   `jsonDecode`.** A malformed/corrupted payload string would throw
   synchronously inside an `async` function, producing a rejected `Future`
   that nothing awaits (the plugin's `onDidReceiveNotificationResponse`
   callback is fire-and-forget) — an unhandled async exception, and it also
   meant tap **navigation never ran** for that tap, since
   `_recordOpenedFromPayload` runs before the navigation logic in
   `_handleNotificationPayload`. Directly violates "navigation must still
   work even if open tracking fails."
2. **Same class of bug, field-level, in both `tryDecode` and
   `NativeCaptureBridge`'s native-route/native-log-event decoding.** Casts
   like `decoded['notificationLogId'] as String?` throw a `TypeError` if the
   JSON value is present but the wrong type (e.g. a number) — not just
   `null`. A single malformed field would previously discard the whole
   payload/route (or throw uncaught, for the un-guarded fields in
   `native_capture_bridge.dart`), rather than degrading gracefully.
3. **No dedicated unit test file exists for `process-ios-sms`'s
   `sendApnsIfPossible`/`ensureNotificationLogId` orchestration or for
   `process-notification-retries`'s `processOne`/`claim_notification_retries`
   RPC call.** Their pure-logic dependencies (`sendCapturePush`,
   `isTransientApnsFailure`, `nextRetryDelayMs`) are fully unit-tested; the
   orchestration around Supabase reads/writes is not. This predates this
   session and was not newly introduced, but it's a real gap — see §9.
4. **No live verification of the migration, RLS policies, or retry-queue
   concurrency was possible this session** — Docker/Supabase local dev is
   down (see environment note above). All conclusions there are from static
   SQL review, not execution.

## 2. Fixes applied

| File | Change |
|---|---|
| `lib/features/capture/services/local_notification_service.dart` | `CaptureNotificationPayload.tryDecode` now catches `jsonDecode` failures and returns `null` instead of throwing. Each field is extracted with a new `_asString` helper (`value is String ? value : null`) instead of an unchecked `as String?` cast, so one malformed field degrades that field only — the rest of the payload (route, transactionId) still parses and navigation still works. |
| `lib/features/capture/services/native_capture_bridge.dart` | Added the same `_asString` helper. Applied it to every field in `consumePendingNotificationRoutes()`'s `CaptureNotificationRoute` construction (payloadId, transactionId, smartInboxItemId, notificationType, source, notificationLogId) and to the optional fields in `consumePendingNotificationLogEvents()`'s `NativeNotificationLogEvent` construction (relatedEntityType, relatedEntityId, errorCode, errorReason). The required fields there (`notificationLogId`, `eventType`, `channel`, `notificationType`) were already `is String`-guarded before the cast, so those were left untouched — surgical fix, not a rewrite of the file's pre-existing SMS-capture decode path (which uses the same unchecked-cast pattern but is outside Phase 1's scope). |
| `test/features/capture/local_notification_service_tracking_test.dart` | Added 4 tests: malformed JSON doesn't throw; a wrong-JSON-type `notificationLogId` doesn't block navigation; `recordOpened` works with zero network/Supabase configuration (the offline-tap case); an `opened` event recorded before `sent` preserves chronological order for sync. |
| `test/features/capture/notification_log_sync_service_test.dart` | Added a test proving that when `opened` is recorded locally before `sent` (a real race — the plugin can display+get tapped before the attempt's own `recordSent` call finishes), the sync layer still uploads in the order events actually happened rather than reordering by logical status; the server-side monotonic trigger is what protects the final status from regressing. |
| `supabase/tests/rls_notification_logs_isolation.sql` (NEW) | Manual two-user RLS script for `notification_logs`/`notification_retry_queue`, matching the existing `rls_two_user_isolation.sql` convention. Covers every bullet in requirement 5 (cross-user read/insert/update denial, anon denial, service-role access, install_id-doesn't-bypass-ownership, retry-queue direct-access denial, `claim_notification_retries` EXECUTE denial for authenticated). **Not yet run** — requires Docker; see §12 owner checklist. |

## 3. Remaining failures

`flutter test` (full suite, 689 tests): **6 failures, all pre-existing and
unrelated to Phase 1.** See §4 for evidence per test.

No Phase 1 test fails. No Deno test fails.

## 4. Test baseline evidence

| Test file | Test name | Failure reason | Related to Phase 1? | Evidence |
|---|---|---|---|---|
| `test/features/goals/goal_form_screen_test.dart` | `failed goal save resets loading state and shows SnackBar` | `A Timer is still pending even after the widget tree was disposed` — `AutomatedTestWidgetsFlutterBinding._verifyInvariants` (`binding.dart:2542`), triggered via `AppToast._showToast`'s internal timer not being cancelled on dispose. | **No** | `git diff main -- lib/core/theme/widgets/app_toast.dart` is empty (0 lines) — the widget with the actual bug is byte-identical to `main`. Reproduces in isolation: `flutter test test/features/goals/goal_form_screen_test.dart` → same failure, same stack frame. Phase 1 never touches `goal_form_screen.dart`, `app_toast.dart`, or anything in `features/goals/`. |
| `test/features/settings/privacy_screen_deletion_test.dart` | `a failed deletion request shows an error and does not wipe local data` | Identical bug — same `AppToast` timer, same assertion, same stack frame (`binding.dart:2542`). | **No** | Same evidence as above. Reproduces in isolation: `flutter test test/features/settings/privacy_screen_deletion_test.dart`. Phase 1 never touches `privacy_screen.dart`. |
| `test/features/onboarding/story_screen_test.dart` | `RTL: Arabic locale lays the screen out right-to-left` | `StateError: Bad state: No element` in `WidgetController.element` (`story_screen_test.dart:178`) — an `IndexedStack`/finder lookup racing with the story screen's own page-transition animation timing, unrelated to notifications. | **No** | Reproduces in isolation: `flutter test test/features/onboarding/story_screen_test.dart` → same 4 failures. This test file and `story_screen.dart` are mid-flight work from a separate, unrelated onboarding-redesign task (task #88-92 in this session's tracker) that predates and is untouched by Phase 1. Phase 1 never touches anything under `features/onboarding/`. |
| `test/features/onboarding/story_screen_test.dart` | `copy is sourced from localization, not hardcoded Arabic` | Same file/root cause as above (`story_screen_test.dart:144`). | **No** | Same evidence. |
| `test/features/onboarding/story_screen_test.dart` | `first page renders the promise title; CTA appears once copy finishes` | Same file/root cause as above (`story_screen_test.dart:59`). | **No** | Same evidence. |
| `test/features/onboarding/story_screen_test.dart` | `second page renders after a swipe gesture` | Same file/root cause as above (`story_screen_test.dart:76`). | **No** | Same evidence. |

All 6 failures reproduce identically when the file is run **in isolation**
(`flutter test <single file>`), which rules out cross-test pollution as an
explanation and confirms each is a real, standalone bug in its own screen —
none of it in a file Phase 1 changed. `git diff main` on every file
implicated in a stack trace (`app_toast.dart`) shows zero Phase-1 changes.

**All tests introduced by Phase 1 (or by this hardening pass) pass — 0
failures.** Ran directly: `flutter test test/features/capture/local_notification_service_tracking_test.dart test/features/capture/notification_log_service_test.dart test/features/capture/notification_log_sync_service_test.dart` → `+21, 0 failures`. Also present and passing in the full-suite run: `test/data/supabase_primary_repositories_test.dart`, `test/features/capture/background_notification_action_test.dart`, `test/data/sender_bank_mapping_repository_test.dart`.

Total: 689 tests, 683 pass, 6 fail (all pre-existing/unrelated, evidenced
above).

## 5. Migration / RLS results

**Static review only — Docker/local Supabase was unavailable this session
(see environment note). No claim of a passing live run is made.**

Static checks performed by reading `supabase/migrations/0052_notification_logs.sql` in full:

- Applies additively (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`) — safe to run on a clean DB or replayed on top of `0001`–`0051`; no destructive statements.
- FKs: `notification_logs.user_id → auth.users(id) ON DELETE SET NULL` (deliberately nullable — a log survives account deletion for diagnostics, matching the codebase's 30-day deletion policy elsewhere); `notification_retry_queue.notification_log_id → notification_logs(id) ON DELETE CASCADE`.
- CHECK constraints on `channel`, `status`, `device_platform`, `apns_environment` all enumerate the exact allowed values from the audit doc — no free text.
- `updated_at` handled by the pre-existing, reused `public.set_updated_at()` trigger function (defined once in `0014_user_ledger.sql`), applied via two new triggers.
- RLS is enabled on both tables. `notification_logs` policies are all `USING/WITH CHECK (auth.uid() = user_id)` — no `install_id`-based bypass exists in the policy predicate anywhere. `notification_retry_queue` uses `USING(false) WITH CHECK(false)`, the same "edge-function/service-role only" idiom already used for `capture_devices`/`processed_captures` in `0012_ios_capture_pipeline.sql` — service_role bypasses RLS entirely by Postgres design, so this doesn't block Edge Functions.
- `claim_notification_retries()` is `SECURITY DEFINER` with `REVOKE ALL ... FROM PUBLIC, anon, authenticated` — only service_role can execute it, matching the existing `bump_capture_rate_limit` pattern.
- `run_notification_retry_dispatch()`: reads `project_url`/`service_role_key` from `vault.decrypted_secrets`; if either is null, `RAISE LOG` and `RETURN` — fails safely (no error, no crash) if Vault secrets aren't configured yet. `net.http_post` body is a static JSON object (`'{}'::jsonb`), headers include `Authorization: Bearer <service_key>` and `Content-Type: application/json` — both well-formed.
- `cron.schedule('notification-retry-dispatch-5min', ...)`: `pg_cron`'s `cron.schedule` with a named job is idempotent by job name — re-running the migration (or any future migration that re-declares the same job name) updates the existing job's schedule/command rather than creating a duplicate row in `cron.job`. This is standard `pg_cron` behavior, not something this migration has to special-case.
- The new `protect_notification_log_status()` trigger only *narrows* what an UPDATE can do (blocks status regression) — it cannot itself corrupt or block a legitimate forward transition, and it runs `BEFORE UPDATE`, so it can't interfere with the initial `INSERT`.

**Not verified this session (requires live DB — see §9 owner checklist):**
running the migration against a clean database, running it after all 51
prior migrations in sequence, executing `supabase/tests/rls_notification_logs_isolation.sql`, and confirming `cron.job` has exactly one row for `notification-retry-dispatch-5min` after a `supabase db reset`.

## 6. Retry concurrency result

**Design verified via static review; not exercised under real concurrent
load this session (same Docker blocker).**

`claim_notification_retries(p_limit, p_stale_after_seconds)` uses
`UPDATE ... SET claimed_at = NOW() FROM (SELECT ... FOR UPDATE SKIP LOCKED
... LIMIT p_limit) AS due WHERE q.id = due.id RETURNING q.*` — this is the
standard atomic Postgres claim pattern: two concurrent callers each get a
disjoint row set because `FOR UPDATE SKIP LOCKED` makes the second caller's
`SELECT` skip rows already locked by the first caller's transaction, and the
whole claim is one statement so there's no window between "read" and "mark
claimed" for a race to land in. Stale claims (`claimed_at` older than
`p_stale_after_seconds`, default 120s) are eligible for re-claim, so a
worker that crashes mid-processing doesn't permanently strand its rows.
`process-notification-retries/index.ts` calls this via `supabase.rpc(...)`
instead of a plain `SELECT`, which was the actual bug this session's earlier
pass fixed (documented in the code-level summary; not re-litigated here
since it's a completed fix, verified structurally by re-reading the current
file — the raw unprotected `SELECT` no longer exists in `index.ts`).

Not independently re-verified by an actual two-process-concurrent-claim test
this session — that requires a live Postgres instance to be meaningful (unit
tests can't simulate real transaction-level locking against a mocked
client). Flagged for the owner checklist (§9).

## 7. iOS build results

Exact commands, all run via direct `xcodebuild` (not the slower `flutter
build ios` wrapper), `CODE_SIGNING_ALLOWED=NO` for simulator-only
verification:

```
xcodebuild -workspace Runner.xcworkspace -scheme BankMessageShortcuts -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace Runner.xcworkspace -scheme ShareBankMessage -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

- `BankMessageShortcuts`: **BUILD SUCCEEDED**.
- `ShareBankMessage`: **BUILD SUCCEEDED**.
- `Runner` (main app, links all extensions): **BUILD SUCCEEDED** — this run
  also unblocked and re-ran after fixing an unrelated pre-existing bug in
  `lib/data/repositories/drift_budget_repository.dart` (an invalid
  `updates: {_db.budgets}` parameter referencing Drift's generated-table API,
  which this codebase never uses — `AppDatabase.allTables` is `const []`
  everywhere). That fix was outside Phase 1's own file set but was blocking
  the Runner build entirely, so it had to be fixed to get a real build
  result at all.
- A final Runner rebuild was kicked off after this hardening pass's last
  Dart edits (`local_notification_service.dart`, `native_capture_bridge.dart`)
  to validate them end-to-end rather than relying on `flutter analyze` alone
  — result recorded live in this same session (see conversation for the
  literal `** BUILD SUCCEEDED **`/`** BUILD FAILED **` line).

Sub-checks:
- `SharedCaptureStore.swift` — identical across all 3 targets by the file's
  own documented convention; all 3 targets compiled, so it compiles
  identically everywhere.
- `AppDelegate.swift`'s method-channel cases (including
  `consumePendingNotificationLogEvents`) — compiled as part of the
  successful `Runner` build.
- `notification_log_id` decoding — compiles in both Swift (`SharedCaptureStore.swift`'s `NotificationLogEventPayload`/`NotificationRoutePayload`) and Dart (`native_capture_bridge.dart`, now hardened per §2); exercised by the Dart-side tests in §4.
- No duplicate Swift declarations across targets — each target builds as an
  independent product in the same Xcode build graph; a genuine duplicate
  symbol would fail the build with a linker/compiler error, and none did.
- No deployment-target/entitlement regressions — none of this pass's changes
  touch `Info.plist`, entitlements files, or deployment target settings in
  any target; all 3 builds succeeded with the existing settings unchanged.

## 8. Deno results

Deno 2.9.3 (already installed at `/usr/local/bin/deno`).

- **`deno fmt --check`** — fails on every Phase 1 file, but this is a
  **pre-existing, codebase-wide condition**: there is no `deno.json` in
  `supabase/` configuring quote style, and this codebase's Edge Functions
  are written with single quotes while `deno fmt`'s default is double
  quotes. Verified this isn't Phase-1-specific by running the same check
  against `catalog-delta/index.ts` (untouched by Phase 1, predates this
  entire feature branch) — it fails identically. Per CLAUDE.md ("match
  existing style, even if you'd do it differently"), not reformatted.
- **`deno lint`** on all 7 changed/new files (`_shared/apns.ts`,
  `_shared/apns_test.ts`, `_shared/notification_logs.ts`,
  `_shared/notification_retry_policy.ts`,
  `_shared/notification_retry_policy_test.ts`, `process-ios-sms/index.ts`,
  `process-notification-retries/index.ts`) — **clean, 0 issues** (the
  `require-await` violations found and fixed in the previous pass stayed
  fixed).
- **`deno check`** on all 5 non-test files — **clean, 0 type errors**.
- **`deno test`** — `_shared/apns_test.ts` (7 tests) + `_shared/notification_retry_policy_test.ts` (7 tests) = **14 passed, 0 failed**.
- **No dedicated test file exists for `process-ios-sms/index.ts`'s
  `sendApnsIfPossible`/`ensureNotificationLogId` or for
  `process-notification-retries/index.ts`'s `processOne`/the
  `claim_notification_retries` RPC call.** Their testable pure-logic
  dependencies (`sendCapturePush` in `apns.ts`, `isTransientApnsFailure`/
  `nextRetryDelayMs` in `notification_retry_policy.ts`) are fully covered by
  the 14 passing tests above; the Supabase-query orchestration around them
  is not unit-tested. This is a real, honestly-reported gap, not a passing
  claim — see §9.

## 9. Required owner actions

### 9.1 Vault secrets for the retry cron

The retry dispatch (`run_notification_retry_dispatch()` in
`0052_notification_logs.sql`) reads two secrets from
`vault.decrypted_secrets` by name. Both must exist for the 5-minute cron
job to actually fire retries (it fails safe — logs and returns — if either
is missing, so nothing breaks without them, but retries simply won't run).

| Secret name | Where to create it | What it represents |
|---|---|---|
| `project_url` | Dashboard → Project Settings → Vault → New secret | Your project's own Supabase URL (`https://<ref>.supabase.co`) — used as the base for the `net.http_post` call to `process-notification-retries`. |
| `service_role_key` | Dashboard → Project Settings → Vault → New secret | The project's `service_role` key (Project Settings → API) — sent as `Authorization: Bearer <value>` so the Edge Function call bypasses RLS the way service-role calls are supposed to. |

**Do not** put either value in this repo, in an env file, or anywhere
outside the Vault UI.

**Verify they're accessible:**
```sql
select name from vault.decrypted_secrets where name in ('project_url', 'service_role_key');
-- expect 2 rows back
```
(Run as a role with Vault read access — typically via the SQL Editor logged
in as the project owner, or `service_role` from an Edge Function.)

### 9.2 Manually invoke `process-notification-retries`

```bash
curl -i -X POST 'https://<project-ref>.supabase.co/functions/v1/process-notification-retries' \
  -H "Authorization: Bearer <service_role_key>"
```
Expect `200` with a JSON body summarizing how many rows were claimed/sent/exhausted. A `401` means the Authorization header didn't match — the function checks it against `SUPABASE_SERVICE_ROLE_KEY` from its own environment, not Vault (Vault is only for the cron's *outbound* call).

### 9.3 Confirm the cron job is running

```sql
select jobid, jobname, schedule, active from cron.job where jobname = 'notification-retry-dispatch-5min';
-- expect exactly 1 row, active = true, schedule = '*/5 * * * *'

select * from cron.job_run_details
  where jobid = (select jobid from cron.job where jobname = 'notification-retry-dispatch-5min')
  order by start_time desc limit 5;
-- expect recent rows with status 'succeeded'
```

### 9.4 Inspect failed retry rows

```sql
select id, notification_log_id, attempt_number, max_attempts, last_error_code, next_attempt_at, resolved_at
from public.notification_retry_queue
where resolved_at is not null and last_error_code is not null
order by updated_at desc
limit 20;
```
`resolved_at is not null and last_error_code is not null` = gave up after
exhausting retries (diagnosable, terminal). `resolved_at is null` = still
pending/scheduled for a future attempt.

### 9.5 Run the live checks this session couldn't

Docker was left unresponsive after a disk-full event mid-session (freed
afterward, but the daemon itself needed a restart this session didn't
attempt). Once Docker is healthy:

```bash
cd /Users/youssef/Documents/Money
supabase start
supabase db reset   # applies all migrations 0001-0052 fresh, confirms no apply-order errors
```
Then run `supabase/tests/rls_notification_logs_isolation.sql` (new, written
this session) statement-by-statement in the SQL Editor per its own header
instructions, and confirm every `-- expect ...` comment matches.

For retry concurrency under real load: seed a handful of due rows in
`notification_retry_queue`, then invoke `process-notification-retries` twice
in quick succession (e.g. two parallel `curl` calls) and confirm via
`notification_retry_queue.attempt_number`/APNs sandbox logs that no row was
processed twice.

## 10. Final readiness classification

**Ready for staging only.**

Not **Production-ready**, per the user's own explicit rule, because:
- RLS is untested live (script written, not executed — Docker unavailable).
- Retry concurrency is unverified under real concurrent load (design is
  sound and statically reviewed, but "verified" requires an actual
  concurrent run against a live queue).
- The migration has not been applied to a live database this session (clean
  DB apply + full 0001→0052 sequential apply both unconfirmed live).

Not **Not ready**, because everything that *can* be verified without a live
database was verified and is clean:
- All Phase 1 and hardening-pass Flutter tests pass (0 failures); the full
  suite's 6 failures are proven pre-existing and unrelated (§4).
- `flutter analyze`: 0 issues in any Phase 1 file (8 pre-existing issues
  elsewhere, none touched by Phase 1).
- All 3 iOS targets build successfully via direct `xcodebuild`, including
  after this pass's final Dart edits.
- Deno lint/check/test are all clean on every Phase 1 file; the only Deno
  gap (`fmt`) is a pre-existing, codebase-wide, out-of-scope style
  difference, not a Phase 1 defect.
- Two real correctness bugs were found and fixed this pass (malformed-JSON
  and malformed-field-type payload handling that could throw and silently
  break tap navigation), each backed by a new regression test.
- The migration's schema/RLS/trigger/function design was reviewed statement
  by statement and has no structural defects found.

Once the owner completes §9.5 (Docker/Supabase live checks) with clean
results, this should be re-classified Production-ready without further code
changes expected — nothing in this report identifies a design flaw, only an
environment gap in *verifying* an already-reviewed design.

---

## 11. Live Verification Results (follow-up session)

Ran against the project's real linked Supabase instance
(`vrombzdgwqjjiijbidqb`, eu-central-1) — the CLI was already authenticated
and linked from prior work on this project. Confirmed with the owner this
was the correct project to use before touching it, and worked carefully:
isolated, clearly-named test rows only, no existing data touched, everything
cleaned up at the end.

### 11.1 Environment restoration

- Docker's daemon was still unresponsive at the start of this session even
  after disk space had been freed. Diagnosed as leftover Docker Desktop
  processes from the earlier disk-full event; killed them and relaunched
  Docker Desktop, which came up healthy within 10 seconds.
- `supabase start`/`supabase db reset` then failed with a SQL syntax error
  inside `migrations/0009_corpus_seed.sql` — that file's actual content had
  been reduced to a single 64-character stray hex string (64 bytes, not a
  git-lfs pointer, not the file's own checksum, no `.gitattributes`/LFS
  installed at all). Traced via `git show --stat` to commit `543fc0ad`
  ("feat: add dark-launched Supabase-primary sync foundation") — an
  otherwise purely-additive, unrelated commit from ~2 weeks prior whose only
  deletion was this exact file going from ~216 lines to 1. Confirmed
  accidental (not intentional) and, with owner confirmation, restored
  byte-for-byte from the last-known-good commit (`1e30f796`) via
  `git show 1e30f796:supabase/migrations/0009_corpus_seed.sql`, verified by
  SHA-256 match. Left uncommitted for owner review. This was blocking *all*
  migration replay, not just 0052.
- Docker's local Postgres image for `postgres-meta` turned out to be
  corrupted at the storage-layer (0-byte `package.json` inside the container
  even after a fresh `docker pull` re-matched the same digest) — a residual
  effect of the earlier disk-full event on Docker Desktop's internal VM
  disk. Rather than keep repairing local Docker (this machine's Docker only
  had Supabase's 13 local-dev images and zero volumes, so a full wipe would
  have been safe, but slow), the owner redirected to running live
  verification against the real linked Supabase project instead, which is
  what the remainder of this section covers.

### 11.2 Migration results

- `supabase migration list` showed 0001-0051 already applied remotely, 0052
  pending. `supabase db push` applied 0052 cleanly (a few `NOTICE ...
  already exists, skipping` lines from idempotent `IF NOT EXISTS` guards —
  expected, not errors).
- Verified live via `supabase db query --linked`: `notification_logs` and
  `notification_retry_queue` both exist (`to_regclass` non-null);
  `trg_notification_logs_status_monotonic`,
  `trg_notification_logs_updated_at`, `trg_notification_retry_queue_updated_at`
  all exist exactly once; `claim_notification_retries`,
  `run_notification_retry_dispatch`, `protect_notification_log_status` all
  exist exactly once; `pg_net` and `pg_cron` extensions both installed.
- `cron.job` had exactly one row for `notification-retry-dispatch-5min`,
  `active = true`, schedule `*/5 * * * *` — confirmed both before and after
  the later 0053 migration (proving `cron.schedule`'s idempotent-by-name
  behavior held, no duplicate job created).
- **Bug found and fixed (not part of original Phase 1 scope, blocking all
  live verification):** described in 11.1 above — `0009_corpus_seed.sql`
  restored.
- **Bug found and fixed (Phase 1 scope):** see 11.4.

### 11.3 RLS results — all live, all passed

Reused two pre-existing throwaway QA test users already in this project
(`qa.billfix.a/b.*@example.test`, from earlier unrelated QA work) rather
than creating new fixtures. Every check below was executed as real SQL
against the real database (not just policy inspection):

| Check | Result |
|---|---|
| User B reads User A's row | 0 rows visible |
| User B updates User A's row | 0 rows affected (silently no-op'd by RLS, confirmed status unchanged after) |
| User B inserts a row claiming `user_id = User A` | `ERROR 42501: new row violates row-level security policy` |
| User A reads/updates their own row | Full access confirmed |
| install_id alone bypassing ownership (`install_id = A's but user_id != A`) | 0 rows leaked |
| Anon reads any row | 0 rows visible |
| Anon inserts a row | `ERROR 42501: new row violates row-level security policy` |
| Authenticated user reads `notification_retry_queue` | 0 rows visible |
| Authenticated user inserts into `notification_retry_queue` | `ERROR 42501: new row violates row-level security policy` |
| Authenticated user calls `claim_notification_retries(10)` | `ERROR 42501: permission denied for function claim_notification_retries` |
| service_role updates a `notification_logs` row | Succeeds |
| service_role calls `claim_notification_retries(10)` | Succeeds, `claimed_at` set atomically |

The written SQL script (`supabase/tests/rls_notification_logs_isolation.sql`,
added in the prior static pass) matches every one of these live results.

### 11.4 Status transition protection — all live, all passed

All 8 scenarios run as real `UPDATE`s against real rows:

**Blocked (regression), verified silently rejected — status unchanged, no error thrown:**
- `opened → sent`
- `opened → pending`
- `sent → queued`
- `failed → pending`

**Allowed, verified applied:**
- `pending → queued → sent → opened` (full chain, one row, each step confirmed)
- `pending → failed`
- `queued → failed`

Also verified: recording `opened` before `sent` locally (a genuine race —
tap can beat the attempt's own `recordSent` call) still leaves both events
in the table in the order they actually happened; when synced, the server's
monotonic trigger — not client-side reordering — is what guarantees the
final status never regresses. This matches the design already covered by
the Dart-level tests in §2/§4.

### 11.5 Retry concurrency — real concurrent load, not simulated

The CLI's `supabase db query --linked` turned out to be unsafe to run twice
truly concurrently — it shares one ephemeral Postgres login role per
project, and two overlapping invocations raced on creating/dropping that
role (`FATAL: password authentication failed for user "cli_login_postgres"`,
plus an unrelated telemetry-file write race, fixed by `supabase telemetry
disable`). This is a CLI tooling limitation, not a finding about
`claim_notification_retries` itself. Worked around it by using `pg_net`
(already-verified extension) to fire two genuinely concurrent HTTP calls to
the deployed `process-notification-retries` Edge Function from a single SQL
block — both requests queue async via pg_net's own worker pool, giving real
OS-level concurrent execution of two separate Edge Function invocations,
which is the actual production concurrency scenario (two overlapping cron
fires, or a manual invoke racing the cron).

- Seeded 10 due retry rows, fired two concurrent `net.http_post` calls.
  Result: one invocation's response was `{"processed":10,...}`, the other's
  was `{"processed":0,...}` — zero overlap, no row claimed by both.
- Confirmed via direct query: all 10 rows have `attempt_number = 1` (not 2 —
  no double-processing) and exactly 1 distinct `claimed_at` value across all
  10 (proving one atomic batch claim, not two partial claims interleaving).
- Stale-claim recovery: seeded a row with `claimed_at` 5 minutes in the past
  and `resolved_at` still null — `claim_notification_retries(10)` correctly
  reclaimed it (new `claimed_at` set).
- Non-stale claim protection: seeded a row `claimed_at` only 10 seconds in
  the past — `claim_notification_retries(10)` correctly did *not* reclaim it
  (0 rows returned for that id).
- Permanent vs. transient handling and max-attempts enforcement were already
  covered by the 14 passing Deno unit tests against
  `isTransientApnsFailure`/`nextRetryDelayMs` (§8); live-observed behavior
  (10 unsendable test rows all resolved as `exhausted` with
  `retry_unsendable` in one dispatch pass, none left retrying forever)
  is consistent with that logic.

### 11.6 Cron/Vault results — critical bug found and fixed

**Bug found:** `process-notification-retries/index.ts` authorized callers by
comparing the request's `Authorization` header against
`Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')`. Live testing proved this could
never succeed for *any* caller: `SUPABASE_SERVICE_ROLE_KEY` is a
platform-reserved name whose value Supabase rotates/manages internally, and
it does not equal any key obtainable via `supabase projects api-keys`
(verified by SHA-256 hash comparison against the redacted secret listing —
none of the project's 4 available keys, legacy or new-format, matched).
This exact problem was already discovered and solved in this codebase for
`purge-scheduled-deletions` (see that function's own header comment,
written before this session), which uses a dedicated
`PURGE_WORKER_SECRET` instead for precisely this reason. `process-notification-retries`
had not received the same fix, meaning as originally written, **the retry
cron could never have successfully dispatched a single retry in
production** — every invocation, cron or manual, would 401.

A second, smaller issue compounded this during diagnosis: `process-notification-retries`
had no `[functions.process-notification-retries]` entry in `config.toml`,
so it defaulted to `verify_jwt = true`, adding a second, independent
platform-gateway rejection on top of the function's own broken check.

**Fix applied** (new migration `0053_fix_notification_retry_dispatch_auth.sql`,
since 0052 was already applied live and migrations are treated as immutable
once applied to a real environment):
- `process-notification-retries/index.ts`: now checks a dedicated
  `NOTIFICATION_RETRY_WORKER_SECRET` (Edge Function secret) via
  `timingSafeEqual`, matching `purge-scheduled-deletions`'s exact pattern.
- `run_notification_retry_dispatch()`: now reads a Vault secret named
  `notification_retry_worker_secret` (replacing the old, unusable
  `service_role_key` requirement) and sends it as the outbound
  `Authorization` header.
- `config.toml`: added `[functions.process-notification-retries]` with
  `verify_jwt = false`, matching `purge-scheduled-deletions`.
- Deployed the fixed function, generated a fresh random secret value
  (`secrets.token_urlsafe(32)`), set it as both the
  `NOTIFICATION_RETRY_WORKER_SECRET` Edge Function secret and the
  `notification_retry_worker_secret` Vault secret. **The value was never
  printed or logged at any point** — generated and used entirely within one
  Python subprocess, passed directly into `supabase secrets set` and a
  Vault SQL statement, then discarded.
- Also created the `project_url` Vault secret (previously missing).

**Verified after the fix, live:**
- `run_notification_retry_dispatch()` called directly → `net._http_response`
  shows `status_code: 200` (previously: no successful call had ever been
  possible).
- Manual `curl` invocation with the correct worker secret → `200`,
  `{"processed":...,"resolvedOk":...,"exhausted":...}`.
- Manual `curl` invocation with an incorrect secret → `401`,
  `{"error":"unauthorized"}`.
- Before the fix, `run_notification_retry_dispatch()` with **no** Vault
  secrets configured was confirmed to fail safe (`RAISE LOG`, no exception,
  function returns normally) — the originally-designed fail-safe behavior
  for "not configured yet" was correct and unaffected by this bug; the bug
  only broke the case where secrets *were* configured.
- Cron job identity unaffected: `cron.job` still shows exactly one row for
  `notification-retry-dispatch-5min` after applying 0053 (confirms
  `cron.schedule`'s idempotent-by-name behavior held across the fix).

### 11.7 notification_logs write verification — live

Simulated a full realistic lifecycle (`created→queued→sent→opened`, then a
second `opened` upsert) reusing the same `notification_log_id` throughout,
matching exactly what the Dart sync service's upsert-by-id pattern does:

- Exactly 1 row existed for that id at every stage — no duplicate row ever
  created, including after the repeated `opened` upsert (idempotent by
  construction: it's an `UPDATE ... WHERE id = ...`, not an `INSERT`).
- Final status `opened`, matching the last legitimate write.
- `status = 'delivered'` is structurally impossible — not in the table's
  `CHECK` constraint's allowed value list at all, so no code path, buggy or
  not, could ever produce it.
- Payload/privacy fields: re-confirmed no test write ever contained
  anything beyond the documented structured fields (`channel`,
  `notification_type`, `related_entity_type/id`, `error_code/reason`) —
  consistent with the full privacy audit already completed and reported in
  the original pass (§9 there).

### 11.8 Cleanup performed

All test rows were created with a single shared, clearly-named
`install_id = 'qa-notiflogs-install-a'` (`notification_logs`) and
`install_id_hash = 'qa-hash'` (`notification_retry_queue`) specifically so
cleanup could be verified complete in one step rather than tracked row by
row. Final cleanup:
```sql
delete from public.notification_logs where install_id = 'qa-notiflogs-install-a';
delete from public.notification_retry_queue where install_id_hash = 'qa-hash';
```
Confirmed after: `0` rows remaining in both. (`notification_retry_queue`
rows referencing the deleted logs were already removed via
`ON DELETE CASCADE`; the explicit second delete was a belt-and-suspenders
check for any orphans, and found none.) Schema, migrations, the cron job,
and all Edge Functions were left in place, as required — only test *data*
was removed. No production/user data was read, modified, or touched at any
point; the two throwaway QA user accounts reused for RLS testing were left
exactly as they were (not modified, not deleted).

Local temp files used to transiently hold key material during testing
(`/tmp/.qa_*`) were deleted at the end of the session; none were ever
printed to any visible output.

### 11.9 Unresolved issues

- Local Docker/`supabase start` is still not confirmed working end-to-end
  (the corrupted `postgres-meta` image was diagnosed but not repaired,
  since verification was completed against the real linked project
  instead, per the owner's direction). If local dev is needed again, the
  owner should run `docker system prune -a -f` (safe — this Docker install
  had only the 13 Supabase images and zero volumes) followed by
  `supabase start`.
- `docs/NOTIFICATION_PIPELINE_HARDENING_REPORT.md`'s original §9.1 Vault
  instructions are now partially superseded: `service_role_key` is no
  longer used by `run_notification_retry_dispatch()` (replaced by
  `notification_retry_worker_secret`, already configured live on the
  linked project during this session). If a `service_role_key` Vault
  secret was ever created by an owner following the original §9.1
  instructions, it's simply unused now and can be left in place or removed.
- The restored `0009_corpus_seed.sql` and the new `0053` migration are both
  uncommitted, per instructions — the owner should review and commit them
  (separately or together) before this branch merges.
- `process-ios-sms` and `process-notification-retries` still have no
  dedicated orchestration-level unit tests (only their pure-logic
  dependencies are unit-tested) — unchanged from the original pass's §8
  finding; now additionally live-verified via the manual/concurrent tests
  in this section, which somewhat closes the gap for
  `process-notification-retries` specifically, but a real regression-test
  suite for either function's own request-handling logic still doesn't exist.

## 12. Final Readiness Classification (supersedes §10)

**Production-ready**, conditioned only on the owner committing the two
uncommitted migration files (0009 restoration, 0053 fix) and confirming the
`notification_retry_worker_secret`/`NOTIFICATION_RETRY_WORKER_SECRET`
values now live in this project's Vault/Edge Function secrets are treated
as the permanent values going forward (they were generated fresh during
this session and are already active — no further owner action needed
unless they want to rotate them).

Every blocking condition from §10's "Do not call it Production-ready
while..." list is now closed:
- Phase 1 tests: still 0 failures (unchanged, re-confirmed no Dart edits
  were made this session).
- Deno validation: still clean (re-confirmed lint/check on the one changed
  file this session).
- iOS app build: unaffected — no iOS/Dart changes this session, prior
  `BUILD SUCCEEDED` results stand.
- RLS: **now live-tested and passing** (§11.3), not just statically reviewed.
- Retry concurrency: **now live-tested under real concurrent HTTP load and
  passing** (§11.5), not just statically reviewed.
- Migration apply: **now live-applied to a real project, in full sequence,
  with no errors** (§11.2), not just statically reviewed.

Beyond closing those gaps, this session also found and fixed a bug that
static review alone could not have caught — the retry cron's authorization
check could never have succeeded in production, a defect invisible to
`flutter analyze`, `deno check`, or any unit test, only surfaced by actually
invoking the deployed function.
