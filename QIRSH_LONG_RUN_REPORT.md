# QIRSH — AUTONOMOUS LONG-RUN REPORT

**Status: IN PROGRESS.** Live checkpoint — updated as the run proceeds, so that
repository evidence rather than conversational memory is authoritative.

| | |
|---|---|
| Branch | `feat/phase1-data-integrity` |
| Starting commit | `464816a6` (C-2 guard fix) |
| Current commit | see `git log` §35 |
| Safety branches | `backup/pre-partition-20260828` (full pre-partition tree), `backup/pre-amend-20260828` |
| Remote actions performed | **NONE** |

---

## 1. EXECUTIVE SUMMARY

Continuing the V2 remediation autonomously. Work so far this run: closed the
force-update **temporal bypass** (a hole in the fix shipped earlier the same
session), made Home a **pure read**, declared the **owner-table grants** that made
fresh environments unreproducible, and began Phase D by building a real
**ConsentAuthority** and wiring the first four egress classes.

Two findings were discovered *by this run* and are not in V2's original list:
the force-update temporal-resurrection bypass (C-2a-1) and the fact that
**`action_url` is unvalidated when arming**, which would brick every client
behind a placeholder store URL.

---

## 5. PHASE-BY-PHASE STATUS

| Phase | Scope | Status |
|---|---|---|
| **A** Tree partition | 6 fixes triaged, quarantine preserved | **COMPLETE** |
| **B** Stop the bleeding | C-1 ✅ · C-2 ✅ · C-2a-1 ✅ · C-9 ✅ · C-2a-2 open · C-5 blocked | **MOSTLY COMPLETE** |
| **C** Environment truth | DF-002 ✅ · DF-005 ✅ (source-only) | **COMPLETE (local)** |
| **D** Privacy authority | policy ✅ · **7 gated, 1 exempt, 4 open** (3 quarantined, 1 unwired) · R-1 inventory test guards regressions | **MOSTLY COMPLETE** |
| **E** Data integrity | F-032 ✅ · C-6 ✅ (2 of 3 paths) · F-029 ✅ (client + server detection) · F-021-pull quarantined | **MOSTLY COMPLETE** |
| **F** Capability activation prep | runbook + preconditions documented | **PREPARED (not executed)** |
| **G** Account scope / aggregation | F-026 ✅ · F-019 ✅ · F-027 ✅ · F-028 ✅ | **COMPLETE** |
| **H** Parser / capture | F-011 ✅ (via C-1) · F-015 ✅ (+F-015b) · F-034 blocked (quarantined Swift + needs device) · rollout blocked on flags | **MOSTLY COMPLETE** |
| **AI** W-001 workstream | architecture + gates | **COMPLETE (design)** |
| **I** Flags / gamification | C-10 ✅ · F-023+F-022 ✅ (client) · F-024 blocked | **MOSTLY COMPLETE** |
| **J** UX foundations | | **NOT STARTED** |

---

## 4. COMMITS CREATED THIS RUN

