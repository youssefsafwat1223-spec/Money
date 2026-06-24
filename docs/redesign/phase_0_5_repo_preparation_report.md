# Phase 0.5 Repo Preparation Report

Date: 2026-06-24

Scope: isolate the dirty tree before Phase 1 Tokens, restore only approved design reference materials, validate, and commit only if safe.

Final result: FAIL. Phase 1 Tokens cannot start.

## Inputs Read

- `docs/redesign/phase_0_reference_baseline_report.md`
- `docs/redesign/phase_0_reference_self_review.md`
- `docs/design_reference/mali_codex_execution_guardrails.md`
- `docs/design_reference/mali_screen_migration_plan.md`

## Safety Snapshot

Branch:

```text
feat/accounts-multicurrency
```

Latest 12 commits at snapshot:

```text
7bd11234 design: create full Mali HTML redesign prototype
9671cf6e feat(ui): redesign dashboard with safe design system
86394a3b feat(ui): migrate app shell navigation to safe design system
24e056a8 feat(ui): add safe shared component foundation
7e339405 feat(ui): add safe phase 1 design token foundation
73a98e48 chore(redesign): Phase 0 — Safety baseline and plans
086814aa feat(ui): redesign budgets screen with shared components
e1ee4a9e feat(ui): redesign transaction details with shared components
f58ddc08 feat(design): Phase 3C — Transactions screen redesign
f2ef07cb feat(ui): redesign smart inbox review flow
24ccc31d feat(ui): redesign dashboard with shared components
70cd6960 chore(ui): finalize typography and icon token foundation
```

Initial stash list:

```text
stash@{0}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

Patch/status backups created:

```text
../MALI_PRE_PHASE1_tracked_dirty_backup.patch
../MALI_PRE_PHASE1_staged_backup.patch
../MALI_PRE_PHASE1_status_backup.txt
```

Backup file verification:

```text
../MALI_PRE_PHASE1_tracked_dirty_backup.patch 70023 bytes
../MALI_PRE_PHASE1_staged_backup.patch 0 bytes
../MALI_PRE_PHASE1_status_backup.txt 3626 bytes
```

The staged backup is empty because there were no staged files.

## Stash Created

Command:

```text
git stash push -u -m "backup: dirty tree before Mali reference Phase 1 tokens"
```

Result:

```text
Saved working directory and index state On feat/accounts-multicurrency: backup: dirty tree before Mali reference Phase 1 tokens
```

Stash list after operation:

```text
stash@{0}: On feat/accounts-multicurrency: backup: dirty tree before Mali reference Phase 1 tokens
stash@{1}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

The full dirty backup stash still exists at `stash@{0}`.

## Restore Operation

After the stash, `git status --short -uall` was clean.

Approved materials were found in the untracked parent of the new stash: `stash@{0}^3`.

Restored only:

```text
docs/design_reference/mali_reference_analysis.md
docs/design_reference/mali_visual_adaptation_spec.md
docs/design_reference/mali_screen_migration_plan.md
docs/design_reference/mali_codex_execution_guardrails.md
docs/redesign/phase_0_reference_baseline_report.md
docs/redesign/phase_0_reference_self_review.md
docs/claude_design_briefs/00_onboarding_current_inventory.md
docs/claude_design_briefs/01_onboarding_claude_design_brief.md
docs/claude_design_briefs/01_onboarding_claude_design_prompt.md
app/docs/images/
```

Immediately after restore, the dirty tree contained only those approved docs/images.

## Files Intentionally Not Restored

These were not restored from the stash:

```text
app/lib/**
app/pubspec.yaml
app/pubspec.lock
app/macos/**
supabase/**
app/fix_all.py
app/fix_appbutton.py
app/fix_remaining.py
app/patch_dashboard.py
app/patch_tx.py
app/patch_tx_fix.py
app/rewrite_budgets.py
app/rewrite_details.py
app/rewrite_transactions.py
app/update_smart_inbox.py
PRE_REVERT_uncommitted_tweaks.patch
docs/claude_design_briefs/.01_onboarding_claude_design_prompt.md.swp
tmp/pdfs/**
app/mali_ui_explorer.html
mockups/mali_html_redesign/index.html
```

## Validation Gates

All validation commands were run from `app/`.

### `flutter analyze`

Result: FAIL.

The clean/restored tree reported 19 analyzer issues. Key errors:

```text
lib/features/budgets/budgets_screen.dart:127:44
error • The getter 'pieChart' isn't defined for the type 'AppLucideIcons'

lib/features/capture/capture_entry_sheet.dart:34:34
error • The getter 'penLine' isn't defined for the type 'AppLucideIcons'

lib/features/transactions/transaction_details_screen.dart:128:61
error • There's no constant named 'expense' in 'TransactionTypeEntity'

lib/features/transactions/transactions_screen.dart:171:51
error • The getter 'iconData' isn't defined for the type 'CategoryView'

lib/features/transactions/transactions_screen.dart:172:52
error • The getter 'colorValue' isn't defined for the type 'CategoryView'

lib/features/transactions/transactions_screen.dart:174:36
error • The getter 'confidence' isn't defined for the type 'TransactionEntity'

lib/features/transactions/transactions_screen.dart:175:47
error • Undefined name 'TransactionType'

lib/features/transactions/widgets/change_category_sheet.dart:91:40
error • The getter 'tag' isn't defined for the type 'AppLucideIcons'

lib/features/transactions/widgets/confirm_transaction_sheet.dart:83:37
error • The getter 'sparkles' isn't defined for the type 'AppLucideIcons'

lib/features/transactions/widgets/confirm_transaction_sheet.dart:115:44
error • The getter 'tag' isn't defined for the type 'AppLucideIcons'

lib/features/transactions/widgets/confirm_transaction_sheet.dart:123:65
error • The named parameter 'categoryKey' is required, but there's no corresponding argument

lib/features/transactions/widgets/confirm_transaction_sheet.dart:125:27
error • The named parameter 'categoryId' isn't defined

lib/features/transactions/widgets/confirm_transaction_sheet.dart:148:37
error • The getter 'calendarDays' isn't defined for the type 'AppLucideIcons'

19 issues found. (ran in 23.9s)
```

