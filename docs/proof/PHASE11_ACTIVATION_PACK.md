# Phase-11 readiness / external activation pack

**Implementation state: FROZEN.** Phases 6–10 are implementation-complete.
No further feature engineering. Auto-commit is NOT enabled and Phase 11 is
NOT unlocked.

**Nothing has been deployed, pushed, or committed.** 54 files sit in the
working tree. `HEAD` is unchanged at `21a5ab40`.

Verified state at freeze:

| | |
|---|---|
| `flutter analyze` | clean, 0 issues |
| `flutter test` | 3265 passed, 2 failed |
| the 2 failures | `.DS_Store` in the vendored `file_picker` fork; `android/key.properties` present locally. Both pre-existing, environmental, unrelated to this work. |
| Drift schema | `_targetSchemaVersion = 32` |
| shadow arm | `enabled = false`, `sampleRate = 0.0` |
| auto-commit | disabled; `kReviewOnlyFamilies` still gates |

> **Working-tree scope.** The tree also contains changes from concurrent
> sessions — `lib/features/dashboard/*`, `lib/domain/finance/goal_pacing.dart`
> and their tests. Those are NOT part of this work and are not described here.
> Do not assume this pack covers them; stage by exact path.

---

## 1. Dedicated Gemini shadow credential / project

The invariant that forces this:

> the shadow call must **never** consume the last unit of capacity the
> production path needs.

Authority isolation is proven in code. Capacity isolation cannot be — two calls
against one quota compete however the code is written.

**Preference order:**

1. **A separate GCP project** with its own Gemini quota. Preferred: shadow
   exhaustion cannot touch production headroom at all.
2. **A separate API key in the same project** plus an explicit per-key rate
   budget provably below production headroom. Weaker — the project ceiling is
   still shared.
3. **No dedicated capacity → the arm stays OFF.** This is today's state.

**Forbidden, and why:**

| credential | reason |
|---|---|
| production `GEMINI_API_KEY` | shadow traffic draws directly on production capacity — violates the invariant |
| the research/benchmark key (`b73a8f361e69`) | scoped to frozen-corpus measurement, not rate-managed for live traffic. Reusing it couples benchmark reproducibility to production load. |

**Sizing:** a shadowed message costs **2** Gemini calls; a non-shadowed one
costs 1. Provision for **peak**, not mean — the failure being avoided is
exhausting headroom during a spike.

---

## 2. Supabase secrets

| secret | required | behaviour |
|---|---|---|
| `GEMINI_SHADOW_API_KEY` | before enabling shadow | dedicated credential. **If absent, the server must REFUSE `contract:"proof-v1"` and serve the normal v1 path. It must never fall back to `GEMINI_API_KEY`.** |
| `PROOF_SHADOW_MAX_RPM` | before enabling shadow | hard server ceiling; refuses beyond it rather than queueing |
| `GEMINI_SHADOW_MODEL` | optional | defaults to the frozen `gemini-2.5-flash-lite` |

The no-fallback rule matters most exactly when someone is misconfiguring under
pressure — that is when a silent fallback would do its damage.

Existing secrets (`GEMINI_API_KEY`, `SUPABASE_*`, `SENTRY_DSN`) are unchanged.

---

## 3. Deployment order

Each step is independently reversible. Steps 1–3 send **zero** shadow traffic.

1. **Deploy `parse-sms`** with `GEMINI_SHADOW_API_KEY` absent. Proves the deploy
   is inert before any capacity question arises.
2. **Ship the client** with `proof_shadow_enabled=false`. Dead code in the field.
3. **Provision** shadow capacity (§1); set the secrets (§2).
4. **Enable at 1%**, one region, 24 h watch.
5. **5%** only if every Call-1 metric in §8 is within threshold.
6. **Hold at 5%** for the measurement window. Do not raise for coverage — the
   sample characterises, it does not maximise.

---

## 4. What must be deployed

**Edge functions — 1 modified, 1 new shared module:**