| Commit | Subject |
|---|---|
| `19e6ce43` | `fix(admin)` "armed" must mean "blocks clients" (C-2a temporal bypass) |
| `9c3aa230` | `fix(db)` declare owner-table grants (DF-002/DF-005) |
| `e723f4ce` | `docs(release)` release readiness track |
| `b32e2395` | `docs(ai)` W-001 AI/ML architecture workstream (OD-11) |
| `e53f8efa` | `docs(plan)` record Phase B/C progress, split C-2a |
| `a241bdae` | `fix(dashboard)` make Home a pure read; repair → startup (C-9) |
| `68777c1c` | `feat(privacy)` ConsentAuthority policy (C-3 part 1) |
| `308aab81` | `fix(privacy)` gate sender→bank mapping egress (C-3 part 2) |
| `b0b364fb` | `fix(privacy)` backup consent hook was dead code (C-3 part 3) |
| `dce16bdd` | `fix(privacy)` gate crash reporting on consent (OD-05, C-3 part 4) |
| `26908fcb` | `docs(run)` checkpoint the long-run report |
| `7b57be14` | `fix(privacy)` gate financial push on consent (C-3 part 5) |
| `2b202958` | `docs(run)` record C-3 progress |
| `3ea5793c` | `feat(db)` server-authorized, audited force-update arming (C-2a-2) |
| `093549bf` | `fix(admin)` route arming through the audited RPC (C-2a-2) |
| `586006ec` | `test(capture)` explicit consent in ledger push mechanics tests |
| `17eea0af` | `fix(flags)` server must not ignore a partial rollout (C-10) |
| `4bb47943` | `docs(release)` exact-transport activation runbook (Phase F) |
| `93b92c93` | `docs(plan)` sync status board |
| `6219024e` | `fix(finance)` one canonical account scope (F-026, F-019, F-027 · OD-08) |
| `7abeb772` | `docs(plan)` findings discovered during remediation |
| `349e221f` | `docs(plan)` H-4 quarantine review — verdict LAND |
| `8eeb266f` | `test(sync)` explicit consent in sender-bank mechanics tests |
| `6e13f44f` | `feat(cards)` canonical card identity (F-032 · OD-02) |
| `13df73ea` | `docs(run)` record F-032 |
| `f3fd86ce` | `fix(dashboard)` like-with-like week comparison (F-028) |
| `2c70cb73` | `fix(gamification)` one vocabulary, one level mapping (F-023 + F-022 · OD-03) |
| `e5e44a9f` | `fix(gamification)` raw value to customStatement (runtime binding) |
| `ef9e2587` | `fix(tests)` repair two contract gates my migrations broke |
| `6611dc3a` | `fix(tests)` remove F-021 pull tests from HEAD (code is quarantined) |
| `39c199cb` | `fix(sync)` atomic guarded account update (C-6) |
| `cee2d4ef` | `fix(sync)` atomic guarded ledger update (C-6 part 2) |
| `2ad082ef` | `fix(parser)` merchant boundary + AMAZON truncation (F-015, F-015b) |
| `9b62839b` | `test(privacy)` egress inventory (C-3 / R-1) |
| `6e7d8d93` | `fix(privacy)` gate notification-log telemetry (C-3) |
| `12560909` | `fix(privacy)` gate Smart Inbox egress (C-3) |
| `f68af055` | `feat(db)` detect corrupt budget category ids (F-029 server) |

*(Earlier, pre-run partition commits: `8e36a24d`, `a6f343fb`, `8d0a422c`,
`e96f8434`, `35754d99`, `3dc87694`, `2ac4c782`, `e2b5b489`, `464816a6`.)*

---

## 6. FINDINGS CLOSED THIS RUN

- **C-2a-1** force-update temporal-resurrection bypass + missing `action_url`
  precondition — *discovered by this run*.
- **C-9** dashboard read mutating financial state.
- **DF-002 / DF-005** environment reproducibility (source-side).
- **C-10** server-side rollout semantics (partial rollout no longer reads as
  fully enabled server-side; country targeting no longer assumed global).
- **F-026 / F-019 / F-027** one canonical `AccountScope`, applied per OD-08.
- **F-032 (client half)** canonical `card_id` + a never-guess backfill, closing
  the silent mis-attribution where two cards sharing four digits merged
  histories and a reassigned card's history was inherited by a new card.
- **F-028** like-with-like week comparison — the dashboard was weighing a
  partial week against a full one, understating current spending by up to 28x
  early in the week.
- **F-023 + F-022** one gamification vocabulary. The achievement intersection
  was EMPTY (not "3 of 4"), the seed guard prevented existing installs from ever
  receiving new keys, the pull never wrote `level_key` (frozen 'beginner'), and
  the unbounded server level curve could RangeError the client's five tiers.

## 7. PARTIALLY CLOSED

