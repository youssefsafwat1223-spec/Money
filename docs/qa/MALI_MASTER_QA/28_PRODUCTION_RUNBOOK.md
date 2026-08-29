# 28 — Production Runbook

Related: [24_MONITORING.md](24_MONITORING.md), [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md).

Day-2 operations: what to do when something goes wrong in production, organized by symptom.

## 1. "Users report captures aren't arriving"

1. Check `capture_devices.last_seen_at` for the affected device(s) — is the device even calling in? If not, this is likely a Shortcuts-automation or App-Extension-level issue on the device, not a backend one.
2. Check Edge Function logs for `process-ios-sms` around the reported time — is `capture_stored` appearing at all? If the function isn't being reached, check `register-device`/`link-capture-device` logs for auth failures.
3. Check `sync-captures` logs — are relay rows being drained? If `processed_captures` has rows for that `install_id_hash` that were never acked, the issue is on the app-drain side, not the capture side.
4. Cross-check against [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) §9 "common failure modes" table for a matching signature.

## 2. "Users report duplicate transactions"

1. Get the exact `payloadId`(s) or a description of the duplicated transaction (amount, merchant, approximate time) from the report.
2. Query `processed_captures`/`capture_fingerprints` for that install/user around the reported time (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) for query patterns) — is there evidence of two distinct `payloadId`s for what should have been one capture (missing Date Received — [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) §3.1)?
3. Check whether the regression fixes in [18_REGRESSION.md](18_REGRESSION.md) `REG-005`/`REG-006`/`REG-010` are actually present in the currently-deployed app/function versions — a duplicate-transaction report is exactly the symptom these fixes were written to prevent, so first confirm the fix is actually live before hypothesizing a new bug.
4. If the fixes are confirmed live and duplicates are still occurring, this is a new bug — follow [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) from reproduction through a new regression test.

## 3. "Users report a notification but no transaction ever appears"

1. Check the relevant `processed_captures` row's `status` — was it `rejected` (correctly, no transaction expected) or `processed`/`needs_review` (a transaction should exist)?
2. If it should exist but doesn't, check whether the relay row was ever acked without a corresponding successful import — this points at a native-queue-drain failure (see [18_REGRESSION.md](18_REGRESSION.md) `REG-008`, and confirm the per-message re-enqueue fix is live).
3. Check Sentry for a crash/exception around the relevant timestamp on that user's device.

## 4. "APNs push failure rate is elevated" (via `24_MONITORING.md` §3 signal)

1. Check the APNs credential configuration (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` environment variables on the Edge Function) — has the key expired or been revoked in the Apple Developer portal?
2. Check whether the failure is concentrated on one APNs environment (`sandbox` vs `production`) — a sandbox-vs-production token/environment mismatch for a specific build channel is a common, narrow-blast-radius cause.
3. Check `capture_devices.apns_token`/`apns_environment` for affected devices — a stale/invalidated token (e.g., after a reinstall) should self-heal on the device's next `registerForRemoteNotifications` call; if it isn't, check the token-refresh wiring in `AppDelegate`/`NativeCaptureBridge`.

## 5. "The retention cron job hasn't run" (missing daily log line)

1. Confirm via `select * from cron.job;` that the job is still present and `active` (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §5) — has it been accidentally unscheduled by a later migration?
2. Confirm `pg_cron` extension is still installed (`select * from pg_extension where extname = 'pg_cron';`) — a project restore or plan change could theoretically affect extension availability; if genuinely unavailable, fall back to a scheduled-Edge-Function alternative per [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) §"If pg_cron is unavailable."
3. Manually invoke `select run_prune_processed_captures();` once to confirm the function itself still works, independent of the scheduler.

## 6. "A feature-flag rollout stage shows a regression signal"

1. **Immediately** consider rolling the flag back to its previous `rollout_percent`/`is_active` state — this is the fastest available mitigation (see [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §5) and does not require a code deploy.
2. Only after mitigating, investigate root cause using the normal [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) process.
3. Do not resume the rollout to the same or a higher stage until the root cause is understood and fixed, with a regression test added per [18_REGRESSION.md](18_REGRESSION.md).

## 7. "Suspected security incident" (leaked credential, unexpected cross-user data access)

Follow [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md) §4 immediately — credential rotation and RLS-bypass-blast-radius assessment take priority over root-causing "how" it happened. Document as you go; root-cause investigation happens after immediate containment.

## 8. General on-call principles

- **Contain, then diagnose, then fix, then verify, then document** — in that order. Do not skip containment to "find the real root cause first" when real user data or ongoing duplication is at stake.
- **The flag-rollback lever is almost always the fastest safe mitigation** for anything traced to a Supabase-primary migration — reach for it before a code hotfix in a live incident.
- **Never take a destructive action (delete rows, force-push, drop a table) as an incident-response step** without the same explicit-approval discipline that applies outside an incident — urgency does not suspend the safety rules in [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md).
- **Every incident gets a written record** — symptom, timeline, containment action, root cause, permanent fix, regression test added. This feeds both [18_REGRESSION.md](18_REGRESSION.md) (if it's a recurring-bug-class) and this runbook (if it reveals a new symptom → cause mapping worth adding here).