| path | change |
|---|---|
| `supabase/functions/parse-sms/index.ts` | IBAN + cue-anchored OTP redaction in `reSanitize`; evidence-span validation wired in |
| `supabase/functions/_shared/evidence_spans.ts` | **new** — server-side span validator |
| `supabase/functions/_shared/evidence_spans_test.ts` | **new** — 10 tests (not deployed; run in CI) |

```bash
cd supabase && supabase functions deploy parse-sms
```

**Database migrations: NONE.**
The schema change is **client-side Drift v31 → v33** — two additive steps, v32
(Phase 8, `capture_work_items`) and v33 (Phase 9A, `capture_review_labels`) —
applied by the app on first launch of the new build. No Supabase migration is
required, and `supabase db push` is **not** part of this activation.

**Client:** both steps ship inside the app binary and run automatically via the
versioned registry (`31 → 32 → 33`, one additive table each). A device upgrading
from v31 runs BOTH in a single pass.

---

## 5. Phase-7 flags — defaults and activation

| flag | default | meaning |
|---|---|---|
| `proof_shadow_enabled` | **`false`** | master switch |
| `proof_shadow_sample_rate` | **`0.0`** | so an accidental enable still shadows nothing |
| `proof_shadow_timeout_ms` | `6000` | independent, shorter than the 12 s production call |
| `proof_shadow_breaker_threshold` | `3` | consecutive failures before self-disable |

Both defaults are asserted in `proof_shadow_isolation_test.dart` — changing
either fails a test rather than shipping quietly.

**Activation:** admin panel → `/flags` → set `proof_shadow_enabled = true`,
then `proof_shadow_sample_rate = 0.01`.

---

## 6. Initial safe sample rate

**Start at 0.01 (1%).** Raise to **0.05 (5%)** only after 24 h with every §8
metric within threshold. **Never above 0.05** without a new decision — 5% is
sufficient for distribution and latency characterisation, and the marginal
sample buys less than the marginal risk to production headroom.

---

## 7. Cohort / control telemetry

**Assignment:** stable hash of install id → `shadow` | `control`. Stable, so a
device does not oscillate mid-window and smear the comparison.

**Control is NOT "everyone else"** — it is an equally-sized, equally-sampled
arm that is *eligible* but not shadowed. Comparing against all remaining
traffic would confound the shadow effect with whatever makes a device eligible.

```sql
-- Call-1 health by cohort (the PASS/FAIL comparison)
SELECT cohort,
       COUNT(*)                                             AS calls,
       AVG(CASE WHEN call1_success THEN 1.0 ELSE 0.0 END)   AS success_rate,
       AVG(CASE WHEN call1_timeout THEN 1.0 ELSE 0.0 END)   AS timeout_rate,
       AVG(CASE WHEN call1_http_status = 429 THEN 1.0 ELSE 0.0 END) AS rate_limited,
       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY call1_latency_ms) AS p50_ms,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY call1_latency_ms) AS p95_ms
FROM capture_telemetry
WHERE observed_at >= now() - interval '7 days'
GROUP BY cohort;

-- Shadow behaviour (characterisation only, never pass/fail)
SELECT proof_shadow_outcome, COUNT(*),
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY proof_shadow_latency_ms) AS p95_ms
FROM capture_telemetry
WHERE cohort = 'shadow' AND observed_at >= now() - interval '7 days'
GROUP BY proof_shadow_outcome;

-- Circuit-breaker activations — must be EXPLAINED, not merely counted
SELECT date_trunc('hour', observed_at) AS hour, COUNT(*)
FROM capture_telemetry
WHERE proof_shadow_breaker_open GROUP BY 1 ORDER BY 1 DESC;

-- Verdict distribution (characterisation)
SELECT proof_verdict, proof_review_reason, COUNT(*)
FROM capture_telemetry
WHERE cohort = 'shadow' GROUP BY 1, 2 ORDER BY 3 DESC;
```

All fields are counters, durations and enums. **No SMS text, no amount, no
merchant** — privacy-safe by construction, verifiable from the types.

---

## 8. Phase-7 live PASS / FAIL criteria

Shadow arm vs control arm, ≥ 7 days, ≥ 1%:

| metric | PASS condition |
|---|---|
| Call-1 success rate | shadow ≥ control − **0.5 pp** |
| Call-1 timeout rate | shadow ≤ control + **0.5 pp** |
| Call-1 429 rate | shadow ≤ control + **0.2 pp** |
| Call-1 p50 latency | shadow ≤ control × **1.05** |
| Call-1 p95 latency | shadow ≤ control × **1.10** |
| availability | no measurable difference |
| production incidents attributed to shadow | **0** |
| breaker activations | understood and explained |

**Window:** ≥ 7 days, covering a full weekly cycle including salary-day peaks.

**Recorded but NOT pass/fail:** shadow cost per 1k captures, shadow failure
rate, payload size distribution, verdict distribution, agreement with the
current decision.

> **Limitation, stated plainly:** silent shadow **cannot** establish
> auto-commit precision. Without labels, disagreement is not ground truth, and
> confirmed transactions frequently receive no user action — the sample is
> selection-biased. Shadow proves feasibility, latency, protocol stability and
> distribution. **Nothing more.**

---

## 9. Kill switch

| method | effect | depends on clients? |
|---|---|---|
| `proof_shadow_enabled = false` | stops on next flag fetch | yes |
| `supabase secrets unset GEMINI_SHADOW_API_KEY` | proof-v1 refused immediately, all clients | **no** |
| client circuit breaker | self-disables after 3 consecutive failures | automatic |

**Use the secret removal when it matters.** It is the only one that does not
wait for clients to behave.

Call 1 is unaffected by all three — it was never modified.

---

## 10. Schema v33 rollback / forward hotfix

**A v31 or v32 binary cannot open a v33 database.** `user_version = 33` exceeds what it
knows, and initialization fails closed with
`UnsupportedDatabaseVersionException`.

**Therefore binary downgrade is NOT a rollback path.** Shipping v31 or v32 to a
device that already ran v33 leaves that user unable to open the app.

| situation | action |
|---|---|
| defect in Phase 8/9/10 logic | **flags / kill switch** — disable the feature; the table stays, unused |
| defect in the migration | **forward hotfix** — new build with a corrected forward migration |
| schema itself is wrong | **forward migration** v33 → v34 |
| any case | **never** ship an older binary to an upgraded device |

Each step is additive — one table plus indexes, inside the existing
migration transaction, `user_version` bumped last. A failure rolls the whole
upgrade back atomically and the app continues on its previous version.

---

## 11. Physical-device QA

**None of this is verifiable in the simulator, and none of it may be claimed
without a real device.**

| area | what to verify |
|---|---|
| SMS capture (Android) | real bank SMS arrives, is captured, and produces a work item |
| iOS capture | App Intent / Shortcuts path and APNs preview |
| notification identity | pending → resolved **replaces** the row, does not stack |
| **lock-screen privacy** | body shows **no amount, no merchant, no bank**; verified on a genuinely locked device |
| notification actions | tap routes through the domain layer; a stale tap does not overwrite a newer edit |
| v31 → v33 migration on real data | upgrade a device holding a **real v31 database**, not a fresh one — both steps must run |
| crash/ACK boundary | force-kill between Drift commit and native ACK; confirm no duplicate work item |
| offline | capture with no network → `offlinePending`, recovers on reconnect |
| battery/wakelock | shadow arm off vs on at 1% |

> **No physical-device QA has been performed. None of the above may be marked
> done from an engineering session, and no result here may be fabricated.**

---

## 12. Signed build

**Blocked on an external account.** `app/CLAUDE.md`: *"Real-device build
requires a paid Apple Developer account (App Groups). Not available yet."*

| requirement | state |
|---|---|
| Apple Developer Program membership | **NOT AVAILABLE** — blocks iOS device QA |
| App Groups entitlement | needs the paid account |
| iOS signed release (`ios-signed-release` in `codemagic.yaml`) | blocked |
| iOS unsigned sideload (`ios-unsigned-sideload`) | available — partial QA only |
| Android release signing | `android/key.properties` exists locally; keystore must come from CI secrets, never the repo |

