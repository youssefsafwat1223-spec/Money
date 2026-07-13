# Supabase-Primary Rollout Report

Date: 2026-07-13

## Architecture

Production today, with all flags OFF:

```text
Flutter UI -> providers/use cases -> routed repositories -> Drift
iOS Shortcut -> process-ios-sms -> processed_captures -> sync/ack -> Drift
```

Per-user QA primary route:

```text
Flutter UI -> providers/use cases -> routed repositories -> Supabase + RLS
                                                   -> post-success Drift cache
iOS Shortcut -> process-ios-sms -> user_transactions -> APNs
                              +-> processed_captures safety relay
App open -> relay sync -> canonical source_payload_id lookup -> ack
```

Widgets never query Supabase directly. Routing happens inside repository
providers and reads the refreshed cached feature flags per operation.

## Implemented phases

- Accounts and transactions direct repositories, typed failures, stable create
  idempotency, tombstones, pagination, backfill, and cache repair.
- Authenticated financial summary RPCs for month/account/category/budget/goal.
- Direct repositories for budgets, goals/contributions,
  subscriptions/payments, plans/links, and Smart Inbox.
- Atomic contribution/payment RPCs and owner-validation triggers.
- Deterministic planning backfill in parent-first order; unresolved parent IDs
  are reported and never guessed.
- Direct iOS capture preparation behind two signed-in per-user gates. Relay,
  APNs fallback, guests, and Swift PreviewParser remain intact.

## Applied migrations

- 0024-0029: primary kill switches and hardened account/transaction parity.
- 0030: authenticated financial summary RPCs.
- 0031: planning child tables, ownership triggers, and atomic RPCs.
- 0032: primary feature flag seeds.

Remote migration history is aligned through 0032. Rollback SQL lives outside
the migration directory and must be used only after impact review.

## Flags

The following are seeded and verified globally as `false`, rollout `0`, and
inactive: accounts/transactions/dashboard/budgets/goals/subscriptions/plans/
Smart Inbox primary flags, `capture_direct_supabase_write`, and all legacy
ledger pull/push/dual-write flags. Per-user overrides are the only approved QA
mechanism.

## Backfill and cache rules

- Accounts precede every child referencing an account.
- Transactions precede bill payments and plan links.
- Existing server rows win; backfill does not overwrite them.
- Missing parent mapping is an unresolved failure, not a nullable guess.
- Supabase commits before Drift mirror. A mirror failure marks the entity cache
  dirty and does not turn server success into a retry with a new ID.
- No local Drift rows are deleted by backfill.

## Capture invariants

- `processed_captures` and `sync-captures` remain active.
- Cloud OFF remains local-only.
- Guests remain relay/local fallback.
- Direct capture requires a linked signed-in user and both
  `capture_direct_supabase_write` and `transactions_supabase_primary`.
- Canonical insert is idempotent by `(user_id, source_payload_id)`.
- APNs receives the canonical transaction ID when direct write succeeds.
- App-open relay sync reuses that row and acknowledges the relay instead of
  creating a second transaction.
- Backend/direct failure is non-fatal to the relay path.

## Security posture

- Service role remains Edge Function/server-only.
- New tables use owner RLS and same-user parent validation.
- Raw SMS is not stored in `user_transactions` or planning payloads.
- Production function logs omit full SMS and payload identifiers.
- Android SMS permissions remain absent and capture remains intentionally
  disabled for MVP.

## Not complete

- No global cutover has been approved.
- No production backfill/reconciliation has been run by this implementation.
- Two-real-user RLS, real iPhone Shortcut/APNs, TestFlight, offline retry,
  1,201-row live pagination, timezone, and cache-failure repair remain manual.
- `processed_captures` retirement and old sync/Drift cleanup are not implemented.
- Anonymous-auth/guest long-term strategy is still a retirement blocker.

## Deployment checklist

1. Confirm migrations through 0032 and function deployment.
2. Confirm all global flags OFF.
3. Create two disposable QA users and baseline row counts.
4. Enable one per-user override at a time on staging.
5. Run `SUPABASE_PRIMARY_MANUAL_QA.md` and save reconciliation counts.
6. Remove overrides and QA data; confirm global flags again.
7. Repeat on TestFlight for Shortcut/APNs only after staging passes.
8. Update privacy disclosures before collecting durable production ledger data.
9. Obtain explicit approval before any global percentage or active flag change.

## Rollback

- Turn the affected per-user primary override OFF.
- Refresh catalog or resume the app so providers invalidate.
- If `financial_cache_health` is dirty, repair from Supabase before Drift
  rollback; do not blindly switch authority.
- Turn `capture_direct_supabase_write` OFF to return signed-in captures to relay
  import. Do not remove relay rows/functions/tables.
- Keep server tombstones and canonical rows for reconciliation; never truncate.
- Roll back an additive migration only after exports, dependency review, and
  explicit approval.
