# PULL Activation

**Only after PUSH is activated and verified in production.**

## Prerequisites

- PUSH activated, shipped, and observed clean for a meaningful period
- Backend unchanged since that proof

## Test data

The same five cases as PUSH — `12.345` KWD, `150` JPY, `0.01` SAR,
`90071992547409.93` SAR, `-1240.50` SAR — but proven in the opposite direction.

## Procedure

1. Seed rows server-side with known exact values.
2. Pull them into a clean install.
3. Require the local canonical `_minor` value to equal the server value exactly.
4. Confirm the decoder rejects a deliberately malformed payload rather than
   coercing it — the strictness is defence in depth and should be seen working.

## What counts as success

Every value byte-exact after the round trip, plus an observed rejection of a
malformed payload.

## Activating

```dart
final exactPullTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.verifiedExact;  // verified <date>, evidence <link>
});
```

Rebuild and ship.

## Why this one is riskier

A push mistake parks writes. A pull mistake **writes wrong money locally**. There
is no automatic repair — the wrong value is already in the user's canonical
store, and rolling the capability back does not undo it.

Take the extra day.

## Planning currency (budgets/goals)

Still parked after both transports are verified, until migration `0077` is
deployed **and** `planningServerCurrencyCapability` is set. `weakerCapability()`
requires both; never unpark on one alone.

## If it goes wrong

Flip `ledger_pull_sync` **off** immediately. Then assess whether any local data
was corrupted — that assessment matters more than the flag, because the flag
stops new damage but does not repair what landed.
