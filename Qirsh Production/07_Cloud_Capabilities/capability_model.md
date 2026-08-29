# Capability Model

## In plain language

Qirsh stores money as exact whole numbers of the smallest unit — 12.345 KWD is
`12345`, never a decimal. Sending that to a server and back can corrupt it if
anything on the path converts through a floating-point number.

Rather than assume the server round-trips exactly, the app **refuses to sync
money until that has been proven in production** — separately for each direction.

That is why cloud financial sync is off today. Not an oversight; the design.

## The four gates

| Gate | Where | Ships as | Blocks |
|---|---|---|---|
| `exactPushTransportCapability` | `app/lib/data/sync/exact_transport_capability.dart` | `unknown` | outbound exact-money sync |
| `exactPullTransportCapability` | same file | `unknown` | inbound exact-money sync |
| `planningServerCurrencyCapability` | same file | `unknown` | budgets/goals cloud sync |
| `kServerRevisionCas` | `app/lib/core/sync/sync_capabilities.dart` | `false` | server-revision CAS |

## Positive proof only

| Value | May run? |
|---|---|
| `verifiedExact` | yes |
| `unknown` | **no** |
| `unsupported` | **no** |

Both non-verified states block. There is no "probably fine" — proving one
direction says nothing about the other, which is why push and pull are tracked
independently.

### Decoder strictness is NOT authority

`moneyFromPulledValue` throws when a value is not `NUMERIC::text` rather than
degrading to a double, and every money pull projects `::text`. That is genuine
defence in depth and is asserted by test — but it proves **payload safety**, not
**transport authority**. It says "if a bad payload arrives we refuse it", which
is a claim about this client's decoding, not about whether the transport has
been verified end-to-end against a live server.

An earlier iteration treated that strictness as sufficient to permit pulling
under `unknown`. That was rejected. Only positive proof may enable a financial
transport.

## ⚠️ Activation is a CODE CHANGE, not a toggle

All three providers are hardcoded and **not wired to `FeatureFlagService`**. No
Supabase flag, admin toggle or remote config can change them. Activation means
editing the file, rebuilding and shipping.

### Consequence for incidents

| Layer | Mechanism | Speed |
|---|---|---|
| Feature flag | `ledger_push_sync`, `ledger_pull_sync`, `planning_*_sync` → off | **remote, immediate** |
| Capability | provider back to `unknown`, ship | needs a release — slow |
| Consent | the user's own setting | per user |

**The fast kill switch is the feature flags.** Flip the flag first; treat the
capability revert as the follow-up release.

## A flag can never falsely authorise a capability

The gate requires the **capability**; flags only ever narrow further. A flag
being on cannot enable an unverified transport. `FeatureFlagService` defaults
every sync flag to `false` and `getBool` returns `false` for unknown keys, so a
flag fetch that fails also fails closed.

## Planning currency needs BOTH

`weakerCapability()` returns `verifiedExact` only when both inputs are
`verifiedExact`. Budgets/goals therefore stay parked unless the planning-currency
capability **and** that direction's transport are both verified — never one
alone. It additionally requires migration `0077` deployed.

## What happens while parked

`shouldParkExactMoneyWrite` keeps the local canonical write and the remote
mutation **durably**, tagged `exact_money_transport_unverified`. It does not
serialise through the legacy JSON-number adapter, does not mark it synced, does
not drop it, and does not retry aggressively. Nothing is lost while parked.
