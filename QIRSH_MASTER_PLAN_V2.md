# QIRSH — MASTER PLAN V2

**STATUS: AUTHORITATIVE.** Supersedes `MASTER_REMEDIATION_PLAN.md` as of 2026-08-28.
Produced by independent review against current Main — **Claude × Fable (4 reviewers) × Codex (2)**.
Findings confirmed by all three model families are marked **⋔ settled**.

> **Evidence limitation (not an implementation blocker).** Codex quota was exhausted before its
> Parser/Capture/AI and Privacy/Flags/Admin reviews completed. For those two scopes:
> **Codex independent review unavailable — Claude + Fable + direct source verification used.**
> No opinion is attributed to Codex there. Every finding in those scopes carries a `file:line`
> verified directly against Main.

> **Method.** Every item was re-verified against source; the previous plan was *not* assumed
> correct. Disagreements between reviewers were resolved by re-opening the code, never by vote.
> Every technical claim carries a `file:line`. Items that could not be verified are marked
> **NEEDS EVIDENCE** rather than carried forward on reputation.
>
> **Result: the previous plan was substantially wrong.** 4 of its findings are stale or
> mis-located, 3 are materially worse than filed, 2 of the 6 "completed" fixes must not land as-is,
> and the 3 highest-severity items in this document were **absent from it entirely**.

---

## 0. LIVE STATUS BOARD

Legend: `OPEN` · `IN PROGRESS` · `FIXED LOCALLY` (implemented + tested, not deployed/reviewed) ·
`VERIFIED` (proven at HEAD by a gate, not merely implemented) · `EXTERNAL EVIDENCE PENDING` ·
`OWNER DECISION REQUIRED`

### Phase A — tree partition · **COMPLETE**
Safety snapshot of the entire pre-partition tree (tracked + untracked): branch
`backup/pre-partition-20260828`. Nothing was discarded at any point.

| Commit | Content | State |
|---|---|---|
| `8e36a24d` | **F-020** account browsing no longer rewrites the default | **VERIFIED** |
| `a6f343fb` | **F-021 (form half only)** card initial balance preserved | **VERIFIED** |
| `8d0a422c` | **F-016 + C-1** catalog authority, gated on validation evidence | **VERIFIED** |
| `e96f8434` | **F-014** Lab runs the real engine + parity gate; artifact recompiled | **VERIFIED** |
| `35754d99` | **F-029** stable category key on the wire, now fail-closed | **VERIFIED** |
| `3dc87694` `2ac4c782` `e2b5b489` | completions the HEAD check exposed (isolate fakes, guard provider + read model) | **VERIFIED** |

**Deliberately NOT landed** — still in the working tree, unreviewed and clearly isolated:

| Held back | Why |
|---|---|
| **F-021 pull half** (`accounts_pull_service.dart`) | §12.2 — four structural defects; three model families independently reached DO NOT LAND |
| **F-017** (guard + admin UI) | §9.1 — the guard is bypassable; landing it would close the finding while the hole remains |
| **H-4 pull gates** | §4.2 — silently disables financial pull; needs its own reviewed decision |
| **NEW-H-3 consent propagation** | §R13 — reverses a documented privacy decision (MALI-059n) |
| backup/restore overhaul · admin UI promotion · migrations 0084–0086 · CI/release | separate workstreams, never reviewed by the QA that produced the old plan |

**Gate note.** Working-tree gates were not sufficient: they passed while the *committed* tree did
not compile. Every commit above was therefore verified by `flutter analyze` in a detached worktree
at HEAD — which found 7 real errors that the working tree hid. HEAD now analyzes clean.

### Phase B/C — autonomous long run (2026-08-28)

| Commit | Content | State |
|---|---|---|
| `19e6ce43` | **C-2a** "armed" redefined as *blocks clients*; temporal-resurrection bypass closed; `action_url` precondition | **VERIFIED** (admin 88/88, tsc clean) |
| `9c3aa230` | **DF-002/DF-005** explicit owner-table grant matrix + Edge-only catalog boundary test | **FIXED LOCALLY** — source-only, **EXTERNAL EVIDENCE PENDING** on deployment |
| `e723f4ce` | Release readiness track (`QIRSH_RELEASE_TRACK.md`) | **VERIFIED** (docs) |
| `b32e2395` | **W-001** AI/ML architecture workstream (`QIRSH_AI_ARCHITECTURE.md`), per OD-11 | **VERIFIED** (docs) |
| `a241bdae` | **C-9** Home is a pure read; repair moved to an explicit startup command | **VERIFIED** |
| `68777c1c` | **C-3** `ConsentAuthority` policy + 10 exhaustive tests | **VERIFIED** (policy) |
| `308aab81` | **C-3** sender→bank mapping egress gated (which banks the user holds) | **VERIFIED** |
| `b0b364fb` | **C-3** backup consent hook was dead code — now fails closed | **VERIFIED** |
| `dce16bdd` | **C-3/OD-05** crash reporting gated on consent | **VERIFIED** |
| `7b57be14` | **C-3** financial PUSH gated (accounts + ledger) | **VERIFIED** |
| `3ea5793c` | **C-2a-2** SECURITY DEFINER arm RPC + trigger + append-only audit | **FIXED LOCALLY** — **EXTERNAL EVIDENCE PENDING** |
| `093549bf` | **C-2a-2** admin route arms via the RPC, fails closed at 503 | **VERIFIED** (source) |
| `17eea0af` | **C-10** server rollout semantics fail closed | **FIXED LOCALLY** — Edge, not deployed |
| `4bb47943` | Phase-F capability activation runbook | **VERIFIED** (docs) |
| `6219024e` | **F-026 / F-019 / F-027** one canonical `AccountScope` (OD-08) | **VERIFIED** |
| `6e13f44f` | **F-032** canonical `card_id` + never-guess backfill (OD-02) | **VERIFIED** (client half) |
| `f3fd86ce` | **F-028** like-with-like week comparison | **VERIFIED** |
| `2c70cb73` | **F-023 + F-022** one gamification vocabulary (OD-03) | **VERIFIED** (client half) |
| `39c199cb` `cee2d4ef` | **C-6** atomic guarded update (accounts + ledger) | **VERIFIED** |
| `2ad082ef` | **F-015** merchant boundary, both paths + the AMAZON truncation | **VERIFIED** |
| `f68af055` | **F-029** server-side detection view (no guessing repair) | **FIXED LOCALLY** |
| `9b62839b` | **R-1** egress inventory — no new network call without a consent decision | **VERIFIED** |
| `6e7d8d93` `12560909` | **C-3** telemetry + Smart Inbox gated | **VERIFIED** |

**Owner decisions OD-01…OD-12 received and applied.** See `QIRSH_AI_ARCHITECTURE.md` for OD-11 and
`QIRSH_RELEASE_TRACK.md` for OD-06.

