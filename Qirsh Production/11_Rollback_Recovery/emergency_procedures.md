# Emergency Procedures

**First question in any incident: is there a server-side lever?** There usually
is, and it is always faster than a release.

## Severity ladder

| Layer | Reach | Speed |
|---|---|---|
| Feature flag | all installs | **minutes** |
| Edge Function redeploy | all installs | minutes |
| Migration rollback | database | minutes |
| Force update | all installs | next launch |
| Capability revert | updated installs only | a release cycle |
| Store rollback | new installs only | hours–days, partial |

## By symptom

### Money syncing wrong — highest severity
1. Flip `ledger_push_sync` and `ledger_pull_sync` **off** now.
2. Assess whether local data was corrupted. **This matters more than the flag** —
   the flag stops new damage; it does not repair what landed.
3. If PULL wrote wrong values, they are already in users' canonical stores.
   Plan a repair; do not assume a capability revert undoes it.

### A parser mis-reads a bank
Set that parser's `validation_status` to `pending`. `catalog-delta` serves only
`passed` rules, so it stops reaching clients on the next catalog sync. The
deterministic engine falls back; no client update needed.

### Gemini failing, slow, or costing too much
```bash
supabase secrets unset GEMINI_API_KEY
```
The three functions return `upstream_unavailable` and **the app continues
normally** on the deterministic parser and the on-device classifier.

### APNs not delivering
Check `aps-environment` matches the build, `APNS_BUNDLE_ID` is exact, and the
`.p8` was pasted whole. Pushes are not financial data — this is HIGH, not
BLOCKING.

### An Edge Function is broken
Redeploy the previous version of **that one function**. They are independent.

### A migration broke something
See [`migration_recovery.md`](migration_recovery.md). **Read the rollback file's
header before running it** — 0084 and 0085 must not be reverted by dropping their
functions.

### Auth failing
Check the provider config (especially Google's "skip nonce checks") and the
redirect URLs. Auth config is Dashboard state, not code — no release needed.

### A client-only defect with no server lever
Hotfix release. If the old build is actively harmful, `arm_force_update()`
(migration `0089`, audited) blocks it at next launch.

## What never to do in an incident

- Do not roll back `0084`/`0085` by dropping their functions
- Do not activate a capability to "test whether that fixes it"
- Do not push a hotfix without the strict gate green at that commit
- Do not delete audit rows as part of a rollback — that is how an incident
  becomes unreconstructable
