# Kill Switch & Capability Rollback

## The hierarchy, fastest first

| Layer | Mechanism | Reach | Speed |
|---|---|---|---|
| **1. Feature flag** | `ledger_push_sync` / `ledger_pull_sync` / `planning_*_sync` → off | all installs | **next flag fetch — minutes** |
| 2. Force update | `arm_force_update()` (migration `0089`, audited) | all installs | next app launch |
| 3. Capability revert | provider → `unknown`, ship | updated installs only | a full release cycle |
| 4. Consent | the user's own setting | one user | immediate, per user |

## Use the flag first. Always.

Capabilities are compiled in; reverting one needs a store release, which for iOS
means review time. During an incident that is far too slow.

Flip the flag, stop the damage, then schedule the capability revert as the
follow-up.

## Flags fail closed

`FeatureFlagService` defaults every sync flag to `false`, and `getBool` returns
`false` for unknown keys. A flag fetch that fails leaves sync **off**, not on.

## Force update — the last resort

Migration `0089` makes arming a server-authorised, audited operation. Before it,
any writer could block every installed client with no audit trail.

```sql
select public.arm_force_update(<announcement_id>, '<reason>', <actor_id>);
```

A trigger blocks arming outside this function. It blocks **all navigation for
every installed client** — use only when a stale client is actively harmful.

## What a capability revert does not do

It stops *further* wrong behaviour. It does not repair data already written. If
PULL wrote wrong money locally, reverting the capability leaves those values in
place. Assess and repair separately.