**OD-13 — an actual AI/ML model is required, and it must be FREE to run
(2026-08-28, owner present, supersedes the earlier external-API framing).** Qirsh
must ship a real model integration, not documentation. A paid per-request API may
NOT be the primary implementation and may not be a hidden fallback. Preference
order: an open-source on-device model, a lightweight local classifier, or another
zero-per-request-cost architecture. It must be practical on both iOS and Android
without making the app unreasonably large, slow, memory-heavy or battery-hungry,
and the SMALLEST model meeting measured accuracy wins. A large general-purpose
LLM added merely to claim the app has AI is explicitly rejected.

Scope the model MAY serve: Arabic + English message understanding, merchant
normalization, category prediction, unknown-message classification, ambiguity
assistance. The deterministic parser remains authoritative for amount, currency,
direction, account/card identity and exact-money values — the model may never
override them.

If a fully embedded model cannot safely be completed this sprint, the complete
inference abstraction, evaluation harness, model asset pipeline and integration
path must still land, with the exact remaining blocker stated.

**OD-12 — gamification vocabulary (2026-08-28, owner present).** The union
approach is **APPROVED**. Preserve the union of the existing client and server
achievement vocabularies; normalize semantic duplicates if any; use ONE canonical
versioned shared catalog; keep progress/state server-authoritative as previously
decided. Existing legitimate client achievements must **not** be discarded merely
because the old server catalog was smaller.

This closes the one product judgement I had flagged as taken on the owner's
behalf: `2c70cb73` chose the union to unblock the fix, and that choice is now
confirmed rather than assumed. Outstanding under OD-12: a duplicate-semantics
normalisation pass (no duplicates found so far, but it has not been proven
exhaustively) and the server half of the shared catalog, which is source-only
until deployment.

### Findings worked this cycle
| ID | State | Note |
|---|---|---|
| **C-1** unvalidated rule writes confirmed money | **FIXED LOCALLY** | three independent controls (client cap, `0087` data + CHECK, evidence-based serving gate). SQL/Edge are source-only → **EXTERNAL EVIDENCE PENDING** on deployment |
| **C-2** force-update guard bypass | **PARTIALLY FIXED — NOT CLOSED** | the no-token bypasses are closed (`464816a6`). **C-2a remains OPEN**, see below |
| **C-2a-1** temporal-resurrection bypass | **VERIFIED FIXED** (`19e6ce43`) | "armed" now means *blocks clients*: severity + is_active + a serving window that has not expired. Closes resurrecting an expired force-update, clearing `valid_until`, scheduling a future block, and widening `target_countries`. Adds an `action_url` precondition — arming without one bricks clients behind a placeholder store URL (`force_update_screen.dart`, fake id `id0000000000`). |
| **C-2a-2** confirmation is client-side only | **FIXED LOCALLY — deployment pending** | **Superseded 2026-08-29.** Arming is routed through the `arm_force_update()` SECURITY DEFINER RPC (`0089`), which audits and mutates in one transaction, and the admin route FAILS CLOSED with a 503 when the migration is absent rather than falling back to the unaudited update. `confirm_force_update` survives only as a pre-check; it is no longer the authority. Remaining: apply `0089` — external. |
| ~~C-2a-2 (previous state)~~ | ~~OPEN~~ | `confirm_force_update` is a **caller-supplied boolean** (`admin/app/api/announcements/route.ts`); the typed phrase «تحديث إجباري» is enforced only in the React dialog (`announcements/page.tsx`). Any direct API call — curl, a script, a compromised admin session — supplies `true` and arms a control that blocks every installed client. The guard now stops a *misclick*, not an *actor*. **C-2 must not be marked closed until confirmation is server-enforced**: a DB trigger or RPC that will not accept a `severity='force_update' AND is_active` transition without a server-verified confirmation record, plus an admin audit row per arm/disarm (§9.3 — there is no audit trail outside referrals today). |
| **C-9** dashboard read mutates financial state | **FIXED LOCALLY** | repair moved to an explicit startup command; read path proven side-effect free |
| **F-016 / F-014 / F-020 / F-029** | **VERIFIED** | landed with review changes applied |
| **F-021** | **CLOSED** | form half VERIFIED; pull half LANDED `4a097ea5` — evidence-based, and an existing conflict now demotes back to pending |
| **C-5** privacy/terms URLs | **BLOCKED — EXTERNAL** | NXDOMAIN. Per OD-06 the policy text is authored after Phase D so it describes *enforced* behaviour; the hosting step is the owner's. |
| **C-3** | **COMPLETE for money paths** | 11 gated · 1 exempt · 1 open (`MerchantFeedbackClient`, UNWIRED — no caller in lib/, cannot leak). Financial pull gated at `f0fa99b7` once H-4 unblocked it. |
| ~~C-3 (previous state)~~ | ~~PARTIALLY FIXED~~ | **7 of 12 egress paths gated** (financial push, sender→bank, backup, diagnostics, telemetry, Smart Inbox). 1 exempt (catalog — no user data, carries the kill switches). **4 open: 3 are the financial PULL services in the H-4 quarantine and cannot be gated until it lands; 1 (`MerchantFeedbackClient`) is UNWIRED and cannot leak today.** `R-1`'s inventory test now fails on any new ungated egress. |
| **C-10** | **FIXED LOCALLY** | server no longer treats a partial rollout as fully enabled |
| ~~F-021-pull / C-6 / F-024 / F-015 / F-034 / F-011-admin~~ | **ALL CLOSED 2026-08-29** | F-021-pull `4a097ea5` · C-6 `6e4c7ff9` (3rd path) · F-024 `a67e1284` · F-015 `2ad082ef` · F-034/H-19 `5b3a1eb4` (device evidence pending) · F-011 `0ae0defe` |
| **F-032 · F-023+F-022** | **client half FIXED** | server-side `card_id` on `user_cards`/`user_transactions`, and server-authoritative gamification with a versioned shared catalog, both still require server work |
| F-020a · F-019 · F-023 · F-032 · F-016 rollout · Sentry · privacy domain · NEW-H-3 · ND-06 · consent deletion | **OWNER DECISION REQUIRED** | §27 |

---

## 1. EXECUTIVE STATUS

| | |
|---|---|
| **Ship-readiness** | **Not near.** Three release-blocking defects, none of which were in the old plan. |
| **Code health** | Strong. `flutter analyze` clean; 2,527 tests pass; sync/money architecture is mature. |
| **The problem** | Not code quality — it is **unverified activation, dishonest safety controls, and an unreviewed working tree.** |
| **Biggest single risk** | The working tree silently disables financial pull **and** contains a bypassable force-update guard. Both would ship under "Step 0 — commit the six fixes, ½ day". |

### The three things that matter most

1. **An unvalidated admin regex can write confirmed money into user ledgers.** (§10.1)
2. **The force-update guard is bypassable, and can brick every client.** (§9.1)
3. **The consent switch is dishonest across ~12 egress paths, including name/phone/DOB.** (§9.2)

