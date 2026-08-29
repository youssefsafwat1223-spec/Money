# 21 — Checklists

Related: [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md), [07_SECURITY.md](07_SECURITY.md).

Consolidated, copy-pasteable checklists. Each references the document that explains the *why* behind each item.

## Code review checklist

- [ ] Every changed line traces to the stated task ([01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 3).
- [ ] No speculative abstraction or unrequested configurability added (Rule 2).
- [ ] New Arabic-facing strings have both `ar` and `en` ARB entries (Rule 11).
- [ ] Financial date-range queries use half-open intervals (Rule 5).
- [ ] Transfer accounting logic, if touched, is updated identically in every place it's duplicated ([09_DATA_FLOW.md](09_DATA_FLOW.md) §1).
- [ ] Category values crossing the Drift/Supabase boundary are correctly translated key ↔ local-id ([04_DATABASE.md](04_DATABASE.md) §4.1).
- [ ] New tests exist for new behavior, not just manual confirmation.
- [ ] Removed-because-now-unused imports/variables are cleaned up; pre-existing unrelated dead code is mentioned, not silently deleted (Rule 3).

## Database checklist

- [ ] Migration has a matching rollback file ([01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 8).
- [ ] Verified against live row counts/shape before writing a constraint-affecting change ([12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §2).
- [ ] Any new unique index intended as an upsert conflict target is **non-partial** ([04_DATABASE.md](04_DATABASE.md) §4.2).
- [ ] RLS enabled and scoped correctly on any new table — deny-all by default unless it's a `user_*`-style per-user table with an explicit `auth.uid()` policy.
- [ ] New RPCs use the correct security mode (INVOKER unless a specific, justified reason for DEFINER exists) and are revoked from `anon`/`authenticated` if service-role-only.
- [ ] Post-apply verification run (§3 in [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md)) and migration history confirmed synchronized.

## Backend (Edge Function) checklist

- [ ] No raw SMS text, phone/card/account numbers, or secrets in any new log line ([07_SECURITY.md](07_SECURITY.md) §4.3).
- [ ] Any new third-party API call gated by the existing AI/enrichment consent flag, not a new ungated path.
- [ ] Idempotency preserved for any write path — plain insert + `23505` recovery for user writes, controlled upsert against a deterministic key only for backfill.
- [ ] Bounded timeouts on any new outbound fetch that could otherwise push the caller past its own timeout budget (see [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §3 precedent).
- [ ] `deno check`/`deno test` run and clean.
- [ ] Only the actually-affected functions are scheduled for deployment ([05_BACKEND.md](05_BACKEND.md) §6).

## Flutter checklist

- [ ] `flutter analyze` clean, `flutter test` passing.
- [ ] Any new provider wrapping a mutable singleton uses a getter function, not a captured instance ([06_FLUTTER.md](06_FLUTTER.md) §3).
- [ ] Any new Supabase-primary repository path exercised under both flag states, not just one.
- [ ] Typed `RepoException` handling present for any new user-facing Supabase call — no raw exception surfaced to the UI.
- [ ] `flutter gen-l10n` regenerated if `.arb` files changed.

## Release checklist

See [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §2/§3 in full — summary:

- [ ] All standard gates green.
- [ ] Version/build number bumped correctly.
- [ ] No reachable debug seam in a release build.
- [ ] Both iOS schemes (`Runner`, `BankMessageShortcuts`) build; `SharedCaptureStore.swift` copies byte-identical.
- [ ] Handbook updated for any architecture/schema/flag change in this release.

## Production checklist (before any global flag change)

- [ ] Per-user override QA fully green across the relevant sections of [11_TEST_MATRIX.md](11_TEST_MATRIX.md).
- [ ] Manual device QA (notification pipeline steps, [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §7) completed and recorded.
- [ ] Rollback plan explicitly stated and understood (instant flag rollback is the first lever — [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §5).
- [ ] Monitoring/alerting in place for the entity being cut over (see [24_MONITORING.md](24_MONITORING.md)).
- [ ] Explicit human sign-off obtained for this specific rollout stage, not inferred from a prior general approval.

## Security review checklist

See [07_SECURITY.md](07_SECURITY.md) §8 for the full, authoritative list — summarized:

- [ ] No new log line leaks PII/secrets.
- [ ] No new unauthenticated financial-data-adjacent endpoint.
- [ ] No new table with permissive default RLS.
- [ ] No service-role key reference under `app/lib/`.
- [ ] Notification content still excludes account balance.

## Pre-commit self-check (for an AI agent, every time)

- [ ] Did the user explicitly ask for a commit right now? If not, stop — leave changes in the working tree ([01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 10).
- [ ] Have all applicable gates from [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md)/[10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) actually been run (not assumed)?
- [ ] Is the final report ([20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md)) complete, with explicit commit-safety and deploy-safety verdicts?
