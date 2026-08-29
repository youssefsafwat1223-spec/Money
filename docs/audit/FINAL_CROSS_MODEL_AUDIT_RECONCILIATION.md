# FINAL CROSS-MODEL TECHNICAL AUDIT — RECONCILIATION

**Status:** FIRST PASS COMPLETE — reconciled, largely UNREMEDIATED
**Baseline:** branch `feat/phase1-data-integrity`, HEAD `12f36726`, clean tree at dispatch
**Date:** 2026-08-23
**Verdict:** **NOT RELEASE READY.** Three CRITICAL defects, independently confirmed at source.

---

## 1. Method

Six adversarial briefs were dispatched to OpenAI Codex (`codex-cli 0.145.0`) via the
delegate relay, plus two independent Claude coverage agents on the two highest-stakes
domains. Claude then reconciled every finding against primary source rather than
accepting any self-report.

| Reviewer | Domain | Sandbox | touchedFiles | Runtime |
|---|---|---|---|---|
| Codex 01 | financial: money + planning cutover | read-only | `[]` | ~20 min |
| Codex 02 | database / RLS / referrals / admin | read-only | `[]` | 24 min |
| Codex 03 | ads / UMP / export UX | read-only | `[]` | 19 min |
| Codex 04 | native platforms / vendored fork / signing | read-only | `[]` | ~25 min |
| Codex 05 | crypto / backup / deletion / security | read-only | `[]` | ~25 min |
| Codex 06 | tests / CI / phase-claim reconciliation | read-only | `[]` | ~25 min |
| Claude A | ad-gate reachability (coverage) | read-only | — | 12 min |
| Claude B | money invariants (coverage) | read-only | — | 22 min |

**Containment held.** Every Codex process ran under `-s read-only`, verified at the OS
process level, and every `result.json` reported `touchedFiles: []`. Zero contact with
production (`vrombzdgwqjjiijbidqb`) or evidence staging (`dpdukyozedajelflkeix`). No
migration applied, no function deployed, no flag flipped, no secret printed. No build ran.

**Reconciliation stance.** Claude verified each load-bearing citation itself. Where Codex
was wrong or overstated, this document says so and downgrades. Where Claude found the
reviewers had *understated* something, it escalates. Two findings concern Claude's own
prior work and are reported without softening.

---

## 2. CRITICAL findings (all three independently verified at source)