---

## 2. WHAT IS CONCLUSIVELY COMPLETE

| Item | Evidence | Confidence |
|---|---|---|
| `flutter analyze` clean | re-run this session: "No issues found!" | **verified** |
| Test suite | 2,527 pass / 1 skip / 3 fail — all 3 are **load-flaky**, pass standalone (10/10 in 1:51) | **verified** |
| CI gate architecture | `codemagic.yaml:64,167,308,448` run `npm ci` + `REQUIRE_ALL_GATES=1 tools/ci_gates.sh`; `ci_gates.sh:211` makes missing tools fatal under strict | **verified** |
| Exact-money transport design | `Money` minor units, `::text` NUMERIC, `moneyFromPulledValue` throws rather than degrading to `double` | **verified** |
| Sync machinery | two outboxes, enqueue-time base tokens, entity-generic conflict policy over 10 entity types (`conflict_policy.dart:126-206`), real resolution UI (`planning_conflicts_sheet.dart`) | **verified** |
| F-014 (Parser Lab parity) | single-source dart2js; goldens asserted both sides; runs in CI | **LAND AS-IS** |
| F-020 (default-account write) | both view-switch sites fixed; no implicit `setDefault` caller remains | **LAND, minor cleanup** |

> ⚠️ **Part 1 of the old plan overstated its own evidence.** "Phase 6 — 9/9 verified pushes" was
> obtained on a **demo build with capability overrides**. In Main's DI, financial push is parked and
> pull is disabled. Those results do not demonstrate that production sync works.

---

## 3. REVIEW OF THE SIX UNCOMMITTED FIXES

| Fix | Verdict | Why |
|---|---|---|
| **F-014** Parser Lab parity | ✅ **LAND AS-IS** | Residual parity holes are known and minor (§11.4). |
| **F-020** default-account | ✅ **LAND** (cleanup) | Two sites now behave divergently (one invalidates 4 providers, one none); one comment is factually wrong. Captures now always land in the persistent default — **product decision required** (§6 F-020a). |
| **F-029** budget category key | ⚠️ **LAND WITH CHANGES** | Correct at enqueue. But **no repair for already-corrupt server rows** — the pull resolver degrades them to `other` (`planning_pull_service.dart:1332-1347`) and a later edit **pushes** `other`, locking corruption in. Seed category ids are per-device `IdGenerator.next()` (`database_seed.dart:36-45`), so **every pre-fix pushed budget is corrupt.** Needs a repair migration + pull-side tolerance **before** transport activation. |
| **F-016** catalog rules | ⚠️ **LAND WITH CHANGES** | Not a dead-code fix — a **parser cutover** (§11.1) that also enables the money-integrity chain in §10.1. |
| **F-021** conflict evidence | 🛑 **DO NOT LAND (pull half)** | Four structural defects (§12.2). The `account_form_sheet.dart` half is fine and may land. |
| **F-017** force-update guard | 🛑 **DO NOT LAND AS-IS** | The guard is **bypassable** (§9.1). |

**Plus, riding along unlabelled in the same tree** (§4.1): the H-4 pull gates that disable financial
pull, a consent-propagation change reversing a documented privacy decision, a backup/restore
overhaul, migrations 0084–0086, and a full admin UI promotion.

---

## 4. CURRENT ARCHITECTURE MAP

```
CAPTURE      native bridge / iOS Shortcut / share / manual paste
                ↓
PARSE        parser_isolate → parser_engine + catalog_rule_matcher     [4 parsers exist — §11.3]
                ↓                            ↘ engine/ai (cloud cascade)
DOMAIN       add_transaction_usecase.dart   [1,803-line god-object]
                ↓
PERSIST      Drift / SQLCipher — app_database.dart (v31)   ← SOLE financial write authority
                ↓
OUTBOX       planning_sync_outbox + ledger_sync_outbox  (base token snapshotted at enqueue)
                ↓
TRANSPORT    *_push_service / *_pull_service   ← ALL GATED OFF (§4.2)
                ↓
SUPABASE     86 migrations · Edge Functions · RLS

ORCHESTRATION  _AppShellState (1,729 lines)  ← a WIDGET owns sync   [boundary leak]
ADMIN → CLIENT admin/ → tables → Edge Functions → catalog_sync_service → Drift → feature_flags
```

### 4.1 The working tree is five workstreams, not six fixes

120 tracked files, **+12,306 / −4,643**, plus 62 untracked paths. The six fixes are ~1,000 lines.

| Workstream | Size | In the old plan? |
|---|---|---|
| The six QA fixes | ~1,000 lines | yes |
| **H-4 pull gates** (disables financial pull) | small, high impact | **no** |
| **NEW-H-3 consent propagation** (reverses MALI-059n) | `planning_outbox_queue.dart:312-403` | **no** |
| Backup / restore / data-portability overhaul | +1,341 / −215 | **no** |
| Admin UI promotion from demo-docker | ~+3,000 | **no** |
| Migrations 0084–0086 + Edge Functions + CI | — | **no** |

### 4.2 Every financial transport gate is OFF, and one is being turned off by this tree

| Gate | State | Blocked on |
|---|---|---|
| `exactPushTransportCapabilityProvider` | `unknown` (`exact_transport_capability.dart:17`) | live push verification |
| `exactPullTransportCapabilityProvider` | `unknown` (:23) | live pull verification |
| `planningServerCurrencyCapability` | `unknown` (:38) | **migration 0077 undeployed** |
| `kServerRevisionCas` | `false` (`sync_capabilities.dart:27`) | **0068 undeployed** + staging tests |

**Pull previously ran.** `git diff` on `app_providers.dart`: `-isPullEnabled: () => true` →
`+isPullEnabled: () => exactPullAllowed(pullCap)`. Committing this tree **disables cloud→device
financial restore** — an unreviewed production behaviour change attributable to none of the six
findings.

---

## 5. ROOT-CAUSE MAP

