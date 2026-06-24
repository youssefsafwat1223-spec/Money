# Phase 0 Reference Baseline Report

Date: 2026-06-24

Scope: Safety Baseline / Dirty Tree Inventory for the Mali visual redesign reference migration.

This phase did not implement UI, did not modify Flutter source files, did not change theme tokens, did not stage files, and did not commit.

## Source Docs Read

- `docs/design_reference/mali_reference_analysis.md`
- `docs/design_reference/mali_visual_adaptation_spec.md`
- `docs/design_reference/mali_screen_migration_plan.md`
- `docs/design_reference/mali_codex_execution_guardrails.md`

## Git Snapshot

Current branch:

```text
feat/accounts-multicurrency
```

Latest 12 commits:

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

Stash list:

```text
stash@{0}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

Pre-report dirty entry count from `git status --short -uall`: 78.

## Dirty Tree Inventory

### A. Reference / Design Docs

These are documentation or design-planning artifacts. They are comparatively safe, but still should be reviewed before Phase 1 so only intentional docs remain.

```text
?? app/docs/mali_redesign_strategy.md
?? docs/claude_design_briefs/00_onboarding_current_inventory.md
?? docs/claude_design_briefs/01_onboarding_claude_design_brief.md
?? docs/claude_design_briefs/01_onboarding_claude_design_prompt.md
?? docs/design_reference/mali_codex_execution_guardrails.md
?? docs/design_reference/mali_reference_analysis.md
?? docs/design_reference/mali_screen_migration_plan.md
?? docs/design_reference/mali_visual_adaptation_spec.md
?? docs/redesign/generated_junk_cleanup_plan.md
?? docs/redesign/phase_1_repo_preparation_report.md
```

### B. Generated Mockup / Reference Images

These appear to be reference images, mockups, or temporary rendered reference outputs. They are not Flutter logic, but they should be intentionally kept, moved, ignored, or removed before Phase 1 to avoid noisy commits.

```text
 M mockups/mali_html_redesign/index.html
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_04_09 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_13_15 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_17_25 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_19_47 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_22_18 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_24_18 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_42_53 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_53_40 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_55_57 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 11_58_44 AM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 12_01_20 PM.png"
?? "app/docs/images/ChatGPT Image Jun 24, 2026, 12_03_22 PM.png"
?? app/mali_ui_explorer.html
?? tmp/pdfs/mali-reference-01.png
?? tmp/pdfs/mali-reference-02.png
?? tmp/pdfs/mali-reference-03.png
?? tmp/pdfs/mali-reference-04.png
?? tmp/pdfs/mali-reference-05.png
?? tmp/pdfs/mali-reference-06.png
?? tmp/pdfs/mali-reference-07.png
?? tmp/pdfs/mali-reference-08.png
?? tmp/pdfs/mali-reference-09.png
?? tmp/pdfs/mali-reference-10.png
?? tmp/pdfs/mali-reference-11.png
?? tmp/pdfs/mali-reference-12.png
?? tmp/pdfs/mali-reference-13.png
?? tmp/pdfs/mali-reference-14.png
?? tmp/pdfs/mali-reference/contact-sheet.png
?? tmp/pdfs/mali-reference/reference-01.png
?? tmp/pdfs/mali-reference/reference-02.png
?? tmp/pdfs/mali-reference/reference-03.png
?? tmp/pdfs/mali-reference/reference-04.png
?? tmp/pdfs/mali-reference/reference-05.png
?? tmp/pdfs/mali-reference/reference-06.png
?? tmp/pdfs/mali-reference/reference-07.png
?? tmp/pdfs/mali-reference/reference-08.png
?? tmp/pdfs/mali-reference/reference-09.png
?? tmp/pdfs/mali-reference/reference-10.png
?? tmp/pdfs/mali-reference/reference-11.png
?? tmp/pdfs/mali-reference/reference-12.png
?? tmp/pdfs/mali-reference/reference-13.png
?? tmp/pdfs/mali-reference/reference-14.png
```

### C. Existing Flutter UI Change

These are tracked Flutter UI files with existing modifications. They are risky for Phase 1 because Phase 1 should be token-only. Do not overwrite, revert, or mix new token work with them without an explicit decision.

```text
 M app/lib/features/budgets/budgets_screen.dart
 M app/lib/features/capture/capture_entry_sheet.dart
 M app/lib/features/transactions/transaction_details_screen.dart
 M app/lib/features/transactions/transactions_screen.dart
 M app/lib/features/transactions/widgets/change_category_sheet.dart
 M app/lib/features/transactions/widgets/confirm_transaction_sheet.dart
```

### D. Existing Business Logic Change

These files are in forbidden redesign scope. They must be reviewed, committed separately, stashed, or otherwise isolated before visual redesign implementation.

```text
 M app/lib/data/catalog/catalog_sync_service.dart
 M app/lib/data/db/app_database.dart
```

### E. Existing Theme / Component Change

No dirty files were clearly classified as existing theme/component changes during this inventory.

### F. Generated / Build / Cache File

These appear generated or tool-created. They should not be mixed into design implementation commits without explicit intent.

```text
 M app/macos/Runner.xcodeproj/project.pbxproj
 M app/macos/Runner.xcworkspace/contents.xcworkspacedata
 M app/pubspec.lock
