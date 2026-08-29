# QIRSH — MASTER CONSOLIDATED BACKLOG & IMPLEMENTATION PLAN

**Consolidated 2026-08-27.** Single entry point for every note written across the Demo Crowd QA,
the Phase-6 push verification, the Phase-3 propagation tests, the Codex release track and the
live interactive session. Sources merged:

| Source | What it holds |
|---|---|
| `demo-docker/DEMO_FINDINGS.md` (1,327 lines) | F-011…F-034 + DF-001…DF-009 |
| `docs/audit/DEMO_FINDINGS.md` (root) | F-013 retraction, F-015, F-016 |
| `demo-docker/UI_UX_REDESIGN_BACKLOG.md` | UX-001…UX-037 |
| `demo-docker/PHASE6_PUSH_PREFLIGHT.md` (902 lines) | PUSH-01…09 + Phase-3 + Phase-6 closure |
| `demo-docker/PARKED_ITEMS_RECONCILIATION_DESIGN.md` | three-way forensics + reconciliation algorithm |
| `docs/MANUAL_RELEASE_PREREQUISITES.md` + `OWNER_RELEASE_CHECKLIST.md` | release blockers (R9) |
| `demo-docker/AUDIT_HANDOFF_F-016.md`, `AUDIT_HANDOFF_DF-002.md` | architecture handoffs |

---

# PART 1 — WHAT IS ALREADY DONE

## 1.1 Verified end-to-end (evidence in PHASE6_PUSH_PREFLIGHT.md)

| Track | Result |
|---|---|
| **Phase 6 — financial push** | PUSH-01…09, 9/9 isolated & verified · zero rollbacks · zero duplicates · every money field byte-exact · both outbox queues emptied |
| **Phase 3 — Admin → App** | announcement content propagation ✅ · coupon catalog ✅ · feature-flag ON/OFF visually confirmed on device ✅ · environment restored to baseline ✅ |
| **Exact-money transport** | 40/40 byte-exact assertions incl. 2⁵³+1 minor units at scale 3 |
| **Parked-queue reconciliation** | 15 parked items → three-way forensic diff → 11 proven dead & removed → zero user intent lost |
| **Interactive live session** | full-push demo build; account create/edit, wallet provider, 15 transactions, income, and a parsed bank message all reached Docker live |

## 1.2 Code fixes implemented in Main (uncommitted working tree)

| Finding | Fix | Tests |
|---|---|---|
| **F-020** viewing an account rewrote the default (server write on every browse) | removed `setDefault()` from both view-switch sites; active-account is UI state only | 1 widget test, fails pre-fix |
| **F-021** conflict raised without divergence evidence + NULL↔0 artifact | evidence-based field diff (exact minor units); base re-proof keeps row `pending`; card-save no longer nulls the initial balance | 5 sync tests + 1 form test, 5 fail pre-fix |
| **F-029** budget push wrote the local category id over the stable key | `enqueueBudget` maps local id → catalog key at enqueue | 2 tests, fail pre-fix |
| **F-016** catalog regex/priority behaviourally dead | new `catalog_rule_matcher.dart`: sender+message eligibility, priority total order, named-group extraction, fail-closed regex, bounded execution; threaded engine → isolate → use case → `RulesClient` | 10 behavioural tests, 4 fail pre-fix |
| **F-014** Parser Lab ran a parallel approximation | `parseSmsWithRules` + contract version; Lab now loads real catalog rules; shared golden corpus | Dart parity test + Node test on the compiled artifact (old artifact fails) |
| **F-017** force-update published on one click | shared guard `announcement-guard.mjs`; POST+PATCH refuse to arm without an explicit token; typed consequence dialog; version-constraint fields added end-to-end | 7 tests; pre-fix Main proven to have no guard |

**Gates:** `flutter analyze` clean · full Flutter suite green (one perf test flaked under parallel load, passes standalone) · admin `node --test` 75/75 · `tsc --noEmit` clean.

⚠️ **Not committed.** Per project rule the working tree is left for review.

---

# PART 2 — OPEN BACKLOG

## 2.1 HIGH — product correctness

| ID | Title | Note |
|---|---|---|
| F-023 | client/server achievement keys diverge — 3 of 4 unlocks invisible | do **not** close the notification epic until all server keys are reconciled |
| F-025 | cloud-consent toggle does not gate the download half of sync | privacy: the switch promises more than it enforces (observed live: sync ran with it OFF) |
| F-018 | all 26 feature flags have zero runtime effect | shares a root cause with F-016; needed for safe staged rollout |

## 2.2 MEDIUM — product

**Sync/data integrity:** F-032 (card reassignment can leave a cross-account card/account mismatch — CONFIRMED locally) · F-019 (Budgets screen ignores the account filter) · F-026 (Home ring vs Budgets screen disagree) · F-027 (paused subscription still billed into the monthly total)

**Parser/capture:** F-015 (merchant swallows the trailing date clause — still reproducible; captured in the new parity goldens) · F-011 («اجتازت الفحص» is a backfill, not validation) · F-012 (12 of 136 banks covered) · F-013 (income capture ladder is hardcoded) · F-034 (Shortcut result does not surface the resolved category)