- **C-3 / F-025** — the authority exists and **5 egress paths are gated**:
  financial PUSH (accounts + ledger — the headline), sender→bank mappings,
  backup upload, diagnostics/Sentry.
  **C-3 stays OPEN.** Still ungated: financial **PULL**, `user_settings` PII,
  Smart Inbox (`isPullEnabled: () => true`), gamification, notification logs,
  the activity ping, metrics, and `enrich-merchant`. Four of the relevant
  services sit in the quarantined H-4 set (`accounts_pull_service`,
  `planning_pull_service`, `planning_push_service`, `encrypted_backup_service`)
  and are deliberately untouched — gating them requires that workstream to be
  reviewed first.
- **C-2 / C-2a-2** — arming is now a server-authorized, audited operation:
  `arm_force_update()` (SECURITY DEFINER, audit-then-sentinel-then-mutate, `FOR
  UPDATE` closing the route's TOCTOU) plus a trigger that refuses any
  not-blocking → blocking transition lacking the sentinel, for **every** role
  including `service_role`. The admin route calls the RPC and fails **closed**
  (503) if the migration is not applied, rather than falling back.
  **Remaining:** password re-authentication at the arm route — the only measure
  that makes a *stolen session* insufficient. Until then C-2 is **not closed**.
  Also: 0089 must be deployed **before** the route change ships, or arming
  through the panel returns 503.

## 8. STILL OPEN (unchanged from V2)

F-032, F-021-pull, C-6 TOCTOU (push services), F-029 server repair,
F-023+F-022, F-024, F-019/026/027/028, F-015, F-034, F-011 (admin-side),
UX programme.

**C-10 closed this run** (server-side rollout semantics).

---

## 12. ADVISOR (FABLE) CONSULTATIONS

**Q: force-update arming authorization design.** Verdict recorded in full at
`19e6ce43`.

| Advice | Claude's decision | Why |
|---|---|---|
| The typed phrase as a *server-checked string* is theatre | **ACCEPTED — did not implement** | `FORCE_UPDATE_CONFIRM_PHRASE` is a public exported constant already in the client bundle; curl sending the phrase is exactly as easy as curl sending `true`. Would have added ceremony without changing the threat model. |
| Refuse the armed *transition*, not the armed *state* | **ACCEPTED** | Refusing the state would make an armed row uneditable, including edits that defuse it. |
| **Temporal fields bypass the transition guard** | **ACCEPTED — fixed** | Verified in source: `catalog-announcements` filters on the serving window, so an expired armed row blocks nobody, and extending `valid_until` took it live without crossing not-armed→armed. This was a live hole in code shipped earlier in the session. |
| Require `action_url` when arming | **ACCEPTED — implemented, scoped** | `ForceUpdateScreen` falls back to a placeholder store URL with a fake app id. Scoped to escalating writes so a legacy armed row without a URL does not become uneditable. |
| Requiring `min/max_app_version` at arm time is a FALSE control | **ACCEPTED — did not implement** | No build defines `APP_VERSION`; every client parses as `0.0.0`, so a min bound would match nobody while the UI claimed the arm was scoped. |
| Trigger + SECURITY DEFINER RPC + audit row; password re-auth | **ACCEPTED in principle — deferred** | Correct next step for C-2a-2 (and it closes the PATCH load-then-update TOCTOU). Not implemented yet; recorded as the remaining C-2 work. |

---

## 13. TESTS RUN — FINAL, ALL AT COMMITTED HEAD

| Gate | Result | Where |
|---|---|---|
| `flutter analyze` | **clean** | committed HEAD, detached worktree |
| Full Flutter suite | **2344 pass / 1 skip / 0 fail** | committed HEAD, detached worktree, nothing else running |
| Full Flutter suite | **2620 pass / 0 fail** | working tree (includes quarantined code) |
| Admin `node --test` | **90 pass / 0 fail** | |
| `tsc --noEmit` | **clean** | |
| SQL/migration contract | **228 pass / 0 fail / 70 skipped** | 70 are credential-gated live tests |
| Deno (Edge) | **9 pass / 0 fail** | |

The HEAD and working-tree counts differ by design: the working tree contains the
quarantined implementations (H-4, F-021 pull, NEW-H-3, backup overhaul) and their
tests; HEAD does not.

### Why every claim is measured at HEAD
Working-tree gates proved actively misleading three separate times this run:

1. during the partition they passed while the committed tree did not compile
   (7 errors);
2. mid-run edits silently invalidated three long suites (and two concurrent
   suites tripped an OS advisory lock in `database_process_liveness_test`);
3. twice, quarantined tests were committed without their implementation — green
   locally, red at HEAD.

Cause 3 is now blocked mechanically by `quarantine_coherence_test`, which was
verified to FAIL when the implementation symbol is removed.

---|---|
| `flutter analyze` (working tree) | **clean** |
| `flutter analyze` (**committed HEAD**, detached worktree) | **clean** |
| Full Flutter suite | **2537 pass / 1 skip / 1 fail** — the single failure is the known load-flaky perf test (`migration_converter_fixture_test`), which **passes standalone** |
| Admin `node --test` | **88 pass / 0 fail** |
| `tsc --noEmit` | **clean** |
| SQL/migration contract tests | 6 (C-1) + 8 (DF-002/005) pass |
| New privacy tests | ConsentAuthority 10 · sender-bank 5 · backup controller 10 · diagnostics 6 |

**Clean-HEAD verification** is performed in a detached worktree
(`.claude/jobs/.../headcheck`), because working-tree gates proved insufficient:
they passed while the committed tree did **not** compile (7 real errors).

---

## 14. PROCESS INCIDENT (recorded deliberately)

While committing C-3 part 2 I staged `app_providers.dart` **whole**, which pulled
the quarantined **H-4 pull-gate** hunks into commit `882c5263` — exactly what the
brief forbids.

Detected immediately by reviewing the commit's own `--stat` (+68 lines for a
6-line change). Recovery, without any destructive command:

1. backed the working file up and created `backup/pre-amend-20260828`;
2. reset the **index only** to the parent's blob (`git restore --source=HEAD~1 --staged`);
3. rebuilt a clean blob = parent content + only my two edits, via
   `git hash-object` + `git update-index`;
4. `git commit --amend`.

Verified afterwards: the amended commit `308aab81` contains only the consent
change; the working tree is **byte-identical** to the backup (H-4 intact and
still uncommitted); HEAD analyzes clean; 37 targeted tests pass at HEAD.

**Rule adopted for the rest of the run:** never `git add <file>` for a file that
carries mixed workstreams — use the hunk picker or the blob-rebuild technique.

---

## 23. MIGRATIONS CREATED (NOT APPLIED ANYWHERE)

| Migration | Purpose | Rollback |
|---|---|---|
| `0087_parser_validation_evidence.sql` | makes `validation_status='passed'` require evidence (C-1) | included, with a pre-image table |
| `0088_explicit_owner_table_grants.sql` | declares owner-table grants (DF-002) | included, with a warning not to run it on the hosted project |

## 25. REMOTE ACTIONS INTENTIONALLY NOT PERFORMED

No deploy, no remote migration, no flag flip, no submission, no account
creation, no purchase, no credential generation. **Zero contact** with production
(`vrombzdgwqjjiijbidqb`) or evidence staging (`dpdukyozedajelflkeix`).

## 26–30. EXTERNAL PREREQUISITES

Tracked in `QIRSH_RELEASE_TRACK.md`. The hard blocker remains the
**privacy/terms URL** (NXDOMAIN), which is both a store requirement and a live
in-app dead link. Per OD-06 the policy text is deliberately authored **after**
Phase D, so it describes enforced rather than intended behaviour.

## 31. KNOWN FLAKY TESTS

`app/test/domain/finance/migration_converter_fixture_test.dart` — "100k
conversions are linear; < 2s". Load-sensitive; passes standalone. Also observed
flaking under parallel load: three `core/backup/backup_key_state_atomicity_test`
cases (Argon2-heavy, 30 s timeout).