**Android device QA is possible now. iOS device QA is not**, until the Apple
account exists. That gates §11 for iOS specifically.

---

## 13. Every remaining action requiring Youssef

| # | action | blocks |
|---|---|---|
| E1 | Provision dedicated shadow Gemini project/credential | Phase-7 live |
| E2 | Decide `PROOF_SHADOW_MAX_RPM` against real production headroom | Phase-7 live |
| E3 | Set Supabase secrets (§2) | Phase-7 live |
| E4 | Review + commit 54 working-tree files (staging **by exact path** — other sessions' work is present) | everything |
| E5 | Deploy `parse-sms` | Phase-7 live |
| E6 | Ship a client build with flags default-off | Phase-7 live |
| E7 | Android physical-device QA (§11) | Phase 11 |
| E8 | Obtain Apple Developer membership | iOS QA |
| E9 | iOS physical-device QA | Phase 11 |
| E10 | Create telemetry dashboard from §7 | Phase-7 measurement |
| E11 | Enable shadow at 1%, then 5% | Phase-7 measurement |
| E12 | Run the ≥7-day cohort/control window | Phase 11 |
| E13 | Adjudicate §8 PASS/FAIL | Phase 11 |
| E14 | Rotate the exposed credentials — 2 Cloudflare tokens and the Gemini research key were pasted in chat | security hygiene, independent of Phase 11 |
| E15 | `rm third_party/file_picker/.DS_Store` to clear the vendored-fork guard | CI cleanliness |

---

## 14. Order of execution

```
E14  rotate exposed credentials        ← do first; independent of everything
E4   review + commit (exact paths)
E15  clear the .DS_Store guard
        │
E1 ─► E2 ─► E3   provision shadow capacity + secrets
        │
E5   deploy parse-sms (inert — no shadow key yet, verify v1 unchanged)
E6   ship client (flags off)
        │
E7   Android device QA          ┐
E8 ─► E9  Apple account → iOS QA ┘  can run in parallel with E10
E10  telemetry dashboard
        │
E11  enable 1% → 24 h watch → 5%
E12  ≥ 7-day cohort/control window
E13  adjudicate §8
        │
        └─► Phase-11 decision (§15)
```

**E14 first**: three credentials were exposed in conversation and should not
survive into a production activation.

**E5 before E6**: deploying the inert server first proves the additive mode
changes nothing before any client can exercise it.

---

## 15. The exact condition that unlocks Phase 11

Phase 11 (narrow auto-commit) unlocks when **all** of the following hold. Any
single failure keeps it blocked.

**A — Phase-7 live measurement PASS**
1. dedicated shadow capacity provisioned (§1 option 1 or 2)
2. ≥ 7 days at ≥ 1% with a stable cohort/control split
3. every Call-1 metric in §8 within threshold
4. zero production incidents attributed to the shadow arm
5. breaker activations explained, not merely counted
6. shadow cost per 1k captures measured and accepted

**B — Phases 8/9/10 verified on real devices**
7. Android physical-device QA passed (§11)
8. iOS physical-device QA passed (§11) — requires E8
9. v31 → v33 migration verified on a device holding a **real v31 database**
10. crash/ACK boundary verified by force-kill on a real device
11. lock-screen privacy verified on a genuinely locked device

**C — external production evidence**
12. signed build produced and installed through the real distribution path
13. telemetry confirmed flowing with the §7 fields populated
14. kill switch exercised **in production** and observed to work

**D — precision evidence that shadow cannot provide**
15. Phase-9 review instrumentation has collected **real user labels** —
    accept/correct rates, with direction corrections specifically — in
    sufficient volume to estimate auto-commit precision.

> **Point 15 is the one most likely to be skipped, and the most important.**
> Silent shadow establishes feasibility, not precision. Enabling auto-commit on
> shadow evidence alone would mean committing real money movements on the
> strength of a measurement that was never capable of showing they were right.
> The labels must be genuine user actions. **No fabricated or inferred labels.**

**Until all fifteen hold: auto-commit stays disabled, `kReviewOnlyFamilies`
keeps gating, and `proof_shadow_enabled` stays `false`.**
