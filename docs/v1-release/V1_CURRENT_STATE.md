# V1 Current State

The factual truth of the project. Updated at the start and end of every work
block. Nothing here is aspirational.

**Reconciled:** 2026-09-15
**Branch:** `feat/phase1-data-integrity`
**HEAD:** `5edfdb6e — fix(budgets): pull-to-refresh could never fire` (2026-09-09)

---

## 1. Toolchain

| Tool | Version | State |
|---|---|---|
| Flutter | 3.47.3 (stable) | Working **only** via `~/.qirsh-qa/env.sh` |
| Dart | 3.13.3 | Working |
| Xcode | 27.0 (27A266a) | **Licence unaccepted — see EB-001** |
| CommandLineTools | licensed (agreed 26.6), SDKs 26.5/27.0 | Working |
| iOS Simulator | — | **Unavailable** (EB-001) |

Every command in this project must first `. ~/.qirsh-qa/env.sh`. Four stale
machine settings are repaired there; see V1_EXTERNAL_BLOCKERS.md.

## 2. Build/test baseline (2026-09-15)

| Gate | Result |
|---|---|
| `flutter pub get` | PASS (after the `intl` bump) |
| `flutter analyze` | **0 issues** |
| `flutter test` | **3,905 pass / 2 skipped / 0 fail** |
| iOS simulator build | **PASS** — `Runner.app` builds, installs, launches |
| Simulator QA | E-1 walk outstanding |

The 25 analyzer issues are **new lint rules introduced by the Flutter 3.47
upgrade**, not product regressions. `app/CLAUDE.md` makes "analyze clean (0
issues)" a commit gate, so they must be driven to zero. 9 of the 10 warnings are
`unawaited_return_in_try_block` inside money push services
(`ledger_push_service.dart`, `accounts_push_service.dart`,
`planning_push_service.dart`) — these sit on financial paths and get a real
read, not a blanket suppression.

## 3. Worktrees

| Path | Branch | Role |
|---|---|---|
| `/Users/luciq/Documents/Money` | `feat/phase1-data-integrity` | **primary — this release** |
| `.../QirshWorktrees/app-onboarding` | `feat/onboarding-visual` | UI Atlas + HTML prototype source |
| `.../QirshWorktrees/app-ios-shortcuts` | `feat/ios-shortcuts` | iOS Shortcuts work |
| `.../QirshWorktrees/app-ui` | `feat/ui-parallel` | parallel UI work |

## 4. Uncommitted work (preserved byte-identically)

13 modified tracked files, 16 untracked paths. Provenance matters because some
are the owner's in-flight work and some were produced by the QA effort that
preceded this charter.

### Owner's in-flight work — DO NOT TOUCH
```
app/integration_test/dashboard_impression_probe_test.dart
app/lib/domain/finance/goal_pacing.dart
app/lib/features/dashboard/dashboard_providers.dart
app/lib/features/dashboard/dashboard_screen.dart
app/lib/features/dashboard/home_sections_providers.dart
app/test/features/dashboard/no_charts_on_home_test.dart
app/test/features/ux_information_and_safety_test.dart
app/docs/dashboard_daily_spend_report.md            (untracked)
app/lib/domain/finance/daily_allowance.dart         (untracked)
app/lib/features/dashboard/widgets/                 (untracked)
app/test/domain/finance/daily_allowance_test.dart   (untracked)
app/test/domain/finance/goal_projection_test.dart   (untracked)
app/test/features/dashboard/daily_spend_card_test.dart (untracked)
docs/QIRSH_SAVINGS_AFFILIATE_IMPLEMENTATION_PLAN.md (untracked)
docs/qa.zip                                         (untracked, 1.3 MB, 47 files)
```
A dashboard "daily spend / daily allowance" feature is mid-implementation. It is
**not** part of this charter's scope and must not be disturbed or committed.

### Produced by the preceding QA effort — this charter owns these
```
app/lib/features/accounts/account_detail_screen.dart   (fix: inert transaction rows)
app/lib/features/cards/card_details_screen.dart        (fix: inert transaction rows)
app/lib/features/goals/goal_details_screen.dart        (fix: edit/delete hidden off-sheet)
app/integration_test/exhaustive_sweep_test.dart        (harness corrections)
app/integration_test/support/sweep_core.dart           (harness corrections)
app/test/harness/sweep_core_test.dart                  (+12 guard tests, 44 total, all pass)
app/integration_test/crud_matrix_test.dart             (untracked)
app/integration_test/destructive_phase_test.dart       (untracked — KNOWN DEFECT, below)
app/integration_test/triage_probe_test.dart            (untracked)
app/integration_test/demo_seed_test.dart               (untracked)
docs/qa/QA_INVARIANT_REGISTER.md                       (untracked)
docs/qa/QA_TRACEABILITY_MATRIX.md                      (untracked)
docs/qa/QA_SECURITY_MATRIX.md                          (untracked)
docs/qa/QA_MASTER_PLAN.md                              (untracked)
```

### Modified by this charter's Phase 1
```
app/pubspec.yaml            intl 0.20.2 -> ^0.20.3 (SDK requires it)
app/pubspec.lock            resolution update
app/analysis_options.yaml   auto-migrated by Flutter 3.47 (excludes build/ and platform dirs)
```

## 5. Known defect in this effort's own test harness

`app/integration_test/destructive_phase_test.dart` **cannot fail.** Its
`record()` (line 58) is a bare `debugPrint`; the file contains exactly one
`expect()`, and it guards shell mount, not the wipe. It therefore prints
`WIPE :: PASS` or `WIPE :: FAIL` and exits zero either way. The only
end-to-end proof that sign-out erases financial data asserts nothing. Tracked as
a release-gate item; see V1_EXECUTION_BOARD.md.

## 6. Inherited evidence

A full 18-subsystem audit completed immediately before this charter:
**1,052 invariants** (134 P0 / 338 P1 / 434 P2 / 146 P3), each proposed by a
subsystem reader and then adversarially verified against source — 622 confirmed,
229 weakened, 14 refuted, 146 added by verifiers, 160 severity downgrades, 115
status downgrades, 10 fabricated handbook citations struck.

Coverage of those 1,052: **284 VERIFIED, 134 TESTED WITH MOCKS, 614 UNVERIFIED,
20 BLOCKED BY EXTERNAL QA**; 526 release-blocking.

Machine-readable source: `~/.qirsh-qa/audit/merged.json` (+ 18 per-domain
`*.verified.json`). Reconciliation against current HEAD is
V1_AUDIT_RECONCILIATION.md. **These are findings, not yet a task list.**
