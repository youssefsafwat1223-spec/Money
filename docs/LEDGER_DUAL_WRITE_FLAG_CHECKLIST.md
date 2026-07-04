# Ledger Dual-Write Flag Checklist

Use this checklist before enabling `ledger_dual_write` for any tester.

Required state:

- Global `feature_flags.ledger_dual_write` remains inactive/false.
- `feature_flag_overrides` exists with RLS enabled.
- `capture_devices.user_id` is linked only through `link-capture-device`.

Cases to verify:

1. No linked user:
   - `process-ios-sms` must keep the capture relay-only.
   - No row is written to `user_transactions`.

2. Linked user, no override, global OFF:
   - `process-ios-sms` must keep the capture relay-only.
   - No row is written to `user_transactions`.

3. Linked user, override true, global OFF:
   - `process-ios-sms` may insert one idempotent row into `user_transactions`.
   - The row uses `source = ios_shortcut`.

4. Linked user, override false, global ON:
   - `process-ios-sms` must not write `user_transactions`.

5. Duplicate payload:
   - Re-running the same `payloadId` must not create duplicate ledger rows.

6. Guest/cloud relay:
   - `processed_captures` remains the relay source.
   - Drift remains the app source of truth after `sync-captures`.
