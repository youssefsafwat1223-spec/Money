# QIRSH — EXACT-FINANCIAL TRANSPORT ACTIVATION RUNBOOK

**Phase F of `QIRSH_MASTER_PLAN_V2.md`. Prepared 2026-08-28. NOT EXECUTED.**

> This runbook is written but deliberately **not run**. Every step below requires
> explicit owner authorisation, and several touch a remote project. Nothing here
> has been applied to production (`vrombzdgwqjjiijbidqb`) or to evidence staging
> (`dpdukyozedajelflkeix`).

---

## 0. WHY THIS EXISTS

Qirsh's cloud half is **dark in production**, and not by accident — by design.
Four independent capability gates all default to a negative verdict, and every
money-bearing transport is gated on positive proof:

| Gate | Location | Default |
|---|---|---|
| `exactPushTransportCapabilityProvider` | `app/lib/data/sync/exact_transport_capability.dart:17` | `unknown` |
| `exactPullTransportCapabilityProvider` | :23 | `unknown` |
| `planningServerCurrencyCapabilityProvider` | :38 | `unknown` (0077 undeployed) |
| `kServerRevisionCas` | `app/lib/core/sync/sync_capabilities.dart:27` | `false` (0068 undeployed) |

`unknown` blocks. `unsupported` blocks. **Only `verifiedExact` permits**, and no
production code path sets it — the only overrides live in the demo workspace.

That is the correct posture: money must not move on an unproven transport. But it
means **the verification evidence was never converted into runtime authority**,
so activation is an unowned step rather than a completed one. This runbook makes
it ownable.

**Reframing that matters:** the Phase-6 "9/9 verified pushes" result was obtained
on a **demo build with capability overrides**, against a local Docker Supabase.
It is real evidence about the *transport*, and no evidence at all about
*production*. Do not treat it as a substitute for step 4.

---

## 1. HARD PRECONDITIONS

Activation must not begin until **all** of these hold. Each is a genuine
correctness dependency, not ceremony.

| # | Precondition | Why it blocks | State |
|---|---|---|---|
| P1 | **C-3 consent enforcement complete**, incl. financial PULL | Activating pull before consent gates it would begin downloading financial data for users who declined. Pull currently has **no** consent gate (its services are in the H-4 quarantine). | **OPEN** |
| P2 | **F-029 server-row repair** | Pre-fix clients wrote per-device category ids into `user_budgets.category_id`. Activating sync propagates those corrupt rows and a later edit locks them to `other`. | **OPEN** |
| P3 | **F-021 pull half reworked** | The rejected implementation strands rows in `pending` with no outbox item, converting every later remote edit into a phantom conflict. Activation multiplies that. | **OPEN** |
| P4 | **C-6 atomic guarded update** | `push` reads `updated_at` then writes in a second statement; a remote write in that window is silently clobbered. Tombstones already use the correct chained `.eq('updated_at', base)` — the pattern exists, it is just not applied. | **OPEN** |
| P5 | **0087 + 0088 applied** | Parser validation evidence and the declared grant matrix. | **NOT APPLIED** |
| P6 | **A staging project exists** | There is currently nowhere to rehearse. DF-002 is why: `supabase/migrations` alone could not stand up a working environment. | **OWNER** |

> If any precondition is skipped, the failure mode is not "activation does not
> work" — it is "activation works and propagates corruption". That asymmetry is
> the whole reason this list exists.

---

## 2. DEPLOYMENT SEQUENCE (staging first, always)

Each step states its own rollback. Do not proceed to the next step until the
current one is verified.

### Step 1 — apply migrations to **staging**
```
0087_parser_validation_evidence.sql      # C-1: validation must be earned
0088_explicit_owner_table_grants.sql     # DF-002: declared privileges
0089_force_update_arming_authority.sql   # C-2a-2: audited arming
0068_entity_revision_cas.sql             # CAS support
0077_planning_currency.sql               # per-row planning currency
```
**Rollback:** each ships its own inverse; 0087 and 0089 preserve pre-images.
**Verify:** `supabase db reset` from migrations alone must produce a working
environment (this is the DF-002 acceptance test, and it has never passed).

### Step 2 — deploy Edge Functions to **staging**
`catalog-delta` (evidence-based parser gate, C-1) and `_shared/feature_flags`
(fail-closed rollout, C-10) are behaviour changes; the rest are listed in
`docs/FINAL_RELEASE_READINESS.md` §3.
**Rollback:** redeploy the previous revision.

### Step 3 — deploy the admin panel to **staging**
Required **after** 0089, never before: the announcements route now calls
`arm_force_update()` and returns **503** if the RPC is absent. That ordering is
deliberate — refusing to arm is recoverable; arming without an audit trail is not.

### Step 4 — prove the transport against **staging**
This is the step that produces the authority the gates are waiting for. Adapt
`demo-docker/tools/verify_local_exact_transport.sh` and `verify_local_exact_push.sh`
to point at staging. They must prove, byte-exact:

- `NUMERIC::text` projection round-trips every money column with no `double`;
- a decimal-string push stores the exact value (including scale-3 currencies —
  KWD/BHD/OMR, where a 0.01 tolerance is **10 minor units**);
- values at and beyond 2⁵³ minor units survive;
- `moneyFromPulledValue` rejects a non-`::text` payload rather than degrading.

**Do not skip the scale-3 cases.** Two-decimal currencies hide the entire class
of rounding defects this transport exists to prevent.

### Step 5 — flip the capabilities
Only after step 4 passes against the *same* backend the app will talk to.
Replace the hardcoded `unknown` verdicts with a **positively verified** source.
Do not hand-edit to `verifiedExact` as a shortcut: the value must be traceable to
a verification artifact, or the next reader cannot tell proof from wishful
thinking — which is exactly how "40/40 verified" ended up describing a demo build.

### Step 6 — un-park and drain, observed
Parked outbox items resume. Watch for: duplicate delivery, money mismatches,
conflict storms (the P3 signature), and `category_id` values that are not stable
keys (the P2 signature).

### Step 7 — production
Repeat 1–6 with a fresh authorisation, out of hours, with the rollback for each
step at hand.

---

## 3. ROLLBACK POSTURE

| Layer | Reversible? | How |
|---|---|---|
| Capability flags | **yes, instantly** | set back to `unknown`; money-bearing transport re-parks. This is the primary kill switch. |
| Edge Functions | yes | redeploy previous revision |
| 0087 / 0089 | yes | shipped inverse; pre-images preserved |
| 0088 | yes on a fresh env; **do not revert on hosted** — it would remove privileges the platform granted |
| 0068 / 0077 | additive | leaving them applied is harmless with capabilities off |
| **Data already pushed** | **NO** | rows delivered to the server are not recalled by turning a flag off |

**The asymmetry is the point.** Activation is instantly reversible; the *data it
moves* is not. That is why §1 is a hard gate and not a checklist.

---

## 4. WHAT "DONE" MEANS

Activation is complete when, on production:

1. every money column round-trips byte-exact, scale-3 included;
2. both outboxes drain to empty with zero conflicts and zero duplicates;
3. a second device converges to identical values;
4. consent OFF still produces **zero** financial egress (P1's acceptance test);
5. the capability values are traceable to a dated verification artifact.

Until then the honest status is **"cloud sync is dark, deliberately"** — which is
a defensible product state, and a far better one than "we think it works".