?? app/macos/Podfile.lock
?? docs/claude_design_briefs/.01_onboarding_claude_design_prompt.md.swp
```

### G. Unknown / Risky

These require explicit review. They include package configuration, pre-revert patch material, and helper scripts that appear to patch or rewrite app files.

```text
 M app/pubspec.yaml
?? PRE_REVERT_uncommitted_tweaks.patch
?? app/fix_all.py
?? app/fix_appbutton.py
?? app/fix_remaining.py
?? app/patch_dashboard.py
?? app/patch_tx.py
?? app/patch_tx_fix.py
?? app/rewrite_budgets.py
?? app/rewrite_details.py
?? app/rewrite_transactions.py
?? app/update_smart_inbox.py
```

## Safe Versus Risky Dirty Files

Safe to keep as docs/reference material, subject to review:

- `docs/design_reference/**`
- `docs/claude_design_briefs/**`, except the `.swp` file
- `app/docs/images/**`
- `app/docs/mali_redesign_strategy.md`
- `docs/redesign/generated_junk_cleanup_plan.md`
- `docs/redesign/phase_1_repo_preparation_report.md`
- `mockups/mali_html_redesign/index.html`, if the mockup is intentional
- `tmp/pdfs/**`, if intentionally retained as generated reference output

Risky before Phase 1:

- `app/lib/data/catalog/catalog_sync_service.dart`
- `app/lib/data/db/app_database.dart`
- all modified Flutter feature UI files
- `app/pubspec.yaml`
- `app/pubspec.lock`
- `app/macos/**` project/workspace/Podfile lock changes
- patch/rewrite helper scripts
- `PRE_REVERT_uncommitted_tweaks.patch`
- editor swap file under `docs/claude_design_briefs/`

## Baseline Validation

All commands were run from `app/`.

### `flutter analyze`

Result: PASS.

Summary:

```text
Resolving dependencies...
Got dependencies!
60 packages have newer versions incompatible with dependency constraints.
Analyzing app...
No issues found! (ran in 11.4s)
```

Notes:

- Flutter printed the standard "new version available" notice.
- Dependency update notices are informational and did not fail analysis.

### `flutter test`

Result: PASS.

Summary:

```text
Resolving dependencies...
Got dependencies!
60 packages have newer versions incompatible with dependency constraints.
01:11 +241: All tests passed!
```

Warnings observed:

- Repeated Drift warning: `It looks like you've created the database class AppDatabase multiple times.`
- This warning appeared during database-heavy tests and did not fail the suite.
- Because this phase does not fix code, the warning is recorded as a pre-existing test-suite warning/risk.

### `flutter build macos --debug`

Initial sandboxed attempt: FAIL due to Flutter SDK cache permissions outside the workspace.

Exact failure:

```text
/usr/local/share/flutter/bin/internal/update_engine_version.sh: line 71: /usr/local/share/flutter/bin/cache/engine.stamp.tmp.77956: Operation not permitted
/usr/local/share/flutter/bin/internal/update_engine_version.sh: line 78: /usr/local/share/flutter/bin/cache/engine.realm: Operation not permitted
```

Escalated rerun: PASS.

Summary:

```text
Resolving dependencies...
Got dependencies!
60 packages have newer versions incompatible with dependency constraints.
The following plugins do not support Swift Package Manager for macos:
  - flutter_secure_storage_macos
  - sign_in_with_apple
Building macOS application...
✓ Built build/macos/Build/Products/Debug/money_companion.app
```

Warnings observed:

- `flutter_secure_storage_macos` and `sign_in_with_apple` do not support Swift Package Manager for macOS yet.
- CocoaPods macOS deployment target warnings appeared for AppAuth, Promises, GTMSessionFetcher, and GTMAppAuth pods. Targets use 10.11 or 10.12 while the supported range starts at 10.13.
- These warnings did not fail the build.

## Safety Assessment For Phase 1

Phase 1 Tokens should not start yet on this working tree.

Reason:

- There are 78 pre-report dirty entries.
- The dirty tree includes forbidden-scope data/database files.
- The dirty tree includes modified feature UI files that Phase 1 must not touch.
- The dirty tree includes package and macOS project files.
- The dirty tree includes patch/rewrite helper scripts whose purpose must be reviewed before future work.

## Recommendation

Phase 0 execution is complete and the technical gates pass after the required build escalation, but Phase 1 should be blocked until the dirty tree is intentionally handled.

Recommended next action before Phase 1:

1. Review and separate the forbidden-scope data/database changes.
2. Decide whether the modified Flutter UI files are intentional work to commit, stash, or preserve on another branch.
3. Decide whether `app/pubspec.yaml`, `app/pubspec.lock`, and macOS project files are intentional.
4. Remove or ignore generated/editor artifacts only if explicitly approved.
5. Keep the reference docs/images if they are approved design inputs.
6. Re-run `git status --short -uall` and the three Flutter gates after the tree is clean or intentionally baselined.

Final status: Phase 0 report created. Phase 1 should not start until the dirty tree is resolved or explicitly accepted.
