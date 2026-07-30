# Mali — Release Validation Runbook

**Purpose.** Execute the 12 external release gates left open by the closed Full Production Audit
(`app/docs/FULL_APP_AUDIT.md`). Every blocker's **code is complete and locally verified**
(analyze 0 · Flutter 993 · Deno 54 · migration lint PASS); what remains is proving each gate with
**real environment evidence**. This runbook is the authority for that validation.

**Branch under validation:** `feat/phase1-data-integrity` · pushed HEAD `68fdd0a0`
(`origin/feat/phase1-data-integrity`).

**Current status of ALL 12 gates: OPEN — no live evidence yet.**

> **Owner roles** (a solo maintainer may wear several): **REL** Release owner · **BE** Backend/Supabase ·
> **AND** Android · **IOS** iOS · **QA** Verification. Assign real names before starting.

> **Do NOT during validation prep:** deploy *production* migrations, change *production* secrets, submit
> to Google Play / App Store, start MALI-026, implement backlog findings, or begin a new audit. Stages 1–3
> use **disposable/staging** resources only.

---

## How to read a gate

Each gate block below has: **Owner · Environment · Credentials · Prep · Commands/UI · Acceptance ·
Evidence to capture · Failure signal · Rollback/recovery · MALI · Status.** "Evidence" is the artifact
you paste back into the gate's status when you close it (log excerpt, screenshot, query output).

---

## A. Supabase staging and migrations

### Gate 1 — Apply migrations 0065 + 0066 + 0067 and verify RLS / cron / grants
- **Owner:** BE
- **Environment:** Disposable or staging Supabase project (hosted, or local via Docker if available). **Never production.**
- **Credentials:** Supabase CLI login; project ref; DB password; service-role key (kept out of logs).
- **Prep:**
  1. Create a throwaway Supabase project (or `supabase start` locally).
  2. `supabase link --project-ref <staging-ref>`.
  3. Confirm the local migration set is intact: `bash supabase/tools/check_migrations.sh` → expect `PASS` (67 files, 13 SECURITY DEFINER locked down).
- **Commands / UI:**
  ```bash
  cd supabase
  supabase db push                      # applies 0001..0067 in order
  # Verify grants are revoked from public/anon/authenticated:
  # (SQL editor) run for each function:
  #   select has_function_privilege('anon','purge_user_data(uuid)','execute');            -- expect f
  #   select has_function_privilege('authenticated','run_purge_scheduled_deletions()','execute'); -- expect f
  #   select has_function_privilege('service_role','run_purge_scheduled_deletions()','execute');  -- expect t
  # Verify cron job exists:
  #   select jobname, schedule from cron.job where jobname='purge-scheduled-deletions-job';  -- 30 3 * * *
  # Verify account_purge_queue exists with RLS on:
  #   select relrowsecurity from pg_class where relname='account_purge_queue';               -- expect t
  ```
- **Acceptance:** all migrations apply with no error; `account_purge_queue` exists with RLS on; `purge_user_data` / `run_purge_scheduled_deletions` / `run_cron_daily_reminders` are revoked from public/anon/authenticated and granted to service_role; cron job scheduled `30 3 * * *`.
- **Evidence to capture:** `supabase db push` success log; the 4+ SQL query outputs above.
- **Failure signal:** migration error; any `has_function_privilege('anon', …)` = true; cron job absent.
- **Rollback/recovery:** `select cron.unschedule('purge-scheduled-deletions-job');` drop the two functions / restore prior `purge_user_data`; `drop table account_purge_queue;`. Because it's a disposable project, the fastest recovery is to recreate the project.
- **MALI:** MALI-005, MALI-036 · **Status:** OPEN

---

## B. Secrets, Vault, Edge Functions, and cron

### Gate 2 — `PURGE_WORKER_SECRET` (Edge) matches Vault `purge_worker_secret`
- **Owner:** BE
- **Environment:** the same staging Supabase project (secrets + Vault).
- **Credentials:** service-role key; ability to set Edge secrets and Vault entries. **Never print secret values.**
- **Prep:**
  1. Generate a strong random secret once; store it in your password manager.
  2. Confirm Vault `project_url` is present (used by the cron RPC to reach the Edge function).