| # | Root architectural issue | Symptoms | Structural remediation | Worth it? |
|---|---|---|---|---|
| **R-1** | **Consent has no enforcement point** — gating is per-service opt-in, so every new service ships ungated by default | F-025, backup upload ungated, AI-without-cloud, enrich-merchant, smart-inbox stub | One `ConsentAuthority` consulted at the two egress funnels that already exist (`_runLedgerSync*`, service construction in `app_providers.dart`) + a written scope contract | **YES — release-gating** |
| **R-2** | **No single account-scope / aggregation policy** — every screen re-derives its own scope predicate | F-019, F-026, F-027, F-028, UX-022, UX-023, UX-001 | One `AccountScope` + one budget-inclusion + one bill-inclusion predicate in `domain/finance`; architecture test forbidding re-derivation. **Must mandate one canonical *input scope*, not just one canonical function** (§27.1) | **YES — ~7 findings** |
| **R-3** | **Admin-authored config has no client contract** — server vocabularies drift from client consumers with no gate | F-018, F-023, F-016 (pre-fix), F-011, F-017 version fields | A repo test diffing server-seeded keys against client consumers; delete retired keys | **YES — 5 findings** |
| **R-4** | **No client version identity** | F-024, dead `X-App-Version` on all 6 catalog calls, F-017 targeting broken both layers | Stamp `APP_VERSION` in all 3 Codemagic workflows + `package_info_plus`; evaluate min/max client-side too | **YES — cheap, unblocks F-017** |
| **R-5** | **Gamification is split-brain** — two level formulas, no shared achievement vocabulary | F-022 + F-023 | One authority decision (curve + catalogue + `level_key` sync) | **YES — merges 2 findings** |
| **R-6** | **Per-device ids leak onto the wire** | F-029, F-032, account local-id mapping | Wire rule: only stable keys cross; server-side validation; `card_id` FK | **YES** |
| **R-7** | **Capability activation is unowned** | all four gates in §4.2 | One "transport activation" runbook (deploy 0068/0077 → verify → flip → un-park) | **YES — the real gate on the cloud half** |
| **R-8** | **Money rendered through `double` via 4+ formatters** | F-033, UX-001, UX-035 | One `Money`-typed display formatter; ban `toDouble()` at the UI boundary | **YES — before Step 5** |
| **R-9** | Sync orchestration lives in a widget; ledger transport filed under `capture/`; 1,803-line use-case | substrate under F-020, F-025, and every future sync bug | Minimal seam now (gate inside engines, not the widget); full extraction deferred | **PARTIAL — do the seam only** |

**Explicitly NOT worth structural treatment:** F-024, F-031, F-033 as *leaf* fixes; UX-004…011,
014, 015, 028; F-012 (content authoring, not architecture).

---

## 6. VALIDATED OPEN FINDINGS

**CRITICAL**
- **C-1** Unvalidated catalog rule writes **confirmed** money (§10.1) — *new*
- **C-2** Force-update guard bypassable; bricks all clients (§9.1) — *new*
- **C-3** Consent switch dishonest across ~12 egress paths (§9.2) — *F-025, re-scoped and enlarged*

**HIGH**
- **F-023 + F-022** gamification split-brain; achievement key intersection **∅**; two level curves (§13.3)
- **F-032** card identity is a soft composite key → silent financial mis-attribution (§10.2)
- **C-4** working tree disables financial pull (§4.2)
- **C-5 ⋔** privacy-policy domain **NXDOMAIN** — store blocker **and** live dead link (§17)
- **C-6 ⋔** guarded UPDATE is a non-atomic TOCTOU on all three push services (§12.3)
- **C-9** *(new, Codex)* **a dashboard READ mutates financial state.** `dashboardDataProvider` →
  `_ensureCurrencyAccounts` (`dashboard_providers.dart:197,304`) calls `accountRepo.create(...)`
  (:212) and backfills null-account transactions; repositories enqueue sync writes. **Opening Home
  can create durable accounts and cloud intent.** Same family as F-020, absent from the old plan.
  Fix: move repair into an explicit idempotent startup command; keep providers pure.
- **C-10** *(new, Codex)* **client and server disagree on what a feature flag means.** The client
  buckets on `rolloutPercent` via SHA-256 (`feature_flag_service.dart:132-147`); the server resolver
  ignores `rollout_percent` **and** `target_countries` entirely
  (`supabase/functions/_shared/feature_flags.ts:10-33`). A flag can be off for 90% of clients and
  fully on in every Edge Function. **This changes the F-018 remedy** (§7) and undermines any claim
  that flags are a universal kill switch.

**MEDIUM**
- **F-030** budget alert loops *every* budget, no dedup, wrong currency label
- **F-028** dashboard compares partial-vs-full week; reports compares elapsed-matched — same label
- **F-027** unfiltered bill total on the Transactions tab + currency-order-dependent silent omission
- **F-019** budget *history* tab unfiltered by account (`budgets_providers.dart:153`)
- **F-026** dashboard **excludes** global budgets, Budgets screen **includes** them
- **F-015** merchant boundary — baked into all 12 catalog rules, so **not a Dart-only fix**
- **F-011** blanket `validation_status='passed'` backfill → **precondition of F-016**
- **F-034** iOS Shortcut returns bare `.result()` at every exit — surfaces nothing
- **F-024** no version identity → **blocks F-017** (§R-4)
- **F-018** 3 of 26 flags live — *re-scoped, see §7*
- **DF-002** no table DML grants → blocks fresh-environment reproducibility
- **F-013** income *is* captured heuristically → reduces to content authoring under F-012
- **C-7** 4 load-flaky tests erode every gate built on the suite
- **C-8** no admin audit trail outside referrals; service-role blast radius (§9.3)

**LOW** — DF-005 (latent), F-012 (content), dead code (`foundation_home_screen.dart`,
`CapturedMessageProcessor.processCapturedMessage`)

---

## 7. FINDINGS CHANGED, MERGED, OR CLOSED

| Finding | Old | New | Why |
|---|---|---|---|
| **F-031** | MEDIUM open | ❌ **CLOSED — STALE** | No hardcoded «جنيه»; plans use `Currency.arabicLabel(plan.currency)`. Residual: plan currency frozen at creation. |
| **F-018** | HIGH "26 flags inert; make them real" | **MEDIUM, re-scoped — and the remedy changed** | 3 live, ~20 dead. 10 retired **deliberately** (MALI-034) so a remote flag cannot switch financial authority — **reviving them is a safety regression.** "Reuse the F-016 authority" is a category error. **Codex C-10 adds:** wiring client consumers is *insufficient* — the server ignores `rollout_percent`/`target_countries`, so staged rollout is unsafe on the backend regardless. Both halves must be fixed together. |
| **F-022** | MEDIUM display, Step 4 | **merged into F-023** | Same root cause; naive fix throws `RangeError` above level 5. |
| **F-033** | MEDIUM | **merged into UX-035** | `FittedBox` layout, not formatting. |
| **F-025** | HIGH "gate the download half" | **CRITICAL, re-scoped** | Push is equally ungated; prescription would ship a false fix. |
| **F-026 / F-030** | — | **VERIFIED (not stale)** ⋔ | Claude initially called these stale; fable proved otherwise, Codex confirmed F-026. See §27.1. |
| **F-019** | HIGH-ish open | **owner decision** | Three-way split. Mechanism undisputed (`:68` unfiltered → `:71` filtered → **`:153` iterates the unfiltered list**). Intent disputed: Codex reads global history as deliberate; the only comment there documents a *performance* optimisation and says the result is "identical to the old full-ledger fold" — i.e. preserved, never declared intentional. → §27 decision 8. |
| **F-027** | "paused sub billed" | **re-located** | Subscriptions screen is correct; the Transactions Bills tab is the offender. |
| **F-013** | MEDIUM code | **content authoring** | Income *is* heuristically captured (`parser_engine.dart:280-282`). |
| **F-012** | MEDIUM code | **content authoring** | 12 rules seeded / 124 banks / 29 profiles. |
| **F-011** | MEDIUM cosmetic | **HIGH precondition** | It is why 12 unvalidated rules look verified (§10.1). |
| **UX-035/036/037, UX-022, UX-023, UX-018** | Step 5 | **merged into product fixes** | 6 of 37 double-counted. |
| §2.5 release blocker | "zero Distribution identities" | **wrong blocker** | Expected — CI signs (`MANUAL_RELEASE_PREREQUISITES.md:67-70`). Real blocker is C-5. |

