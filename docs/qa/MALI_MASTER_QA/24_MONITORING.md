# 24 — Monitoring

Related: [07_SECURITY.md](07_SECURITY.md), [28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md), [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md).

## 1. Current observability surfaces

| Surface | What it covers | Access |
|---|---|---|
| Sentry (`sentry_flutter`) | App crashes, unhandled exceptions, breadcrumbs | `SentryConfig.isConfigured` gates it; optional at build time via `--dart-define=SENTRY_DSN=...` |
| Edge Function logs (structured JSON) | Every capture-pipeline event (`sms_parse_result`, `capture_stored`, `apns_sent`/`apns_skipped`/`capture_apns_failed`, `capture_idempotent_replay`, `capture_ledger_write_failed`, `process_ios_sms_complete`) | Supabase Dashboard → Edge Functions → Logs, or `supabase functions logs <name>` |
| Postgres logs | `pg_cron` job execution (`RAISE LOG` from `run_prune_processed_captures()`), any database-level error | Supabase Dashboard → Logs → Postgres Logs |
| Admin panel dashboard | User stats (total, MAU, new-this-month), catalog counts, daily signup chart | `admin/` app, `/dashboard` route |
| `cron.job_run_details` | Scheduled job run history/status (if retained by the plan) | Direct SQL query — see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §5 |

## 2. What is logged vs. what is deliberately never logged

**Logged** (structured, safe): event names, booleans (`hasAmount`, `pushSent`), enums (`status`, `parserSource`), counts, error *types* (not full messages containing user content) where feasible, timing/duration where relevant.

**Never logged** (per [07_SECURITY.md](07_SECURITY.md) §4.3): raw SMS text, merchant/beneficiary names, phone numbers, card numbers, account numbers, device secrets, JWTs, service-role keys. This is a standing constraint on every log line added to any capture-pipeline or auth-adjacent code — review every new `console.log`/`debugPrint` against it before merging.

## 3. Key log events to watch (capture/notification pipeline)

| Event | Meaning | Concerning pattern |
|---|---|---|
| `sms_parse_result` | A capture was parsed (deterministic ± AI) | A sustained drop in `hasAmount`/`hasCurrency` rate suggests a parser-rules regression or a new, unhandled bank SMS format |
| `capture_stored` | Relay row written | Should roughly track incoming capture volume; a sudden spike could indicate a misfiring automation loop on some device |
| `apns_sent` / `apns_skipped` / `capture_apns_failed` | Push delivery outcome | A rising `capture_apns_failed` rate suggests an APNs credential/certificate issue (see [28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md)) |
| `capture_idempotent_replay` | A payload was replayed (client retry or genuine duplicate call) | A high replay rate relative to fresh captures suggests client-side timeouts are firing more than expected — check whether the bounded-timeout budgets in [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §3 need retuning |
| `capture_ledger_write_failed` | Direct-write to `user_transactions` failed non-fatally | Should be rare; a sustained rate while `capture_direct_supabase_write` is enabled for any user warrants investigation before wider rollout |
| `process_ios_sms_complete` | End-to-end request finished | Overall latency/duration here is the signal to watch against the 8s client-timeout budget |
| `prune_processed_captures: captures=% fingerprints=%` (Postgres log) | Daily retention job ran | Absence of this log line on a given day means the cron job did not run — investigate immediately (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §5) |

## 4. What is NOT yet instrumented (known gaps)

- No dedicated metrics/dashboard for feature-flag rollout health (e.g., error rate specifically for users on a given flag override vs. the general population) — currently this must be inferred manually from Edge Function logs filtered by known QA install IDs, or from Sentry issue tags if present. This is a real gap worth closing before any flag reaches a meaningful global `rollout_percent` (see [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §4).
- No automated alerting is described here as currently wired up — treat any specific alerting-threshold claim as needing verification against the actual Supabase project's configured integrations before relying on it operationally.
- No client-side structured analytics beyond `metrics`/`UserActivityService` pings — this project deliberately keeps client telemetry minimal, consistent with the trust posture in [02_PROJECT_DISCOVERY.md](02_PROJECT_DISCOVERY.md) §6.

## 5. Reading Edge Function logs safely

```bash
supabase functions logs process-ios-sms --project-ref <ref>
```

or via the Dashboard. Because logs are structured JSON with no PII by design (§2), they can be shared/pasted for debugging without the sanitization concerns that would apply to, say, a raw request/response dump — but always double-check a specific log line before sharing it externally, since a bug in the logging code itself (accidentally logging a raw field) is exactly the kind of regression [07_SECURITY.md](07_SECURITY.md) §8's review checklist exists to catch.

## 6. Monitoring after a flag rollout stage increase

Per [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §4, each rollout stage gets a minimum 24–48h observation window. During that window, watch:

- Edge Function error rates for the affected functions.
- `capture_ledger_write_failed` rate, if the direct-write flag is involved.
- Any new Sentry issues tagged or correlated with the rollout timing.
- User-reported symptoms through whatever support channel exists — treat an uptick here as a leading indicator that may arrive before logs make the pattern obvious.
