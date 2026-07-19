# Mali Adversarial QA Remediation — Progress Tracker

Source plan: `docs/ADVERSARIAL_QA_REMEDIATION_PLAN.md`. Queue discipline: one batch = one Codex run,
reviewed and gated by the orchestrator before the next batch dispatches. Nothing in this queue is
committed or deployed automatically — every landing is a human-reviewed step.

## Status table

| Batch | Status | Commit(s) | Notes |
|---|---|---|---|
| Batch 1 (findings #1-8) | Implemented, **migrations + functions DEPLOYED live and verified**; code **not yet committed** | — | 56 files touched. Migrations 0035-0037 applied live 2026-07-14. Finding #8 (user deletion) correctly left as inert scaffolding — no UI wired, still BLOCKED BY PRODUCT DECISION. |
| Batch 2 (findings #9-15) | Implemented, gate-verified, migration 0038 **DEPLOYED live and verified**; code **not yet committed** | — | #15's RPC (`delete_user_account_safely`) was delivered early in Batch 1's migration 0037; its missing concurrency test was added via a delta brief and is now live-verified. |
| Batch 3 (findings #16-21) | Implemented, gate-verified, migration 0039 + 4 functions **DEPLOYED live** — but live-testing found finding #20's new RPC is **currently broken in production**. **Not yet committed.** | — | See CRITICAL LIVE BUG note below. Everything else in Batch 3 verified working live. |
| Batch 4 (findings #22-27) | Implemented by Codex, independently gate-verified by orchestrator, **not yet committed, not deployed (no migrations)** | — | All 6 findings addressed; one honest gap (no new automated tests) flagged below. |

## Per-batch review notes

### Batch 1
- Codex's own report: test-clean (`flutter analyze` pass, `flutter test` 558 pass, both `xcodebuild`
  schemes pass, admin-auth tests 4/4, security/concurrency contract tests 5/5, `git diff --check`
  clean). Deno tests not run (Deno unavailable in that environment — same binary-availability gap
  hit earlier in this session; resolved then via the npx-cached copy at
  `~/.npm/_npx/05b6ef7b13673c57/node_modules/.bin/deno`, worth reusing if Codex's environment also
  lacks a `deno` on PATH).
- Finding #8 (user deletion) correctly left as scaffolding-only per the plan's explicit stop condition —
  no destructive code, nothing wired to a UI trigger. Still BLOCKED BY PRODUCT DECISION.
- Codex flagged 7 globally-enabled Supabase-primary flags as a "remaining risk" — this is **not new**;
  the user explicitly approved this flag state earlier in the same session this plan originated from
  ("this cutover was intentional and previously approved... treat the current global feature-flag
  state as the intended baseline"). Re-confirm it's unchanged before Batch 1 deploys, but it is not a
  blocker introduced by this work.
- **Unplanned but in-scope turn:** Codex implemented finding #15 (atomic last-account-deletion RPC,
  originally scoped to Batch 2) as part of Batch 1, landing in migration `0037_atomic_account_deletion.sql`.
  This is a defensible pull-forward (it directly depends on and complements #6, which is Batch 1)
  rather than scope creep — noting it here so Batch 2 doesn't redo it.
- **Needs your eyes (not yet resolved):**
  1. The worktree has "substantial pre-existing unrelated changes… mixed into several files" per
     Codex's own report — before committing, diff must be reviewed file-by-file to separate Batch-1
     changes from unrelated pre-existing edits; do not commit the dirty tree wholesale.
  2. Nothing from Batch 1 is deployed (migrations, `unlink-capture-device`, modified functions) — a
     deploy is a separate, explicit, user-authorized step, not implied by "implementation done."
  3. Manual iPhone tests (6 listed in Codex's report) have not been performed yet — required before
     Batch 1 is considered launch-ready, independent of whether it's committed.

### Batch 2
- Dispatched to Codex covering findings #9 (Riyadh timezone), #10 (capture health monitoring),
  #11 (budget alert race), #12 (atomic local capture queue), #13 (DB CHECK constraints),
  #14 (sender/bank ambiguity). #15 excluded (already delivered in Batch 1) — brief asked Codex to
  verify #15 satisfies its own spec rather than reimplement it.
- **Orchestrator independently re-ran every gate (not taken on faith):**
  - `flutter analyze` — 0 issues, confirmed directly.
  - `flutter test` — 565 passed, confirmed directly (matches Codex's own count).
  - `xcodebuild Runner` — BUILD SUCCEEDED, confirmed directly.
  - `xcodebuild BankMessageShortcuts` — Codex reported this **failed** in its own sandbox due to a
    `CoreSimulatorService`/`simdiskimaged` crash (environment issue, not a code issue). Re-ran
    independently in this environment: BUILD SUCCEEDED. Confirms it was purely Codex's sandbox's
    simulator daemon, not a defect in the change.
  - `git diff --check` — clean, confirmed directly.
  - `SharedCaptureStore.swift` md5 across all three copies — confirmed identical directly
    (`e86534ae0424a2d1899037484babf5ea`), matches Codex's own report.
  - Migration `0038` (CHECK constraints): ran the actual violation-count query against the **live**
    production database myself (Codex correctly did not, since it wasn't authorized to touch live
    data) — **zero existing rows violate any of the five new constraints**. This migration is safe
    to apply whenever deployment is authorized; no data-repair step needed.
  - Read the `riyadh_time.dart` diff directly — correct, matches the plan's recommended device-local
    default, kept the `RiyadhTime` name as instructed, one clear comment on the now-legacy `offset`
    constant.
  - Read the new `budget_progress_usecase_test.dart` concurrency test directly — genuinely
    deterministic (uses a `Completer` gate, not a timing/sleep-based race), correctly proves the
    in-flight-sharing guard added for finding #11.

### LIVE DEPLOYMENT — 2026-07-14 (Batch 1 + Batch 2 migrations and functions)

User explicitly authorized deployment. All four migrations (0035, 0036, 0037, 0038) applied directly
via `supabase db query --linked -f <file>` in order, then `supabase migration repair --status applied
0035 0036 0037 0038` to keep the tracking table honest (the exact gap that had to be caught and fixed
for migration 0034 earlier — done proactively this time). `supabase migration list --linked` confirmed
local/remote synchronized through 0038 immediately after.

**Schema verified live post-deploy:** `admin_users` table exists (1), `processed_captures.claimed_user_id`
column exists (1), `delete_user_account_safely` function exists (1), all 5 new CHECK constraints exist (5).

**Functions deployed:** `process-ios-sms` (27→28), `sync-captures` (13→14), `parser-test` (20→21),
`unlink-capture-device` (new, v1) — all confirmed ACTIVE post-deploy.

**Live verification performed (not just "deployed," actually exercised):**
1. **Finding #15 (atomic account deletion):** re-ran `account_deletion_concurrency_node_test.mjs`
   live — now **passes** (previously correctly failed with `PGRST202` before the migration existed).
   Confirmed: exactly one of two concurrent deletes succeeds, the other rejected `23514`, exactly one
   account remains. Test's own cleanup ran successfully.
2. **Finding #2 (fingerprint race):** live-fired two genuinely concurrent `process-ios-sms` requests
   (same amount/merchant/sender/timestamp, two distinct `payloadId`s) against a fresh throwaway QA
   device. Result: request A → `status: processed`; request B → `status: duplicate` /
   `duplicateStatus: suspicious_duplicate` referencing A's payloadId. Cross-checked at the DB level:
   exactly 1 row in `capture_fingerprints` for that device, not 2 — the race is closed. QA device and
   rows fully cleaned up afterward (0 remaining).
3. **Finding #1 (admin authorization):** confirmed `admin_users` has **0 rows** right now — meaning
   the admin panel is currently fail-closed for everyone, including real admins, until an admin is
   bootstrapped (expected/correct per the design, but flagging clearly — **no one has the ability to
   evaluate the admin panel via this table's check until finding #1's bootstrap step is performed**).
   Ran the required negative tests live with a throwaway non-admin user: (a) reading `admin_users`
   returns an empty array with HTTP 200 (correct — RLS scopes to own row, which doesn't exist), (b)
   attempting to INSERT itself into `admin_users` is denied with `403`/`42501` (no INSERT grant to
   `authenticated`), (c) an unauthenticated (anon-key-only) read is denied with `401`/`42501` (no
   SELECT grant to `anon`). All three match the plan's required negative-test set exactly. Throwaway
   user cleaned up afterward.

Note: the admin **Next.js app itself** has no hosted deployment target (per `app/CLAUDE.md`, it runs
locally via `npm run dev`/`npm start`) — there is nothing to "deploy" for it beyond the database-level
`admin_users`/RLS piece verified above, which is the actual security boundary. The `requireAdmin()`
code path itself (middleware/layout/server actions) was reviewed in the diff but not exercised via a
running dev server in this session.
- **Gap found and confirmed, then closed at the test-authoring level:** finding #15's RPC
  (`delete_user_account_safely`, delivered early inside Batch 1's migration
  `0037_atomic_account_deletion.sql` — note the actual name differs from the plan document's
  placeholder `delete_account`) had no deterministic concurrency test anywhere in the repo. A scoped
  delta brief closed this: `supabase/tests/account_deletion_concurrency_node_test.mjs` — throwaway
  auth user, two real accounts, two concurrent `delete_user_account_safely` RPC calls, asserts
  exactly one success/one `23514 last_account` rejection/exactly one account remaining, cleans up in
  `finally`. Read directly and confirmed well-constructed.
  - Codex could not run it live (no Supabase credentials in its sandbox) and said so honestly instead
    of skipping silently or faking a pass — exactly the behavior asked for.
  - Orchestrator ran it live with real credentials from this session: the test executed for real
    (not skipped) and failed with `PGRST202: Could not find the function
    public.delete_user_account_safely ... in the schema cache` — i.e. it correctly detected that
    migration 0037 has never actually been applied to the live database. This is not a defect in the
    test or the RPC (already read directly and confirmed correct: `FOR UPDATE` lock, `23514`
    rejection, `authenticated`-only grant) — it's the expected consequence of nothing from Batch 1/2
    being deployed yet. **This is the hard limit of what can be verified without an actual deploy.**
- **Confirmed, not new:** the working tree's `touchedFiles` snapshot mixes three layers — genuinely
  pre-existing changes that were already dirty before this whole QA arc started (e.g.
  `cards_carousel.dart`, `goal_form_screen.dart`, `budget_form_screen.dart` — present in the very
  first `git status` of this session), Batch 1, and Batch 2. Codex's own report already disclosed
  this (it ran `dart format lib test`, which touched already-dirty pre-existing files too). Nothing
  broken by it (all gates still green), but whoever commits must separate these three layers by hand
  rather than committing the tree wholesale — this was already true before Batch 1/2 and is not
  something either batch caused.

### Batch 3
- Dispatched to Codex covering findings #16 (lazy transaction list), #17 (bounded/resumable
  pagination), #18 (budget_progress_summary RPC wiring), #19 (backup schema-version framework),
  #20 (bill-payment two-phase → single atomic RPC), #21 (rate-limit hardening on device endpoints).
- **Orchestrator independently re-verified every gate:**
  - `flutter analyze` — 0 issues, confirmed directly (matches Codex's own report).
  - `flutter test` — 567 passed, confirmed directly (matches Codex's own count).
  - `git diff --check` — clean, confirmed directly.
  - Deno: Codex's environment lacked a `deno` binary and said so honestly rather than skipping
    silently. Orchestrator used the cached npx copy from earlier this session
    (`~/.npm/_npx/05b6ef7b13673c57/node_modules/.bin/deno`) to actually run what Codex couldn't:
    `deno check` on all 6 changed/new `.ts` files — clean; `deno test --allow-env` on the new
    `capture_auth_test.ts` — 1/1 passed.
- **Read every substantive diff directly, not just trusted the report:**
  - New migration `0039_budget_progress_rpc_flag_and_bill_payment_rpc.sql` — new
    `budget_progress_supabase_rpc` flag row (`is_active=false, rollout_percent=0`, correct insert
    style matching migration 0030's precedent) + `create_subscription_and_record_payment(...)` RPC.
    The RPC is genuinely atomic (single plpgsql function body = single transaction), idempotent on
    both `local_id` (subscription upsert) and `client_request_id` (payment insert), `SECURITY
    INVOKER`, correctly grant-restricted to `authenticated` only. Rollback file correctly reverses
    both the flag row and the function/grants.
  - `budget_progress_usecase.dart`'s closure-injection design matches the plan's pre-existing
    detailed spec exactly: optional `FetchBudgetBatchSpent` typedef, batched by distinct
    `BudgetPeriod` values, per-budget fallback to the original single-query path when the batch
    result has no entry for that budget id, existing in-flight guard (from Batch 2's #11) correctly
    preserved by wrapping the renamed `_calculate()` rather than being replaced.
  - `restore_backup_usecase.dart` — cleanly generalized into an ordered, schema-version-ranged list
    of post-restore steps (`_postRestoreMigrations`), with the pre-existing accounts backfill
    preserved as the sole current entry rather than a hardcoded special case, exactly as instructed.
  - Rate-limit hardening — new `bumpCaptureEndpointRateLimit()` reuses the existing
    `bump_capture_rate_limit` RPC with an endpoint-namespaced key (`installIdHash:endpoint`), with a
    non-atomic fallback path if the RPC call itself fails (consistent with the existing fallback
    pattern already used in `process-ios-sms`). Confirmed wired into all 4 target endpoints
    (`register-device`, `link-capture-device`, `register-push-token`, `sync-captures`) via grep.
  - Confirmed `monthly_financial_summary`/`category_spending_summary` were already wired pre-Batch-3
    (Codex's own report distinguishes this correctly) — only `budget_progress_summary` is new work.
- **Real finding, not scope creep — flagging clearly:** while implementing #18, Codex's diff also
  fixed two leftover call sites in `budget_progress_usecase.dart`'s `_currentPeriodFor`/
  `_periodForStart` (yearly boundaries in both, monthly in the latter) that were still using the
  *pre-Batch-2* pattern — `DateTime.utc(riyadh.year...).subtract(RiyadhTime.offset)` — left over from
  before Batch 2's `#9` timezone fix changed what `RiyadhTime.toRiyadh()` returns (from a
  UTC+3-shifted value to a plain `toLocal()` value). Since `toRiyadh()` no longer shifts, the old
  `.subtract(offset)` pattern would have silently shifted yearly/monthly budget-period boundaries by
  3 hours in the wrong direction — a genuine regression Batch 2 introduced and left unnoticed in
  exactly these two branches (daily/weekly/monthly-in-`_currentPeriodFor` were already correctly
  fixed via the `RiyadhTime.startOfMonth`/`startOfWeek` helpers, which Batch 2 did fix). Confirmed via
  `git show HEAD:...` that this was the original, pre-session code shape, and independently wrote and
  ran a throwaway sanity test (`RiyadhTime.startOfMonth`/`endOfMonth` produce clean, unshifted local
  boundaries) — passed, then deleted the temp test file (not part of any batch's deliverable). This
  fix was a necessary side effect of correctly implementing #18's period-batching logic, not
  unrequested scope creep — flagging only so it's visible, since it wasn't explicitly commissioned.

### 🔴 CRITICAL LIVE BUG — introduced by this deploy, found by live-testing, 2026-07-14

After deploying migration 0039 + the 4 Batch 3 Edge Functions, live-tested every new capability
before moving on (same discipline as Batches 1/2). Finding #20's new RPC,
`create_subscription_and_record_payment`, **fails on every call** with:

```
{"code":"42P10","message":"there is no unique or exclusion constraint matching the ON CONFLICT specification"}
```

**Root cause:** `user_subscriptions_user_local_id_uidx` is a **partial** unique index —
`CREATE UNIQUE INDEX ... ON user_subscriptions (user_id, local_id) WHERE (local_id IS NOT NULL)` —
but the new RPC's `insert ... on conflict (user_id, local_id) do update set ...` clause has no
matching `WHERE local_id IS NOT NULL` predicate. Postgres requires an `ON CONFLICT` target to
exactly match a partial index's predicate to infer it; without that, it can't resolve which
constraint to use and raises `42P10` unconditionally. **This is the identical bug class this project
already fixed once before, in migration `0027_fix_upsert_conflict_indexes.sql`** — Batch 3's new
migration reintroduced it in the new RPC.

**Severity: Critical, and currently live.** Confirmed via grep that
`app/lib/data/repositories/supabase_bill_repository.dart:308` already calls this RPC, and
`subscriptions_supabase_primary` is one of the flags already at `is_active=true, rollout_percent=100`
in production (confirmed earlier this session). **Any real user creating a new subscription with an
immediate payment right now will hit this error.** This did not exist before today's deploy — it was
introduced by applying migration 0039.

**Not yet fixed.** No fix migration has been written or deployed. QA test data from this discovery
was fully cleaned up (only a throwaway auth user was created; both RPC calls failed before any row
was inserted, so no orphaned account/subscription/payment rows exist).

**Immediate options, awaiting direction:**
1. Write and deploy a small fix migration (e.g. `0040_fix_bill_payment_rpc_conflict_target.sql`)
   changing the `ON CONFLICT` clause to `on conflict (user_id, local_id) where local_id is not null
   do update set ...`, matching the exact fix pattern already used in migration 0027. This is a
   same-day, low-risk, additive fix (`CREATE OR REPLACE FUNCTION`, no data change).
2. Roll back migration 0039 entirely (its rollback file exists and was reviewed as correct) until a
   fix is ready, if the live exposure window is a concern before a fix can be prepared.

**RESOLVED 2026-07-14 — option 1 implemented, deployed, and live-tested.** See the dedicated section
below for the full record. **New, separate bug discovered during live-testing of the fix — not yet
fixed, needs its own decision** (see "Needs your eyes").

### 0040 hotfix — full record

Migration `0040_fix_bill_payment_rpc_conflict_target.sql` + rollback. Verified line-for-line before
writing: confirmed the live index is exactly
`CREATE UNIQUE INDEX user_subscriptions_user_local_id_uidx ON user_subscriptions (user_id, local_id)
WHERE (local_id IS NOT NULL)`, and confirmed zero existing rows violate that uniqueness rule (safe to
add `WHERE local_id IS NOT NULL` to the `ON CONFLICT` target). The fix changes exactly one line
(`on conflict (user_id, local_id) do update set` → `on conflict (user_id, local_id) where local_id is
not null do update set`) — confirmed via a scripted diff of the extracted function bodies that this is
the *only* difference from 0039's version; every parameter, the return shape, `SECURITY INVOKER`,
`search_path`, and grants are byte-identical. The rollback restores 0039's exact (broken) function body
— confirmed identical via the same scripted diff, and its validity as compilable SQL is established by
the fact that it's the literal same `CREATE OR REPLACE FUNCTION` statement that already executed
successfully when 0039 was originally deployed (re-running it live to "test" it would just reintroduce
the bug, so this indirect proof was used instead of a live dry-run).

Deployed: applied via `supabase db query --linked -f`, `migration repair --status applied 0040`,
verified `migration list --linked` shows local/remote synced through 0040.

**Live test results (fresh throwaway users A/B, all cleaned up afterward — 0 rows, 0 users remaining):**
1. Create subscription without immediate payment (plain insert path, unaffected by the RPC) — **PASS**.
2. Create subscription with immediate payment via the fixed RPC (installment type) — **PASS**, was
   previously failing 100% of the time with `42P10`; now returns `paid_count: 1` correctly on first call.
3. Retry same request (same `local_id`/`client_request_id`) — **PASS** on identity (same
   subscription/payment IDs returned, no duplicate rows) — **but surfaced a second, separate bug**,
   see below.
4. Exactly one subscription row for the local_id despite 2 calls — **PASS**.
5. Exactly one payment row for the client_request_id despite 2 calls — **PASS**.
6. `paid_count` correct — **FAIL on retry** (see new bug below); correct on the first call only.
7. No duplicate transaction/payment rows — **PASS** (same as 4/5).
8. Cross-user access rejected — **PASS**, and stronger than expected: an unauthenticated (anon-key-only)
   call is denied at the Postgres grant level itself (`42501 permission denied for function`, HTTP 401)
   before even reaching the function's own `auth.uid() is null` check — defense in depth. Also verified
   User B reusing User A's *exact* `local_id`/`client_request_id` string correctly creates B's own
   fully independent row (own name/amount/user_id), never touching or merging with A's data.
9. A second, different `local_id` for the same user succeeds independently (distinct subscription and
   payment IDs from the first) — **PASS**.
10. Rollback file compiles — confirmed by the identical-to-already-executed-SQL argument above, since
    directly re-running it live would revert the fix under test.

**🟢 RESOLVED 2026-07-14 — migration 0041, deployed and live-tested.** On any second/retry call to
`create_subscription_and_record_payment` for an already-existing subscription, the subscription-
upsert's `on conflict ... do update set ... paid_count = excluded.paid_count ...` clause overwrote
`paid_count` with `p_paid_count` (a separate, subscription-level parameter that defaults to `null` and
is unrelated to per-payment installment tracking) — silently wiping out whatever value the *later*
`elsif subscription_row.type = 'installment' then update ... paid_count ...` step had correctly set on
a prior call. Unreachable before 0040 (every call failed outright with `42P10`) — a pre-existing defect
in 0039's original design, exposed rather than introduced by 0040.

### 0041 hotfix — full record

**Fix:** removed exactly one line (`paid_count = excluded.paid_count,`) from the subscription upsert's
`ON CONFLICT DO UPDATE SET` list. Nothing else changed — the initial-INSERT value (`p_paid_count`) and
the payment-driven `elsif` update block are both untouched. Captured the live (post-0040) function
definition first via `pg_get_functiondef`, confirmed via a scripted, whitespace/type-normalized diff
that the fix migration differs from it by exactly this one line, and that the rollback restores the
captured live (0040) definition exactly (only cosmetic differences: Postgres's own introspection omits
the default `SECURITY INVOKER` keyword and reformats the parameter list to one line — logically
identical, confirmed by the diff). Re-verified the same two indexes the RPC depends on
(`user_subscriptions_user_local_id_uidx`, `user_bill_payments_request_uidx`) are unchanged since 0040.
No `ALTER TABLE`/schema change in this migration at all — pure function redefinition — so there is no
existing-row repair question.

**Deployed:** applied, migration history repaired and verified synced through 0041.

**Live test results (fresh throwaway users A/B, all cleaned up afterward — 0 rows, 0 users remaining):**
- **A** (first call, non-installment type) — **PASS**: `paid_count` follows input/default (`null`,
  since not passed and type isn't `installment`).
- **B** (first call, installment type + immediate payment) — **PASS**: `paid_count: 1`.
- **C** (exact retry of B) — **PASS**, the critical check: same subscription/payment IDs (idempotent
  identity), `paid_count` **remains 1** (previously reset to `null` before this fix). Confirmed both
  via the RPC response and a direct DB query (exactly 1 subscription row, exactly 1 payment row,
  `paid_count = 1`).
- **D** (retry with `p_paid_count` null) — covered by C (no `p_paid_count` passed either time).
- **E** (retry with explicit stale/lower `p_paid_count = 0`) — **PASS**: authoritative `paid_count`
  (1) preserved despite an explicit conflicting value sent.
- **F** (second, genuinely distinct payment, installment_index=2) — **PASS**: `paid_count` correctly
  increments to 2.
- **G** (two genuinely concurrent identical calls via `Promise`-style background curl) — **PASS**:
  both converged on the identical subscription.id and payment.id; DB-level check confirmed exactly 1
  subscription row, exactly 1 payment row, `paid_count = 1` — no race, no duplicate.
- **H** (User B reuses User A's exact `local_id`/`client_request_id`) — **PASS**: fully independent
  row, own `paid_count` (1, distinct from User A's 2), no cross-contamination.
- **I** (rollback restores exact pre-fix/0040 function) — confirmed via the scripted diff before
  deployment, per above.

**Gates:** migration history synced through 0041; `flutter analyze` 0 issues; `flutter test` 567
passed (unchanged, pure SQL migration); `git diff --check` clean; global flags confirmed untouched
(`budget_progress_supabase_rpc` still off, `subscriptions_supabase_primary` unchanged at its
pre-existing 100%).

**Batch 3 status:** with both 0040 (ON CONFLICT target) and 0041 (paid_count overwrite) live and
verified, `create_subscription_and_record_payment` is now fully correct and idempotent under every
tested scenario, including genuine concurrency. Batch 3 can be considered functionally closed pending
only: (a) code review/commit of the accumulated working-tree changes, and (b) the still-outstanding
manual iPhone tests noted for earlier batches (unrelated to this RPC).

### Batch 4
- Dispatched to Codex covering findings #22 (Android `FLAG_SECURE`), #23 (iOS app-switcher privacy
  overlay), #24 (remaining loading/progress-state sweep), #25 (remaining client-side form validation),
  #26 (APNs registration-failure diagnostics feeding the existing Batch 2 capture-health tile), #27
  (opportunistic minor cleanup).
- **Orchestrator independently re-verified every gate:**
  - `flutter analyze` — 0 issues, confirmed directly.
  - `flutter test` — 567 passed, confirmed directly (unchanged from the 0041 hotfix — see gap noted
    below).
  - `xcodebuild Runner` — BUILD SUCCEEDED, confirmed directly.
  - `xcodebuild BankMessageShortcuts` — Codex reported this **failed** in its sandbox again due to the
    same `CoreSimulatorService`/`simdiskimaged` crash pattern seen in Batch 2. Re-ran independently:
    BUILD SUCCEEDED. Confirms (again) it's Codex's sandbox's simulator daemon, not a code defect.
  - `git diff --check` — clean, confirmed directly.
  - Confirmed no Batch 3 bill-payment RPC files or migrations 0037-0041 were touched (explicit check
    per the brief's requirement) — all still present exactly as before, untouched.
  - No new migration was created for this batch (correct — none of these findings needed one).
- **Read every substantive diff directly:**
  - `MainActivity.kt` — `FLAG_SECURE` set once in `onCreate`, standard/correct, blocks both the
    recents-thumbnail and in-app screenshot attempts on Android.
  - `AppDelegate.swift` — a branded blank overlay is installed on `applicationDidEnterBackground` and
    removed on both `applicationWillEnterForeground` and `applicationDidBecomeActive` (belt-and-
    suspenders removal timing). APNs registration failures are now captured with message/domain/code/
    timestamp, persisted to `UserDefaults` (self-clearing the moment a token is later obtained
    successfully), and forwarded live via the existing method-channel pattern plus a new pull-based
    getter for next-launch/settings-open polling.
  - `native_capture_bridge.dart` — clean, well-typed wrapper (`ApnsRegistrationFailure`) matching the
    established `ApnsTokenInfo` style exactly; handles `MissingPluginException` gracefully.
  - `settings_providers.dart` — confirmed this correctly **extends** Batch 2's existing
    `captureHealthStatusProvider`/`CaptureHealthStatus` (adds an `apnsRegistrationFailure` field, folds
    it into `shouldNudge` via OR-logic) rather than creating a parallel/duplicate diagnostic surface,
    exactly as instructed.
  - `goal_details_screen.dart` — the known `var saving = false` gap (non-`setState`-wired) is now a
    proper `StatefulBuilder`-scoped state, correctly wired to disable the submit button and show a
    `CircularProgressIndicator`, with a `finally`-guarded reset and a generic `catch` alongside
    `RepoException` — exact match to the established Batch 1 pattern.
  - `goal_form_screen.dart` — beyond the explicitly-requested deadline-in-the-past re-validation
    (correctly re-checked at submit time, not just at date-picker time), Codex also added a full
    busy-state guard to this form's `_submit()` (previously had none at all, same class of gap as
    Batch 1's accounts-screen finding). Not explicitly commissioned, but squarely in the spirit of
    #24's "sweep remaining loading/progress-state gaps" — a defensible, disclosed extension, not scope
    creep. Confirmed correct end-to-end (button disable, spinner, `finally`-reset, generic catch).
  - `bill_form_sheet.dart` — the date picker's `firstDate` changed from
    `DateTime.now().subtract(365 days)` to today (closing the "up to 365 days in the past" gap
    directly at the picker level), **plus** a submit-time re-check mirroring the goal-deadline fix's
    defense-in-depth pattern. The manual-paid-amount validator changed from `amount < 0` to
    `amount <= 0` (closing the "exactly 0 allowed" gap). Also hoisted the bill/payment request IDs into
    `initState`-computed fields (`_billRequestId`, `_manualPaymentRequestId`) — checked whether this
    duplicates Batch 1's `BillPaymentAttempt` helper (it does not: that helper is only ever wired into
    `bill_details_sheet.dart`'s separate record-payment dialog, never into this form's own inline
    manual-paid-amount flow, which had no stable-id scheme at all before this change) — a genuine
    correctness improvement (retries of a failed save now reuse the same ID instead of generating a
    fresh one each attempt), not a regression or duplicate mechanism.
- **Real, honest gap — not blocking, but worth noting:** unlike every prior batch, **no new automated
  test file was added** for any Batch 4 finding. `#22`/`#23` are inherently untestable via
  `flutter test` (native platform behavior, correctly marked `MANUAL QA REQUIRED` in the plan), but
  `#24`/`#25`'s pure-Dart logic (busy-state guards, deadline/date validation) could have been covered
  by a widget test the way equivalent Batch 1-3 fixes were. Not fixed here since the user's instruction
  was to report and stop after review, not expand scope — flagging for a decision on whether to send a
  small follow-up test-only delta brief, or accept manual QA coverage as sufficient for this batch
  given its lower risk profile (UI polish, not data-integrity or security).

### Gap-closure pass (post-Batch-4)
- Added automated regression coverage for Batch 4's testable Dart-side changes via a scoped Codex
  delta (3 new test files: `goal_details_screen_test.dart`, `goal_form_screen_test.dart`,
  `bill_form_sheet_test.dart` — 10 new tests, all deterministic via `Completer`-gated fakes through
  real use cases, zero production-code changes). Independently re-verified: 577 tests passing.
- Produced `docs/USER_DELETION_DECISION_BRIEF.md` (finding #8's product-decision brief).
- Produced `docs/MANUAL_IPHONE_QA_CHECKLIST.md` (consolidated, 10 groups / 20 tests, covering all
  four batches).
- Produced `docs/WORKING_TREE_SEPARATION_PLAN.md` (full categorization of all 188 changed/new paths
  into pre-existing/pre-QA/Batch 1-4/test-gap/mixed-needing-hunk-staging buckets).
- Final gate re-run: `flutter analyze` 0 issues, `flutter test` 577 passed, both `xcodebuild` schemes
  succeed, `git diff --check` clean, migration history synced through 0041, all global flags confirmed
  unchanged from their intentional baseline.
- **Remediation is now code-complete.** Remaining work is exclusively: (1) the user-deletion product
  decision, (2) manual iPhone QA execution, (3) commit-time review per the separation plan.

## Needs your eyes (running list, most recent first)

- (Batch 2, pending) — to be filled in after review.
- (Batch 1) See the three numbered items under "Batch 1" above — none resolved yet.

## End-of-run checklist (once Batch 4 lands)

- [ ] Run full `flutter analyze` / `flutter test` / both `xcodebuild` schemes / `deno check`+`deno test`
      once more on the final combined tree, not just each batch's own slice.
- [ ] Grep the whole repo once for anything the queue was specifically about (e.g. no remaining
      unguarded `alert80Sent`/`alert100Sent` read-then-write, no remaining hardcoded Riyadh offset).
- [ ] Replay all new migrations (0035 onward) from a clean state and check for drift before any live
      deploy.
- [ ] Resolve the user-deletion product decision (finding #8) before building any UI trigger for it —
      independent of whether the rest of the queue has landed.
- [ ] Perform all outstanding `MANUAL QA REQUIRED` iPhone tests across every batch.
- [ ] Only then: deploy migrations/functions, and only then consider wider-than-QA flag rollout.