## 32. QUARANTINED / UNLANDED WORK

Still uncommitted in the working tree, deliberately: **F-021 pull half**,
**F-017 admin UI**, **H-4 pull gates**, **NEW-H-3 consent propagation**, the
backup/restore overhaul, the admin UI promotion, migrations 0084–0086, CI/release
changes.

---

## 36. EXACT NEXT ACTIONS (in order)

### Immediately actionable locally, in dependency order
1. **Land the H-4 pull gates** — reviewed this run, verdict LAND (`QIRSH_MASTER_PLAN_V2.md` §8a).
   Unblocks 2 and 4.
2. **Gate financial PULL on consent** — the last large C-3 gap. Blocked on 1,
   because the pull services are in the quarantine.
3. **Gate the remaining egress classes**: `user_settings` PII, Smart Inbox
   (`isPullEnabled: () => true`), gamification, notification logs, activity ping,
   metrics, `enrich-merchant`.
4. **Phase E — data integrity**: F-032 `card_id` (OD-02), F-021 pull rework,
   C-6 atomic guarded update, F-029 server-row repair.
5. **F-028** — the last aggregation item (dashboard compares partial-vs-full
   week; reports compares elapsed-matched, under one label).
6. **F-023 + F-022** — gamification split-brain (OD-03).
7. **Phase H** — F-015 in-engine merchant normalisation, F-034, F-016 staged
   rollout (OD-04, blocked on a real flag consumer).

### Blocked on the owner
- **C-5 privacy/terms hosting** — the artifacts cannot be authored honestly until
  Phase D completes, and the hosting step is the owner's (OD-06).
- **F-024 `APP_VERSION`** — the one-line-per-workflow fix lives in
  `codemagic.yaml`, which is inside the quarantined CI workstream. Landing it
  requires that workstream to be reviewed, or an explicit exception.
- Everything in `QIRSH_RELEASE_TRACK.md` §2–§5.

---

## 37. RELEASE READINESS VERDICT

**Not release-ready, and materially closer than at the start of the run.**

Closed this run: an unvalidated-regex path to confirmed money, two force-update
arming bypasses plus a server-side authorization layer, a read path that mutated
financial state, five consent egress leaks, server-side rollout semantics, and
three aggregation defects.

Still blocking, honestly stated:
- **financial PULL egresses without consent** (C-3 incomplete);
- **no `card_id` identity** — `last4` still merges distinct physical cards (F-032);
- **gamification is split-brain** — client and server share no achievement vocabulary;
- **cloud sync is dark** and its activation has six unmet preconditions (Phase F);
- **the privacy/terms URL is NXDOMAIN** — a store blocker and a live dead link.

None of these is a regression introduced by this run; all are pre-existing and
now precisely located, with tests where fixed.

---

# FOR CHATGPT REVIEW

Independent review packet. Everything below is **committed** on
`feat/phase1-data-integrity`. Nothing has been deployed, published or applied
remotely.

## Highest-risk commits, in order of what I would want challenged

| Commit | Why it deserves scrutiny |
|---|---|
| `2c70cb73` | **Gamification vocabulary.** I chose the UNION of two disjoint achievement sets as the canonical contract. That is a product judgement, not a purely technical one — if the server's three transaction-count achievements were meant to REPLACE the client's six, my choice is wrong. Also changes the DB seed from "only when empty" to per-key `INSERT OR IGNORE`. |
| `6e13f44f` | **Card identity migration.** Adds `card_id` to transactions and backfills it. The backfill deliberately leaves ambiguous rows NULL. Verify the SQL correlated subquery is right, and that "exactly one live card" is the correct match predicate. |
| `3ea5793c` + `093549bf` | **Force-update arming.** A SECURITY DEFINER RPC + trigger + transaction-local sentinel, and a route that fails closed at 503 if the migration is absent. Check the sentinel cannot leak across statements, and that the trigger's transition logic cannot be stepped around. |
| `19e6ce43` | **"Armed" redefined as "blocks clients".** Judge whether `blocksClients()` matches `catalog-announcements`' serving filter exactly. A mismatch reopens the bypass. |
| `7b57be14`, `dce16bdd`, `b0b364fb`, `308aab81` | **Consent gates.** All default to DENY. Check I have not broken a legitimate path, and that "read fresh at egress" really holds. |
| `17eea0af` | **Server rollout semantics.** I made a partial rollout fail closed server-side because the server cannot reproduce the client's install-id cohort. Challenge whether failing closed is right versus bucketing on `user_id`. |
| `6219024e` | **Canonical `AccountScope`.** Encodes OD-08: a global budget applies to every account. Verify against intended product behaviour. |

