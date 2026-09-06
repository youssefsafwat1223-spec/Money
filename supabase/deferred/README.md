# Deferred migrations

A migration in this directory is **complete, reviewed and deliberately NOT
deployed**. It is held here rather than in `../migrations/` so that
`supabase db push` cannot propose it — a header comment saying "do not apply"
does not stop the CLI, and the whole point of deferring is that the tool must not
offer it.

**This is not an archive of abandoned work.** Everything here is intended to ship
once a specific, named condition is met. Each entry states that condition.

## Rules

- **Only the highest-numbered migration may be deferred.** The lint in
  `../tools/check_migrations.sh` requires the active chain to be gapless, so
  parking a migration from the middle would break it — correctly. If you need to
  defer something that is not last, renumber it to the end first.
- **Move the rollback with it.** Source and reversal stay together so activation
  is one move, not two half-remembered ones.
- A deferred migration is **not** counted by the active lint. That is intended:
  it is not part of the deployment target.

## Reactivating

```bash
git mv supabase/deferred/00NN_name.sql          supabase/migrations/
git mv supabase/deferred/00NN_name_rollback.sql supabase/rollback/
bash supabase/tools/check_migrations.sh          # numbering must stay gapless
supabase db push --dry-run --linked              # must now propose it
```

If a later migration has since taken the number, renumber the deferred one to the
new tail before moving it back.

---

## 0099_record_metric_ad_keys.sql — DEFERRED 2026-09-04

> **RENUMBERED 0098 → 0099 on 2026-09-06.** An active migration
> `migrations/0098_engagement_worker_secret_auth.sql` claimed 0098, exactly as
> the policy above anticipates. This file and its rollback were renamed so that
> **no number is ever carried by both an active and a deferred migration** — a
> duplicate would mislead tooling, operators and the release ledger about what
> "0098" means. Only the filenames and their self-naming header comments
> changed; the executable SQL is byte-identical (verified by hashing the
> non-comment body before and after).
>
> If a future migration takes 0099 too, renumber this file again to the new
> tail before moving it back. Reactivating it below the last applied remote
> version would additionally require `--include-all`, which the Supabase CLI
> otherwise refuses.

**Condition for activation: an explicit owner decision to switch report-export
and banner telemetry ON.**

`0099` adds eleven event keys to `record_metric`'s server-side allowlist, which
0072 ships as `ARRAY['app_open']`.

**There is no telemetry feature flag. That allowlist IS the switch.** Two of the
eleven keys are already emitted by shipped clients:
`report_export_coordinator.dart:82` fires `report_export_requested` at the top of
`run()`, before any ad gate, and `:201` fires `report_export_completed` after
every successful export. Their only gate is cloud-processing consent
(`report_ads_analytics.dart:39`) — **not** `enable_report_ads`.

So applying 0099 would immediately begin persisting report-export telemetry for
every cloud-consenting user, and no feature flag could prevent it. That is
incompatible with the standing requirement that telemetry stay off, so it is
deferred rather than deployed. Deferring is safe: nothing depends on it, and
until it is applied the client's ad-key events are silently dropped by
`record_metric`, exactly as they have been since R4.

**Before activating, fix the finding recorded in
`docs/project/MIGRATION_LEDGER.md`:** `p_dimension` is server-side free text —
the function enforces only `length <= 128` (`0099:72`) while a comment claims the
client can only pass a placement key. A `p_dimension ~ '^[a-z0-9_]{1,32}$'` guard
closes it.