---

## 8. NEWLY DISCOVERED FINDINGS

Beyond C-1…C-8 above:

1. **Ignore-list runs before catalog matching** (`parser_engine.dart:136-147`) with raw `contains`
   on `'won'`, `'click'`, `'اضغط'`, `'http://'` (:960-969) — a legitimate debit carrying a dispute
   link is dropped and **no admin rule can rescue it**.
2. **Catalog rules gated by an undocumented `banks.sms_senders` alias lookup**
   (`rules_client.dart:127`) — a rule's own `sender_pattern` is subordinate to it.
3. **`_lastResortParse` is gated on AI failure state** (`add_transaction_usecase.dart:418-420`) —
   consent-OFF users and the entire automatic drain never get it. **Turning AI ON increases
   *deterministic* coverage.**
4. **The server capture path implements the OPPOSITE (correct) arbitration order**
   (`process-ios-sms/index.ts:454-456`). Two policies ship in one product.
5. **`enrich-merchant` is not AI-consent gated** — SMS-derived merchant tokens + install_id reach
   Google Places with the AI switch OFF.
6. **Backup upload consent hook is dead code** — `RemoteBackupController` defaults
   `consentGranted: () => true` (`remote_backup_controller.dart:12-13`) and the provider omits the
   callback (`backup_service.dart:157`).
7. **`GroundingCheck` fails all comma-grouped amounts** (`grounding_check.dart:8-18`) — correct AI
   answers rejected; 3 failures suppress the sender for the session.
8. **AI currency hallucination can auto-create an account in the wrong currency**
   (`add_transaction_usecase.dart:222-235`, invoked :674-679).
9. **iOS Shortcut double-parse race** — durable local copy parsed by the device engine while the
   relay row carries the server's parse; payloadId dedup keeps whichever lands first.
10. **No branch/merge strategy**, with precedent: `99d63d93` landed a previous mixed tree as one commit.
11. **Step 5's own execution doc lives only in `demo-docker/`** — the workspace the plan declares evidence-only.
12. **Tabby duplicates reframed** — `_busy` guard exists (`manual_transaction_sheet.dart:487`) and the
    dedup hash excludes timestamp **by design** (`transaction_dedup.dart:5-12`); 5 distinct-timestamp
    messages are 5 intended rows. Open question is whether the duplicate *detector* surfaced them.

---

## 8a-RESOLVED. QUARANTINE CLEARED (2026-08-29)

**Every quarantined workstream reviewed in this document has now been resolved.**

| Workstream | Outcome |
|---|---|
| **H-4** pull gates | **LANDED** — 4 commits, `b7f0359d`…`ab14ce10` |
| **H-1** reconcile truthfulness | **LANDED** — `93275043` |
| **F-021** pull half | **LANDED** — `4a097ea5`, evidence-based, merged with C-3 |
| **C-6** planning push | **LANDED** — `6e4c7ff9` |
| **F-024** CI version identity | **LANDED** — `a67e1284` (enforcement only; no CI experiments) |
| **F-011** admin surface | **LANDED** — `0ae0defe` (enforcement only; presentation left behind) |
| **F-034 / H-19** Shortcut | **SOURCE LANDED** — `5b3a1eb4`; device evidence pending |

**Correction to §8a below.** It states H-4's dependency graph justified deferring
the landing. On execution the H-4 workstream proved to be **three** implementation
files, not seven — the earlier estimate conflated it with H-1, NEW-H-3 and the
capture ownership-guard work that merely share `app_providers.dart`. The original
review text is retained unedited beneath, because a plan that quietly rewrites its
own wrong estimates teaches nothing.

The remaining working-tree content is the genuinely separate NEW-H-3 (consent
propagation), the capture ownership guard, the backup/restore overhaul, and the
admin/CI presentational work — none of which this sprint claimed.

---

## 8a. QUARANTINE REVIEW — H-4 PULL GATES (2026-08-28)

V2 quarantined this workstream because it "silently disables financial pull" —
an unreviewed production behaviour change riding along unlabelled inside
"commit the six fixes". That was the right call at the time. The review has now
been done, and the verdict is **LAND**.

**What it does.** Separates PULL authority from PUSH authority (they shared one
`isEnabled` predicate) and requires the same positive proof for money-bearing
pulls that push already required: `exactPullAllowed(cap)`, where `unknown` and
`unsupported` both block. Defaults fail closed
(`_defaultPullEnabled → false`, `_defaultPullCapability → unknown`).

**Why it should land, despite being a behaviour change:**

1. **It is symmetric with push, which is already accepted.** Money-bearing push
   has required positive proof since MALI-026. Pull carrying the same money
   (`initial_balance::text`, `current_balance::text`) had no equivalent gate —
   an asymmetry with no principled defence.
2. **It improves the failure mode rather than merely disabling a feature.**
   `moneyFromPulledValue` throws rather than degrading to a `double`, so under an
   `unsupported` transport the pre-H-4 behaviour was *"attempt every row, throw,
   and wedge the cursor"*. H-4 turns that into *"do not run"*. Cleanly not
   running beats failing per-row and stranding a watermark.
3. **The disabling is largely moot today.** Financial PUSH is parked in
   production, so the server holds little or no canonical financial data for the
   pull to fetch. Pull was reading what push never wrote.
4. **It is instantly reversible.** Flipping the capability to `verifiedExact`
   after the Phase-F proof re-enables it with no code change — which is exactly
   the activation step the runbook describes.

**What is NOT included, and stays rejected.** `accounts_pull_service.dart`
contains no H-4 gate at all — both of its hunks are the **F-021 pull half**,
which remains **DO NOT LAND** (§12.2). Likewise `planning_pull_service.dart`'s
changes belong to **NEW-H-3** (consent propagation), reviewed separately. The
three workstreams were entangled in the tree but are cleanly separable by file
and hunk.

**Consequence.** Landing H-4 unblocks the consent gating of financial PULL
(C-3), which cannot be written against files held in quarantine.

---

## 8b. FINDINGS DISCOVERED DURING REMEDIATION (2026-08-28 long run)

Recorded separately because they were found by *doing the work*, not by the
review — which is itself evidence that the review was necessary but not
sufficient.

