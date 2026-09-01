# Phase 7 — shadow arm: provisioning and deployment contract

**Status: ENGINEERING COMPLETE / EXTERNAL LIVE-MEASUREMENT GATE.**
Not PASS. Nothing in this document has been provisioned or deployed, and
nothing here may be executed from an engineering session.

The architecture half is done and proven (16/16 isolation tests). What remains
is a live cohort/control measurement that needs production traffic and
dedicated shadow capacity, neither of which exists yet.

---

## 1. Dedicated shadow credential — the hard requirement

The plan's invariant is the reason this section exists:

> the shadow call must **never** consume the last unit of capacity the
> production path needs.

Authority isolation is already proven. Capacity isolation is not, and cannot be
proven by code: two calls against one quota compete no matter how the code is
written. So the shadow arm needs its own capacity, in this order of preference:

1. **A separate GCP project with its own Gemini quota.** Preferred. Failure of
   the shadow project cannot consume production headroom in any way.
2. **A separate API credential inside the same project, with an explicit
   per-key rate budget** provably below production headroom. Weaker: the
   project-level ceiling is still shared.
3. **No dedicated capacity.** Then the arm stays OFF. This is the current state.

### Explicitly forbidden

| credential | why |
|---|---|
| the **production** `GEMINI_API_KEY` | shadow traffic would draw directly on the capacity production needs — the invariant above |
| the **research/benchmark** key | it is a research credential scoped to frozen-corpus measurement. It is not rate-managed for production traffic, and reusing it would silently couple benchmark reproducibility to live load |

### Sizing input

At a 5% sample of shadowed messages the shadow arm issues **one additional
Gemini call per shadowed message** — Gemini calls per shadowed message: 2, per
non-shadowed message: 1 (unchanged). The shadow budget must be provisioned for
peak, not mean, because the failure mode being avoided is exhausting headroom
during a spike.

---

## 2. Secret and configuration contract

### Server (Supabase Edge Function secrets)

| name | required | purpose |
|---|---|---|
| `GEMINI_SHADOW_API_KEY` | yes, before enabling | dedicated shadow credential. **Absent → the server must refuse `contract:"proof-v1"` and return the normal v1 path.** Never falls back to `GEMINI_API_KEY`. |
| `GEMINI_SHADOW_MODEL` | no | defaults to the frozen `gemini-2.5-flash-lite` |
| `PROOF_SHADOW_MAX_RPM` | yes, before enabling | hard server-side ceiling; the shadow path refuses beyond it rather than queueing |

> The no-fallback rule is the important one. A shadow path that silently uses
> the production key when its own is missing would defeat the entire purpose of
> the separation, and it would do so exactly when someone is misconfiguring
> under pressure.

### Client (remote feature flags)

| flag | default | meaning |
|---|---|---|
| `proof_shadow_enabled` | **`false`** | master switch. Off until dedicated quota exists. |
| `proof_shadow_sample_rate` | **`0.0`** | fraction of captures shadowed. Zero, so an accidental enable still shadows nothing. |
| `proof_shadow_timeout_ms` | `6000` | independent, strictly shorter than the production call's 12 s |
| `proof_shadow_breaker_threshold` | `3` | consecutive failures before self-disable |

Both defaults are asserted in `proof_shadow_isolation_test.dart`, so a change
to either fails a test rather than shipping quietly.

---

## 3. Rollout order

Each step is separately reversible, and none of steps 1–3 sends any shadow
traffic.

1. **Deploy the server** with the additive `contract:"proof-v1"` mode while
   `GEMINI_SHADOW_API_KEY` is absent. A v1 request is byte-identical to today;
   a proof-v1 request is refused for want of a credential. This proves the
   deploy is inert before any capacity question arises.
2. **Ship the client** with `proof_shadow_enabled=false`. Dead code in the
   field, exercised by nothing.
3. **Provision** the shadow project/credential and set `PROOF_SHADOW_MAX_RPM`.
4. **Enable at 1%** in a single region. Watch Call-1 health for 24 h.
5. **5%** if — and only if — every Call-1 metric in §7 is within threshold.
6. Hold at 5% for the measurement window. **Do not raise for coverage; the
   sample exists to characterise, not to maximise.**

---

## 4. Kill switch

**Primary:** set `proof_shadow_enabled=false` remotely. Takes effect on the
next flag fetch, needs no deploy and no app update.

**Server-side:** remove `GEMINI_SHADOW_API_KEY`. The proof-v1 path then refuses
immediately, for every client, regardless of flag propagation delay. This is
the one that does not depend on clients behaving.