**Notifications/UI truth:** F-030 (budget-threshold alert not reliably scoped to the triggering category) · F-031 (Plan UI hardcodes «جنيه») · F-033 (large card values render zero-like) · F-022 (level 7 shows «مبتدئ» forever) · F-024 (app cannot display its own version) · F-028 (two different week-over-week percentages under one label)

**New from the live session (to be filed):** possible missing double-submit protection — five identical `Tabby 2000.00 EGP` transactions landed within three minutes; needs confirmation whether they were intentional before opening a finding.

## 2.3 Demo/environment (DF-*) — mostly not product

DF-002 (**real latent defect**: migrations never grant table DML to `authenticated`) and DF-005 (catalog RLS scoped to `anon` only) must be fixed in Main. DF-001/003/004/006/007/008/009 are local-environment facts, already resolved or documented.

## 2.4 UI/UX — 37 entries

- **Design system:** UX-002 (hardcoded black/white — largest collector) · UX-001 (decimal precision) · UX-012 (nav icons) · UX-009 (floating nav overlaps content) · UX-032 (no widget may intrude into another widget)
- **HIGH screens:** UX-033 (onboarding full redesign) · UX-034 (cards page & card/transaction management) · UX-003 (budget sheet — full redesign, not recoloring) · UX-013 (accounts show no balances) · UX-022 (refunds invisible in Reports) · UX-025 (goals list omits deadline/rate) · UX-035/036/037 (unreadable large numbers · plan currency · notification context)
- **MEDIUM/LOW:** UX-004…008, 010, 011, 014, 015, 020, 023, 024, 026…031
- **Admin-panel:** UX-016…019, 021

## 2.5 Release prerequisites (owner action — cannot be done from here)

**Hard blocker:** zero iOS **Distribution** identities in the keychain — archive succeeds, export fails. Then: App Store Connect record, provisioning for `BankMessageShortcuts` + `ShareBankMessage`, Android keystore + `key.properties`, `SENTRY_DSN` in Codemagic, Google "skip nonce checks" on production, final display-name decision (Mali vs قرش).

## 2.6 W-001 — On-Device AI Model Integration · FUTURE WORKSTREAM · **DESIGN PHASE ONLY**

**Status: NOT STARTED. No implementation, no parser-architecture change, until the architecture
document below is explicitly approved.**

### Intent
Qirsh should eventually carry an AI/ML model rather than relying solely on deterministic
regex/catalog parsing. **Governing constraint, non-negotiable:** where an exact bank/parser rule
exists, **deterministic parsing remains the trusted path**. The model is designed as an intelligent
**classification / fallback layer**, never an uncontrolled replacement.

### Grounding — what already exists (the design must reconcile with this, not ignore it)
There is already a **cloud** AI cascade in Main: `_tryAiParseFirst` runs *before* the deterministic
parser in `add_transaction_usecase.dart:369`, gated by `loadAiConsent`, backed by the
`parse-sms`, `bank-discovery` and `enrich-merchant` Edge Functions (Gemini). Any on-device proposal
must state explicitly how it relates to that cascade: replace it, precede it, follow it, or split by
task. Note the ordering tension: today AI runs first and deterministic parsing second — the reverse
of the stated governing constraint. **Resolving that ordering is part of the design phase.**

### Required architecture/design deliverable (14 questions, each needs a decision + rationale)
1. **Task scope** — which exact tasks use the model; which are explicitly excluded.
2. **Placement** — on-device / backend / hybrid, with the trade-off argued, not assumed.
3. **Transaction & category classification** — label set, relation to the stable category keys.
4. **Merchant understanding / normalisation** — interaction with `enrich-merchant` and the merchant-keyword catalog.
5. **Bank-message understanding & fallback** — precisely when the model is consulted: only when no catalog rule matched, or also on low-confidence matches.
6. **Arabic + English** — one multilingual model or per-language; dialect and digit-shape handling.
7. **Footprint** — model size, RAM/CPU/battery, minimum supported devices, cold-start cost.
8. **Inference stack** — iOS (Core ML / MLC / GGUF) vs Android (NNAPI / LiteRT / ExecuTorch); one runtime or two.
9. **Privacy** — what data (if any) leaves the device; how it maps to the existing consent switch; PDPL implications. Note F-025 is open: the consent switch does not currently gate everything it claims.
10. **Offline behaviour** — the app is local-first; the model must not make capture worse offline.
11. **Confidence thresholds & deterministic fallback** — numeric thresholds and the exact arbitration order between rule / model / heuristics.
12. **Integration with catalog authority** — how it composes with `CatalogRuleMatcher` (F-016) without weakening it; a matched rule must stay authoritative.
13. **Rollout / rollback / observability** — model versioning, staged rollout, kill switch, what is measured in production.
14. **Data & accuracy targets** — training/eval dataset requirements, labelling process, and *measurable* accuracy/precision-recall targets per task, with an explicit bar below which the model does not ship.

