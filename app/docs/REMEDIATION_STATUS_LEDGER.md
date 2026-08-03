# Mali — Remediation Status Ledger

Single source of truth for the state of every finding from `FULL_APP_AUDIT.md`
(MALI-001…044) and `FINAL_FULL_PRODUCTION_AUDIT.md` (MALI-045n…077n). **No finding
is ever removed from this ledger.** Updated at the end of every phase.

- **Baseline HEAD:** `e2679d0e` (feat/phase1-data-integrity)
- **Last updated:** Phase 2 complete (locally verified) — 2026-07-30

> **Phase 2 note — bug found & fixed during implementation (not a new finding):**
> `drift_repository_support.dart` `userSettingsFromRow` hard-coded both consent
> flags to `true`, so runtime consent was ALWAYS ON and revocation was a no-op
> (the re-audit's MALI-001 verdict under-counted this). Fixed as part of the
> MALI-001/059n remediation (the read now reflects the persisted versioned state).

### Approved product decisions
- **MALI-059n (consent default) — APPROVED 2026-07-30:** Cloud processing and AI
  processing both **default OFF**; they are **separate explicit opt-ins**; the
  local/offline app is fully usable without either; consent is **never inferred**
  from onboarding completion, authentication, restore, migration, or previous
  default values; existing installs that never made an explicit choice **migrate
  to OFF**; revocation takes effect **immediately and fails closed**. A versioned
  consent schema distinguishes unset / explicitly-accepted / explicitly-declined
  (not a default-true boolean).
- **MALI-046n — CLOSED (locally verified):** on-device production-path
  confirmation remains part of external gate 6 (per Phase-1 approval).
- **MALI-045n — Code complete · Locally verified:** final closure requires the
  on-device backup→restore round-trip in external gate 6.

**Status vocabulary:** Not started · In progress · Code complete · Locally verified ·
External verification pending · Closed · Decision required · Blocked.

**Classification (actionable scope):** C=Code · T=Test · D=Docs · P=Product/policy ·
X=External-only · DUP=Duplicate · AF=Already-fixed (fresh evidence). VC findings from
the re-audit are recorded Closed (local) with any external tail tracked separately.

## Legend for "Phase"
P1 migrations/restore · P2 lifecycle/consent · P3 sync · P4 financial · P5 security/notif/native ·
P6 backup/DB/reliability · P7 CI/test/arch/docs · P8 MALI-026 · P9 external validation · — none.

## Master ledger

| Finding | Sev | Class | Phase | Status | Subsumed-by / Notes |
|---|---|---|---|---|---|
| MALI-001 | Crit | C+P | P2 | Code complete · Locally verified | explicit versioned default-OFF consent; read-clamp bug fixed; `89db9f09` |
| MALI-002 | Crit | X | P9 | Locally verified | on-device 2-user smoke = gate 6; legacy-null-owner window = MALI-070n |
| MALI-003 | Crit | X | P9 | Locally verified | release-binary fail-closed proof = gate 3/10 |
| MALI-004 | Crit | X | P9 | Locally verified | live Edge adversarial = gate 12 |
| MALI-005 | Crit | X | P9 | Locally verified | live purge time-travel = gates 1/2/12; purge coverage lows = MALI-075n |
| MALI-006 | High | X | P9 | Code complete (device pending) | merged-manifest+smoke = gate 3 |
| MALI-007 | High | — | — | Closed | atomic write+outbox re-verified |
| MALI-008 | High | C | P3 | Not started (core Closed) | periphery = MALI-072n |
| MALI-009 | High | C | P3 | Not started | subsumed by MALI-056n |
| MALI-010 | High | C | P3 | Not started | subsumed by MALI-056n |
| MALI-011 | High | C | P2 | Code complete · Locally verified | atomic wipe + unsynced inventory (flush→re-check→discard); `374560ff` |
| MALI-012 | High | X | P9 | Locally verified | on-device kill = gate 6/9 |
| MALI-013 | High | C+X | P5/P9 | Code complete (device pending) | apply()-in-receiver = MALI-068n; gates 9/10/11 |
| MALI-014 | High | C | **P1** | Code complete · Locally verified | closed by MALI-045n fix; on-device round-trip = gate 6 |
| MALI-015 | High | — | — | Closed | RPC path re-verified (client+server) |
| MALI-016 | High | — | — | Closed | atomic per-relation deletion re-verified |
| MALI-017 | High | C | P2 | Code complete · Locally verified | local-only cards in the inventory guard (interactive path); delete/reset gate behind explicit confirmation; remote/cross-UID wipe for isolation; `374560ff` |
| MALI-018 | High | C+T | P4 | Not started | canonical repo predicate Closed; provider tier open |
| MALI-019 | High | C | P5 | Not started | subsumed by MALI-061n |
| MALI-020 | High | X | P9 | Locally verified | archive privacy report = gate 5 |
| MALI-021 | High | C | P6/P7 | Not started (scope Closed) | dead file + PDF sweep = MALI-076n/065n |
| MALI-022 | High | C | P3 | Not started | resolver 4-of-12; server conditional update needed |
| MALI-023 | Med | C | P3 | Not started | + child StateError storm amplifier |
| MALI-024 | Med | C | P3 | Not started | XP dual-authority/replay |
| MALI-025 | Med | C | P5 | Not started | iOS 64-limit, redaction |
| MALI-026 | Med | C | **P8** | Not started | separate financial-storage project |
| MALI-027 | Med | C | **P1** | Code complete · Locally verified | closed by MALI-046n fix |
| MALI-028 | Med | C | P4 | Not started | half-open interval + week anchor (MALI-062n) |
| MALI-029 | Med | C | P7 | Not started | global invalidation breadth |
| MALI-030 | Med | C | P7 | Not started | streamed reports/memory |
| MALI-031 | Med | C | P5 | Not started | App Group encryption/Keychain |
| MALI-032 | Med | C+T | P5 | Not started | telemetry scrub coverage |
| MALI-033 | Med | C | P5 | Not started | Android backup rules (now covers SMS queue) |
| MALI-034 | Med | C | P7 | Not started | import cycle + legacy repair retirement |
| MALI-035 | Med | D | P7 | Not started | CLAUDE.md drift (incl. dangerous "all optional") |
| MALI-036 | Med | X+C | P7/P9 | Code complete (limits) | CI wiring = MALI-066n; hosted run = gate 8 |
| MALI-037 | Med | C | P7 | Not started | CVE/license gate |
| MALI-038 | Low | C+T | P7 | Not started | font bundling (+ test MALI-067n) |
| MALI-039 | Low | C | P5/P7 | Not started | debug diagnostics redaction (debug-only) |
| MALI-040 | Low | T | P7 | Not started | test isolation (subsumed by MALI-067n) |
| MALI-041 | Low | T | P7 | Not started | admin auth test (subsumed by MALI-066n/067n) |
| MALI-042 | Low | T | P7 | Not started | Edge unit isolation (MALI-066n) |
| MALI-043 | Low | P+D | P7 | Decision required | canonical brand name (Mali vs Qirsh) |
| MALI-044 | Low | C | P5 | Not started | metrics WITH CHECK(true) |
| MALI-045n | High | C | **P1** | Code complete · Locally verified | FK-safe restore (full parents + suspend-correctly + sanitize + verify); 5 regression tests; on-device round-trip = gate 6 |
| MALI-046n | High | C | **P1** | Closed · locally verified | `enableMigrations:false` → pipeline owns user_version; 5 regression tests; on-device path = gate 6 |
| MALI-047n | High | C | P4 | Not started | transactions-screen non-canonical total |
| MALI-048n | High | C | P4 | Not started | plan spend currency/refund/scope |
| MALI-049n | High | C | P4 | Not started | dashboard budget ring period |
| MALI-050n | High | C | P4 | Not started | Home category totals vs chip |
| MALI-051n | High | C | P3 | Not started | child cursor skip = permanent loss |
| MALI-052n | High | C | P3 | Not started | self-conflict + terminal conflicts |
| MALI-053n | High | C | P2 | Code complete · Locally verified | flush now covers child + smart-inbox + notif-log + sender-mapping outboxes; `374560ff` |
| MALI-054n | High | C | P2 | Code complete · Locally verified | native+file residue purge on every destructive path; fail-closed admission; `374560ff`. Device execution = gate 6/9 (external) |
| MALI-055n | Med | C | P3 | Not started | accounts no conflict detection; setDefault mass-rollback |
| MALI-056n | Med | C | P3 | Not started | withdrawal round-trip, null-base overwrite, payload version |
| MALI-057n | Med | C | P3 | Not started | pull conflict without base compare (folds into 052n) |
| MALI-058n | Med | C | P6 | Not started | SQLCipher key in DB + backup |
| MALI-059n | Med | P+C | P2 | Code complete · Locally verified | decision implemented (default OFF, separate opt-ins, migrate-to-OFF, versioned state, device-local, restore resets); `89db9f09` |
| MALI-060n | Med | C | P5 | Not started | anon-key AI unmetered |
| MALI-061n | Med | C | P5 | Not started | gamification bypasses policy; budget dual-authority |
| MALI-062n | Med | C | P4 | Not started | weekly anchor + budget scope divergence |
| MALI-063n | Med | C | P4 | Not started | PDF multi-currency; latent 0030 RPCs |
| MALI-064n | Med | C | P4 | Not started | bill paid double-count; monthly formula |
| MALI-065n | Med | C | P5 | Not started | report PDF tmp lifecycle |
| MALI-066n | Med | C | P7 | Not started | unexecuted-gate cluster |
| MALI-067n | Med | T | P7 | Not started | source-text tests, no-close, warning suppression |
| MALI-068n | Med | C | P5 | Not started | native durability (apply/locks/timestamp) |
| MALI-069n | Med | C | P6 | Not started | conn leak + second-instance busy_timeout |
| MALI-070n | Low | C | P2 | Code complete · Locally verified | pending-actions file purged on destructive paths; `374560ff`. Announcement-dismissal residue = minor, remains backlog |
| MALI-071n | Low | C | P5 | Not started | logo.dev consent gating |
| MALI-072n | Low | C | P3 | Not started | _isConflict string-match; sender-mapping deletes |
| MALI-073n | Low | C | P6 | Not started | missing account_id/category_id indexes |
| MALI-074n | Low | C | P4 | Not started | card refund gross, NULL-account attribution, decimals |
| MALI-075n | Low | C | P5 | Not started | backend lows (search_path, gamification writable, purge coverage) |
| MALI-076n | Low | C | P6 | Not started | backup lows (trim, blob version, hasRemoteBackup, dead export) |
| MALI-077n | Low | C+P | P7 | Not started | ops lows (keystore name, email, dead API, package path) |

## Phase roll-up

| Phase | Findings | Status |
|---|---|---|
| P1 migrations/restore | MALI-046n/027, MALI-045n/014 | **Code complete · Locally verified** (full suite 1003; awaiting approval) |
| P2 lifecycle/consent | 053n,054n,070n,011,017,001,059n | **Code complete · Locally verified** (full suite 1015; commits 374560ff + 89db9f09; awaiting approval) |
| P3 sync | 051n,052n,055n,056n,057n,008,009,010,022,023,024,072n | Not started |
| P4 financial | 047n,048n,049n,050n,062n,063n,064n,074n,018,028 | Not started |
| P5 security/notif/native | 031,032,033,060n,061n,065n,068n,071n,075n,019,025,044,039 | Not started |
| P6 backup/DB/reliability | 058n,069n,073n,076n | Not started |
| P7 CI/test/arch/docs | 066n,067n,029,030,034,035,037,038,040,041,042,043,077n,036-limits,021-deadfile | Not started |
| P8 MALI-026 | 026 | Not started (blocked on P1) |
| P9 external validation | 12 gates (002,003,004,005,006,012,013,017,019,020,022,036) | Not started |

Decision-required (await explicit product approval): **MALI-059n** (consent default),
**MALI-043** (canonical brand name). These are surfaced, never silently decided.
