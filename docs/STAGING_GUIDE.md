# Staging & TestFlight Testing Guide

How to safely test Supabase-primary sync flags on real devices without touching production.

---

## 1. Environment setup

Mali supports three Supabase environments via the `SUPABASE_ENV` dart-define:

| Value | Meaning |
|-------|---------|
| `production` (default) | Live Supabase project — never enable sync flags here |
| `staging` | Dedicated staging Supabase project for pre-release testing |
| `local` | Supabase running locally via `supabase start` |

### Run with staging keys (simulator)

```bash
flutter run -d "Mali-iPhone" \
  --dart-define=SUPABASE_URL=https://your-staging-ref.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-staging-anon-key \
  --dart-define=SUPABASE_ENV=staging
```

### Build TestFlight IPA with staging keys

In `codemagic.yaml`, pass the staging variable group:

```yaml
environment:
  groups:
    - supabase_staging   # different Codemagic group from production
  vars:
    SUPABASE_ENV: staging
```

Or pass dart-defines directly in the build script:

```bash
flutter build ipa \
  --dart-define=SUPABASE_URL=$STAGING_SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$STAGING_SUPABASE_ANON_KEY \
  --dart-define=SUPABASE_ENV=staging
```

> **Safety guard:** If `SUPABASE_ENV` is not `production` in a release build, the app
> logs a `FlutterError` via `FlutterError.reportError`. This surfaces in Sentry/Crashlytics
> and prevents a staging build from silently entering production without being noticed.

---

## 2. Staging Supabase project setup

Create a separate Supabase project (different `project-ref`) for staging.
Run all migrations in order so the schema matches production exactly:

```bash
supabase link --project-ref <staging-project-ref>
supabase db push
```

Deploy edge functions to the staging project:

```bash
SUPABASE_ACCESS_TOKEN=<your-token> supabase functions deploy --project-ref <staging-project-ref> catalog-flags
supabase functions deploy --project-ref <staging-project-ref> catalog-delta
supabase functions deploy --project-ref <staging-project-ref> catalog-announcements
supabase functions deploy --project-ref <staging-project-ref> catalog-flags
supabase functions deploy --project-ref <staging-project-ref> catalog-versions
supabase functions deploy --project-ref <staging-project-ref> parser-test
```

---

## 3. Per-user flag overrides (Phase J)

Migration `0019_feature_flag_overrides.sql` adds a `feature_flag_overrides` table.
This lets you enable a flag for a single tester without changing global `feature_flags`.

### SQL to enable a flag for one tester

```sql
-- Find the tester's user_id in Authentication → Users
INSERT INTO feature_flag_overrides (user_id, key, enabled)
VALUES (
  '<tester-user-uuid>',
  'ledger_pull_sync',
  true
)
ON CONFLICT (user_id, key) DO UPDATE SET enabled = EXCLUDED.enabled;
```

### SQL to disable a flag override

```sql
DELETE FROM feature_flag_overrides
WHERE user_id = '<tester-user-uuid>' AND key = 'ledger_pull_sync';
```

### Checking active overrides

```sql
SELECT f.key, f.is_active AS global_active, o.enabled AS override
FROM feature_flags f
LEFT JOIN feature_flag_overrides o ON o.key = f.key AND o.user_id = '<tester-user-uuid>'
ORDER BY f.key;
```

---

## 4. Safe flag test order

Enable flags one at a time. Validate each before proceeding to the next.

| Order | Flag | What it does | When to enable |
|-------|------|--------------|----------------|
| 1 | `ledger_dual_write` | process-ios-sms also writes `user_transactions` | First — read-only risk. Backend-only. |
| 2 | `ledger_pull_sync` | App pulls `user_transactions` → Drift cache | After verifying dual-write rows look correct |
| 3 | `ledger_push_sync` | Drift writes push to `user_transactions` | After pull is validated |
| 4 | `smart_inbox_pull_sync` | App pulls `user_smart_inbox` → local cache | Independent; can test alongside 1–3 |

**Never enable on production** until each flag has passed ≥1 week of TestFlight without issues.

---

## 5. Rollback per flag

```sql
-- Force a flag OFF globally (affects all users immediately on next catalog sync)
UPDATE feature_flags SET is_active = false, rollout_percent = 0
WHERE key = 'ledger_pull_sync';

-- Or remove a single tester's override
DELETE FROM feature_flag_overrides
WHERE user_id = '<tester-user-uuid>' AND key = 'ledger_pull_sync';
```

The Flutter app re-syncs flags on every cold start. Flag changes take effect within one app restart.

---

## 6. Verify flags are OFF on production

Run this query in the production Supabase SQL editor before any release:

```sql
SELECT key, is_active, rollout_percent, value
FROM feature_flags
WHERE key IN (
  'ledger_dual_write',
  'ledger_pull_sync',
  'ledger_push_sync',
  'smart_inbox_pull_sync'
)
ORDER BY key;
```

Expected result: all rows show `is_active = false`, `rollout_percent = 0`.

---

## 7. TestFlight build checklist

- [ ] `flutter analyze` → 0 issues
- [ ] `flutter test` → all pass
- [ ] Build targets staging Supabase project (`SUPABASE_ENV=staging`)
- [ ] Staging project has all migrations applied (`supabase db push`)
- [ ] Edge functions deployed to staging project
- [ ] All 4 sync flags `is_active = false` on staging (confirm with SQL above)
- [ ] Install on TestFlight device, cold-start, confirm debug log shows `env=staging`
- [ ] Enable `ledger_dual_write` for tester via `feature_flag_overrides` → confirm via SQL
- [ ] Trigger an iOS Shortcut capture → confirm `user_transactions` row appears in staging DB
- [ ] Proceed with flag 2 only after flag 1 is stable