## Financial-data changes
- `6e13f44f` — `transactions.card_id` column + backfill (client DB only).
- `6219024e` — which budgets each surface counts; changes displayed totals.
- `f3fd86ce` — week-over-week window; changes a displayed percentage.
- `35754d99` — budgets now fail closed rather than pushing a local category id.

## Consent / privacy changes
`68777c1c` (policy), `308aab81` (sender→bank), `b0b364fb` (backup), `dce16bdd`
(Sentry), `7b57be14` (financial push). **Financial PULL is still ungated** — the
services are in the H-4 quarantine.

## Migrations created (NONE APPLIED)
`0087` parser validation evidence · `0088` owner-table grants · `0089`
force-update arming authority · `0090` budget-category detection view.
All ship rollbacks; `0087` and `0089` preserve pre-images.

## Parser changes
`8d0a422c` (F-016 + C-1 corroboration gate) and `e96f8434` (F-014 parity).
The corroboration rule — a rule-captured amount the heuristics cannot reproduce
is capped below auto-confirm — is the one most worth a second opinion, since it
changes which captures auto-confirm.

## AI architecture decisions
`b32e2395` / `QIRSH_AI_ARCHITECTURE.md`. Recommendation: **no additional model
this cycle**, on the grounds that the labelled corpus is ~37 messages and
contaminated by F-015. Challenge the corpus-size threshold and the claim that
the AI cascade and catalog authority are on disjoint paths.

## Advisor disagreements
Fable proposed a server-checked typed phrase and mandatory version bounds at
arming time. **I rejected both** — the phrase is a public constant already in the
client bundle (so it is not a control), and version bounds cannot work while no
build defines `APP_VERSION`. Reasoning is in `19e6ce43`. Worth a second opinion.

## Not fully proven
- Every SQL migration is **contract-tested against its own text**, never executed.
  No live database has run any of it.
- `0089`'s trigger/RPC behaviour is asserted structurally, not behaviourally.
- The C-3 gates are unit-tested; there is **no end-to-end network-recording
  harness** proving nothing egresses with consent off. That is the acceptance
  test I would want before believing C-3 is closed.
- **F-032 and F-023 are client-half only.** The server has no `card_id` and no
  shared achievement catalog.

## Specific things to inspect
```
app/lib/data/db/app_database.dart              backfillCardIdentity()
app/lib/domain/finance/account_scope.dart      includesBudget vs includesRow
app/lib/core/privacy/consent_authority.dart    the decide() switch
admin/lib/announcement-guard.mjs               blocksClients() + escalation rule
supabase/migrations/0089_*.sql                 sentinel + trigger interaction
app/test/domain/gamification_vocabulary_test.dart   migration-contract test
```


---

# SPRINT 2 — FINAL COMPLETION SPRINT (2026-08-29)

**Starting HEAD:** `44ba170a`  ·  **Ending HEAD:** see §S13  ·  **19 commits**

## S1. What this sprint closed

Every item that was blocked by a quarantine decision is now landed.