- **Commands / UI:**
  ```bash
  cd supabase
  supabase secrets set PURGE_WORKER_SECRET=<value>          # Edge env
  # Vault (SQL editor):
  #   select vault.create_secret('<same-value>','purge_worker_secret');   -- or update if exists
  #   select vault.create_secret('https://<ref>.supabase.co','project_url'); -- if missing
  supabase functions deploy purge-scheduled-deletions
  # Then trigger the cron RPC manually and confirm a non-403:
  #   select run_purge_scheduled_deletions();
  ```
- **Acceptance:** a cron-triggered POST reaches `purge-scheduled-deletions` and returns **non-403**; a wrong Bearer returns **403** (already proven in logic by `supabase/functions/_shared/purge_worker_auth_test.ts`).
- **Evidence to capture:** function logs showing the authorized call (no "Vault secrets not configured"); a deliberate wrong-Bearer test returning 403.
- **Failure signal:** purge never runs; function logs "Vault secrets not configured"; cron call 403s.
- **Rollback/recovery:** rotate both Edge secret and Vault entry to a new **matching** value; re-deploy the function.
- **MALI:** MALI-005 · **Status:** OPEN

### Gate 2b — Deploy + smoke all Edge Functions (engagement + capture + catalog)
- **Owner:** BE
- **Environment:** staging Supabase.
- **Credentials:** as Gate 2.
- **Prep:** run the Deno suite locally first: `deno test --allow-all supabase/functions/` → expect **54 passed**.
- **Commands / UI:**
  ```bash
  cd supabase
  for fn in catalog-delta catalog-announcements catalog-flags catalog-versions parser-test \
            evaluate-budgets evaluate-goals evaluate-gamification cron-daily-reminders \
            purge-scheduled-deletions process-ios-sms; do
    supabase functions deploy "$fn"
  done
  ```
- **Acceptance:** each function deploys; a benign authorized call to each returns 2xx.
- **Evidence to capture:** deploy logs; one sample 2xx per function.
- **Failure signal:** deploy error; unexpected 5xx on a valid call.
- **Rollback/recovery:** redeploy previous function version; disable the cron job while investigating.
- **MALI:** MALI-004, MALI-019 · **Status:** OPEN

---

## C. RLS and authorization adversarial tests

### Gate 3 (audit gate 12) — Live RLS + Edge authorization adversarial suite
- **Owner:** BE + QA
- **Environment:** staging Supabase with two real test users (A, B).
- **Credentials:** two user JWTs (A, B); an ordinary project JWT; the service-role key (for the negative "should be rejected from client" tests).
- **Prep:** create users A and B; complete onboarding for each; seed a few financial rows for A.
- **Commands / UI:**
  ```text
  1. RLS isolation: as B, attempt to read/update A's rows in
     transactions/accounts/cards/budgets/goals/plans/smart_inbox → expect 0 rows / denied.
  2. Engagement Edge authz (MALI-004): call evaluate-budgets / evaluate-goals /
     evaluate-gamification with:
       - anon key                         → reject
       - ordinary user JWT (no secret)    → reject
       - forged record.user_id = B as A   → reject / no cross-user mutation
       - correct service-role secret      → accept
  3. Cron RPC: call run_cron_daily_reminders() / run_purge_scheduled_deletions()
     as anon/authenticated → reject; as service_role → accept.
  4. Replay + malformed-event: resend a valid event twice (idempotent, no double effect);
     send an invalid table/op → reject.
  ```
- **Acceptance:** every cross-user and unauthorized attempt is denied; only service-role/secret calls succeed; replays are idempotent; malformed events rejected.
- **Evidence to capture:** per-case request/response (status + body) table; RLS query outputs.
- **Failure signal:** any cross-user read/write succeeds; any anon/user call drives a service-role function; a replay doubles state.
- **Rollback/recovery:** disable affected Edge functions and the cron job; fix the guard/RLS; re-run 0057/engagement migration lockdown.
- **MALI:** MALI-004, MALI-005, MALI-019, MALI-036 · **Status:** OPEN

