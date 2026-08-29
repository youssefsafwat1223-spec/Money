# PUSH Activation

**PUSH is always first.** Detail for runbook §10.3.

## Why push before pull

A push failure is **contained**: the outbox parks the write durably with
`exact_money_transport_unverified` and nothing is lost.

A pull failure under an unverified transport writes **wrong money into the local
canonical store** — not contained, and not automatically repairable. Recovering
means telling users their recorded spending was wrong.

## Prerequisites

- Backend provisioned (runbook Phase 3)
- Internal beta running (Phase 9)
- A test account you are willing to write junk into

## Test data — values chosen to break naive implementations

| Case | Value | Currency | Proves |
|---|---|---|---|
| 3-decimal | `12.345` | KWD | scale not truncated to 2 |
| 0-decimal | `150` | JPY | no phantom fraction added |
| 2-decimal floor | `0.01` | SAR | smallest unit survives |
| Large magnitude | `90071992547409.93` | SAR | **beyond 2^53** — a float corrupts this |
| Negative | `-1240.50` | SAR | sign preserved and attached |

The large-magnitude case is the important one: it is the value that silently
proves whether anything on the path went through a double.

## Procedure

1. Create each transaction locally in the beta build.
2. Trigger a push through the real PostgREST path — not a script that bypasses
   the app's serialisation.
3. Read each row back with an explicit `::text` projection.
4. Require **byte-exact** equality with what was sent. Not "equal to 2dp".
5. Confirm **idempotency**: replaying the same request id does not double-write.
6. Confirm **conflict typing**: a competing update produces a typed durable
   conflict, not a silent overwrite.

## What counts as success

A captured record — screenshot or query output — showing sent value and
round-tripped value identical, character for character, for **all five** cases.

## What counts as failure

Any difference at all, including one that looks harmless. `12.35` where `12.345`
was sent is a failure. `90071992547409.94` is a failure.

## Activating

Edit **only** the push provider in
`app/lib/data/sync/exact_transport_capability.dart`:

```dart
final exactPushTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.verifiedExact;  // verified <date>, evidence <link>
});
```

Leave pull and planning-currency at `unknown`. Rebuild and ship.

## Verifying after activation

- Parked-write count falls to zero
- No `exact_money_transport_unverified` entries accumulate
- Server rows match local values exactly

## If it goes wrong

Flip `ledger_push_sync` **off** — remote and immediate. Then revert the provider
in the next release. Do not wait for the release to stop the bleeding.