| Item | Verdict | Commits |
|---|---|---|
| **H-4** capability authority | **LANDED** — verified 2377/0 at HEAD | `b7f0359d` `57846869` `6f836d6c` `486a9484` `ab14ce10` |
| **C-3** consent enforcement | **COMPLETE for money paths** | `f0fa99b7` |
| **H-1** reconcile truthfulness | **LANDED** as one coherent unit | `93275043` |
| **F-021** evidence-based conflicts | **LANDED** | `4a097ea5` `e802dfc7` |
| **Planning C-6** TOCTOU | **LANDED** — all 3 push paths now atomic | `6e4c7ff9` |
| **F-024** version identity | **LANDED** | `a67e1284` |
| **F-011** parser trust | **LANDED** | `0ae0defe` |
| **F-034 / H-19** Shortcut durability | **SOURCE COMPLETE** — device evidence pending | `5b3a1eb4` |
| **OD-13** AI model | **IMPLEMENTED** | `52b89448` |
| **C-5** privacy/terms | **REPO COMPLETE** — hosting external | `44afd4aa` |
| **Phase F** runbook accuracy | **UPDATED** for H-4 | `9dff5903` |

## S2. H-4 — and a correction to my own estimate

I previously told the owner H-4 spanned "~7 interlinked files" and was too risky
to land unattended. That was wrong. The actual H-4 workstream is **three**
implementation files; my estimate conflated it with H-1, NEW-H-3 and the capture
ownership-guard work that merely share `app_providers.dart`. The mis-estimate is
why it sat unlanded for a full run.

Landed in four reviewable commits: the pure predicate, the child push/pull
authority split, the four pull providers, and the startup backfills.

The subtlest finding was the **planning pull**: it already consulted a
capability, but only through the per-entity currency gate, which constrains three
of six entities. Subscriptions, plans and bill_payments short-circuited to `true`
and never consulted the transport at all. A gate covering half the entities reads
as covered when it is not.

## S3. C-3 verdict — COMPLETE for money paths

Egress inventory: **11 gated · 1 exempt · 1 open**. The one open entry is
`MerchantFeedbackClient`, which has no caller in `lib/` and therefore cannot leak.

Gates sit before the auth lookup and before any cursor read, which is what makes
the property hold for startup, resume, retry and reconciliation without each
needing its own check. Consent is read fresh at every call, so revocation is
immediate (OD-07).

One self-correction: I first listed the child sync service as "gated by its
caller" and the inventory test passed — but only because that caller file
contains OTHER services' gates. That is exactly the comfortable fiction the
inventory exists to prevent. The child service now carries its own gate.

## S4. H-1 / F-021 verdict — LANDED, as separate coherent units

H-1 and F-021 were entangled in the tree but are different findings and landed
separately.

**H-1**: `ran` meant only "no exception escaped"; the three backfill reports were
discarded. A row whose backfill failed keeps `server_id IS NULL` with no outbox
entry, so sign-out saw "nothing pending" and wiped the only copy — data loss
reached through a success report. Landed as one unit (exact `::text` comparison +
`partial` outcome + inventory visibility) because the parts do not work
separately.

**F-021**: `pending` was treated as a conflict on sight, and the flag was
terminal — an account could freeze permanently over a divergence that never
existed. Now evidence-based, and an existing conflict re-checks and DEMOTES back
to pending, which is what makes it a fix rather than a mitigation.

`NULL`↔`0` is not conflated anywhere: a missing column or unparseable value
counts as a MISMATCH, which is stricter than "narrowly scoped".

## S5. Planning C-6 verdict — LANDED

The last of three services with the check-then-write shape. The guard now travels
with the mutation (`.eq('updated_at', base)` chained onto the update), decoded via
`guardedAck` — never `maybeSingle`, which would throw PGRST116 on zero rows and
resurrect the Phase-9L mis-classification.

**The fakes mattered more than the fix.** Nineteen sink fakes needed the new
method. Most model no concurrent writer, so delegating is honest. But
`planning_entities_sync_service_test` owns the "conflicts WITHOUT clobbering"
case, and there a delegating fake made the test FAIL — correctly, because the
write landed. That fake now genuinely refuses the write.

## S6. Phase F verdict — LOCALLY PREPARED