| ID | Finding | State |
|---|---|---|
| **C-2a-1** | **Temporal-resurrection bypass.** `catalog-announcements` serves a row only while its window is live, so a force-update whose `valid_until` is in the past blocks nobody — yet it is still `severity=force_update AND is_active`. Extending `valid_until` therefore took it from blocking NOBODY to blocking EVERY client *without crossing the not-armed→armed transition* the C-2 guard checks. A hole in a fix shipped hours earlier. | **FIXED** `19e6ce43` |
| **C-2a-3** | **Arming with no `action_url` bricks clients.** `ForceUpdateScreen` falls back to a placeholder store URL with a fake app id (`id0000000000`), so an armed force-update without a real URL traps every user behind a dead button. | **FIXED** `19e6ce43` |
| **C-11** | **Test suites were asserting the wrong thing after fail-closed changes.** 21 constructions across 10 test files exercised push/backup MECHANICS without supplying consent, so once the gates defaulted to DENY they silently began asserting the refusal path. Passing tests that no longer test what they claim are worse than failing ones. | **FIXED** (`586006ec`, `6219024e`) |
| **C-12** | **`monthlyEquivalentsTotalMoney` is a footgun by design.** It is deliberately filter-free ("the caller decides"), and the one caller that forgot produced F-027. Documented in tests rather than removed, since the unfiltered form has legitimate uses. | **MITIGATED** |

### Process finding
Working-tree gates are **not sufficient evidence**. During the partition they
passed while the committed tree did not compile (7 errors), and mid-run edits
silently invalidated three long suites. Every claim in this document that says
VERIFIED is verified at **committed HEAD in a detached worktree**, not in the
working tree.

---

## 9. PRIVACY & SECURITY RISKS

### 9.1 CRITICAL — the force-update guard is bypassable

`admin/app/api/announcements/route.ts:88-112` evaluates the guard on the **incoming payload only**;
it never reads the stored row. `armsForceUpdate` requires `severity==='force_update' &&
is_active===true` **in the same payload** (`announcement-guard.mjs:25-27`). `normalizePayload`
leaves absent fields `undefined`, and `JSON.stringify` drops them:

```
PATCH {id, is_active:true}  on a dormant force_update row
  payload.severity === undefined → guard passes, NO TOKEN
  severity not transmitted        → stays 'force_update'
  is_active → true                → ARMED
```
Symmetric bypass: `PATCH {id, severity:'force_update'}` on an already-active row.
Because `valid_until`/`min_app_version`/`max_app_version` normalize to `X || null`, those nulls **are**
transmitted — the accidental arm is also stripped of expiry and version bounds.

Effect: `app_shell.dart:1382` → `ForceUpdateScreen` blocks **all** navigation for **every** client.

**Status — FIXED, but C-2 is NOT closed.** `464816a6` closes both no-token bypasses: the guard now
judges the effective post-write row (stored ⊕ payload) and treats arming as a *transition*, so only
not-armed → armed demands the token. Three tests, all verified failing pre-fix.

**C-2a — OPEN.** `confirm_force_update` is still a **caller-supplied boolean**; the typed phrase
«تحديث إجباري» is enforced only in the React dialog. Any direct API call — curl, a script, a
compromised admin session — supplies `true` and arms. The guard now stops a *misclick*, not an
*actor*. **C-2 stays open until confirmation is server-enforced**: a trigger/RPC that refuses the
`severity='force_update' AND is_active` transition without a server-verified confirmation record,
plus an audit row per arm/disarm (§9.3 — no audit trail exists outside referrals).

### 9.2 CRITICAL — consent is dishonest (F-025, enlarged)