---

## D. Android release build and native capture

### Gate 4 (audit gate 3) — Android release build + merged-manifest verification
- **Owner:** AND
- **Environment:** machine with Android SDK + an emulator or device. *(Not available on the audit workstation.)*
- **Credentials:** release keystore (or a temporary debug-signed build for smoke); staging Supabase dart-defines.
- **Prep:** `flutter doctor -v` must show a valid Android toolchain.
- **Commands / UI:**
  ```bash
  cd app
  flutter build apk --release \
    --dart-define=SUPABASE_URL=<staging-url> --dart-define=SUPABASE_ANON_KEY=<staging-anon>
  # Verify merged manifest contains INTERNET:
  #   unzip -p build/app/outputs/flutter-apk/app-release.apk AndroidManifest.xml | \
  #     (aapt2 dump xmltree ...) → assert android.permission.INTERNET present
  ```
- **Acceptance:** signed/again-signed build installs; merged **release** manifest declares `INTERNET`; auth + Supabase sync + Edge calls + Sentry succeed; notifications schedule and survive reboot.
- **Evidence to capture:** merged-manifest INTERNET line; auth/sync smoke recording; reboot-then-notification test.
- **Failure signal:** missing INTERNET; production networking fails; notifications lost after reboot.
- **Rollback/recovery:** fix `android/app/src/main/AndroidManifest.xml`; rebuild; re-verify merged manifest.
- **MALI:** MALI-006 · **Status:** OPEN

### Gate 5 (audit gate 9) — Android durable capture on device (process-death/reboot)
- **Owner:** AND + QA
- **Environment:** Android SDK + device.
- **Credentials:** none beyond the app build.
- **Prep:** install the Gate 4 build; enable share-to-Mali.
- **Commands / UI:**
  ```text
  1. Share a bank SMS to Mali; force-stop the app before Flutter drains → reopen → item still imported.
  2. Reboot the device with a queued item → reopen → item survives and imports.
  3. peek/ack round-trip: import once, confirm no duplicate on next drain.
  4. Capability API: with notification perm only, assert SMS capability reports correctly (never conflated).
  ```
- **Acceptance:** shared messages survive process death + reboot; peek≠delete; ack removes only the matching item; capability states are honest.
- **Evidence to capture:** screen recording of each scenario; `DurableCaptureQueue` state before/after kill.
- **Failure signal:** shared message lost on process death; duplicate import; wrong permission state shown.
- **Rollback/recovery:** the durable SharedPreferences-backed queue is the fix; if regressions appear, verify enqueue-before-return and idempotent ack.
- **MALI:** MALI-013 · **Status:** OPEN

### Gate 6 (audit gate 11) — Android durable-queue unit tests (JVM harness)
- **Owner:** AND
- **Environment:** Android/JVM test harness (JUnit/Robolectric) — **does not exist yet; must be wired.**
- **Credentials:** none.
- **Prep:** add an Android unit-test source set to the Gradle module.
- **Commands / UI:** `cd app/android && ./gradlew test` (after adding tests).
- **Acceptance:** queue tests pass — survives recreation, peek≠delete, ack-only-matching, idempotent, malformed-safe.
- **Evidence to capture:** Gradle test report.
- **Failure signal:** any queue invariant fails; harness absent (current state).
- **Rollback/recovery:** logic is already written in `DurableCaptureQueue.kt`; add the harness and iterate.
- **MALI:** MALI-013 · **Status:** OPEN

---

## E. Google Play SMS-policy readiness

