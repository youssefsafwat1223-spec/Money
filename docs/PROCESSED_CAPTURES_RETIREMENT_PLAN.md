# processed_captures Retirement Plan

Status: plan only. Not implemented.

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
- The future `capture_direct_ledger_write` flag is enabled for that user.
- The flag remains OFF by default in Flutter and Supabase seeds.
- `ledger_dual_write` and ledger pull/import have passed staging/manual testing.
- `ledger_push_sync` has passed offline retry and conflict validation.
- Notification tap routing has been validated with server ledger IDs.
- Guests still have a supported local/relay fallback.
- A rollback can return signed-in users to the relay path without losing capture
  payloads.

The placeholder flag must remain OFF by default and inactive globally.

## Planning Sync Boundaries

Phase G sync foundations are intentionally separate from capture routing:

- Accounts, budgets, subscriptions, goals, and plans can be dark-launched behind
  per-user planning flags.
- `bill_payments` remains plan-only because recording/deleting a payment mutates
  installment counters and may be linked to a local transaction.
- `goal_contributions` remains plan-only because importing the child rows can
  double-count `saved_amount` unless contribution idempotency is validated.
- `plan_transaction_links` remains plan-only until transaction `server_id`
  mapping is stable across devices.

These planning tables do not replace `processed_captures` and must not change
iOS Shortcut/App Intent/APNs routing.

## Rollback

Keep the relay path as the default. If direct ledger capture is tested later and
fails, turn the future flag OFF and continue using `processed_captures` +
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
