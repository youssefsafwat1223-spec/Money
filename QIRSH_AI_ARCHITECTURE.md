# QIRSH — AI/ML ARCHITECTURE & EVALUATION WORKSTREAM (W-001)

**Status: DESIGN — implementation gated on the evidence gates in §12.**
Created 2026-08-28 under **OD-11**. Companion to `QIRSH_MASTER_PLAN_V2.md`.

> **OD-11 standing decision.** AI/ML **is** an intended strategic part of the final Qirsh product.
> This document exists so that direction cannot quietly disappear from the roadmap. It also exists
> so that AI is adopted on *evidence* rather than fashion — those are not in tension.
>
> "No additional model in the current remediation cycle" is a **sequencing** conclusion, not a
> rejection. §12 states exactly what unlocks the next step.

---

## 1. WHAT ALREADY EXISTS (this is not a greenfield design)

Qirsh already ships a **cloud AI cascade**. Any proposal must start from it, not around it.

| Component | Location | What it does |
|---|---|---|
| `parse-sms` | `supabase/functions/parse-sms/` | Gemini parse of a sanitised SMS |
| `bank-discovery` | `supabase/functions/bank-discovery/` | proposes an unknown sender's bank |
| `enrich-merchant` | `supabase/functions/enrich-merchant/` | merchant → category via Google Places |
| client cascade | `app/lib/domain/usecases/add_transaction_usecase.dart` | `_tryAiParseFirst` (:365) → deterministic parse (:374) → `_applyAiResponse` (:399) |
| grounding | `app/lib/engine/ai/grounding_check.dart` | AI amount must appear as a literal substring of the SMS |
| failure tracking | `app/lib/engine/ai/ai_sender_failure_tracker.dart` | 3 failures suppress a sender for the session |

### 1.1 The single most important architectural fact

**The AI cascade and the deterministic catalog authority run on DISJOINT paths.**

| Path | senderId | catalog rules | AI |
|---|---|---|---|
| Automatic SMS capture (the high-volume path) | present | **loaded** | **OFF** — `app_shell.dart:934` passes `onDeviceOnly: true` |
| Manual paste | **absent** | **none** — `rules_client.dart:126` returns `[]` for an empty sender | **ON** |

Consequences that shape everything below:

1. **Deterministic-first is already true where it matters.** On the automatic path AI never runs, so
   the OD-11 invariant ("AI must never overwrite trustworthy deterministic exact-money evidence") is
   currently satisfied there *structurally*, not by policy.
2. **The AI ordering defect is confined to manual paste** — a human-supervised, low-volume surface.
   That bounds the risk, and it also bounds the *benefit* the current cascade delivers.
3. **The server capture path implements the opposite, correct order** —
   `supabase/functions/process-ios-sms/index.ts:454-456` is deterministic-amount-first. Two
   arbitration policies ship in one product. Unifying them is a prerequisite, not a nice-to-have.

---

## 2. THE CORPUS — why this is the real gate

Measured in this repository:

| Asset | Count |
|---|---|
| Seeded catalog parser rules | **12** |
| Seeded banks | **124** |
| Hardcoded `BankProfile`s | 29 |
| Golden SMS fixtures (`bank_sms_golden_fixtures.dart`) | **33** |
| Parser-Lab parity fixtures | 4 |
| **Total labelled messages available for evaluation** | **~37** |

**~37 labelled messages cannot evaluate a model.** It cannot establish a baseline, cannot measure a
regression, cannot calibrate a confidence threshold, and cannot distinguish a model that generalises
from one that memorised. Any accuracy number produced against this corpus would be noise presented
as evidence.

Worse, the labels are **contaminated**: F-015 means merchant labels embed trailing date clauses
(golden: `"STARBUCKS COFFEE بتاريخ 16/06/2026"`), and that bug is baked into all 12 catalog rules'
`(?<merchant>[^\n]+)` capture. Training or evaluating merchant normalisation on this corpus would
teach the model the bug.

**This — not model availability — is why AI integration is not the next step.**