### Gate 7 (audit gate 10) — Play Permissions Declaration for auto-SMS (only if auto-SMS ships)
- **Owner:** REL + AND
- **Environment:** Google Play Console.
- **Credentials:** Play Console access for the app listing.
- **Prep:** decide whether auto-SMS ships in v1. **Default build is Play-safe** (RECEIVE_SMS + `SmsCaptureReceiver` commented out). If auto-SMS is deferred, this gate is **N/A for that release** and share-capture remains the path.
- **Commands / UI:**
  ```text
  1. In Play Console → App content → Permissions Declaration: declare RECEIVE_SMS for
     "money management / financial SMS", attach a demo video + prominent-disclosure screen.
  2. Only AFTER approval: uncomment RECEIVE_SMS + SmsCaptureReceiver in the manifest
     (or ship a dedicated flavor) and rebuild.
  3. Verify opt-in flow: user grants → only financial SMS enqueue; denial degrades to share-capture.
  ```
- **Acceptance:** Play approves the declaration; prominent disclosure present; only financial SMS captured; denial degrades cleanly.
- **Evidence to capture:** Play approval record; disclosure screenshot; a filtered-capture demo.
- **Failure signal:** app rejected/removed for undeclared RECEIVE_SMS; unrelated SMS captured.
- **Rollback/recovery:** keep the Play-safe build (permission commented); ship auto-SMS only post-approval.
- **MALI:** MALI-013 · **Status:** OPEN (or N/A if auto-SMS deferred)

---

## F. iOS signed build, APNs, App Group, and extensions

### Gate 8 (audit gate 4) — APNs token registration + push routing
- **Owner:** IOS + BE
- **Environment:** **physical** iPhone + paid Apple Developer account (App Groups + APNs entitlements).
- **Credentials:** APNs auth key/cert; provisioning profiles; staging Supabase.
- **Prep:** configure APNs key in the backend; ensure the device registers for remote notifications.
- **Commands / UI:**
  ```text
  1. Install a signed dev build on device; grant notifications.
  2. Confirm the device uploads an APNs token to the backend (capture_devices row).
  3. Trigger a budget/goal/streak/bill event; confirm exactly one push arrives and routes to the right screen.
  ```
- **Acceptance:** device registers a token; each push type arrives once and routes correctly; quiet-hours/disabled types are suppressed (server-side, MALI-019).
- **Evidence to capture:** token upload log; per-type push screenshots; a quiet-hours suppression test.
- **Failure signal:** no token; no delivery; duplicate or unwanted push.
- **Rollback/recovery:** check entitlements, APNs environment (sandbox vs prod), device token upload; disable server push authority if duplicates.
- **MALI:** MALI-019 · **Status:** OPEN

### Gate 9 (audit gate 6, iOS portion) — App Group + extensions on device
- **Owner:** IOS + QA
- **Environment:** physical iPhone + paid account (App Group `group.com.youssefsafwat.mali`).
- **Credentials:** signing/provisioning with the App Group entitlement.
- **Prep:** install signed build with Runner + ShareBankMessage extension.
- **Commands / UI:**
  ```text
  1. Share a bank SMS via the share sheet → enqueues to App Group → app imports it.
  2. Use the "Process Bank SMS" App Intent/Shortcut (compiled into Runner) → captures via SharedCaptureStore.
  3. Confirm ONLY Runner + ShareBankMessage are embedded (no obsolete BankMessageShortcuts.appex).
  ```
- **Acceptance:** share-sheet + App Intent capture both enqueue and import; exactly the two expected targets embedded.
- **Evidence to capture:** capture recording; `verify_ios_packaging.sh` output on the built app.
- **Failure signal:** capture lost; wrong/extra extension embedded.
- **Rollback/recovery:** run `app/tools/verify_ios_packaging.sh`; fix target/embedding wiring.
- **MALI:** MALI-012, MALI-020 · **Status:** OPEN

---

## G. App Store privacy archive validation

### Gate 10 (audit gate 5) — App Store archive privacy report
- **Owner:** IOS + REL
- **Environment:** signed **Release archive** (paid account), Xcode Organizer.
- **Credentials:** distribution certificate + provisioning.
- **Prep:** archive a Release build.
- **Commands / UI:**
  ```text
  1. Xcode → Product → Archive → Organizer → Generate Privacy Report.
  2. Confirm the report lists Runner + ShareBankMessage PrivacyInfo.xcprivacy with the declared types.
  3. Reconcile the App Store Connect privacy questionnaire with the declared data types
     (OtherFinancialInfo, DeviceID, EmailAddress/Name/Phone for Runner; OtherFinancialInfo for the extension).
  ```