**Automatic:** the client circuit breaker opens after 3 consecutive failures
and stops issuing requests without any human action.

---

## 5. Rollback / disable

Ordered by blast radius, smallest first:

| situation | action | effect on Call 1 |
|---|---|---|
| shadow noisy or costly | flag → `false` | none — Call 1 was never modified |
| shadow implicated in production degradation | remove `GEMINI_SHADOW_API_KEY` | none |
| server deploy suspect | redeploy previous `parse-sms` | none — v1 handling is byte-identical either way |

There is **no database rollback to consider**: Phase 7 adds no schema and no
migration. Disabling is complete and instantaneous, which is the property that
makes shadow safe to try at all.

---

## 6. Telemetry fields

Privacy-safe by construction: counters and durations only, never SMS text,
never an amount, never a merchant.

| field | type | note |
|---|---|---|
| `proof_shadow_outcome` | enum | `skipped` / `breakerOpen` / `completed` / `timedOut` / `failed` |
| `proof_shadow_latency_ms` | int | Call-2 only |
| `proof_shadow_breaker_open` | bool | breaker activations |
| `proof_verdict` | enum | `proven` / `review` / `notTransaction` — **characterisation only** |
| `proof_review_reason` | enum | the `ProofReason` name; no free text |
| `proof_payload_bytes` | int | envelope size distribution |
| `call1_success` / `call1_timeout` / `call1_http_status` | — | production health, **already collected**; the cohort split is the new part |
| `call1_latency_ms` | int | p50/p95 by cohort |
| `cohort` | enum | `shadow` / `control` |

---

## 7. Cohort / control measurement plan

**Assignment.** Stable hash of install id → `shadow` or `control`. Stable so a
device does not oscillate between arms mid-window, which would smear the
comparison.

**Control is not "everyone else".** It is an equally-sized, equally-sampled arm
that is *eligible* for shadowing but not shadowed. Comparing shadowed devices
against all remaining traffic would confound the shadow effect with whatever
makes a device eligible.

**Window.** Minimum 7 days, to cover a full weekly traffic cycle including
salary-day peaks.

**Primary comparison** — Call-1 health, shadow arm vs control arm:

| metric | comparison |
|---|---|
| success rate | shadow ≥ control − 0.5 pp |
| timeout rate | shadow ≤ control + 0.5 pp |
| 429 / rate-limit rate | shadow ≤ control + 0.2 pp |
| p50 latency | shadow ≤ control × 1.05 |
| p95 latency | shadow ≤ control × 1.10 |
| availability | no measurable difference |

**Also recorded, explicitly NOT pass/fail:** shadow cost per 1k captures,
shadow failure rate, breaker activations, payload size distribution, verdict
distribution, agreement with the current decision.

### The limitation, stated plainly

Silent shadow **cannot** establish auto-commit precision. Without labels,
disagreement is not ground truth, and confirmed transactions frequently receive
no user action, so the sample is selection-biased. Shadow proves feasibility,
latency, protocol stability and distribution. **Nothing more.** Precision
evidence is Phase 9's job.

---

## 8. Live PASS criteria

Phase 7 may be marked **PASS** only when all of the following hold on real
production traffic:

1. dedicated shadow capacity provisioned — §1 option 1 or 2;
2. ≥ 7 days at ≥ 1% with a stable cohort/control split;
3. every Call-1 metric in §7 within threshold;
4. zero production incidents attributed to the shadow arm;
5. circuit-breaker activations understood and explained, not merely counted;
6. shadow cost per 1k captures measured and accepted;
7. the architecture half still green (16/16 isolation tests) on the deployed
   build.

Until then Phase 7 remains **ENGINEERING COMPLETE / EXTERNAL
LIVE-MEASUREMENT GATE**, and Phase 11 stays blocked.

---

## 9. Commands — for the operator, not for this session

Recorded so the deploy is reproducible. **Not executed here.**

```bash
# 1. server, inert (no shadow credential set)
cd supabase && supabase functions deploy parse-sms

# 2. provision shadow capacity, then:
supabase secrets set GEMINI_SHADOW_API_KEY=<dedicated-shadow-key>
supabase secrets set PROOF_SHADOW_MAX_RPM=<budget-below-production-headroom>

# 3. enable gradually (admin panel → /flags)
#    proof_shadow_enabled = true
#    proof_shadow_sample_rate = 0.01   → 0.05 only after 24h clean

# KILL SWITCH — either is sufficient, the second does not need clients
#    proof_shadow_enabled = false
supabase secrets unset GEMINI_SHADOW_API_KEY
```