---

## 3. USE-CASE MATRIX (OD-11 §1–4)

| Task | Deterministic owns | AI may propose | AI may NEVER override |
|---|---|---|---|
| **Amount** | ✅ always, when a rule or profile extracts it | only when NO deterministic extraction exists | ✅ **never** overrides an extracted amount |
| **Currency** | ✅ always | only when absent | ✅ **never** |
| **Direction (debit/credit)** | ✅ when the rule/profile declares it | when ambiguous | ✅ never against an explicit rule |
| **Date/time** | ✅ when deterministically parsed | when absent or ambiguous | ✅ never a parsed date |
| **Account / card identifier** | ✅ always (last4, account number) | never | ✅ **never** |
| **Merchant (raw extraction)** | ✅ when captured | when absent | may *normalise* (see below) |
| **Merchant normalisation** | — | ✅ primary AI candidate | must not change the raw stored value |
| **Category** | keyword map is a floor | ✅ primary AI candidate | may not override a user's explicit choice |
| **Is-this-a-transaction** | ✅ ignore-list + rules | ✅ on unknown senders | never re-classifies an exact rule match |
| **Unknown-bank understanding** | — | ✅ primary AI candidate | output is a *suggestion*, pending review |
| **Confidence scoring** | ladder in `parser_engine.dart` | may contribute a signal | may not lift a parse to auto-confirm alone |
| **Anomaly / insight** | — | ✅ safe (advisory, non-financial-authority) | never mutates a transaction |

**The invariant, stated once:** *AI output may fill a gap. It may not contradict a deterministic
extraction of an exact financial fact.* Everything in §4 exists to enforce that mechanically rather
than by convention.

---

## 4. TARGET ARCHITECTURE — HYBRID-READY

```
                    ┌──────────────────────────────────────────┐
   raw message ───► │ 1. DETERMINISTIC AUTHORITY               │
                    │    catalog rule (validated) → profile    │
                    │    → heuristic ladder                    │
                    └───────────────┬──────────────────────────┘
                                    │ produces a FieldSet with per-field provenance
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ 2. GAP ANALYSIS                          │
                    │    which fields are missing / low-conf?  │
                    └───────────────┬──────────────────────────┘
                          gaps only  │  (no gaps → done, AI never invoked)
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ 3. INFERENCE PROVIDER (pluggable)        │
                    │    on-device model | backend | none      │
                    │    consent-gated, budgeted, cancellable  │
                    └───────────────┬──────────────────────────┘
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ 4. ARBITRATION + CONTAINMENT             │
                    │    merge ONLY into gaps; re-verify money │
                    │    against source text; clamp confidence │
                    └──────────────────────────────────────────┘
```

**Key design commitments**

- **Per-field provenance.** Every field carries where it came from (`catalogRule` / `bankProfile` /
  `heuristic` / `ai` / `user`). Arbitration is then a *rule about provenance*, not an ordering
  accident. This is the structural fix for today's "AI ran first so AI wins".
- **Gap-filling, not replacement.** Step 4 merges AI output only into fields step 1 left empty.
  A deterministic amount is unreachable by construction — it is never a candidate for overwrite.
- **Provider abstraction** (`InferenceProvider`): `none` (default), `backend`, `onDevice`. Swapping
  the provider must not change arbitration. This is what makes the design hybrid-ready without
  committing to a model today.
- **Deterministic-first ordering everywhere**, matching `process-ios-sms`. Removes the current
  two-policies-in-one-product split, and removes the ~25 s worst-case AI latency that currently
  precedes parsing on manual paste (`ai_parser_client.dart:110-158`).

---

## 5. EXACT-MONEY CONTAINMENT (OD-11, non-negotiable)

Current defects this must fix, all verified in source:

| Defect | Evidence | Required fix |
|---|---|---|
| AI amount crosses a `double` | `ai_parser_client.dart:41` `(json['amount'] as num).toDouble()` | carry `amount_text` as a **string** end-to-end; parse into `Money` minor units; never a `double` |
| Currency is never grounded | `add_transaction_usecase.dart:1137` adopts `aiResponse.currency` unconditionally | currency must appear in the source text, or be inherited from the deterministic parse — never invented |
| Tolerance is currency-blind | `_amountsClose` `< 0.01` (:1573) | compare in **minor units** — 0.01 is **10 minor units** for KWD/BHD/OMR |
| Grounding fails on grouped amounts | `grounding_check.dart:8-18` has no thousands separator | canonicalise both sides before comparison |
| Hallucinated currency can auto-create an account | `_accountForCurrency` (:222-235) invoked at :674 | account creation must never be driven by an ungrounded AI field |

**Rule:** an AI-sourced money field may only be *accepted*, never *reconciled*. If it disagrees with
the deterministic value, the deterministic value wins and the disagreement is logged as an eval
signal.

---

## 6. PRIVACY MODEL (OD-05, OD-07, OD-10)

- **Consent is the egress boundary**, enforced at the network layer by the Phase-D
  `ConsentAuthority` — not by a UI toggle and not by each service remembering to check.
- **Known holes that must close before any backend AI expansion:** `enrich-merchant` is not
  AI-consent gated (`app_providers.dart:1131-1160`; the server checks only *cloud* consent), and the
  in-app parse path reads `aiConsentGranted` alone while the sync payload and iOS bridge correctly
  enforce cloud-OFF ⇒ AI-OFF.
- **On-device inference is the privacy-preferred option** precisely because it moves the boundary:
  no message content leaves the device, so the consent question narrows to model download and
  telemetry.
- **Prompt-injection boundary (if an LLM is used):** bank SMS is **untrusted input**. It must never
  be concatenated into an instruction context that can alter tool use or output schema. Enforce a
  strict output schema, reject anything that does not validate, and never let message content
  influence *which* operation runs.

---

## 7. ON-DEVICE vs BACKEND — honest comparison for THIS product

| | On-device | Backend (current) | No model (today) |
|---|---|---|---|
| Privacy | **best** — nothing leaves | needs consent; content egresses | best |
| Offline | **works** (the app is local-first; capture happens offline) | fails | works |
| Latency | ~10–100 ms | up to **25 s** worst case today | 0 |
| Cost | zero marginal | per-call, rate-limited (500/day) | zero |
| Binary size | **+10–50 MB** — significant for an Arabic-first market with mid-range devices | 0 | 0 |
| Arabic quality | small models are weak on Arabic dialects + Arabic-Indic digits | strong | n/a |
| Updatability | ships with the app | instant | n/a |

**Reading:** on-device wins on privacy/offline/latency/cost — exactly Qirsh's stated values — and
loses on Arabic quality and binary size. That trade is *empirical*, and cannot be settled with 37
labelled messages. Hence §12.

---

## 8. RECOMMENDATION

**For the current remediation cycle: NO ADDITIONAL MODEL. Build the boundary and the corpus.**

Not because AI is unproven in general, but because in *this* codebase:

1. The dominant capture gap is **content, not intelligence** — 12 parser rules against 124 banks,
   and zero credit/income rules. Authoring rules through the now-real F-016 authority is cheaper,
   deterministic, auditable, and fixes the same user-visible problem a model would be asked to paper
   over.
2. A cloud cascade **already exists** and already covers fallback, merchant enrichment and
   categorisation. Its problems are **arbitration, grounding and consent** — every one of which an
   on-device model would *inherit*, not fix.
3. The evaluation corpus (~37, contaminated) cannot support a ship/no-ship decision.

**What to build now (all of it useful regardless of which model wins later):**

- **W-001-A** per-field provenance + gap-filling arbitration (§4) — also fixes the manual-paste
  ordering defect and unifies client/server policy.
- **W-001-B** exact-money containment (§5) — required whether or not a model ever ships.
- **W-001-C** the evaluation corpus + harness (§9) — the actual unlock.
- **W-001-D** `InferenceProvider` abstraction with `none` as the default — makes the eventual model
  a configuration change rather than a rewrite.

---