With cloud consent OFF and signed in, all of these leave the device (each verified to have **zero**
consent reads): accounts/planning/**ledger push and pull** incl. transactions · **`user_settings`
carrying `display_name`, `phone_number`, `date_of_birth`** (`planning_outbox_queue.dart:383-386`) ·
smart-inbox (pull gate is a hardcoded `() => true`, `app_providers.dart:1085`) · gamification +
engagement · notification logs · **sender→bank mappings — which banks the user uses**
(`sender_bank_mapping_sync_service.dart:61-88`) · `profiles.last_seen_at` · metrics ·
`feature_flag_overrides` · Sentry (`main.dart:25-26`) · encrypted **backup upload** (finding 6) ·
in-app AI parse with cloud OFF (finding 5).

The privacy screen promises «إيقافها يعطّل … والمزامنة» (`privacy_screen.dart:74-77`).
Two modules contradict each other on what the switch means (`ad_consent_service.dart:11` says
"analytics only"). **PDPL-scope exposure, live today.**

### 9.3 HIGH — admin blast radius
Every admin route uses **service-role** (`admin/lib/supabase-server.ts:27-36`). No audit trail
outside referrals. Flag PATCH forwards `value`/`rollout_percent` unvalidated
(`admin/app/api/admin-data/route.ts:93-97`). `requireAdmin()` throws are unmapped in the
announcements route → unauthenticated callers get **500, not 401**.

---

## 10. DATA-INTEGRITY RISKS

### 10.1 CRITICAL — an unvalidated admin regex writes confirmed money
```
parser_engine.dart:92    catalogRuleConfidence = 0.95        (applied :196)
add_transaction_usecase.dart:312  autoConfirmThreshold = 0.92 (:637 auto-confirms)
rules_client.dart:130-135  loads rules WHERE is_active AND NOT is_deleted
                           — NO validation_status filter
0004_parser_lab.sql:15     UPDATE sms_parsers SET validation_status='passed'  (blanket backfill)
```
→ **An admin-authored, never-validated regex sets confirmed money in user ledgers, unreviewed, on
the high-volume automatic capture path.** Enabled by landing F-016.

### 10.2 HIGH — card identity (F-032)
`updateCard` writes `card_last4` with **no validation** against the transaction's `account_id`
(`drift_transaction_repository.dart:366-386`); `moveToAccount` moves a card without touching its
transactions (`drift_card_repository.dart:184-209`). **No `card_id` column exists on transactions**
(verified). Reassigning a card orphans history — or silently re-attaches it to a *different*
physical card if the old account later gains the same last4.

### 10.3 Irreversible operations requiring rollback scripts
F-029 server-row repair · F-023 achievement reconciliation · F-032 `card_id` backfill ·
any force-update publish · the uncommitted backup-format change (verify old-backup restore first).

---

## 11–16 · ARCHITECTURE SECTIONS

**11.1 F-016 is a parser cutover.** 12 rules seeded (`0002_catalog_mvp.sql:545`) covering NBE, CIB,
Banque Misr, QNB, SNB, Rajhi, Riyad, STC Pay, Vodafone/Orange/Etisalat Cash, Fawry — the two primary
markets. They have never executed. Catalog rules **outrank** the 29 hardcoded profiles
(`parser_engine.dart:153-196`). Requires: a before/after corpus, F-011 enforcement, and a staged
rollout — note `parser_engine_version` **has no consumer**, so the gate must be built.

**11.2 ReDoS.** The isolate + 2s timeout + kill is real (`parser_isolate.dart:24,35,38`), but a
timeout nulls the **whole** ParseResult (`add_transaction_usecase.dart:374-381`) — one bad admin
regex silently disables the deterministic engine for that sender, with no metric and no kill switch.
The Lab and `parser-test` run the same regex with **no timeout at all**.

**11.3 Four deterministic parsers exist**: device engine+catalog · server `process-ios-sms` with its
own static `parser_rules.json` (catalog rules never reach the Shortcut path) · Swift `PreviewParser`
· compiled Lab. Two AI integrations with **opposite** arbitration order.

**11.4 F-015 is not Dart-only** — all 12 rules capture `(?<merchant>[^\n]+)`, and
`parser_engine.dart:170` takes the rule's group verbatim. Merchant normalisation must move into the
engine (one tested place) rather than living in admin-authored regex.

**12.1 Sync is mature but OFF** (§2, §4.2). **12.2 F-021's four defects:** the base-proof refresh
updates the *table* while the push guard reads the base from the *outbox payload*
(`planning_outbox_queue.dart:431-443`) · conflict→pending demotion strands rows permanently
(`accounts_pull_service.dart:258-271`) · three incompatible conflict-evidence semantics now coexist ·
`metadata` is pushed but excluded from the diff. **12.3 C-6 TOCTOU:** fetch-then-blind-update on all
three push services, while tombstones already use the correct atomic `.eq('updated_at', base)`.

**13 Flags/admin:** 3 live; delivery mechanism works incl. same-session invalidation
(`app_providers.dart:413-416`). **13.3 Gamification:** intersection ∅; server level
`floor(sqrt(xp/100))+1` (unbounded) vs client 5 fixed tiers; pull writes `level`, never `level_key`
(`gamification_sync_service.dart:142-145`) → «مبتدئ» forever.

**14 AI/ML recommendation: NO ADDITIONAL MODEL YET.**
Decisive fact: the AI cascade and the catalog authority are on **disjoint paths** — the automatic
drain passes `onDeviceOnly: true` (`app_shell.dart:934`) so AI never runs there; manual paste sends
**no senderId**, so `catalogRulesForSender` returns `[]` (`rules_client.dart:126`) and catalog rules
never load. Deterministic-first is therefore **already satisfied** on the automatic path; the
ordering defect is confined to manual paste (human-supervised).
The dominant capture gap is **content** (12 rules / 124 banks, zero credit rules) — authoring beats
modelling. A cloud cascade already covers fallback, merchant normalisation and categorisation; its
problems are **arbitration and grounding**, which an on-device model would inherit, not fix.
**Prerequisites before revisiting:** invert manual-paste ordering · make a matched catalog rule
immune to AI override for amount/currency · replace substring grounding with canonical-value +
currency comparison · close R-1 · grow the 4-case corpus into a real eval set. **W-001 stays design-only.**

**15 UI/UX:** 6 of 37 are duplicates of product findings; UX-034 blocked on F-032, UX-033 on R-1,
UX-013 on a balance read-model. Genuinely design-system: UX-002 (39 files with hardcoded
`Colors.black/white`), UX-001, UX-009, UX-012, UX-032. **"System before screens" holds for those**,
but UX-013 and UX-012 should jump the queue. Adopt R-8's formatter **before** any repaint.

**16 Testing:** 356 Dart files → 2,527 tests · 6 admin node suites · ~28 Supabase contract tests ·
**1** iOS test file · **0** Android. Missing automated gates, in priority order:
(1) admin→app propagation contract; (2) "pull never runs with consent OFF"; (3) multi-device
convergence; (4) fresh-environment bootstrap (`supabase db reset` + contract suite); (5) large-value
rendering goldens; (6) design-token lint; (7) fix the 4 load-flaky tests.

---

## 17. RELEASE STRATEGY

**The old plan named the wrong blocker.** Zero Distribution identities is *expected* — the repo is
shaped for managed CI signing (`MANUAL_RELEASE_PREREQUISITES.md:67-70`).

**The real hard blocker (R9 §0, omitted from the old plan):** `privacy_screen.dart:23-26` opens
`https://mali.youssefsafwat.com/privacy` and `/terms`. **Re-verified: NXDOMAIN** for that host and
the apex. Both a store blocker *and* a live dead link in the shipping build.

| Class | Items |
|---|---|
| **Code blockers** | C-1, C-2, C-3, C-4 |
| **Architecture blockers** | R-1, R-7 (capability activation) |
| **QA blockers** | fresh-env bootstrap, consent regression gate, parser corpus |
| **External-owner** | privacy domain · Distribution cert / ASC · extension provisioning · Android keystore · SENTRY_DSN · Google nonce · display name |

**Critical path:** partition tree → staging (DF-002) → migration+function rehearsal → internal build
→ device QA → beta → phased rollout. **All external-owner items start day 0, in parallel.**
Binary-level phased rollout works today; **feature-level kill switches do not** (only 3 flags live).

---

## 18–21 · SEQUENCING (re-derived from zero)

Weighting: data-loss > privacy/security > financial correctness > architectural deps > sync >
parser > release > testability > UX > cosmetic.

| Phase | Content | Why here | Effort | Risk |
|---|---|---|---|---|
| **A** | **Partition the tree.** ≥5 reviewed commit series, per-series gates, named merge target. Quarantine H-4 pull gates + NEW-H-3 consent for their own review. **Hold F-017 and F-021's pull half.** | Nothing may be built on an unbisectable 12.3k-line tree. Landing first is right; "½ day" is fiction | 1.5–2.5d | Med |
| **B** | **Stop the bleeding.** C-2 guard (effective-state + schema + DB trigger + audit) · C-1 (`validation_status` filter, decouple 0.95 from auto-confirm) · C-5 privacy URLs · **C-9 make dashboard reads pure** | Highest severity, all small, all independent. C-9 joins here because a read that writes corrupts every measurement taken after it | 2d | Low |
| **C** | **Environment truth.** DF-002 + DF-005 + fresh-env CI job | Additive SQL; unblocks a reproducible staging env that every later verification needs | 1d | Low |
| **D** | **Privacy (R-1).** One `ConsentAuthority` + egress inventory + network-recording acceptance test. Includes backup, AI-without-cloud, enrich-merchant | Live PDPL exposure. **Ship separately from any flag change** — both alter sync admission | 2–3d | Med |
| **E** | **Data integrity.** F-032 schema decision + `card_id` · F-029 repair migration · C-6 atomic guards · F-021 pull-half rework | Corruption writers; must precede transport activation | 3–4d | High |
| **F** | **R-7 capability activation.** Deploy/verify 0068 + 0077 → flip gates → un-park → re-verify on Main | The real gate on the cloud half. Must follow D and E | 2d | High |
| **G** | **Aggregation authority (R-2).** F-019, F-026, F-027, F-028 + UX-022/023 onto one scope policy | One change, ~7 findings | 2–3d | Med |
| **H** | **Parser (R-3 partial).** F-011 enforcement → F-016 staged cutover with corpus → F-015 in-engine → manual-paste arbitration → F-034 | Ordered by dependency; F-016 cannot precede F-011 | 3–4d | Med |
| **I** | **Config contract (R-3).** F-018 re-scoped · F-023+F-022 (R-5) incl. row reconciliation · R-4 version identity | R-4 also unblocks F-017's version fields | 2–3d | Med |
| **J** | **UX programme.** R-8 formatter → UX-013 + UX-012 early → UX-002 tokens + lint gate → screens | After the data is true | — | Low |
| **∥** | **Release track — from day 0** | External poles are the longest | — | — |
| **∥** | **W-001 design doc — anytime, no code** | Needs no code; decisions in H may pre-answer it | — | — |

**Entry/exit criteria (abbrev.):** every phase exits on: targeted regression test failing pre-fix ·
full suite green · `flutter analyze` clean · no unrelated diff. **E and F additionally require** a
paired rollback script and a staging rehearsal before production.

---

## 22. EXECUTION BOARD

| Order | Workstream | Findings | Depends on | Parallel with | Risk | Exit gate |
|---|---|---|---|---|---|---|
| 1 | Partition tree | — | — | Release, W-001 | Med | ≥5 series, each green |
| 2 | Stop the bleeding | C-1, C-2, C-5, C-9 | 1 | 3, Release | Low | bypass tests fail pre-fix; providers provably pure |
| 3 | Environment truth | DF-002, DF-005 | 1 | 2 | Low | `db reset` + contracts green in CI |
| 4 | Privacy authority | C-3/F-025 (+3 new) | 1, 3 | 6 | Med | consent OFF ⇒ only auth+catalog on the wire |
| 5 | Data integrity | F-032, F-029, C-6, F-021 | 1, 3 | 6 | High | rollback scripts + staging rehearsal |
| 6 | Aggregation | F-019/026/027/028, UX-022/023 | 1 | 4, 5 | Med | one scope policy; arch test |
| 7 | Capability activation | R-7 | 4, 5 | 8 | High | 0068+0077 verified; Phase-6 re-run on **Main** |
| 8 | Parser | F-011→F-016→F-015→F-034 | 2 | 7 | Med | corpus ≥ hardcoded baseline |
| 9 | Config contract | F-018 **+ C-10 server-side rollout**, F-023+F-022, F-024 | 3 | 8 | Med | key-diff test in CI; client and server agree on the same flag for the same user |
| 10 | UX programme | 31 real items | 6, 8 | — | Low | formatter + token lint first |

**Claude owns:** 1, 2, 4, 5, 9. **Parallelizable to a second agent:** 3, 6, 8, 10.
**Blocks production:** 2, 3, 4, 5, 7 + all external-owner items.

---

## 23–26 · GATES, ROLLBACK, EFFORT

**Required regression gates:** consent-egress harness · admin→app propagation contract · parser
before/after corpus · fresh-env bootstrap · multi-device convergence · money-rendering goldens ·
config key-diff · design-token lint.

**Rollback:** phases A–D and G–J are code-only and revertible. **E, F, and any migration touching
user data require a paired rollback script, a staging rehearsal, and a 30-day pre-image table.**
Force-update publishes are irreversible by nature — keep the C-2 guard in the release smoke.

**Effort:** ~20–26 engineering days to the end of phase I, excluding the UX programme and excluding
external-owner lead times.

---

## 27. OWNER DECISIONS REQUIRED

1. **F-020a — where do captured transactions land?** Pre-fix, browsing an account moved the default,
   so captures followed the viewed account. Post-fix they always land in the persistent default.
   Users may read this as "captures go to the wrong account". *Trade-off: least-surprise vs. not
   writing server state on a browse.*
2. **F-032 — `card_id` FK, or validated `last4`-within-account?** FK is correct but needs an
   irreversible backfill on live user data. *Blocks UX-034.*
3. **F-023 — which gamification system is authoritative?** Client's 6 achievements + 5 tiers, or the
   server's 3 + unbounded curve? They share nothing. *Requires a row-reconciliation migration.*
4. **F-016 rollout — how staged?** `parser_engine_version` has no consumer, so the gate must be
   built, or the cutover ships all-at-once for the two primary markets.
5. **Sentry under consent-OFF** — pair with R-1 or document in the privacy policy before submission.
6. **Privacy domain** — register `youssefsafwat.com`, or host elsewhere and change the two URLs.
7. **NEW-H-3** — is cross-device consent propagation intended? It reverses MALI-059n.
8. **F-019 — should budget *history* be account-scoped?** The snapshot tab filters; the history loop
   iterates the unfiltered list (`budgets_providers.dart:153`). Reviewers split on whether this is a
   bug or intent, and **no comment declares it intentional**. *Trade-off: consistency with the
   account-scoped ring above it vs. history being a global record.*
9. **ND-06 — cards and custom categories auto-resolve server-wins** (`conflict_policy.dart:182-196`,
   `deterministicPreferRemote`). Documented as deliberate — it only discards *this* device's
   un-pushed edit — but a **card reassignment or category rename can be silently dropped**, which
   interacts with F-032. *Confirm this is still the intended trade-off once cards gain real identity.*
10. **Does revoking consent require deleting already-uploaded cloud data?** No deletion/retention
    contract is expressed anywhere by the toggle (**NEEDS EVIDENCE**). PDPL-relevant; decide before
    the privacy copy is finalised.

### 27.1 Review coverage (state this when citing V2)

| Scope | Claude | Fable | Codex | Confidence |
|---|:--:|:--:|:--:|---|
| Sync / data integrity / F-020,021,029 | ✅ | ✅ | ✅ | **three-family** |
| Whole-plan architecture / sequencing | ✅ | ✅ | ✅ | **three-family** |
| Parser / capture / AI | ✅ | ✅ | ❌ quota | two-family |
| Privacy / flags / admin / F-017 | ✅ | ✅ | ❌ quota | two-family |

The two-family scopes contain C-1 and C-2 — the highest-severity findings here. Both were
**re-verified independently in source by Claude** (the auto-confirm chain and the PATCH bypass), so
neither rests on a single reviewer. They are not, however, three-family settled.

### 27.2 Review integrity notes
- **Claude was wrong four times** (F-018 count, F-019, F-026, F-030), each time by verifying that two
  surfaces call the same canonical helper without checking what each caller filters *before* the
  call. **Design consequence:** R-2 must mandate one canonical *input scope*, not merely one
  canonical function, or it re-diverges precisely there.
- **Codex cross-check pending.** Sections most likely to be amended: §12 (F-021 internals), §14
  (AI recommendation), §18 (sequencing).