### Dependencies (hard — must land before W-001 implementation)
| Dep | Why |
|---|---|
| **F-016** (catalog rule authority) | ✅ implemented — the model must compose with a real deterministic authority, not the dead one |
| **F-018** (flags become real) | needed for staged rollout / kill switch (req. 13) |
| **F-025** (consent actually gates) | privacy claims (req. 9) are unverifiable until the switch is honest |
| **F-015** (merchant boundary) | eval labels are contaminated while merchants embed dates |
| **F-013 / F-012** (income ladder, bank coverage) | define what deterministic parsing already covers, i.e. the model's real gap |
| **F-014** (Parser Lab parity) | ✅ implemented — the parity harness becomes the eval bench |

### Recommended sequence position
**After Step 3 (Parser & capture quality), before or parallel to Step 5 (UI/UX).** Rationale: the
model's value is defined by what deterministic parsing *cannot* do — measuring that gap requires the
parser cluster fixed first, otherwise the model is trained to paper over known bugs. The design phase
itself may begin any time; it needs no code.

### Explicit stop condition
Design document → operator review → **explicit approval** → only then implementation planning.

## 2.7 Coverage audit — what this file is, and what it is NOT

This is an **index + plan**, not a copy of every note. Full evidence (repro steps, payloads, SQL,
screenshots) stays in the source files listed at the top; each item above is traceable by its ID.

Audited for anything unmerged, and found one item worth calling out:

- **`docs/ADVERSARIAL_QA_REMEDIATION_PROGRESS.md` is STALE.** Its status table still says Batches 1–4
  are "not yet committed" and that finding #20's RPC
  (`create_subscription_and_record_payment`) is "🔴 CRITICAL — currently broken in production"
  with `42P10`. **Both statements are historical.** Migration `0040_fix_bill_payment_rpc_conflict_target.sql`
  fixed the `ON CONFLICT` predicate the same day, `0041` followed, and the tree has ~379 commits since.
  → **Action: add a superseded banner to that file** so nobody re-opens a closed emergency.
- `docs/audit/GAPS_AND_OPEN_QUESTIONS.md` — all 12 sections closed into `docs/specs/PRODUCT_SPEC.md §24/§25`. Nothing open.
- The remaining `docs/*.md` (referral, coupons, ads, notification, rollout, staging) are **system
  designs and closure reports**, not open backlogs. They are references for the work above.

---

# PART 3 — IMPLEMENTATION PLAN

Each step: reproduce against Main → regression test that fails pre-fix → smallest structural fix →
targeted tests → combined suite → analyze/typecheck. Stop and report between steps.

### Step 0 — Land what exists (½ day)
Review the current working tree, run the full gates, commit the six fixes in labelled commits.
*Nothing else should start on top of an unreviewed tree.*

### Step 1 — Trust & privacy cluster (2–3 days)
**F-025** (make the consent switch actually gate pull) → **F-018** (make flags real, reusing the
F-016 authority) → **F-023** (reconcile achievement keys; only then close the notification epic).
*Grouped because all three are "the system claims X but does Y".*

### Step 2 — Data-integrity cluster (2–3 days)
**F-032** (define and enforce the card↔account invariant in UI + Drift + server) → **F-019**,
**F-026**, **F-027** (account-scope and aggregation truth) → **DF-002**, **DF-005** (server grants/RLS).

### Step 3 — Parser & capture quality (3–4 days)
**F-015** (merchant boundary — cheap, high impact on categorisation) → **F-013** (income ladder into
the catalog authority now that F-016 exists) → **F-034** + **F-030** (capture → notification context;
needs one isolated trace each before any code) → **F-011**/**F-012** (product-scope decisions).

### Step 4 — Display truth (1–2 days)
**F-031**, **F-033**, **F-022**, **F-024**, **F-028** — small, independent, high visibility.

### Step 4.5 — W-001 On-Device AI · **DESIGN ONLY, no code** (see §2.6)
Produce the architecture document answering all 14 questions, with the deterministic-first
constraint stated as a hard invariant. **Stops at operator approval** — implementation is not
scheduled here and does not begin without it. May start earlier in parallel (it needs no code), but
its *implementation* stays gated behind Step 3.

### Step 5 — UI/UX programme (per `UI_REDESIGN_IMPLEMENTATION_PLAN.md`)
A) design-system foundations → B) HIGH screens (onboarding, cards, budget sheet, accounts, reports,
goals) → C) MEDIUM by surface → D) admin panel in parallel.
*System before screens, otherwise every screen is repainted twice.*

### Step 6 — Release readiness
Owner-only prerequisites, then the signed build path. **Blocked on the distribution certificate.**

## Sequencing rationale
1. **Correctness before cosmetics** — a redesigned screen showing wrong numbers is worse than a plain one.
2. **Clusters, not tickets** — the grouped items share root causes; fixing them together avoids re-touching the same files.
3. **Reproduce before fixing** — F-030/F-033/F-034 are user-reported without traces; each needs one isolated reproduction first (explicitly recorded in their entries).
4. **Release last** — it is gated on an external credential, not on code.
