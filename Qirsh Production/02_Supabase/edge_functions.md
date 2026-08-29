# Edge Functions — Production Deployment

Canonical source: `supabase/functions/` (24 functions — do not move).

## Deployment order

**None required.** No function depends on another at deploy time; all share
`_shared/`, which deploys with each. Deploy secrets first (runbook §3.1) so the
workers never have a window of failing cron runs.

## The 24 functions

### Catalog (client reads; served to every install)
`catalog-delta` · `catalog-announcements` · `catalog-flags` · `catalog-versions`
· `catalog-campaigns` · `catalog-coupons`

`catalog-delta` serves **only** parsers with `validation_status = 'passed'`,
which is why migration `0087` has a user-visible effect.

### Capture / parsing
`parse-sms` · `process-ios-sms` · `bank-discovery` · `parser-test` ·
`sync-captures`

Require `GEMINI_API_KEY` for the AI-assisted path. **Without it they return
`upstream_unavailable` (retryable) and the deterministic parser continues** —
they never proceed with a null key and never leak.

### Device / push
`register-device` · `register-push-token` · `link-capture-device` ·
`unlink-capture-device` · `set-device-consent`

### Engagement
`evaluate-budgets` · `evaluate-goals` · `evaluate-gamification` ·
`cron-daily-reminders` · `merchant-feedback` · `enrich-merchant`

`enrich-merchant` **soft-degrades by design** without `GOOGLE_MAPS_API_KEY`,
falling back to `bestEffortCategoryForMerchant()`. Enrichment is an enhancement,
not a correctness path.

### Workers — JWT verification deliberately OFF
`purge-scheduled-deletions` · `process-notification-retries`

`supabase/config.toml` sets `verify_jwt = false` for both. They are invoked by
`pg_cron` or an operator, never by a client, and gate on a dedicated shared
secret instead of a user JWT.

**Both fail closed on a missing secret** — verified in source:

- `bearerSecretAuthorized()` opens with `if (!configuredSecret) return false;`
  (`_shared/capture_auth.ts:124`), covered by `_shared/purge_worker_auth_test.ts`
- `process-notification-retries` checks `if (!workerSecret || !timingSafeEqual(...))`

So deploying before the secrets exist is safe — they reject everything.

## Deploying

```bash
cat supabase/.temp/project-ref     # prove the target

cd supabase
for fn in catalog-delta catalog-announcements catalog-flags catalog-versions \
          catalog-campaigns catalog-coupons parser-test bank-discovery \
          parse-sms process-ios-sms enrich-merchant merchant-feedback \
          evaluate-budgets evaluate-goals evaluate-gamification \
          cron-daily-reminders link-capture-device unlink-capture-device \
          register-device register-push-token set-device-consent \
          sync-captures purge-scheduled-deletions process-notification-retries; do
  echo "── $fn"; supabase functions deploy "$fn" || break
done
```

## Verifying

Dashboard → Edge Functions → 24 listed, each "Deployed".

```bash
# A worker must REJECT an unauthenticated call. 403 here is the pass condition.
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST https://<ref>.supabase.co/functions/v1/purge-scheduled-deletions
```

Anything other than 401/403 is a **release blocker** (STOP condition #5).

## If a deploy fails

Redeploy that one function; the others are unaffected. A failure part-way
through the loop leaves earlier functions deployed, which is safe — they are
independent.