All three capabilities still ship `unknown`; `kServerRevisionCas` stays `false`.
The runbook now records what flipping each one actually starts doing, that
consent is an independent gate, and why PUSH must be flipped before PULL.

No remote migration applied, no capability activated, no flag flipped.

## S7. AI verdict — IMPLEMENTED (OD-13)

See `QIRSH_AI_ARCHITECTURE.md` §14 for the full record.

**Selected:** a pure-Dart TF-IDF character-n-gram nearest-neighbour classifier
over the merchant catalog the app already ships. **No external provider. No paid
API. No model asset. No network path.**

**Fable consultation:** recommended option B (classical, catalog-seeded) over an
embedded neural model. **Accepted** — after validating the premise against the
repo (332 seeds confirmed, categorizer confirmed exact-substring). Fable's
decisive argument, which I adopted: 37 contaminated examples are too few to
*evaluate* with, so the neural path is blocked in both directions.

**Measured:** `n=3320  model 98.0%  baseline 93.4%` — ~70% relative error
reduction. Per-perturbation, where the value actually is: alef variants 100% vs
0%, teh marbuta 100% vs 0%, diacritics 100% vs 8%.

**Live external-call verification: N/A** — there is no external call to verify.
That is the point of the architecture, not a gap in it.

## S8. F-024 / F-011 / F-034 verdicts

**F-024 LANDED.** `X-App-Version` was always `''` because six call sites read a
dart-define no build set. Version-targeted rules — including the force-update
kill switch — could not match. One canonical accessor, a non-empty fallback, a
test that fails if the fallback drifts from pubspec, and one CI define per
workflow. No unrelated CI experiments came with it.

**F-011 LANDED.** The admin route passed `validation_status` through from request
input, so one string could promote an unvalidated regex to money-writing
authority. Promotion is now not an editing operation at all; demotion always is.
Evidence columns are not client-writable, and an already-`passed` row with no
evidence cannot launder its status through an edit.

**F-034 SOURCE COMPLETE — EXTERNAL EVIDENCE PENDING.** The real finding was H-19:
the Shortcut deleted the only durable local copy on backend success, while the
relay row is swept at 30 days. Fixed to mark `.sent`. Physical-device
verification requires a paid Apple Developer account and an iPhone.

## S9. C-5 verdict — REPOSITORY COMPLETE, EXTERNALLY BLOCKED

Policy and Terms written, URLs centralised and overridable. Deliberately NOT
pointed at a plausible-looking address: a link that 404s on a domain we do not
control is a privacy policy the user cannot read while appearing to be one.

The policy was written last on purpose — until C-3 landed, an honest version
would have had to admit consent did not reliably stop uploads.

## S10. New findings fixed during the sprint

* **H-19** (above) — data loss on the Shortcut success path.
* **C-11, fourth occurrence** — 35 pull constructions across 17 files had
  silently become refusal-path tests under C-3's fail-closed default. Found only
  by running full suites at HEAD rather than targeted subsets.

## S11. Process failures worth recording

1. **I overwrote uncommitted work in the tree twice** (H-1's reconcile, then
   `planning_push_service`) by copying files into it to run a test. Both
   recovered byte-identical from the `pre-partition` safety snapshot. The
   snapshot did its job; the cause was mine, and the fix was to do all
   verification in the isolated worktree instead.
2. **A self-deadlocking wait loop** — `until ! ps aux | grep -q "[f]lutter test"`
   matched its own command line and never exited. Killed and re-run directly.
3. **An Argon2 "Segment processing timeout"** appeared in one full run. It is the
   known load-sensitive flake, and I caused it by running work concurrently with
   the suite — violating my own serialisation rule. Re-run clean rather than
   normalised away.

## S12. Fable consultations

| Topic | Recommendation | Outcome |
|---|---|---|
| On-device model selection | Option B (classical, catalog-seeded), fold in C's interface + harness slice; neural gated behind a real corpus | **ACCEPTED** after validating the premise against the repo. Its framing that the corpus blocks *evaluation*, not just training, is now the recorded rationale. |
