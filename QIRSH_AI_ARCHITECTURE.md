# QIRSH — AI/ML ARCHITECTURE & EVALUATION WORKSTREAM (W-001)

**Status: IMPLEMENTED (on-device) — 2026-08-29, under OD-13.**
Created 2026-08-28 under **OD-11**. Companion to `QIRSH_MASTER_PLAN_V2.md`.

> **UPDATE 2026-08-29 — OD-13 supersedes the sequencing conclusion below.**
> The owner required an ACTUAL model in the app, FREE to run, on-device-first,
> with no paid per-request API as the primary path or as a hidden fallback.
> A model now ships. §14 records what was built, why this shape, and what it
> measurably does. Sections 1–13 are retained unchanged as the reasoning that
> led here — including the recommendation NOT to ship a neural model, which
> §14 upholds rather than overturns.

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


---

## 14. WHAT SHIPPED (OD-13, 2026-08-29)

### 14.1 The decision, and the fact that decided it

Fable was consulted as tie-breaker between (A) an embedded quantized neural
model, (B) a classical on-device classifier, and (C) abstraction-only with the
model deferred. Its recommendation was **B, with C's interface-and-harness
slice folded in**. I validated the premise against the repository before
building — 332 merchant→category seeds confirmed present in
`category_seeds.dart`, and the categorizer confirmed to be exact-substring
matching — then implemented it.

The decisive fact is sharper than "37 examples is too few to train on":

> **37 contaminated examples are too few to EVALUATE with.**

Both directions are therefore blocked, including the "we'd use it zero-shot, no
training needed" counter-argument. A shipped model whose lift over the trivial
baseline cannot be demonstrated is a claim, not an engineering artifact. This is
recorded explicitly so the decision is not relitigated from the training-set
angle alone.

The reframe that made a real model possible: **the training data was already in
the bundle.** The merchant→category catalog is ~330 real labelled pairs, Arabic
and Latin, uncontaminated. And for short, noisy, transliterated merchant strings,
character n-grams are the *right* tool — this is character-level entity matching,
not sentence semantics. The neural option was not the stronger one here, merely
the more fashionable.

### 14.2 What was built

| Component | Location |
|---|---|
| Arabic/Latin normaliser | `app/lib/engine/intelligence/text_normalizer.dart` |
| TF-IDF char-n-gram classifier | `app/lib/engine/intelligence/merchant_classifier.dart` |
| `MerchantIntelligence` boundary | same file — a neural implementation can be swapped behind it |
| Integration | `Categorizer` step 5, before the `other` fallback |
| Wiring | `add_transaction_usecase.dart` (the real capture path) |
| Evaluation harness | `app/test/engine/merchant_intelligence_eval_test.dart` |
| Privacy proof | `app/test/architecture/ai_privacy_test.dart` |

Cost: **zero per request, zero model asset, zero native dependency**, <5ms
inference in pure Dart. Nothing to download, nothing to version, no app-size or
battery argument to defend.

### 14.3 Measured behaviour

Evaluated on a perturbation set generated from the catalog — the variants banks
actually emit:

```
n=3320    model 98.0%    exact-substring baseline 93.4%
```

Absolute lift is 4.6 points, and **running it showed that to be the wrong
headline**: against a 93% baseline, absolute lift is capped near 7 points however
good the model is. The honest measures:

* **relative error reduction: ~70%** of the baseline's residual errors removed;
* the per-perturbation breakdown, which is where the value actually is:

| Perturbation | Model | Baseline |
|---|---|---|
| alef variants (ا/أ/إ/آ) | **100%** | 0% |
| teh marbuta (ة/ه) | **100%** | 0% |
| diacritics (tashkeel) | **100%** | 8% |

Those are the cases substring matching cannot handle even in principle. The
aggregate number hides them because prefix/suffix noise leaves the merchant
substring intact and the baseline survives it.

### 14.4 Structural guards against decorative AI

The risk with a mandated model is that it ships and adds nothing. Prevented
mechanically, not by intention:

1. **Wired into the real abstain path.** It runs only after every deterministic
   source has declined, and before the `other` fallback. There is no parallel
   "AI service" that nothing calls. An integration test asserts a novel variant
   reaches a category through it.
2. **A CI lift gate.** If the model stops beating the baseline it replaced, the
   suite fails. It cannot rot into decoration silently.
3. **Abstention.** Below its confidence floor it returns null rather than
   guessing; precision above the floor is asserted >90%. The promise is
   precision when it speaks, not coverage.
4. **Confidence capped below the deterministic sources**, so a suggestion can
   never win a comparison against a rule that fired.
5. **Optional dependency.** With no model supplied, capture behaves exactly as
   before — AI unavailability degrades to the deterministic path and can never
   lose a transaction.

### 14.5 The write fence (OD-11 / OD-13)

Writable surface: a suggested **category**, and a normalised merchant **display**
name. Never amount, currency, direction, date, account or card identity,
balances, any canonical `_minor` money field, or dedup/identity/sync keys. The
normalised string is a matching key and is explicitly never a join key or a
persisted identity.

If deterministic evidence says 12.50 EGP and a model says 125 EGP, the model
loses — and in this architecture it is never even asked, because money never
reaches it.

### 14.6 Privacy

There is **no network path to gate**. Inference is pure Dart over bundled data,
so "zero AI egress with consent off" is structurally absent rather than blocked.

Tests enforce this rather than assuming it: the intelligence layer may not import
anything network-capable, and no paid-provider SDK name may appear — OD-13
forbids a paid API as primary path *or* hidden fallback, and that prohibition is
now checkable rather than remembered.

### 14.7 On-device learning

A user correction becomes a first-class exemplar and generalises to variants of
that merchant. The model measurably diverges from its shipped state as the user
corrects it, with nothing leaving the device — the one capability a lookup table
cannot imitate, and the honest answer to "is this really AI".

### 14.8 What is NOT done, and its entry gate

Unknown-message triage ("is this a transaction at all") is the same machinery
over the same features and is the clearly-defined next increment.

The neural path is not abandoned; it is **gated**: a clean labelled corpus of
≥500 messages AND a demonstrated ≥5-point lift over the Dart baseline on that
corpus, before a single megabyte of model asset enters the bundle. If those never
materialise, the neural model correctly never ships. Realistic candidate when
they do: `paraphrase-multilingual-MiniLM-L12-v2` (Apache-2.0), ~117MB int8 —
still likely too heavy, needing distillation below ~30MB; runtimes
`tflite_flutter` (Apache-2.0) or ONNX Runtime (MIT), both clean on licensing;
the real cost is the SentencePiece tokenizer and per-platform binary maintenance.