## 9. EVALUATION CORPUS & HARNESS (the unlock)

**Target: ≥ 1,000 labelled messages** before any model comparison is meaningful, spanning:

| Dimension | Required coverage |
|---|---|
| Banks | the top ~20 by real user volume, both markets (SA + EG) |
| Direction | debit, credit/income, transfer, refund, reversal |
| Language | Arabic, English, mixed; Arabic-Indic **and** Western digits |
| Currency | SAR, EGP, USD + at least one **3-decimal** currency (KWD/BHD/OMR) |
| Adversarial | OTP, promo, balance-inquiry, dispute links, "won"-style false positives |
| Malformed | truncated, concatenated, duplicated, wrong-encoding |

**Labelling rules:** labels come from the *message text*, never from current parser output (or the
corpus inherits today's bugs — F-015 is the cautionary example). Every label records the annotator
and date.

**Harness:** extend the existing `parser_lab_parity` goldens — the mechanism already asserts Dart
and compiled-JS agreement, so it generalises to "engine vs engine+model" with no new infrastructure.

**Metrics per task:** exact-match for money/currency/direction; precision/recall/F1 for category;
plus a **false-auto-confirm rate**, which is the only metric that maps to real user harm.

---

## 10. THRESHOLDS, FALLBACK, ROLLOUT

- **Confidence is not comparable across sources.** A model's 0.9 and the heuristic ladder's 0.9 mean
  different things. Calibrate the model on held-out data before any threshold is trusted.
- **Auto-confirm requires corroboration**, exactly as C-1 established for catalog rules: two
  independent readings agreeing. A model alone must never lift a parse to auto-confirm.
- **Fallback:** model unavailable / times out / fails schema validation → deterministic result
  stands. Never worse than today.
- **Rollout:** staged behind a flag with a **real consumer** — note this is blocked on C-10, since
  the server ignores `rollout_percent` today, so a "staged" AI rollout would silently be a full one.
- **Kill switch, versioning, rollback:** model version pinned per release; a kill switch disables
  inference without an app update; every inference records model version for attribution.

---

## 11. USER-CORRECTION FEEDBACK

Corrections are the highest-value labelled signal Qirsh can obtain — the user is the ground truth.

- Corrections feed the **evaluation** corpus, gated by consent.
- **No uncontrolled retraining.** No online learning, no auto-promotion. A correction changes a
  future *evaluated, reviewed* model version, never live behaviour.
- Corrections on **exact money** are a defect signal about the deterministic layer and must be
  triaged as parser bugs first, not as training data.

---

## 12. GATES — what unlocks implementation

| # | Gate | Status |
|---|---|---|
| G1 | F-015 fixed **in the engine**, so merchant labels are clean | **OPEN** — Phase H |
| G2 | Evaluation corpus ≥ 1,000 labelled, uncontaminated messages | **OPEN** |
| G3 | Deterministic baseline measured on G2 — *the number AI must beat* | **BLOCKED on G2** |
| G4 | Consent enforcement real (C-3/F-025, incl. `enrich-merchant`) | **OPEN** — Phase D |
| G5 | Per-field provenance + gap-filling arbitration shipped (W-001-A) | **OPEN** |
| G6 | Exact-money containment shipped (W-001-B) | **OPEN** |
| G7 | Flags actually gate (C-10), so a staged rollout is real | **OPEN** — Phase I |
| G8 | Catalog coverage campaign done — the honest deterministic ceiling | **OPEN** — Phase H |

**Decision rule:** when G1–G8 are closed, measure the residual miss rate against G3. If deterministic
parsing already handles the corpus, the remaining gap is categorisation and merchant normalisation —
which favours a **small on-device classifier**, not an LLM. If unknown-bank understanding dominates
the residual, that favours the **backend** cascade, kept consent-gated. **Let the residual choose.**

**Permitted before the gates close (OD-11):** an isolated, disabled-by-default, non-production local
prototype that contacts no remote service and cannot alter canonical financial data. Nothing in
§1–§11 depends on it.
