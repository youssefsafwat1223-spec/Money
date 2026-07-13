# processed_captures Retirement Plan

Status: retirement plan only. Direct-write preparation exists, but retirement is not implemented.

`processed_captures` remains active and is still required for the current iOS
Shortcut/APNs capture flow.

## Current Required Behavior

- `process-ios-sms` continues to write backend-processed capture relay rows.
- `sync-captures` continues to fetch relay rows for the app.
- Flutter imports relay rows into Drift and acknowledges/deletes only after the
  local commit succeeds.
- iOS Shortcut/App Intent and APNs routing continue to use the relay path.
- Guests continue to use relay/local fallback behavior.
- `processed_captures`, `capture_devices`, `capture_fingerprints`, and
  `capture_rate_limits` must not be removed.

## Why Retirement Is Blocked

Direct ledger capture requires a durable user-owned server ledger row. Guests do
not have `auth.uid()`, so they cannot safely write to user-owned ledger tables.
Until the guest strategy is decided, the relay is the safe bridge between native
capture and Drift.

## Future Direct Ledger Capture Conditions

Direct capture may be considered only when all are true:

- The user is signed in.
- Both `capture_direct_supabase_write` and `transactions_supabase_primary` are
  enabled for that signed-in QA user.
- The flag remains OFF by default in Flutter and Supabase seeds.
- Direct transaction repositories and source-payload idempotency have passed
  staging/manual testing.
- `ledger_push_sync` has passed offline retry and conflict validation.
- Notification tap routing has been validated with server ledger IDs.
- Guests still have a supported local/relay fallback.
- A rollback can return signed-in users to the relay path without losing capture
  payloads.

Both flags must remain OFF by default and inactive globally.

## Planning Sync Boundaries

Planning direct repositories are intentionally separate from capture routing:

- Accounts, budgets, subscriptions, goals, and plans can be dark-launched behind
  per-user planning flags.
- Bill payment and goal contribution mutations use authenticated atomic RPCs so
  counters are updated exactly once.
- Plan transaction links require stable server transaction IDs; unresolved
  local links are reported and never guessed during backfill.

These planning tables do not replace `processed_captures` and must not change
iOS Shortcut/App Intent/APNs routing.

## Rollback

Keep the relay path as the default. If direct capture QA fails, turn
`capture_direct_supabase_write` OFF and continue using `processed_captures` +
`sync-captures` without data loss.

## Manual Validation Before Any Retirement

- Cloud OFF: local fallback still works.
- Cloud ON guest: relay row imports into Drift.
- Cloud ON signed-in: relay row imports into Drift.
- APNs delivered: notification tap syncs relay then routes correctly.
- Duplicate payload: no duplicate Drift transaction.
- Network failure: App Intent falls back safely.
- Ack/delete: relay row is deleted only after Drift commit.
- Ledger flags: `ledger_dual_write`, `ledger_pull_sync`, and `ledger_push_sync`
  are validated together on staging before any direct capture flag is tested.
- Guest strategy: guests have a documented local-only or relay strategy.
- RLS: user-owned ledger rows cannot be read across users.
- Rollback: disabling the direct-capture flag returns all users to relay flow.
