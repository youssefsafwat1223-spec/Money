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
| **D** Privacy authority | policy ✅ · 5 egress paths gated · PULL still open | **IN PROGRESS** |
| **E** Data integrity | F-032, F-021-pull, C-6, F-029 repair | **NOT STARTED** |
| **F** Capability activation prep | runbook + preconditions documented | **PREPARED (not executed)** |
| **G** Account scope / aggregation | F-026 ✅ · F-019 ✅ · F-027 ✅ · F-028 open | **MOSTLY COMPLETE** |
| **H** Parser / capture | F-011 ✅(partly via C-1) · F-015, F-034, rollout | **NOT STARTED** |
| **AI** W-001 workstream | architecture + gates | **COMPLETE (design)** |
| **I** Flags / gamification | C-10, F-023+F-022, F-024 | **NOT STARTED** |
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

## 13. TESTS RUN

| Gate | Result |
|---|---|
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