- **Acceptance:** privacy report shows both manifests with accurate types; App Store privacy label matches actual data flows.
- **Evidence to capture:** the generated privacy report PDF; App Store Connect privacy answers.
- **Failure signal:** missing/inaccurate manifest in the archive; label mismatch.
- **Rollback/recovery:** re-run `app/tools/verify_ios_packaging.sh` on the archived app; fix manifest wiring; re-archive.
- **MALI:** MALI-020 · **Status:** OPEN

---

## H. Backup/restore, sign-out, and account deletion

### Gate 11 (audit gate 6, data-safety portion) — On-device backup/restore + sign-out wipe smoke
- **Owner:** QA
- **Environment:** device (iOS and/or Android) + staging backend + Storage bucket `backups`.
- **Credentials:** a test user; backup passphrase.
- **Prep:** populate an account with transactions, cards (assigned + unassigned + design), custom categories, budgets, goals, bills, plans.
- **Commands / UI:**
  ```text
  1. Backup (v3) upload → download on a fresh install → passphrase restore → assert
     every table/field round-trips (cards, custom categories, account cols, mappings).
  2. Sign-out while offline with pending edits → choose outcome → assert no cross-user residue
     and no unsynced-data silent loss warning was bypassed.
  3. Card cloud guard: create an unassigned card, attempt sign-out → assert the pre-sign-out warning fires.
  ```
- **Acceptance:** restore is byte/semantic-complete; sign-out leaves no residue and honors the data-loss guard.
- **Evidence to capture:** before/after data diff; recordings of each flow.
- **Failure signal:** any table/field lost on restore; cross-user artifact; silent unsynced loss.
- **Rollback/recovery:** backup v3 + MALI-011 wipe coverage are the fixes; if a gap appears, extend the snapshot/wipe inventory.
- **MALI:** MALI-011, MALI-014, MALI-017 · **Status:** OPEN

### Gate 12 (audit gates 1+2, deletion end-to-end) — Account-deletion purge saga (time-travel)
- **Owner:** BE + QA
- **Environment:** staging Supabase (Gates 1 + 2 complete).
- **Credentials:** a disposable test user with data across all 24 purge tables + a Storage backup object.
- **Prep:** create the user, seed data + a backup object, request deletion.
- **Commands / UI:**
  ```text
  1. Request deletion in-app → row appears in account_purge_queue (30-day schedule).
  2. Time-travel: set the queue row due-now; run run_purge_scheduled_deletions().
  3. Inject a per-step failure (e.g. Storage delete) → assert the discovery profile is NOT removed first
     and the job retries idempotently until auth deletion succeeds.
  4. After success: scan all 24 tables + Storage + auth → zero residue.
  ```
- **Acceptance:** every step is idempotent; failure mid-way is recoverable; final scan shows complete erasure across DB/Storage/auth/logs/devices.
- **Evidence to capture:** per-step logs; the all-table + Storage + auth residue scan output.
- **Failure signal:** retained auth/storage/log/device data; profile removed before dependent steps.
- **Rollback/recovery:** re-run the idempotent worker; on a disposable project, recreate and re-test.
- **MALI:** MALI-005 · **Status:** OPEN

---

## I. Two-device sync and conflict resolution

### Gate 13 (audit gate 11) — Live two-device planning conflict + server-atomic update
- **Owner:** QA + BE
- **Environment:** 2 devices + live/staging Supabase, same account.
- **Credentials:** one test account signed in on both devices.
- **Prep:** create a budget/goal/bill/plan; sync both devices to the same base.
- **Commands / UI:**
  ```text
  1. Go offline on both; edit the SAME row differently on each; reconnect.
  2. Assert exactly ONE conflict is raised, resolvable both ways (keep-mine re-pushes / keep-theirs re-pulls).
  3. (Hardening) add a version / WHERE updated_at=base guarded server update to close the client-side TOCTOU,
     then re-run to confirm no lost update slips through.
  ```