### C-1 — Editing a budget/goal/bill silently rewrites its stored amount
*Source: Claude coverage agent B (Codex's financial run missed this). Escalated High → CRITICAL.*

Money edit forms seed the text field from a **truncated** display string, then parse that
truncated text back as canonical money on save.

```
budget_form_screen.dart:473   _amountController.text = budget.amount.toStringAsFixed(0)   // ZERO decimals
budget_form_screen.dart:387   parseLocalizedMoney(_amountController.text, currency)
goal_form_screen.dart:400,404 toStringAsFixed(0)
bill_form_sheet.dart:162,172  toStringAsFixed(2) / toStringAsFixed(0)
bill_details_sheet.dart:313   toStringAsFixed(2)
allocate_income_sheet.dart:91,93
```

Open a 1500.50 SAR budget, press Save **without touching the amount** → stored
`amount_minor` becomes 150100. Silent +0.50 SAR, then pushed to the server by the outbox.
A 12.345 KWD bill becomes 12.350 on every edit *and* every recorded payment.

Why it is the worst finding: it fires on a **routine edit of ordinary data**, needing no
restore, no sync, and no unusual state. The correct pattern already exists in the same
codebase — `account_form_sheet.dart:111-112` uses shortest-round-trip `'$v'` and is
lossless — so the money forms are inconsistent with the app's own working pattern, not
deliberately designed.

Remediation: seed from `money.toDecimalString()`; add an edit-round-trip test per form;
extend the write-path guard to forbid `toStringAsFixed(` on any `kMoneyFields` getter.

### C-2 — "Export all Qirsh data" corrupts planning state on import
*Source: Codex 01 (F-01). Confirmed CRITICAL.*

Verified link by link:
1. The exporter emits only legacy REAL money — `t.amount`, `b.amount`, `target_amount`,
   `saved_amount` (`drift_financial_exporter.dart:27,314,345,417`). No `_minor` column
   appears anywhere in it. Budgets and goals additionally export **no `currency` column**.
2. The importer is **inconsistent**: it writes `_minor` for accounts(142),
   transactions(224), subscriptions(317), bill_payments(373) and plans(441) — but the
   budgets(282-300) and goals(394-412) INSERTs write neither `_minor` nor `currency`.
3. Those columns **are canonical**: `money_v30_backfill.dart:134-137` registers
   `budgets.amount_minor`, `budgets.last_notified_spent_amount_minor`,
   `goals.target_amount_minor`, `goals.saved_amount_minor`.
4. A canonical read **requires** non-null minor: `money_codec.dart:69-73` throws
   `MoneyStorageException('v30 read requires a minor value')`.

Import into a canonical DB therefore yields budget/goal rows whose authoritative money is
NULL. Planning reads throw; the canonical marker then covers non-canonical rows and
bootstrap throws (`planning_cutover.dart:81-89`). The per-row currency was never exported,
so **automatic recovery is impossible**.

### C-3 — Migration 0083 silently reverts the account-purge function
*Source: Codex 02 (H-01), independently re-found by Codex 05 (SEC-03). Escalated High → CRITICAL.*

`0083_referral_rewards.sql:1785` does `create or replace function public.purge_user_data`
and its body is annotated `-- Original 0065 body, unchanged`. The 0065 body was
forward-copied, **silently dropping the four deletions migration 0072 had added**.

Residual impact (Claude's own check, beyond what Codex enumerated):

| Table dropped from purge | Auth FK? | Survives account deletion? |
|---|---|---|
| `user_engagement_events` | `ON DELETE CASCADE` (0070) | No — rescued by cascade |
| `metrics_rate_limits` | none (0072) | **Yes** |
| `gamification_awarded_transactions` | none (0073) | **Yes** |
| `ai_request_idempotency` | none, PK `owner_key` carrying `u:<uuid>` (0071) | **Yes** |

The deletion saga (`purge-scheduled-deletions/index.ts:131-150`) then dequeues the user and
reports erasure complete while identity-bearing rows persist. This is a right-to-erasure
correctness failure, not merely a functional bug. Compounded by SEC-06/H-06: purge nulls
`target_user_id`/`target_ref` but retains operator-entered free text in `reason` /
`after_state`, which routinely contains emails, phone numbers or UUIDs.

**Remediation must be a forward migration (0084)** rebuilt from the 0072 body plus the
referral block — never another copy-forward.

---

## 3. Defects in Claude's own prior work (reported without softening)

### O-1 — Unterminated quote in `codemagic.yaml` — **FIXED in this pass**
Found independently by Codex 04 and Codex 06. Introduced by Claude during phase A2.

```sh
echo "Materialised keystore removed.      # <- no closing quote
```

With `set -eu`, bash fails to **parse** the block, so the step fails *and* the preceding
`rm -f` never runs — `android-release` could never complete, and the materialised upload
keystore was left in the runner workspace until teardown.

The existing tests asserted `rm -f` appeared as **text** and never validated the scalar as
shell — exactly the "asserts text, not behaviour" pathology this audit criticises
elsewhere. Fixed, and verified by extracting all 19 `script: |` scalars and running
`bash -n` over each (0 failures). The check was proven non-vacuous against the original
string before being trusted.

### O-2 — The "mandatory" Android compile gate is manual-only — **OVERCLAIM, uncorrected**
`grep -n "triggering:" codemagic.yaml` returns **nothing**: the file has no triggering
section anywhere, so every Codemagic workflow is manual-start. GitHub Actions runs
`ci_gates.sh` but never compiles Android.

Claude's R8C framing — "keeps an Android compile in the ordinary pre-release path"
(`android_ci_compile_gate_test.dart:9-11`) — is **false as written**. The compile happens
only if a human remembers to start the workflow. The R8C record and
`docs/FINAL_RELEASE_READINESS.md` must be corrected.

---

## 4. Where Claude disagreed with Codex

Findings were not passed through unchallenged.

| Finding | Codex | Claude verdict | Reason |
|---|---|---|---|
| Ads F1 | CRITICAL (ships TEST App ID) | **Split** | Codex conflated two defects; see below |
| CI-02 | HIGH (gate exits 0 with stages unavailable) | **MEDIUM** | Accurate on exit code, but the script is *not* silent |
| Ads F4 | HIGH (stale entitlement reuse) | **MEDIUM** | Impact bounded by the 5-min TTL; self-heals |
| Money F5 | Low | **Low, NEEDS_MORE_EVIDENCE** | Requires ~1e12–1e13 balances; agent said so honestly |

**Ads F1, split.** Codex's headline failure mode — CI shipping a production ad unit under
a test App ID — is **not reachable in CI**: `codemagic.yaml:281` supplies
`ADMOB_APP_ID_ANDROID` as a real Codemagic environment variable, so `System.getenv`
(gradle) and `String.fromEnvironment` (dart-define) receive the same value. That path
requires a *manual local* build passing only `--dart-define`. Downgraded to HIGH.

But Codex **under-weighted** the sub-finding, which Claude escalates to CRITICAL:
`build.gradle.kts:41,43` accept **any non-blank string with no shape validation**, and the
Google Mobile Ads startup provider is pre-Dart —
`MobileAdsInitProvider`, `android:initOrder="100"`, confirmed in the resolved
`play-services-ads-api-25.3.0` manifest. Strings extracted from the shipped SDK binary
confirm the validation exists: `"The Google Mobile Ads SDK was initialized without an
application ID"`, `"Application is missing a valid GADApplicationIdentifier"`,
`GADInvalidInitializationException`. **An operator typo in one Codemagic variable ships a
malformed app id into the manifest and crashes the app at launch, for every user, on every
launch — ads or not.** No Dart guard can defend this, because the provider runs first.

**CI-02, downgraded.** `unavail()` (`ci_gates.sh:53`) increments a counter and never sets
`fail`, so `exit "$fail"` returns 0 — accurate. But the script prints
`"! … UNAVAILABLE (reported separately, not a pass)"`, switches its final line to
`ALL RUN GATES PASSED (N unavailable)` versus `ALL LOCAL GATES PASSED` only when the count
is zero, and emits `CI_GATES_JSON {…"unavailable":N…}`. The real risk is an automated
consumer keying on exit code alone. This does **not** retroactively invalidate this
project's recorded "13/13 first-attempt green" claims, but every future green must be
quoted together with the unavailable count. Remediation: a `REQUIRE_ALL_GATES=1` strict mode.

**A Claude-only finding, honestly downgraded.** `report_export_ad_gateway.dart:74-75`
gates `preload()` on `_unitId` alone and never consults `isConfiguredFor`, so the gateway
in isolation would initialise the SDK against an empty iOS `GADApplicationIdentifier` and
crash. Claude then proved this is **not currently reachable**: the only two `preload()`
call sites (`report_export_coordinator.dart:148,179`) both sit behind `_adConfigAvailable`,
bound to `isConfiguredFor` at `report_ads_providers.dart:119-120`. Recorded as LOW /
defense-in-depth rather than inflated.

---

## 5. The systemic pattern

Findings across four independent domains share **one root cause**: an authoritative
definition was updated in one place while an older or partial copy survived elsewhere.

- 0083 forward-copied the 0065 purge body, dropping 0072's additions → **C-3**
- The `_minor` cutover reached 5 of 7 importer tables → **C-2**
- The money-write guard **exempts** `budgets`/`goals`/`goal_contributions` as
  "base-currency pending" (`money_write_path_guard_test.dart:6-12`) while
  `money_v30_backfill.dart:134-137` registers those same tables as canonical → the exact
  hole C-2 slipped through (TQ-06)
- Comments assert safety properties the code does not implement:
  `report_entitlement.dart:107-108` ("will not be returned as fresh anyway" — false for a
  within-TTL entry); `referrals/page.tsx:467` (`// one intent, reused on retry` — the UUID
  is a local variable regenerated per invocation)

**Why a 2218-test green suite coexists with three CRITICAL defects.** The money guards
cover schema completeness and SQL write adapters only. They do not cover (a) money leaving
`Money` into UI text and returning — C-1, (b) money-column *readers/predicates*, (c)
display formatting, (d) exception taxonomy on ingress. Every High/Medium money finding
sits in one of those four uncovered bands. Case-by-case patching will let this class
regrow; the fixes must include mechanical invariants (e.g. a test enumerating every
registered `V30MinorColumn` and asserting the importer writes it).

---

## 6. Full finding register

Severity is Claude's post-reconciliation judgement, not the reviewer's claim.

### CRITICAL
| ID | Finding | Evidence |
|---|---|---|
| C-1 | Edit forms silently rewrite stored money | `budget_form_screen.dart:473,387` |
| C-2 | Export/import corrupts canonical planning money | `drift_financial_importer.dart:282,394` |
| C-3 | 0083 reverts `purge_user_data()` | `0083_referral_rewards.sql:1785` |
| C-4 | Gradle accepts unvalidated AdMob app id → pre-Dart launch crash | `build.gradle.kts:41,43` |

### HIGH
| ID | Finding | Evidence |
|---|---|---|
| H-1 | Startup reconciliation reports failed backfills as success; sign-out then wipes | `startup_sync_reconcile_service.dart:57-72` |
| H-2 | Backfills stamp `synced` despite a monetary mismatch | `accounts_backfill_service.dart:156-177` |
| H-3 | Sign-out inventory counts outbox rows, not unsynced financial rows | `unsynced_inventory.dart:74-83` |
| H-4 | Exact-transport capabilities `unknown` but pulls hardcoded enabled | `app_providers.dart:1018-1025,457-460` |
| H-5 | No timeout anywhere on the ad path; one stalled callback bricks export | `report_export_ad_gateway.dart:73,79,105-127` |
| H-6 | Coordinator `try/finally` with no catch → accepted report never generates | `report_export_coordinator.dart:99-129` |
| H-7 | AdMob app-measurement auto-init runs before every consent gate | manifest:73-75, `Info.plist:99-100` |
| H-8 | SQLCipher key `read → deleteAll → write` is non-atomic; crash orphans the DB | `app_session.dart:679-687` |
| H-9 | Sign in with Apple omits the request-bound nonce | `supabase_auth_service.dart:54` |
| H-10 | Concurrent first entitlement grants collapse into one duration | `0083:593,652` |
| H-11 | Concurrent qualification + rule publication overwrites the pinned rule | `0083:708-720` |
| H-12 | Concurrent awards for distinct transactions lose XP | `0074:96,105-108` |
| H-13 | Admin operation IDs regenerated on retry despite a comment claiming reuse | `referrals/page.tsx:467` |
| H-14 | Purged users' PII survives in admin audit `reason`/snapshots | `0083:1812-1816` |
| H-15 | Codemagic release builds bypass the canonical gate | `codemagic.yaml:339-355` |
| H-16 | O-2: Android compile gate is manual-only | no `triggering:` in `codemagic.yaml` |
| H-17 | O-1: unterminated quote broke `android-release` | `codemagic.yaml:308` — **FIXED** |
| H-18 | iOS cloud-consent revocation not propagated/enforced server-side | Codex 04 #1 — **REFUTED (Batch 16)** |
| H-19 | Closed-app Shortcut captures can be permanently lost after 30 days | Codex 04 #2 — **CONFIRMED → remediated (Batch 17)** |
| H-20 | Restore can commit, report rollback, and tell the user nothing changed | SEC-05 |
| H-21 | v4 snapshots may omit most tables and produce a partial merge | SEC-06 |
| H-22 | Restored financial rows can be wiped before ever syncing | SEC-07 |
| H-23 | Backup encryption state shared across accounts | SEC-02 |
| H-24 | Account deletion leaves previous/orphaned backup objects | SEC-04 — **CONFIRMED → remediated (Batch 16)** |

### MEDIUM (selected — the release-relevant ones)
`MONEY-F4` dedup matches the REAL shadow with float equality → duplicate SMS ingested
twice · `MONEY-F6` v30 full-table exact postflight re-runs on every app open and is
fail-closed (DB can become permanently unopenable) · `MONEY-F7` restore fidelity check
sums the legacy REAL column with a 1e-6 epsilon, so it cannot detect corruption of the
authoritative column · `MONEY-F3` unsupported (non-null) server currency escapes the pull
quarantine → planning sync permanently dead · `MONEY-F2` 22 files hardcode 2-decimal money
display; KWD's third digit is invisible app-wide · `MONEY-F8` income allocation splits in
doubles; `Money.allocate` is correct and has zero production call sites · ads
F3/F4/F5/F6/F7/F8 · M-01 code rotation breaks admin lookup · M-02 fraud reversal leaves
orphaned progress · CI-02 · TQ-01…TQ-07 · MIG-01 · DOC-01 · SEC-10…SEC-16.

---

## 7. What is NOT verifiable without violating containment

Live schema/RLS/ACL state, actual pgcrypto installation schema, cron activation, Edge
deployment state, secret presence or values, live Postgres race reproduction (all
concurrency findings are statically derived), real-device SDK callback behaviour under
interruption, resolved `Info.plist`/merged manifest inside a signed artifact, AdMob console
ownership, and store policy outcomes. All remain external evidence.

---

## 8. Remediation status

Remediation proceeds in small dependency-aware batches. Every batch is verified before the
next begins, and **every new guard is proven to FAIL on the original defect** before it is
trusted — a test that has never failed proves nothing, which is how most of these findings
survived in the first place.

| Batch | Scope | Status | Verification |
|---|---|---|---|
| 0 | Documentation corrections (O-1/O-2/L-01) | **DONE** | docs only, no product code |
| A | O-1 `codemagic.yaml` shell-syntax fix | **DONE** | all 19 `script:` scalars `bash -n` clean; check proven non-vacuous |
| 1 | **C-1** money edit forms | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 6 new guards · 161 feature tests green · guard proven to fail on the bug |
| 2 | **C-2** export/import canonical money | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 39 portability tests green · 2 new tests proven to fail on the bug |
| 3 | **C-3** + **H-14** purge completeness | **REMEDIATED_PENDING_SECOND_PASS** (source-only) | migration lint 0001..0084 · 180 node tests pass / 0 fail · 6 new guards proven non-vacuous |
| 4 | **C-4** + **H-5** + **H-6** + A1 ad path | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 74 report_ads tests green · 10 new tests proven to fail on the bug |

> **Classification note.** No finding in this document is CLOSED. Every remediated item is
> **REMEDIATED_PENDING_SECOND_PASS**: the fix exists in source and is verified by targeted
> tests, but final closure requires (a) a full regression run and (b) the mandatory Codex
> second pass against the remediated tree. Nothing here is device-proven.
| 5 | **H-1 + H-2 + H-3** sync false-success → sign-out data loss | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 474 sync/session/capture + 208 settings/backup tests green · 18 new lifecycle tests · all three guards proven to fail on pre-fix code |
| 6 | **H-8** SQLCipher key atomicity / crash window | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 456 db/session/backup/settings + 69 architecture + 6 privacy + 9 key-state + **24 crypto-prod** (13m15s, serialized) tests green · 11 new fault-injection tests · guards proven to fail on pre-fix behaviour |
| 7 | **H-4** exact-transport capability authority (strict: UNKNOWN fails closed both directions) | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 508 sync/session/capture + 96 app-shell/startup/architecture tests green · 25 new authority tests · UNKNOWN-pull guard proven to fail against the earlier permissive implementation |
| 8 | **H-9** Apple Sign-In nonce binding | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 89 auth/session/onboarding + 69 architecture + 27 app-shell/startup tests green · 21 new tests · 7 proven to fail on the pre-fix nonce-free flow |
| 9 | **H-7** AdMob init vs UMP authority — **premise REFUTED**, ordering pinned, C-4 refined | **REMEDIATED_PENDING_SECOND_PASS** (downgraded HIGH → LOW) | analyze clean · 161 report_ads/architecture + 65 app-shell/settings/report tests green · 18 new guards · 3 properties proven to fail on pre-fix behaviour · Gradle configuration validated (exit 0) |
| 10 | **H-22** restored rows wiped before syncing — re-verification | **SUPERSEDED_BY_BATCH_5 / CLOSED_PROVEN_PENDING_SECOND_PASS** | proof-only; 14 tests, zero production changes |
| 11 | **H-20 + H-21** restore integrity family | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 217 backup/restore + 105 session/settings/portability + 69 architecture tests green · 19 new tests · 3 fixes each proven to fail on pre-fix code |
| 12 | **H-23 + S-1** backup crypto account isolation | **REMEDIATED_PENDING_SECOND_PASS** | analyze clean · 234 backup/restore + 68 session/deletion/H-8 + 69 architecture tests green · 17 new tests · both fixes proven to fail on pre-fix code · no format/crypto change |
| 13 | **H-10 + H-11 + H-12** SQL absent-row locking family | **REMEDIATED_PENDING_SECOND_PASS** · 0085 **SOURCE-ONLY / LOCAL-POSTGRES-VERIFIED / NOT APPLIED REMOTELY** | 0085 source-only · migration lint 0001..0085 · 11 contract tests (8 fail without 0085) · node suite 191/0/69 · **LIVE concurrency proof on local PG 15.19: pre-fix 7/11 (defects reproduced), post-fix 11/11, 10/10 stress runs, 0 deadlocks** · throwaway cluster destroyed |
| 14 | **H-13** admin operation idempotency | **REMEDIATED_PENDING_SECOND_PASS** (client-only; NO migration) | typecheck clean · lint clean · admin build OK · 66 admin tests (9 new behavioral, proven to fail on pre-fix) · server idempotency verified complete → no 0086 |
| 15 | **H-15 + H-16** CI authority / release-gate enforcement | **REMEDIATED_PENDING_SECOND_PASS** (CI config) · **REMOTE_CI: PENDING_PUSH** | YAML valid · 17 new structural contract tests (proven to fail on pre-fix config) · ci_gates.sh strict run GREEN (deps-policy gap fixed) · 86 architecture + node 191/0/69 + ci_gates contract 5/5 · **not verified on a real remote run** |
| 16 | **H-18** cloud-consent revocation + **H-24** account-deletion Storage orphans | **H-18 = REFUTED** (server-authoritative + propagated); **H-24 = REMEDIATED_PENDING_SECOND_PASS** (edge-only; NO migration) | H-18 traced end-to-end (no change). H-24: saga now sweeps the user's whole `<uid>/` prefix. deno check + lint clean · 7 new fake-store Deno tests (untracked-sibling assertion proven to FAIL on pre-fix single-path removal) · node suite 191/0/70 · live prefix-sweep harness EXISTS, credential-gated, **NOT RUN** (validation-staging auth required) |
| 17 | **H-19** closed-app Shortcut capture durability | **REMEDIATED_PENDING_SECOND_PASS** (iOS App Intent one-line fix; NO migration) · **PHYSICAL CLOSED-APP EVIDENCE = PENDING_DEVICE** | Root cause: App Intent DELETED the durable App Group copy on backend success, leaving the 30-day-swept relay as the only copy. Fix: retain it as `.sent` so the existing per-item-lease drain imports it (locally if the relay is gone). analyze clean · 244 capture tests green · 5 new durability tests (relay-expiry recovery, idempotency, dup, cloud-off) · Swift source-contract guard flipped (fails on pre-fix `remove`). Sibling sweep: Share Extension + Android queue clean (ack-based, no age sweep) |
| 18+ | remaining HIGH findings + **N-2** (backup CAS) + **N-3** (campaign double-create) | **NOT STARTED** | — (**H-17** = Codemagic unterminated quote already REMEDIATED from Batch A — not reopened) |

### What changed

- **C-1** — five money forms now seed from `<entity>.<field>Money.toDecimalString()`
  instead of a rounded display double. New guard forbids the whole class
  (`toStringAsFixed` reaching a `TextEditingController` via a money getter) and proves the
  seed↔parse round-trip is exact for 2-, 3- and 0-decimal currencies, negatives, and
  values beyond 2^53.
- **C-2** — the exporter now emits `currency` for budgets/goals; the importer writes the
  canonical `_minor` columns for budgets, goals **and** goal_contributions, resolving the
  currency from the row, else the parent goal, else the device base currency. Pre-fix
  packages still import canonically. New test asserts *no planning row may carry a NULL
  canonical minor after import*.
- **C-3 / H-14** — **`supabase/migrations/0084_purge_user_data_restore.sql`**, rebuilt from
  the *0072* body plus 0083's referral block, restoring all four dropped deletions and
  extending audit de-identification to `reason` (redacted — it is `NOT NULL` with a length
  CHECK), `before_state` and `after_state`. New contract test folds every migration in
  order and fails if any re-definition deletes fewer tables than its predecessor; 0083 is
  recorded as an exact, known historical regression that 0084 must repair.
- **C-4 / H-5 / H-6** — Gradle now validates the AdMob application id and **fails the
  build** on a malformed value or an explicit test-publisher id in release (a typo
  previously shipped an app that crashed at launch via the pre-Dart
  `MobileAdsInitProvider`). The gateway bounds initialize/load/show, releases its in-flight
  flag in `finally`, no longer strands the discarded `load()` Future, and can finally
  return `lifecycleInterrupted`. The coordinator catches ad-stage failures so a broken SDK
  can never withhold the user's report.

- **H-1 / H-2 / H-3 (Batch 5)** — the data-loss chain, fixed as one unit because the
  failure modes compose. Full lifecycle traced: startup → backfill → success/failure
  persistence → retry → sign-out → wipe.
  - `ReconcileOutcome` gained **`partial`**, plus `isProvenComplete` / `shouldRetry`.
    `ran` now means *every row is positively proven persisted*; the three backfill reports
    are consulted instead of discarded. `app_shell` retries on `partial` as well as
    `failed` (previously a half-finished backfill latched the one-shot flag for the session).
  - A detected money mismatch is **never** stamped `synced` in any of the three backfills.
    It lands in `sync_status='conflict'` — the existing durable state where
    `accounts_pull_service` refuses to overwrite and the keep-mine/keep-theirs picker can
    resolve it non-destructively. The planning backfill previously accepted a pre-existing
    remote row with **no field comparison at all**; it now compares money exactly, and a
    parse failure counts as a mismatch (uncertainty never resolves to "proven").
  - `UnsyncedInventory` gained `unprovenFinancialRows` (server_id NULL, not queued, not
    deleted — mirroring `hasUnsyncedLocalData()` so the two cannot drift) and
    `unresolvedConflicts`. Both block a silent wipe and are named in the Arabic warning.
  - The pre-sign-out flush now attempts a **reconcile** first: outbox pushes can only drain
    queued intents, and these rows never had one, so the user gets a real chance to persist
    before being asked to discard.
  - **Sign-out is still possible.** This surfaces and requires explicit confirmation
    (cancel / discard-and-sign-out); it never vetoes. Soft-deleted rows are excluded so the
    guard cannot become a permanent blocker, and no server-side retention was added.
  - Account-switch isolation verified: `_didReconcile` already resets on any session
    change, now pinned by a test.
  - *Test-definition change, stated explicitly:* the old
    "a clean, fully-synced database reports nothing pending" case asserted the **weaker
    outbox-only** rule and broke under the corrected definition, because a fresh DB carries
    the migration-seeded default account with no `server_id`. That row was already treated
    as unsynced by `hasUnsyncedLocalData()` and is named in the reconcile service's own
    docstring, so counting it is consistent with the system's existing definition. The test
    was rewritten to prove the original intent (*proven*-synced ⇒ nothing pending) and a
    second case now asserts the seeded row is reported until backfilled.
  - *Observation, not fixed (out of Critical/High scope):* the `plan_transaction_links`
    backfill still accepts a pre-existing remote row without comparing `deleted_at`, so a
    remotely-deleted link could be stamped synced. No money is involved; recorded for a
    later batch.

- **H-8 (Batch 6)** — the SQLCipher key crash window. Full lifecycle traced: creation →
  secure-storage persistence → DB open → lookup → wipe → deletion → restart.
  - **The window.** `wipeAndReset()` was `read(dbKey) → deleteAll() → write(dbKey)`.
    Between the delete and the write, the encrypted DB existed on disk with no usable key.
    A process kill *or a failing `write`* there made the data unrecoverable:
    `classifyDatabaseKeyState` correctly reports `keyUnavailable`, but nothing can open it.
  - **Fixed structurally, not by re-ordering.** The key is now **never deleted**, so the
    dangerous state is unreachable by construction. `deleteAll()` — which cannot exclude a
    key — is gone from production code and a guard forbids its return. Every interruption
    now degrades to "some non-key entries survive", which is recoverable by re-running.
  - The sweep enumerates storage (`readAll`), unions a deterministic fallback list for
    platforms that cannot enumerate, deletes, then **verifies against storage** and retries
    survivors. A permanently failing entry raises
    `SecureStorageWipeIncompleteException` — requirement 5 means a wipe that left
    credentials behind must not look like success. In-memory session state is reset to
    signed-out *before* the throw, so the app stays in a safe state.
  - **Both destructive callers** (`privacy_screen` account deletion, `settings_screen`
    reset-all) share the same shape: `DataWipeService.wipeAll()` empties the tables in ONE
    transaction, then `wipeAndReset()` clears storage. The encrypted file always survives
    by design, which is why the key must too — preserving it retains no sensitive data.
  - `signOut()` was verified separately: it deletes only named keys, never the DB key and
    never `deleteAll()`. **Batch 5 interaction checked** — the reconcile added to
    `flushPendingForSignOut()` runs *before* the local wipe, so no new ordering window was
    introduced between financial preservation and cryptographic cleanup.
  - Requirement 7 preserved and pinned: `keyUnavailable` (DB present, key absent) remains
    distinguishable from `freshInstall` (neither present); no path mints a new key over an
    existing database. Requirement 6 preserved: the owner uid/generation markers are
    destroyed even though the device-scoped key survives.
  - **Backup crypto untouched** (requirement 9): H-8 did not require any envelope or
    backup-key change, so none was made.

- **H-4 (Batch 7)** — capability authority vs. actual transport.
  - **The core contradiction, and it was worse than reported.** The startup backfills are a
    PUSH path that serializes canonical money as **exact decimal strings**, yet they never
    consulted `shouldParkExactMoneyWrite` — the predicate every outbox push service honours.
    Under Batch 5 that let an unauthorised transport mark rows `synced` and report `ran`
    (proven-complete). Now gated, returning the new
    `ReconcileOutcome.blockedUnverifiedTransport` — non-proven, retryable, and defaulting to
    `unknown` so a caller that omits the capability fails **closed**.
  - **Pull had no seam at all.** `accountsPullServiceProvider` shared the push predicate
    (`() => true`) and `ledgerSyncServiceProvider` was `isPullEnabled: () => true`, so
    "explicit false must disable" was *unimplementable* — an `unsupported` transport could
    not be switched off; every row would throw and wedge the cursor. All money-bearing pulls
    now route through `exactPullAllowed`.
  - **Planning pull leaked past its own gate**: only the three planning-currency entities
    were constrained; every other money-bearing entity (subscriptions, plans, bill_payments)
    short-circuited to `true`. The capability now applies to the whole pull.
  - **Pull authority is POSITIVE-PROOF ONLY — symmetric with push.** `verifiedExact` may
    run; `unsupported` and `unknown` must not, in BOTH directions.
    - An intermediate Batch-7 iteration permitted pull under `unknown`, reasoning that the
      throwing `moneyFromPulledValue` decoder made it self-verifying. **That was rejected on
      review and reversed:** decoder strictness proves *payload safety*, not *transport
      authority* — "we will refuse a bad payload" is a claim about this client's decoding,
      not about the transport having been verified end-to-end. Only positive proof may
      enable a financial transport.
    - The strict decoder remains, and is still asserted by test, as an independent second
      line of defence — with an explicit test that it does **not** unlock the gate.
    - **Accepted consequence:** financial cloud pull (accounts, ledger, planning) stays
      DISABLED while the capability is `unknown`. That is intentional. Activation is a
      separate reviewed release decision and was NOT performed to preserve behaviour.
  - **A skipped pull advances no cursor** (requirement 6). Verified by position in all three
    services: the enable check precedes every `readSyncCursor`/`writeSyncCursor`, so pull
    resumes correctly once the capability is proven — `accounts_pull_service` and
    `ledger_sync_service` return before any cursor access, `planning_pull_service` `continue`s
    past the entity before its cursor read.
  - **Smart Inbox exemption re-validated, not inherited**: it contains no
    `moneyFromPulledValue`, `::text`, `kMoneyCodec`, `_minor` or `Money`. A guard now fails
    if it ever gains one, forcing the exemption to be revisited.
  - **Requirement 7 — races are structurally absent, not merely unobserved.** There is no
    capability discovery mechanism: all three are synchronous constant Providers, resolved
    identically on first read. Nothing can be uninitialized, stale, mid-refresh, or fetched-
    and-failed. A guard now forbids adding an async/mutable path without a race review.
  - **Requirement 4 preserved**: guards forbid the capability file referencing
    `FeatureFlagService`, rollout percentages, remote config or local prefs, and forbid
    inferring capability from local schema/cutover state. Activation is a reviewed code
    change — the safest model for financial authority, not a gap to close with a flag.
  - Requirement 10 honoured: all three capabilities still return `unknown`, `kServerRevisionCas`
    still `false`; a guard fails if any provider is switched to `verifiedExact`.
  - `smartInboxSyncServiceProvider` was examined and deliberately left alone — it carries no
    money, so gating it on a money transport would be incorrect.

- **H-9 (Batch 8)** — Apple Sign-In nonce binding.
  - **The defect:** `getAppleIDCredential` received no `nonce` AND `signInWithIdToken`
    received no `nonce` — there was no cryptographic binding at either end, so a
    still-valid Apple identity token minted for this app carried no per-attempt challenge
    and could be replayed to the public auth endpoint for its whole validity window.
  - **Fixed end-to-end**, not just at the Supabase call: a per-attempt 32-byte
    `Random.secure()` nonce is generated, `SHA-256(raw)` (lowercase hex) goes to the
    authorization request, and the RAW value goes to the token exchange, which re-hashes and
    compares against the token's `nonce` claim.
  - **Concurrency/staleness:** the nonce is function-scoped, so two concurrent attempts can
    never share or overwrite one another's value — cross-attempt contamination is impossible
    by construction rather than by guarding. A monotonic `_appleAttemptSeq` additionally
    re-checks supersession after BOTH awaits (the system sheet and the exchange), so a stale
    attempt completing late cannot establish a session behind a newer one. Cancellation is
    now typed (`AuthCancelledException`) instead of surfacing as an opaque error.
  - **Secret hygiene:** nothing is persisted (no secure storage, no prefs) and the file has
    no log sink at all; guards forbid interpolating the nonce or identity token into a
    string.
  - **Google deliberately unchanged** and pinned by test: the native Google SDK hashes its
    own nonce inside the `id_token` and never exposes the raw value, so it has nothing to
    send — adding a nonce there would break sign-in rather than harden it.

  #### ⚠️ Provider-configuration finding (requirement 4/10) — docs corrected, remote config untouched

  `skip_nonce_check` is a **per-provider** setting (`[auth.external.<provider>]`), so the
  Google requirement never implied it for Apple. Before this fix Apple sent no nonce, which
  made the setting look irrelevant for it. **After this fix, enabling "skip nonce checks" for
  Apple would leave the new binding unverified server-side and make the client fix
  cosmetic** — re-opening token replay.

  Three runbooks stated "Skip nonce checks = ON" in tables that mix Google and Apple rows,
  without scoping it. All three now state **ON for Google only / OFF for Apple**:
  `FINAL_RELEASE_READINESS.md`, `PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md`,
  `MANUAL_RELEASE_PREREQUISITES.md`. Local `supabase/config.toml` already has
  `skip_nonce_check = false` under `[auth.external.apple]`, which is correct; a test now
  pins it. **No remote Auth configuration was changed and no project was contacted.**

- **H-7 (Batch 9) — the reported premise did not survive verification. Downgraded HIGH → LOW.**

  H-7 claimed the Google Mobile Ads SDK "begins sending user-level event data to Google
  immediately" at process start, upstream of every consent gate, and that the fix was
  `DELAY_APP_MEASUREMENT_INIT` (Android) / `GADDelayAppMeasurementInit` (iOS). Verified
  directly against the SDKs google_mobile_ads 9.0.0 actually ships:

  | Claim | Evidence | Verdict |
  |---|---|---|
  | `GADDelayAppMeasurementInit` mitigates iOS | Absent from the GMA 13.3.0 binary's string table, where `GADApplicationIdentifier` IS present | **Not supported** — adding it is a no-op |
  | `DELAY_APP_MEASUREMENT_INIT` mitigates Android | Absent from every `play-services-ads*` 25.3.0 jar | **Not supported** — adding it is a no-op |
  | Ads SDK links analytics | `play-services-ads-api:25.3.0` → `play-services-measurement-sdk-api:20.1.2` | **True**, but that artifact declares **zero** components (no provider/service/receiver) — linked, not started |
  | `MobileAdsInitProvider` sends data at process start | Disassembled: `onCreate()` returns `false` immediately; `attachInfo()` reads app metadata, logs the OPTIMIZE_* flags, reads `APPLICATION_ID`, validates it, then calls `super` | **Refuted** — no network, no measurement, no initialization |

  Adding either key would have been decoration implying a protection the SDK does not
  provide — precisely the unsupported hack the brief forbids. **Nothing was added.**

  What the process-start provider DOES do is validate the manifest app id against
  `^ca-app-pub-[0-9]{16}~[0-9]{10}$` and throw `IllegalStateException` on a mismatch — which
  independently **confirms C-4** and revealed a **refinement**: the C-4 Gradle gate and the
  Dart `_appIdShape`/`_unitIdShape` were LOOSER than the SDK (`\d{10,22}~\d{6,12}`), so a
  value could pass our validation and still crash at launch. Both now match the SDK exactly;
  all four Google test identifiers were confirmed to satisfy the tightened shape first.

  The property that genuinely matters — and is genuinely ours — is the ordering, now pinned:
  ads-off release return → `ensureGathered()` → privacy-options refresh → `maybePreload()`
  (flag + config + entitlement + `canRequestAds`) → the single `MobileAds.instance.initialize()`
  call site → load → present. Guards assert there is exactly ONE initialize call site, that
  it sits behind `isConfiguredFor`, that consent precedes preload, that a disabled feature
  returns before UMP *and* before preload, that failure stays fail-open, and that UMP remains
  sole authority (no `adConsentState`, no ATT). QA hooks (`UMP_DEBUG_FORCE_EEA`,
  `UMP_DEBUG_TEST_DEVICE`, `REPORT_ADS_TEST_OVERRIDE`) are re-proven release-inert.

  Because the native evidence is VERSION-SPECIFIC, a guard pins `google_mobile_ads: 9.0.0`
  exactly (no caret) — an SDK bump invalidates this analysis and must re-run it.

  **Build validation:** `gradlew --offline help` under JDK 17 / Gradle 9.1.0 / AGP 9.0.1
  configured successfully (exit 0), evaluating the modified `build.gradle.kts`. That is
  configuration-scope validation appropriate to a build-script change — **no full APK build
  was run, and none is claimed.**

- **H-20 / H-21 (Batch 11) — restore integrity family.**

  **H-20 — the commit/reporting lie, and a privacy defect underneath it.**
  `RestoreBackupUseCase.call()` did post-commit work (FK re-enable assertion,
  `_postRestoreMigrations`) *inside* the region `restore_service` wrapped with
  `on BackupException`/`catch (_)` → `markRolledBack` + `rollbackCompleted`. So a
  post-commit failure told the user their data survived when it had been replaced —
  **and overwrote the in-transaction committed marker that restart recovery depends on.**

  Underneath it: `runPostRestoreSetup()` is **privacy-required**, not convenience. It resets
  `ai_consent_granted` / `cloud_processing_enabled` / both consent states (MALI-059n) so a
  restore cannot import consent as authorization on a new device. Running post-commit meant a
  crash in that window committed restored data **with a legacy backup's consent flags
  intact**. It now runs INSIDE the transaction (after verification, so plan semantics are
  unchanged).

  Three layers, strongest first:
  1. `markRolledBack` gained `AND committed_at IS NULL` — the storage layer now refuses to
     relabel a committed operation, protecting *every* caller rather than trusting each site.
  2. `_terminal()` consults the journal before reporting rollback — covering post-commit
     failures this batch did not enumerate (lease release, teardown), since the in-transaction
     marker is the durable authority.
  3. A typed `RestoreCommittedPostStepException` (step name only, no data) maps to
     `committedPendingAcknowledgement` + a `post_restore_step_incomplete` warning. **Nothing
     is swallowed** — the failure is reported, just truthfully.

  **H-21 — v4 completeness.** A table absent from the snapshot is skipped by the conditional
  DELETE (`if (!tables.containsKey(table)) continue;`), so its LIVE rows survive and merge;
  and `expectedRowCounts` is derived only from tables that ARE present, so verification never
  checked it. An omitted `budgets`/`goals`/`plans`/`cards` committed as a *successful full
  restore* that was really a partial merge. Only `transactions` was accidentally protected
  (its check uses `?? 0`, so surviving live rows tripped the count).

  Semantics chosen: **option 1 — required, rejected in preflight.** Re-derived from source,
  the builder always writes a key for every `backedUpTables` entry (empty list when the user
  has no rows), so v4+ now requires every KEY to be present. An **empty list stays legal** —
  that is a genuinely complete snapshot of a user with no such rows; "absent" is never
  inferred to mean "optional". Rejection happens in `validateTables`, **before the first
  DELETE** (PART 3).

  **PART 6 — older formats keep their own semantics.** The contract is v4+ ONLY. v2/v3
  legitimately omit tables (a v2 backup carries no cards/categories/sender_bank_mappings) and
  are unchanged; a test asserts the same table set validates under v3 and is rejected under
  v4, so an old partial format is never silently reinterpreted as complete.

  **PART 5 — H-22 protection intact.** A test asserts restored rows still report
  `unprovenFinancialRows > 0` after a successful restore, and that the backup format still
  carries no `server_id`/`sync_status`/`synced_at`/`server_updated_at` — the warning was not
  made to disappear by restoring sync columns.

  **PART 8 — sibling sweep: clean, no new Critical/High.** The Qirsh package import already
  enforces completeness (`decodeQirshPackage` throws on any missing table CSV) and writes its
  `financial_import_runs` idempotency marker INSIDE the transaction, so it has neither the
  commit/reporting lie nor partial-snapshot acceptance. Observation only: it validates rows
  during insert rather than up front, which is safe because the whole import is transactional.

- **H-23 / S-1 (Batch 12) — backup crypto account isolation.**

  **H-23 — the leak.** All seven backup-crypto keys (`backup_enabled`, `backup_salt`,
  `backup_recovery_code`, `backup_local_key`, `backup_key_slots`, `backup_envelope_version`,
  `backup_last_at`) were device-global with no owner, and `AppSession.signOut()` clears
  session keys but not these. So after A enabled backup, signed out, and B signed in,
  `backupNow()` still saw `backup_enabled == '1'` and encrypted **B's data with A's content
  key** — whose slots are wrapped by A's passphrase and recovery code — then uploaded it under
  B's path. A could decrypt B's backup; B was "protected" by a secret they never chose.

  **Fix — account binding, still device-scoped, no format change.** A new local
  `backup_owner_uid` marker binds the cached crypto to one account. The decision is a pure,
  exhaustively-tested function (`classifyBackupStateOwnership`) that is **fail-closed**: only
  a matching explicit owner is `owned`; a different owner is `foreign` (never used, never
  surfaced as enabled, and deliberately NOT deleted so the other account can sign back in);
  pre-owner-binding state is `adoptable` only by the identity that owns the local database
  (the same authority the sync backfills use), and every ambiguous combination is `foreign`.
  Wired into `backupNow` (the critical gate, before any key read), `status`, `enable`
  (records owner), restore (binds to the restoring account), and clear (retires the marker).

  **No recoverability lost:** key slots are serialized into the blob itself, so a restore
  needs only the blob plus the passphrase or recovery code — never this cache. The marker is
  device-local bookkeeping and is never uploaded (asserted by test against `uploadMetadata`).

  **H-8 interaction checked:** this service never touches `SecureDatabaseKeyStore` or the DB
  key; the H-8 preserve-across-wipe behaviour is unchanged (68 deletion/key-state tests green,
  incl. the H-8 atomicity suite). Backup crypto is NOT made to survive like the DB key.

  **S-1 — WRITE-NEW → VERIFY → RETIRE-OLD.** The v2/legacy-v3 restore branches deleted
  `_envelopeVersionKey` FIRST; a crash there left the version marker gone with no successor,
  an ambiguous state that changes how the next restore reads the material. Every branch now
  establishes all successor values, verifies they are readable (fail-closed on a bad
  read-back), and only then retires superseded markers — so no interruption produces a
  half-migrated state and an envelope is never "upgraded" until the migration is committed.
  Modelled boundaries: before writes (old intact), after some writes (old markers still
  present, re-run completes it), before/after retirement.

  **Scope discipline:** no public backup format or version was redesigned, and
  `backup_crypto.dart` was not touched — so the crypto-prod suite was not required, and old
  v2/v3/v4 backups remain restorable (asserted by the existing compatibility suite, 234
  backup tests green).

- **H-10 / H-11 / H-12 (Batch 13) — SQL absent-row locking family.**

  **✅ LIVE-PROVEN on a local ephemeral Postgres (2026-08-23).** Under separate authorization
  a throwaway PostgreSQL 15.19 cluster was stood up **local-only** (unix socket, no TCP, no
  Docker, zero remote contact), seeded from the **real** table DDL + real function bodies, and
  driven by a deterministic concurrency harness (hold txn A open → poll `pg_stat_activity`
  until txn B is genuinely lock-blocked → commit A → assert). Results:

  | | pre-fix (0083/0074) | post-fix (0085 applied) |
  |---|---|---|
  | H-10 concurrent first grants | **7 days** (defect) | **14 days** ✓ |
  | H-12 concurrent distinct awards | **xp=10, 2 claims** (ledger says 2, aggregate says 1) | **xp=20** ✓ |
  | H-11 open-cycle pin under V2 publish | **pinned V2** (defect) | **pinned V1** ✓ |
  | idempotency / existing-row extend / duplicate claim | all correct | all correct |
  | **total** | **7/11** | **11/11** (10/10 stress runs, 0 deadlocks) |

  The absent-row case *is* the tested scenario (every race starts from an empty authority
  row). No deadlock, serialization failure, or search_path/permission error appeared in the
  server log. The cluster and the Postgres package were destroyed afterward (leak-checked;
  disk 17.4 → 16.8 GiB, all postgres artifacts removed). **0085 was applied ONLY to that
  disposable local DB — never to staging or production.**

  Status: **H-10 / H-11 / H-12 = REMEDIATED_PENDING_SECOND_PASS**; 0085 = **SOURCE-ONLY /
  LOCAL-POSTGRES-VERIFIED / NOT APPLIED REMOTELY.**

  **Root cause (shared):** `SELECT ... FOR UPDATE` locks nothing when the target authority
  row does not exist yet, so two concurrent "first" transactions both read empty state and a
  later `ON CONFLICT DO UPDATE` writes one's precomputed value over the other's.
  - **H-10** (`apply_entitlement_mutation`): two first grants both compute `now()+7d`; the
    second overwrites the first's `ends_at` → 7 days instead of 14, though the ledger shows
    two grants.
  - **H-11** (`qualify_referral_internal`): two first qualifiers both take the awaiting-rule
    branch; with a rule publish between their reads, the loser's `ON CONFLICT` overwrites the
    winner's pin → the open cycle counts a V1 qualification but is governed by V2.
  - **H-12** (`award_gamification_for_transaction`): the claim serializes per *transaction*,
    but the XP read-modify-write is on the per-*user* row and was unlocked → two
    distinct-transaction awards write +10 instead of +20. **Severity: MEDIUM-HIGH** — real
    lost-update integrity corruption, but XP is not money.

  **One primitive for the class** (`supabase/migrations/0085_...sql`, source-only, ordered
  after 0084): `pg_advisory_xact_lock` on a deterministic per-authority key, taken before the
  read. It needs no existing row (fixing the absent-row case by construction), releases at
  commit/rollback, and each function takes exactly ONE lock, so lock ordering is uniform and
  no deadlock cycle is introduced. H-11 additionally gets a conditional `ON CONFLICT ... WHERE
  cycle_state='awaiting_rule'` so an already-open pin is never overwritten (belt-and-braces on
  top of the lock). Idempotency is untouched and independent (same op-id still collapses to
  one mutation; distinct op-ids each apply once).

  **Fidelity:** 0085 `CREATE OR REPLACE`s the three functions, reproducing their bodies
  **verbatim** (proven line-by-line: the only non-injected divergence is the intended H-11
  `ON CONFLICT` line) plus the injected lock. It never edits applied history (0083/0074
  untouched — 0083's pre-existing publisher advisory lock is unrelated). SECURITY DEFINER,
  each function's original `search_path`, and the locked-down ACLs are all preserved; no
  privilege broadened. The 0084-before-0085 rollout order is documented in the file.

  **Note (not changed, surgical discipline):** `award_gamification_for_transaction` uses
  `SET search_path = public` (vs the hardened `pg_catalog, public, pg_temp` on the newer
  functions). Preserved verbatim; hardening it is a separate concern, not folded into a
  concurrency batch.

  **N-2 (NEW, reported not fixed — same class).** Sibling sweep of every `FOR UPDATE` site
  found `0076_backup_generation_cas.sql`: the CAS read `SELECT * FROM backups WHERE
  user_id=… FOR UPDATE` locks nothing on an absent row, so two concurrent FIRST backups both
  pass the compare-and-set on a stale empty read and the `ON CONFLICT (user_id) DO UPDATE`
  lets the second silently overwrite the first's pointer — the whole point of the CAS
  (`stale_generation`) never fires. Only the first-backup race; once a row exists, `FOR
  UPDATE` serializes correctly. Consequence: a losing device's backup pointer is overwritten
  (its blob orphaned in storage, recoverable next cycle) instead of getting a typed
  `stale_generation`. Same fix shape (advisory lock on `user_id`). **Severity ~MEDIUM;
  reported per requirement 14, not auto-fixed.** Lower-risk candidate also noted:
  `0083` admin `rotate_code` (`referral_codes … status='active' FOR UPDATE`) — admin-only,
  claim-guarded, low concurrency; not confirmed a defect.

- **H-13 (Batch 14) — admin operation idempotency. Client-only fix; no migration.**

  **The defect was 100% client-side.** Every admin mutation already routes through
  `referral_admin_claim` (or `apply_entitlement_mutation`), which is idempotent per
  `operation_id`: same id + same fingerprint → `claimed:false` no-op; same id + **different**
  payload → `idempotency_mismatch`. But the referrals page minted `crypto.randomUUID()`
  **inside every handler**, so a lost response → operator retry → **new id → the server saw a
  new intent and mutated twice** (grant added duration twice, publish created V+1 and V+2,
  rotation retired another code). The header comment ("minted once per intent, reused on
  retry") was aspirational, not real.

  **Requirement 16 satisfied — NO 0086.** Verified every RPC's idempotency boundary at
  source (and `apply_entitlement_mutation` live in Batch 13). The server guarantees are
  already sufficient; the fix belongs entirely in the client.

  **Intent-state architecture** (`lib/operation-intent.mjs`, a pure state machine, + a thin
  `useOperationIntent` React `useRef` wrapper):
  - `begin(key)` returns a stable id while the same intent is unresolved; a changed `key`
    (action / target / days / progress / reason / rule params) is a NEW intent → new id.
  - `resolved()` is called ONLY on a **KNOWN** outcome. Outcome classification
    (`outcomeKnown`): transport failure (fetch threw) or **5xx** → UNKNOWN, id **preserved**
    for safe retry; **2xx/4xx** → definitive, intent resolved. `api()` was extended to
    surface `status` + `transportError`.
  - Held in a ref, so re-render / data refresh / loading-state changes never disturb the id
    (requirement 8); a genuine remount ends the lifecycle. The client keys the id by payload,
    so it can never send same-id-with-different-payload (the server guard remains as
    defence-in-depth).

  **Mutation inventory** (**10** distinct actions — corrected from an earlier "all 8"
  miscount — all now single-id-per-intent): the 6 `ManualActions` (grant · extend · shorten ·
  revoke → `admin_mutate_entitlement`; adjust_progress; rotate_code), the 2 `ReferralAction`
  (reject · reverse), and the 2 rule actions (publish · deactivate) — every one gated by
  `referral_admin_claim`. Routes are
  admin-guarded, forward `operation_id` unchanged, and never regenerate it (verified: zero
  `randomUUID` in `app/api/`).

  **Tests (behaviour, not format):** 9 new cases simulate the real lifecycle — the central
  lost-response-after-success retry (reuses id → server no-ops), gateway 5xx (unknown → reuse),
  rapid double-submit, edited-payload = new intent, deliberate-repeat-after-success = new id,
  confirmed-rejection resolves, re-render stability, and exactly-once across grant/publish/
  rotate/adjust. **Proven non-vacuous:** the pre-fix "always mint" behaviour fails 5/9
  including all three core scenarios. Audit behaviour (requirement 12) is correct by
  construction: the server's `referral_admin_claim` writes ONE audit row per operation_id and
  returns the prior `after_state` on a duplicate — no misleading duplicate success records.

  **N-3 (NEW, MEDIUM, reported not fixed — same class, different tier).** Sibling sweep of the
  whole admin app (requirement 15): the only `operation_id` generation was the referrals page.
  But `POST /api/campaigns` inserts into `growth_campaigns` with a server-generated UUID PK,
  **no operation_id and no natural unique key**, so a lost-response retry **silently creates a
  duplicate campaign**. Same H-13 class, but catalog content (not financial/entitlement) →
  **MEDIUM**. Coupons are protected (`slug UNIQUE` → a retry fails loudly, fail-safe); flags/
  banks/categories/parsers are toggles/edits (idempotent by nature). Reported per requirement
  15, not fixed.

- **H-15 / H-16 (Batch 15) — CI authority / release-gate enforcement. CI config only; not remotely verified.**

  **H-15 — release workflows bypassed the canonical gate.** All three artifact-producing
  Codemagic workflows (`ios-unsigned-sideload`, `ios-signed-release` → TestFlight,
  `android-release` → Play) ran only `flutter analyze && flutter test` — a thin subset —
  then went straight to sign/build/submit. No workflow invoked `tools/ci_gates.sh` (the
  canonical authority GitHub Actions already runs). A backend/SQL/crypto/admin regression
  the canonical gate catches would pass a release and produce a signed artifact.

  **Fix (requirement 4 — one authority, not duplicated).** Each artifact workflow now runs
  **`REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`** as a mandatory step placed BEFORE any
  signing material, build, or submission. Codemagic aborts the workflow on a non-zero step,
  so a gate failure structurally makes provisioning / keystore / build / TestFlight / Play
  **unreachable** (proven by structural ordering tests). The `ios-signed-release` gate
  precedes `Build signed IPA` + `submit_to_testflight`; the `android-release` gate precedes
  keystore materialisation + the AAB build; the release AAB build is itself the mandatory
  Android *release* compile.

  **CI-02 closed as part of this.** `ci_gates.sh` gained `REQUIRE_ALL_GATES=1` strict mode: a
  tool-missing UNAVAILABLE (deno/node/admin not set up) becomes FATAL, so a release gate
  cannot hollow-pass with mandatory stages silently absent. A new `external()` classifier
  keeps genuinely-provenance-gated stages (iOS packaging without a built Runner.app;
  deliberate `SKIP_FLUTTER_TEST`) non-fatal even in strict mode — never counted as PASS
  (requirement 9). A2's fail-closed signing is untouched.

  **H-16 — the Android compile gate never ran automatically.** `backend-and-quality-gates`
  (the sole Android-compile coverage) had no `triggering:` block → manual-only. It now
  auto-triggers on **push + pull_request** to `main`/`master`/`develop`/`feat/*`, with a
  `changeset` exclusion for `docs/**` and `**/*.md` so an Android build is not spent on a
  README edit. It also now runs `ci_gates.sh` (replacing its hand-duplicated subset —
  requirement 4) plus the fatal Android debug compile. Release workflows deliberately keep
  NO trigger, so an ordinary PR/push can never sign, submit, or distribute (requirements 10,
  11) — verified by test. No store upload was added to the quality workflow.

  **⚠️ Finding surfaced by the strict run (pre-existing, now fixed): the deps-policy gate went
  STALE when the vendored fork entered the tree.** Chronology matters here, and an earlier
  draft overstated it — the accurate sequence is:
  - Canonical `ci_gates.sh` runs on the source tree **before** the R8B `file_picker` fork was
    vendored may legitimately have been green — those historical records are not invalidated.
  - When R8B added `../third_party/file_picker` as a path dependency, it was never added to
    `tools/check_deps_policy.sh`'s `APPROVED_PATH_DEPS`, so the deps-policy gate became
    **stale** relative to the new tree.
  - From that point, a **fresh** canonical run on the later tree would **fail** deps-policy —
    which is what this Batch-15 strict run surfaced (prior "gate green" claims made *after*
    the fork landed were therefore not reproducible).
  - The vendored fork is audit-sanctioned (it MUST resolve from the path, never pub.dev —
    QIRSH_FORK.md), so the allowlist now explicitly recognises it.

  After the fix, `ci_gates.sh` runs GREEN in strict mode.

  **Validation (requirement 18):** YAML parses (ruby), all 17 modified shell scalars
  `bash -n` clean, `git diff --check` clean, 17 new structural contract tests (parse
  codemagic.yaml with `package:yaml`, no whitespace scans) — **proven to fail on the pre-fix
  config** — plus 86 architecture tests, node 191/0/69, ci_gates contract 5/5, and a real
  local strict `ci_gates.sh` run GREEN. **REMOTE CI is NOT verified** — no push is
  authorised, so the triggers and gate ordering are proven in configuration only.

  **Batch-15 FOLLOW-UP (strict-gate hardening).** Three concerns were closed:
  1. **`SKIP_FLUTTER_TEST` was a release escape.** Under strict mode it was a non-fatal
     `external` state, so a release caller could bypass the mandatory Flutter tests. The
     broad `external()` bucket was split into three classifiers that **preserve the reason in
     code** (requirement 7): `unavail()` (tool missing → strict-fatal), `caller_skipped()`
     (a bypassed mandatory test → strict-fatal, "not evidence"), and `artifact_pending()`
     (genuinely can't run pre-build → deferred, never strict-fatal). SKIP_FLUTTER is now
     `caller_skipped`: **strict+skip exits 1** (verified), while normal/portable mode keeps
     the historical fast path (skip reported, non-fatal, never counted as PASS).
  2. **The artifact-dependent gate now has a mandatory POST-BUILD counterpart** (requirements
     3/4/5). The iOS packaging/provenance gate cannot run in the pre-build pass (no built
     Runner.app), so it is `artifact_pending` there — and both iOS workflows now run
     `stamp_ios_provenance.sh` + `verify_ios_packaging.sh` on **the artifact THIS run
     produced**, after the build and before packaging/submission. A missing artifact or a
     missing/mismatched provenance / packaging regression aborts the step, so
     `submit_to_testflight` is unreachable. `android-release`'s post-build signer inspection
     was confirmed intact (requirement 6).
  3. **The three EXTERNAL stages from the prior run, named** (requirement 1): (A) `flutter
     test bulk (SKIP_FLUTTER_TEST=1)` and (B) `flutter test crypto (SKIP_FLUTTER_TEST=1)` —
     both **caller-skipped** (they appeared only because that run set the flag; a real
     release does not) — and (C) `ios packaging (no built Runner.app)` — **artifact-dependent**,
     now with its post-build counterpart.

  The follow-up's stamp→verify flow was NOT executed end-to-end locally (no iOS artifact is
  buildable here) — only its wiring, ordering, and script syntax were validated; it is
  config-ready / pending-remote like the rest of the batch.

  **Batch-15 ARTIFACT-IDENTITY follow-up.** A sharper review found the post-build verify
  targeted the wrong file: `flutter build ipa` produces BOTH the archive's Runner.app
  (`build/ios/archive/.../Runner.app`, "A") and the exported IPA (`build/ios/ipa/*.ipa`,
  "C"); Codemagic submits **C**, but the step validated **A** — and the provenance sidecar
  lives *outside* the bundle, so it isn't in C either. Validating A while submitting C does
  not prove the submitted artifact (A ≠ C). Fixed with a shared
  `tools/verify_ios_release_artifact.sh <final.ipa>` that (1) records the **sha256** of the
  exact IPA that will be distributed, (2) extracts its `Payload/*.app`, and (3) runs
  `stamp_ios_provenance.sh` + `verify_ios_packaging.sh` on **that payload** — so the thing
  verified is the thing submitted. `ios-signed-release` now points it at `build/ios/ipa/*.ipa`
  (the same path Codemagic submits); `ios-unsigned-sideload` verifies the packaged
  `money_companion-unsigned.ipa` **after** packaging. **Signature safety:** the submitted IPA
  is never modified — extraction + stamping happen on a throwaway temp copy; the sidecar is
  external; the submitted bytes (sha256 logged) are unchanged. Proven locally end-to-end on a
  synthetic IPA (hash + payload extraction + verify all execute). The binding is
  same-path + no-intervening-mutation + recorded hash — **CONFIG_PROVEN**; a real signed IPA
  from a Codemagic build is **REMOTE_ARTIFACT_BINDING_PENDING_PUSH**.

  Status: **H-15 / H-16 = REMEDIATED_PENDING_SECOND_PASS (CI config)**; **REMOTE_CI_EXECUTION
  = PENDING_PUSH / NOT VERIFIED.**

### Sibling sweep (requirement 11) — reported, NOT remediated

Searched for equivalent non-atomic delete/replace patterns across the SQLCipher key,
device secret, install identity, auth/session credentials, and backup crypto material.

| Area | Verdict |
|---|---|
| Install identity (`install_id.dart`) | **Clean** — read-or-create, never deletes |
| Auth/session credentials (`signOut`) | **Clean** — individual named deletes, no replace |
| Planning-currency repair marker | **Clean** — deletes only its own marker |
| Backup key state (`_persistKeyStateAfterRestore`) | **S-1 — REMEDIATED in Batch 12** (write-new → verify → retire-old) |

**S-1 — MEDIUM — REMEDIATED_PENDING_SECOND_PASS (Batch 12).** `encrypted_backup_service.dart`
`_persistKeyStateAfterRestore` previously had a **v2/legacy-v3 branch that deleted
`_envelopeVersionKey` FIRST**, then wrote salt/local key — a crash in that window left the
envelope version absent while the local key was still the superseded value. Impact was
bounded (the backup salt travels inside the blob and the passphrase is user-supplied, so
restore stayed possible by re-entering it — no user data destroyed), but it was fixed as
part of the H-23 batch rather than deferred: the method now **writes all new material,
`verify()`s it is readable, and only then `retire()`s the superseded markers**, so no
interruption can leave an inconsistent key state (see the Batch-12 closure above and the
`_persistKeyStateAfterRestore` contract at `encrypted_backup_service.dart:504-559`).
Fault-injection coverage is in `backup_account_isolation_test.dart`. **Status:
REMEDIATED_PENDING_SECOND_PASS — no S-1 code change in this regression.**

### Batch 16 — Privacy / erasure completion (H-18 REFUTED · H-24 CONFIRMED → remediated)

**H-18 — cloud-consent revocation not propagated / enforced server-side — REFUTED.**
Traced consent end-to-end from the current tree; the premise no longer holds, so no fix was
made (per instruction: do not fix a premise that no longer exists).
- **Server is authoritative and read fresh per request.** `resolveVerifiedIdentity`
  (`_shared/ai_endpoint.ts`) reads consent live — the device path from `capture_devices`
  (`ai_consent_granted`, `cloud_processing_enabled`, and `revoked_at` → hard
  `credential_revoked`), the user-JWT path from `user_settings` — and fails closed on a
  missing row. `consentError` blocks the request when the relevant grant is false. Every
  processing endpoint enforces it: `parse-sms` / `bank-discovery` (`kind='ai'`),
  `enrich-merchant` (`kind='cloud'`), and `process-ios-sms` independently re-reads
  `ai_consent_granted`/`revoked_at` so a client `allowAi` can never override a server OFF.
- **Revocation propagates.** Toggling the privacy switch calls `_setConsent` →
  `syncBackendState` → `set-device-consent`, which **writes** `capture_devices`
  (`ai_consent_granted`, `cloud_processing_enabled`); OFF is pushed explicitly. The push is
  re-driven at app startup (`bootstrap_runner`), on resume (`app_shell`), and on each sync
  (`capture_sync_service`), with best-effort retry. There is no "UI toggle changes only local
  state" gap.
- Scope is correct: device consent is per-device (`capture_devices`), user consent per-user
  (`user_settings`). Multi-device revocation is device-scoped by design.
- **Observation (not H-18):** `sync-captures` uses `verifyDevice` (no `revoked_at` check),
  but it only *delivers already-processed* captures back to the owning device — no new cloud
  processing — so it is not a consent-enforcement gap.

**H-24 — account deletion leaves orphaned backup Storage objects — CONFIRMED → remediated
(edge-function only, NO migration).**
The durable deletion saga (`purge-scheduled-deletions`) removed only the single
`backups.blob_path`. But the active v3/CAS backup path (MALI-076n, migration 0076) publishes
each backup as a **new per-generation object** under `<uid>/g/<gen>.enc`, and its own source
comment states *"An interrupted upload can only orphan a new object"* and *"retire the
previous object ONLY after the new pointer commits"* (a best-effort **client-side** delete).
A deleted account's `<uid>/` prefix can therefore retain: the previous generation (un-retired
after a crash/offline), **interrupted-publish orphans referenced by NO DB row at all**, and
any legacy `<uid>/backup.enc`. The Storage bucket RLS (migration 0001) scopes ownership to
the whole `<uid>/` prefix, not one object name — so these are all user-owned, passphrase-
recoverable blobs surviving "erasure." A DB-pointer cleanup (even one extended to
`previous_object_path`) fundamentally cannot see the uncommitted orphans.

- **Fix** — `supabase/functions/_shared/storage_erasure.ts` (`eraseBackupObjects`): the saga
  now **sweeps the user's whole `<uid>/` prefix** — the exact server-authoritative ownership
  boundary the bucket RLS defines, keyed on the queue row's `user_id` (not a broad guess) —
  recursing into `g/`, removing every object, unioned with the tracked `blob_path`. It is
  **fail-closed** (any real list/remove error keeps the step incomplete → the SQL purge does
  NOT proceed and the queue row retries), **idempotent** (empty/absent prefix = success), and
  **non-truncating** (paged to exhaustion + recursive; no silent cap). The saga's Step-1 wire
  and header comment were updated; failure-stage label `remove_storage_blob` preserved for
  operator continuity.
- **Erasure-ordering invariant preserved.** Storage is Step 1; a Storage failure `continue`s
  and never reaches the SQL purge (Step 2) or auth deletion (Step 3), so the DB purge cannot
  claim erasure while a recoverable object may remain.
- **Proof** — `deno check` + `deno lint` clean on all changed TS. `_shared/storage_erasure_test.ts`
  (7 fake-store Deno tests, all green): sweeps untracked siblings, recurses into sub-prefixes,
  pages past one page, removes the tracked path when listing omits it, and surfaces both a
  list error and a remove error (fail-closed). The core untracked-sibling assertion was
  **proven non-vacuous** — it FAILS against a reconstructed pre-fix single-path helper and
  passes only with the sweep. Full supabase node suite **191 pass / 0 fail / 70 skipped**
  (no regression). A credential-gated **live** harness
  (`supabase/tests/account_deletion_storage_erasure_live_harness.mjs`) reproduces the
  multi-object orphan on real Storage and asserts the prefix ends empty; it **EXISTS and
  SKIPS cleanly** and was **NOT RUN** — running it mutates a project, which requires explicit
  validation-staging authorization (production `vrombzdgwqjjiijbidqb` / evidence staging
  `dpdukyozedajelflkeix` retain ZERO contact).
- **No migration.** The fix is entirely in the edge function + a shared helper; `0086` was
  proven **unnecessary** and was not created. `0084`/`0085` remain untouched.

### Batch 17 — Closed-app Shortcut capture durability (H-19 CONFIRMED → remediated)

**H-19 — a closed-app Shortcut capture can be permanently lost after 30 days — CONFIRMED.**
Traced the full closed-app path from the App Intent to Drift import.

- **Data-loss chain (cloud ON).** The "Process Bank SMS" App Intent
  (`BankMessageShortcuts.swift`) correctly writes a durable App Group copy
  (`status: .pendingSend`) *before* the network call. But on backend **success** it then
  **deleted that copy** (`SharedCaptureStore.remove(payloadID:)`), on the assumption that the
  server relay row in `processed_captures` is now the copy. That relay row is swept
  **unconditionally at 30 days** by `run_prune_processed_captures()`
  (`DELETE FROM processed_captures WHERE created_at < NOW() - INTERVAL '30 days'` — daily
  pg_cron, **not** gated on import/delivery/ack). So: Shortcut runs while the app is closed →
  local copy deleted on success → APNs shows "captured" → user does not open Flutter for
  >30 days → the relay row is pruned → next open's `sync-captures` returns nothing → the
  transaction the user was told was captured is **gone**.
- **Everything else was already correct.** The App Group store is a per-item lease
  (`peekPendingPayloadsJSON` never deletes; Dart `acknowledgeSharedMessage` removes only after
  a committed Drift import); the `app_shell` drain pulls the relay FIRST and then **imports
  locally, on-device**, anything the pull did not; imports are atomic and deduped by a
  permanent `capture_payload:%` marker (explicitly exempt from `pruneOldDedupHashes`). The
  single deletion at success defeated all of it.
- **Fix (iOS App Intent, one line; NO migration, NO server change).** On backend success the
  intent now `updateStatus(payloadID:, status: .sent)` instead of removing — the same durable
  state the cloud-OFF and backend-unreachable paths already use. The host drain then imports
  it (from the relay if still present, else locally on-device) and only THEN acks/removes it.
  The shared payloadId dedups to one transaction; `.sent` tells the drain the notification is
  already owned (no duplicate banner). This makes the *client* the durable authority and lets
  the server relay stay a 30-day ephemeral relay — the intended architecture (§4/§17: not a
  bigger TTL). `0086` was **not** created; `0084`/`0085` untouched.
- **Cloud-OFF / consent (§5/§12).** Cloud-OFF already persists `.sent` and imports locally —
  unchanged. A retained `.sent` copy imported locally after consent revocation uses the
  on-device parser only (AI is fresh-consent-gated both client- and server-side, per Batch 16)
  — no unauthorized cloud processing under an old grant. `retryPendingSend` re-checks
  `cloudProcessingEnabled` fresh and falls back to local when revoked.
- **Crashes / idempotency (§8/§10).** Persist-before-network; atomic import + permanent
  payloadId marker; ack only after commit. Same payload retried, crash-after-commit-before-ack,
  and relay-expiry-then-local-recovery all collapse to exactly one Drift row.
- **Ownership (§11).** Local import runs under `OwnershipGuard` (admission token re-validated
  before commit and before any banner); a capture cannot import into the wrong signed-in
  account. Sign-out/account-switch `purgeUserOwnedState()` still wipes pending copies (fail
  closed); the fix neither regresses nor widens that (a still-signed-in unopened app is the
  H-19 case, and it is now durable).
- **Proof.** `flutter analyze` clean · **244 capture tests green** · new
  `test/features/capture/closed_app_capture_durability_test.dart` (5 tests: retained-copy
  survives relay expiry → one import; pre-fix removed-copy → documented loss; relay-present →
  one import, local acked; crash-after-commit idempotent; duplicate execution → one). The
  sweep boundary is **injected** (`Relay.sweepAll()`), so no 30-day wait is needed. The Swift
  source-contract guard `testShortcutRetainsDurableCopyOnBackendSuccess` asserts the intent
  retains (`updateStatus(.sent)`) and does **not** `remove` — it fails against the pre-fix
  source. **Physical closed-app device evidence = PENDING_DEVICE** (no iPhone available; the
  full iOS test build was not run to avoid an unrelated pod build).
- **Sibling sweep (§16).** The iOS Share Extension (`ShareViewController.swift`) enqueues a
  durable `.pending` copy and never removes early — clean. Android `DurableCaptureQueue`
  removes only on Flutter ack (no age-based sweep); it has a bounded `MAX_ITEMS` drop-oldest
  **capacity** cap (not time-based — a documented backlog tradeoff, not an H-19-class defect).
  The only age-based sweep in the system is the server relay's 30-day prune, which is now
  correct given a durable client copy. No new Critical/High siblings.

### Second-pass remediation round (R1–R10) — SOURCE-COMPLETE, CODEX RE-VERIFICATION BLOCKED

The 12 Codex-second-pass Critical/High findings were remediated by Codex (implementer) under Claude
(orchestrator) review, each in its own dependency-aware batch, independently gate-verified with a
non-vacuous test:
- **C-2** exact export/import transport (canonical `*_minor`, lossy REAL = documented legacy fallback).
- **NEW-C-1** account form seeds canonical Money; form-seed guard extended to accounts.
- **H-2** backfill compares balance_after/foreign/planning-null-currency; mismatch → conflict not synced.
- **H-4** planning child sync gets a distinct fail-closed pull capability; blocked pull = no query/cursor/sync.
- **H-24** storage erasure: `<uid>/`-prefix validation (cross-user delete closed), 2-scan convergence,
  chunked removes, no depth wedge, post-Auth terminal sweep; `{complete,retryable}`.
- **H-18** full-revocation propagation (no early return) + `process-ios-sms`/`ai_endpoint` enforce
  `cloud_processing_enabled` master gate + `revoked_at`, fail-closed, before any processing.
- **H-19** unprocessable captures persist as durable Smart Inbox review items before ack (idempotent,
  onDeviceOnly, ownership/crash-safe).
- **H-20 + H-23** backup `enable()` writes material→verify→owner→enabled-last (fail-closed); post-commit
  key-state failure → typed `committedPendingBackupState` (never "no change"/rollback), retryable.
- **H-13** admin operation_id persisted in per-tab sessionStorage keyed to payload; survives remount;
  cleared on definitive completion.
- **H-5** global finite deadline around the whole ad opportunity (incl. `ad.show()`); fail-open to report; one opportunity.
- **NEW-H-1** single-IPA enforcement + build-time provenance bound to sha256+commit; verify-not-synthesize; publish the exact verified path.
- A follow-up updated one stale `backend_hardening_contract_test.mjs` source-scrape assertion to the
  new (strictly stronger) consent contract.

Combined local regression **GREEN**: strict `ci_gates` (migrations, deno all-functions+lint, analyze,
flutter bulk 2448 + crypto-prod 24, node contract 191/0/70, skip-manifest, admin auth, l10n, all arch
guards, deps) + admin tsc/lint/build. iOS packaging = artifact-pending; Android build TOOL_UNAVAILABLE
(no JDK); iOS Swift full build not run (sandbox); external/live evidence still pending.

**Codex re-verification then RAN (three challenge→remediate→regress rounds):**
- **Codex verification round 1** accepted 5 (H-4, H-5, H-13, H-20, NEW-H-1) and REOPENED 7 with deeper
  residuals (C-2, NEW-C-1, H-2, H-18, H-19, H-23, H-24). All 7 re-remediated in batches RB1–RB5 + a
  stale-test follow-up; round-2 combined regression GREEN.
- **Codex verification round 2** accepted H-2, H-23, H-24; RECLASSIFIED H-19 → MEDIUM (High last-copy loss
  fixed; residual = backend OTP-misclassification review-spam); REOPENED C-2, NEW-C-1, H-18; found my RB4
  had REGRESSED H-20; and found NEW-H-2 (capture-sync cross-account admission race). The two Criticals
  needed human product decisions (currency change/merge) — the user chose FAIL-CLOSED: NEW-C-1 = disallow
  currency change on an in-use account; C-2 = quarantine mismatched-currency contributions on merge. All 5
  (C-2, NEW-C-1, H-18, H-20, NEW-H-2) re-remediated in batches RC-A/B/C; round-3 combined regression GREEN
  (12/12 gates, flutter 2476+24/1-skip, node 266/196/0/70, migration lint 0001..0086).
- New source-only migration **0086_backups_owner_liveness.sql** (H-24 pre-deletion-JWT barrier: a
  SECURITY DEFINER `backups_owner_is_live()` in the backups-bucket INSERT/UPDATE RLS). 0086 SOURCE-ONLY,
  not applied remotely; 0 historical migrations modified.

**CURRENT STATE / BLOCKER (stop-condition B):** every reopened/new Critical/High (C-2, NEW-C-1, H-2, H-4,
H-5, H-13, H-18, H-19→Med, H-20, H-23, H-24, NEW-H-1, NEW-H-2) is now source-remediated and
Claude-gate-verified with the round-3 combined regression GREEN — BUT the **Codex verification of the
round-3 batch could not complete** (Codex/ChatGPT usage limit, resets ~Sep 1). So the round-3 fixes are
**Claude-gate-verified but NOT yet Codex-re-verified.** Everything stays **REMEDIATED_PENDING_SECOND_PASS**;
Codex-accepted-as-of-round-2: H-2, H-4, H-5, H-13, H-23, H-24, NEW-H-1. Not release-ready; no
commit/push/deploy. The user_settings consent DEFAULT-TRUE remains a deferred human product decision.

### NEW-H-3 remediation + independent (Claude) round-3 review

**NEW-H-3 — pre-bind consent CREATE clobbered remote settings/profile — REMEDIATED_PENDING_CODEX_REVERIFICATION.**
A pre-bind consent revocation now travels as a **consent-only** operation: the outbox queues
`_buildConsentOnlyPayload` (local_id + `consent_only` marker + the two consent flags, cloud-master
normalized), the push layer sends a minimal `{user_id, local_id, ai_consent_granted,
cloud_processing_enabled}` row (a PostgREST merge-upsert touches only provided columns; an absent row
is created with SERVER defaults), and the push deliberately does **not** bind the row — the pre-bind
default-writer guard stays active until a genuine pull merges and binds (which preserves the local OFF,
per the round-3 H-18 fix). Files: `planning_outbox_queue.dart`, `planning_push_service.dart`,
`settings_sync_service_test.dart` (5 new tests). **Non-vacuity proven live**: with the pre-fix full-row
payload restored, the production-risk test fails exactly as predicted (`display_name` expected
'Remote User', actual **null**). Validation: analyze clean; settings suite 15/15; planning/capture/
settings/sync 522; round-3 subset (portability/accounts/finance/backup/session/architecture) 553 — all
green. No migration (0087 not needed); no server change; consent DEFAULT-TRUE product decision untouched.

**Independent adversarial review of the fix (Claude — NOT the Codex pass):** all attack vectors held —
no remaining full-row path pre-bind (bound updates carry post-merge values; guard still blocks
non-consent pre-bind writes, re-proven post-consent-push by test), absent-row fallback uses server
defaults (never client defaults as authority), stale ON cannot outlive a newer OFF, mid-flight binding
degrades to a narrow guarded update / OFF-only conflict patch, `user_id` is the authenticated uid (RLS
scope). One LOW observation recorded: a brand-new user who revokes pre-bind may have local onboarding
choices reverted to server defaults by the first pull (narrow, recoverable, non-profile).

**NEW-H-4 (HIGH, PRE-EXISTING — found by the review's sibling sweep, NOT fixed; reported per scope
discipline):** the registration bootstrap's "pull first so an existing remote singleton wins" safety
assumption breaks when the first planning pull FAILS: the engine swallows the pull error
(`planning_sync_engine.dart:112-116` — debugPrint only) yet still runs `registerMissingRows()` and an
immediate push (`:126-127`); `_registerSettings` sees the unbound post-wipe row and enqueues a
**full-row** settings CREATE from fresh-device defaults, which the same-cycle push merge-upserts over
the user's existing remote settings/profile (same destructive outcome as NEW-H-3, different door; the
poisoned CREATE is durable and pushes before the next cycle's pull). Predates rounds 1–3.
**NEW-H-4 — REMEDIATED_PENDING_CODEX_REVERIFICATION.** Registration's settings CREATE is now gated on
POSITIVE remote authority: `registerMissingRows({required bool settingsPullCompleted})` (required — no
call site can forget), and the engine derives the flag exclusively from the pull result's
`completedEntities.contains(settingsEntityType)` on the success path (`planning_sync_engine.dart` —
assignment sits before the swallowing catch, pinned by a source-scrape contract test). Tri-state
collapse: FOUND → pull bound server_id (registration query matches nothing); CONFIRMED_ABSENT →
completed pull + still unbound → the legitimate new-user bootstrap; UNKNOWN (failed/cancelled pull or
the legacy reconcile path) → registration stays pending and retries on the next completed cycle — no
poisoned CREATE is ever enqueued. Custom categories stay ungated (fresh local UUIDs → insert-only,
cannot merge-clobber). Files: `planning_startup_registration_service.dart`, `planning_sync_engine.dart`,
tests in `planning_startup_registration_service_test.dart` (component + wiring contract) and
`settings_sync_service_test.dart` (3 end-to-end: failed-pull no-clobber + next-cycle recovery;
confirmed-absent bootstrap still works; consent-OFF still propagates narrowly during a failing pull).
**Non-vacuity proven live**: with the pre-fix unconditional registration restored, the production-risk
test fails with the exact clobber (remote `display_name` expected 'Remote User', actual **null**).
Validation: analyze clean · planning/capture/settings/sync 527 · round-3 subset 553 — all green. No
migration (0087 not created). Sibling sweep: `settingsLocalId` is the only fixed-key singleton in sync
payloads; every other entity uses per-row UUIDs (insert-only) — no other instance of the class. LOW
observation: a genuinely-new user in legacy-reconcile mode has settings registration deferred to the
first normal-pull cycle (conservative delay, not loss).

**Independent adversarial review of the NEW-H-4 fix (Claude — NOT the Codex pass): held on all
vectors** — no path lets a failed pull authorize a full CREATE (only-caller = engine; flag derivation
pinned; per-entity EOF is the sole completedEntities producer); nothing durable/poisoned survives the
failed cycle (asserted); absence is never inferred from an error (throw → incomplete → UNKNOWN);
NEW-H-3's consent-only path is untouched and proven to propagate during pull failure; cancelled
admission aborts before registration and sign-out wipes the outbox (no cross-account registration);
push-before-pull stays safe because no pre-bind full-row producer remains (consent = narrow, automatic
writers = blocked, registration = positively gated).

**CRITICAL OPEN = 0 · HIGH OPEN = 0.** Codex final re-verification of round 3 + NEW-H-3 + NEW-H-4
remains PENDING (quota).

### Open findings carried forward

- **plan_transaction_links backfill ignores `deleted_at`** on a matched remote row
  (Batch 5 residual) — a remotely-deleted link can be stamped `synced`. No money involved. LOW.
- *(S-1 is NOT open — REMEDIATED_PENDING_SECOND_PASS in Batch 12; see the sibling-sweep
  section above.)*
- **`sync-captures` / `verifyDevice` does not check `revoked_at`** (Batch 16 observation) —
  delivery-only of already-processed captures; not a consent-processing gap, recorded for a
  later batch rather than fixed.
- **H-24 live Storage erasure proof** → **PENDING_VALIDATION_EVIDENCE** (harness exists, not
  run; needs validation-staging authorization).
- **Android capture queue `MAX_ITEMS` drop-oldest** (Batch 17 observation) — capacity-bounded,
  not age-based; an unacked capture can be dropped only under an unrealistic SMS backlog.
  Recorded, not changed.

### Still required

1. **Batches 5+ are not started** — 20 HIGH findings remain open.
2. **`0084` has been applied NOWHERE.** It is source-only and needs separate authorisation.
   Production `vrombzdgwqjjiijbidqb` and evidence staging `dpdukyozedajelflkeix` retain
   ZERO contact.
3. The **mandatory Codex second pass** runs only after the full Critical/High set is
   complete, against the remediated tree.
4. No full-suite run has been performed since remediation began; the batch verifications
   above are targeted.

**This tree must not ship.** The CRITICAL set is closed in source but unproven on device,
and 20 HIGH findings — including silent sign-out data loss (H-1..H-3) and a
non-atomic SQLCipher key wipe (H-8) — remain open.