Interpretation:

- The errors are in existing Flutter feature UI files on clean HEAD after the dirty stash was removed.
- Phase 0.5 did not fix them because this phase forbids Flutter code changes.
- Phase 1 cannot start while the analyzer fails.

### `flutter test`

Result: PASS.

Summary:

```text
01:09 +241: All tests passed!
```

Warnings:

- Repeated Drift warning: `It looks like you've created the database class AppDatabase multiple times.`
- This warning did not fail tests.

### `flutter build macos --debug`

Sandboxed result: FAIL due to Flutter SDK cache permission:

```text
/usr/local/share/flutter/bin/internal/update_engine_version.sh: line 71: /usr/local/share/flutter/bin/cache/engine.stamp.tmp.2725: Operation not permitted
/usr/local/share/flutter/bin/internal/update_engine_version.sh: line 78: /usr/local/share/flutter/bin/cache/engine.realm: Operation not permitted
```

Escalated rerun result: FAIL due to Flutter compile errors matching analyzer failures.

Key build errors:

```text
lib/features/budgets/budgets_screen.dart:127:44: Error: Member not found: 'pieChart'.
lib/features/transactions/transaction_details_screen.dart:128:61: Error: Member not found: 'expense'.
lib/features/capture/capture_entry_sheet.dart:34:34: Error: Member not found: 'penLine'.
lib/features/transactions/transactions_screen.dart:171:51: Error: The getter 'iconData' isn't defined for the type 'CategoryView'.
lib/features/transactions/transactions_screen.dart:172:52: Error: The getter 'colorValue' isn't defined for the type 'CategoryView'.
lib/features/transactions/transactions_screen.dart:174:36: Error: The getter 'confidence' isn't defined for the type 'TransactionEntity'.
lib/features/transactions/transactions_screen.dart:175:47: Error: The getter 'TransactionType' isn't defined for the type 'TransactionsScreen'.
lib/features/transactions/widgets/confirm_transaction_sheet.dart:83:37: Error: Member not found: 'sparkles'.
lib/features/transactions/widgets/confirm_transaction_sheet.dart:115:44: Error: Member not found: 'tag'.
lib/features/transactions/widgets/confirm_transaction_sheet.dart:148:37: Error: Member not found: 'calendarDays'.
lib/features/transactions/widgets/confirm_transaction_sheet.dart:125:27: Error: No named parameter with the name 'categoryId'.
lib/features/transactions/widgets/change_category_sheet.dart:91:40: Error: Member not found: 'tag'.
Target kernel_snapshot_program failed: Exception
Failed to package /Users/youssef/Documents/Money/app.
Command PhaseScriptExecution failed with a nonzero exit code
** BUILD FAILED **
Build process failed
```

Warnings:

- macOS plugin Swift Package Manager warnings for `flutter_secure_storage_macos` and `sign_in_with_apple`.
- CocoaPods macOS deployment target warnings for AppAuth, Promises, GTMSessionFetcher, and GTMAppAuth.

## Remaining Dirty Files

After restore and validation, the dirty tree contains approved docs/images plus macOS files generated or modified by `flutter build macos --debug`.

Current risky dirty files:

```text
 M app/macos/Runner.xcodeproj/project.pbxproj
 M app/macos/Runner.xcworkspace/contents.xcworkspacedata
?? app/macos/Podfile.lock
```

Approved restored dirty files:

```text
app/docs/images/*.png
docs/claude_design_briefs/00_onboarding_current_inventory.md
docs/claude_design_briefs/01_onboarding_claude_design_brief.md
docs/claude_design_briefs/01_onboarding_claude_design_prompt.md
docs/design_reference/mali_codex_execution_guardrails.md
docs/design_reference/mali_reference_analysis.md
docs/design_reference/mali_screen_migration_plan.md
docs/design_reference/mali_visual_adaptation_spec.md
docs/redesign/phase_0_reference_baseline_report.md
docs/redesign/phase_0_reference_self_review.md
docs/redesign/phase_0_5_repo_preparation_report.md
docs/redesign/phase_0_5_repo_preparation_self_review.md
```

No staged files were present before writing this report.

## Commit Decision

No commit was created.

Reason:

- `flutter analyze` failed.
- `flutter build macos --debug` failed.
- Validation generated risky macOS dirty files.
- The commit condition required only approved design docs/images/reports to remain dirty, all gates to pass, and stash to exist.

## Phase 1 Readiness

Phase 1 Tokens cannot start now.

Blockers:

1. Clean HEAD fails analyzer/build in existing Flutter UI files.
2. `flutter build macos --debug` generated macOS project/lock dirty files during validation.
3. A commit was not allowed because validation failed.

Recommended next step:

- Decide whether to restore the stashed dirty work that previously made validation pass, or fix clean HEAD analyzer/build failures in a separate non-redesign repair phase.
- After that repair/baseline, rerun Phase 0.5 or a focused safety gate before Phase 1 Tokens.