- **Acceptance:** concurrent edits produce exactly one resolvable conflict; no silent lost update.
- **Evidence to capture:** both-device recordings; server row version history.
- **Failure signal:** a lost update slips through the read-then-write race; conflict never surfaces or never resolves.
- **Rollback/recovery:** client base-token compare is shipped; add the server-atomic conditional update (needs a migration + live test).
- **MALI:** MALI-022 · **Status:** OPEN

### Gate 14 (audit gate 7) — Card cloud rollout round-trip
- **Owner:** BE + QA
- **Environment:** live/staging Supabase + 2 devices.
- **Credentials:** test account on both devices; ability to flip `kUserCardsCloudV2`.
- **Prep:** deploy migration 0064; server-advertise the card-cloud capability.
- **Commands / UI:**
  ```text
  1. Confirm 0064 applied and capability advertised.
  2. Flip kUserCardsCloudV2=true in a validation build.
  3. Create an unassigned card + design fields on device A → confirm round-trip to device B and to a reinstall.
  ```
- **Acceptance:** unassigned + design fields survive reinstall and reach a second device; nothing disappears.
- **Evidence to capture:** device-A→device-B card recording; reinstall round-trip.
- **Failure signal:** card/customization disappears on reinstall/second device.
- **Rollback/recovery:** keep the flag **false** (the client guard warns before loss); re-enable only after 0064 verified live.
- **MALI:** MALI-017 · **Status:** OPEN

---

## J. Old-client / new-server compatibility

### Gate 15 (audit gate 8) — Hosted CI green + old/new client compatibility matrix
- **Owner:** REL + BE
- **Environment:** Codemagic + staging Supabase.
- **Credentials:** Codemagic project with the `supabase` variable group; staging DB.
- **Prep:** ensure the authored workflows (`android-release`, `backend-and-quality-gates`) are wired in `codemagic.yaml`.
- **Commands / UI:**
  ```text
  1. Run both Codemagic workflows → expect green (config assertions, Deno Edge tests,
     admin lint/build, migration lint, flutter analyze/test).
  2. Compatibility matrix: run an OLD client build against the NEW schema (migrations 0060–0067),
     and a NEW client against a PRE-0064 schema → both function without data loss.
  ```
- **Acceptance:** both workflows green on Codemagic; old-client/new-schema and new-client/old-schema both work.
- **Evidence to capture:** Codemagic run URLs + status; compatibility-matrix results.
- **Failure signal:** green CI ships a broken Android/backend combo; a migration breaks an old client.
- **Rollback/recovery:** roll back the migration; gate the client on a min-schema-version check.
- **MALI:** MALI-036 · **Status:** OPEN

---

## K. Internal beta smoke suite

### Gate 16 — Aggregate internal-beta smoke (entry to Stage 3)
- **Owner:** QA
- **Environment:** internal beta build (TestFlight internal / Play internal testing) on real devices, pointed at staging.
- **Credentials:** beta distribution access; 2–3 internal testers.
- **Prep:** Gates 1–15 that apply to the shipping platforms must be green.
- **Commands / UI:**
  ```text
  Run the end-user smoke across both platforms:
   - onboarding + truthful consent toggles (MALI-001)
   - capture (share sheet / App Intent) → import → notification
   - add/confirm transactions; totals/refunds/excluded accounts correct (MALI-018)
   - backup + restore round-trip (MALI-014)
   - sign-out wipe + re-login as a different user shows no residue (MALI-002/011)
   - account deletion request path (MALI-005)
   - two-device edit → conflict resolution (MALI-022)
  ```
- **Acceptance:** every smoke path passes on both shipping platforms with no data loss or cross-user leak.
- **Evidence to capture:** a signed-off smoke checklist per platform + recordings.
- **Failure signal:** any data-loss, cross-user, consent, or auth path fails.
- **Rollback/recovery:** halt beta; file the specific gate regression; do not promote to Stage 4.
- **MALI:** aggregate · **Status:** OPEN

---

## L. Production go / no-go checklist

### Gate 17 — Go/No-Go (entry to Stage 4)
- **Owner:** REL (final sign-off)
- **Environment:** N/A (decision gate).
- **Credentials:** N/A.
- **Go requires ALL of:**
  - [ ] Gates 1–3 green (Supabase migrations, secrets/Vault, RLS/authz adversarial) on staging.
  - [ ] Gate 4/5 green if Android ships this release (build + on-device durable capture).
  - [ ] Gate 7 satisfied or auto-SMS explicitly deferred (Play-safe build).
  - [ ] Gates 8/9/10 green if iOS ships (APNs, App Group/extensions, App Store privacy report).
  - [ ] Gates 11/12 green (backup/restore, sign-out, deletion saga).
  - [ ] Gate 13 green (two-device conflict) and Gate 14 satisfied or card-cloud flag left false.
  - [ ] Gate 15 green (hosted CI + compatibility matrix).
  - [ ] Gate 16 green (internal beta smoke, both platforms).
  - [ ] Rollback runbook rehearsed for each deployed migration; monitoring/alert thresholds set.
- **Acceptance:** every applicable checkbox is evidence-backed.
- **Evidence to capture:** the completed checklist with links to each gate's evidence.
- **Failure signal:** any unchecked applicable item → **No-Go**.
- **Rollback/recovery:** stay on the prior release; address the failed gate.
- **MALI:** all · **Status:** OPEN

---

## Release stages — entry / exit criteria

### Stage 1 — Disposable Supabase validation
- **Entry:** branch `feat/phase1-data-integrity` pushed (done, HEAD `68fdd0a0`); local gates green (analyze 0 · Flutter 993 · Deno 54 · migration lint PASS); a disposable Supabase project exists.
- **Work:** Gates 1, 2, 2b, 3 (Sections A–C) and Gate 12 (deletion saga, Section H).
- **Exit:** all of the above green with captured evidence; **no production resources touched.**

### Stage 2 — Signed development-device validation
- **Entry:** Stage 1 exit met; signing assets available (Android keystore; paid Apple account for iOS).
- **Work:** Gates 4, 5, 6 (Android), 8, 9 (iOS device/APNs/App Group), 11 (backup/sign-out), 13/14 (two-device) — pointed at staging.
- **Exit:** all applicable device gates green with recordings/evidence.

### Stage 3 — Internal beta
- **Entry:** Stage 2 exit met; Gate 10 (App Store privacy report) prepared; Gate 15 (hosted CI + compat matrix) green; Gate 7 resolved or auto-SMS deferred.
- **Work:** Gate 16 aggregate smoke on TestFlight-internal / Play-internal, staging backend, 2–3 testers.
- **Exit:** Gate 16 green on both shipping platforms; no open data-loss/cross-user/consent/auth defects.

### Stage 4 — Staged production rollout
- **Entry:** Gate 17 Go/No-Go = **Go**; production Supabase migrations deployed **backend-first** (backend compatibility precedes client, since migrations are forward-only); production secrets set; monitoring live.
- **Work:** phased rollout (e.g. Play staged % / App Store phased release); watch error/erasure/sync dashboards.
- **Exit:** rollout at 100% with no Sev-1 regression across a defined soak window.

### Stage 5 — Post-release monitoring
- **Entry:** Stage 4 at 100%.
- **Work:** monitor crash-free rate, purge-worker success, sync conflict/dead-letter rates, notification delivery, Sentry PII hygiene; keep the rollback runbook ready.
- **Exit:** stable soak window passed → begin the post-release backlog (starting with **MALI-026**, then the grouped backlog in `FULL_APP_AUDIT.md`).

---

## Cross-reference

- Canonical finding classification, commit ledger, and gate acceptance detail: **`app/docs/FULL_APP_AUDIT.md`** (closure dashboard + section G).
- Local gate commands: `app/CLAUDE.md`, `tools/ci_gates.sh`, `supabase/tools/check_migrations.sh`, `app/tools/verify_ios_packaging.sh`.
- **Deferred (do not start during validation):** MALI-026 (fixed-precision money — separate project) and the post-release backlog.
