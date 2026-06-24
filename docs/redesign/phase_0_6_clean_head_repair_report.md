# Phase 0.6 Clean HEAD Repair Report

Date: 2026-06-24

Scope: repair only existing clean-HEAD analyzer/build errors blocking Phase 1 Tokens.

Final result: PASS.

## Inputs Read

- `docs/redesign/phase_0_5_repo_preparation_report.md`
- `docs/redesign/phase_0_5_repo_preparation_self_review.md`
- `docs/design_reference/mali_codex_execution_guardrails.md`
- `docs/design_reference/mali_screen_migration_plan.md`

## macOS Validation Artifact Cleanup

The Phase 0.5 build had generated these dirty files:

```text
app/macos/Runner.xcodeproj/project.pbxproj
app/macos/Runner.xcworkspace/contents.xcworkspacedata
app/macos/Podfile.lock
```

Before cleanup, copies were saved to:

```text
../MALI_PHASE0_6_MACOS_VALIDATION_BACKUP/project.pbxproj
../MALI_PHASE0_6_MACOS_VALIDATION_BACKUP/contents.xcworkspacedata
../MALI_PHASE0_6_MACOS_VALIDATION_BACKUP/Podfile.lock
```

Only those macOS validation artifacts were reverted/removed. No other files were cleaned.

The successful Phase 0.6 macOS build regenerated the same macOS files. They were removed/reverted again after the build so they would not enter either commit.

## Analyzer Errors Before Repair

`flutter analyze` initially failed with 19 issues. Exact blocker classes:

```text
lib/features/budgets/budgets_screen.dart:127:44
error • The getter 'pieChart' isn't defined for the type 'AppLucideIcons'

lib/features/capture/capture_entry_sheet.dart:1:8
warning • Unused import: 'dart:io'

lib/features/capture/capture_entry_sheet.dart:34:34
error • The getter 'penLine' isn't defined for the type 'AppLucideIcons'

lib/features/transactions/transaction_details_screen.dart:16:8
warning • Unused import: '../common/app_category_chip.dart'

lib/features/transactions/transaction_details_screen.dart:81:11
warning • The value of the local variable 'isDark' isn't used

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

lib/features/transactions/widgets/confirm_transaction_sheet.dart:19:8
warning • Unused import: 'change_category_sheet.dart'

lib/features/transactions/widgets/confirm_transaction_sheet.dart:60:11
warning • The value of the local variable 'category' isn't used

lib/features/transactions/widgets/confirm_transaction_sheet.dart:61:11
warning • The value of the local variable 'isNewMerchant' isn't used

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
```

## Files Changed

### `app/lib/features/budgets/budgets_screen.dart`

Changed the empty-state icon from missing `AppLucideIcons.pieChart` to existing Material `Icons.pie_chart_outline`.

Reason: compile-only UI repair. No state, provider, route, or behavior change.

### `app/lib/features/capture/capture_entry_sheet.dart`

Removed unused `dart:io` import.

Changed missing `AppLucideIcons.penLine` to existing Material `Icons.edit_outlined`.

Reason: compile-only UI repair. Manual add flow behavior remains unchanged.

### `app/lib/features/transactions/transaction_details_screen.dart`

Removed unused `AppCategoryChip` import and unused `isDark` local.

Replaced invalid `TransactionTypeEntity.expense` check with a local UI-only debit helper:

```text
type != TransactionTypeEntity.income && type != TransactionTypeEntity.refund
```

Reason: adapt UI to existing `TransactionTypeEntity` without editing domain models.

### `app/lib/features/transactions/transactions_screen.dart`

Replaced nonexistent `CategoryView.iconData` with existing `CategoryView.icon`.

Replaced nonexistent `CategoryView.colorValue` with existing `CategoryView.color`.

Replaced nonexistent `TransactionEntity.confidence` with existing `TransactionSourceEntity.aiParsed` source check.

Replaced nonexistent `TransactionType.expense` with existing `TransactionTypeEntity` income/refund debit check.

Reason: adapt list row UI to existing APIs without adding fields/enums.

### `app/lib/features/transactions/widgets/change_category_sheet.dart`

Changed chip icon from missing `AppLucideIcons.tag` to existing `CategoryView.icon`.

Removed now-unused icon import.

Reason: compile-only UI repair that also makes the picker use the category's existing visual metadata.

### `app/lib/features/transactions/widgets/confirm_transaction_sheet.dart`

Removed unused `change_category_sheet.dart` import.

Removed unused `category` and `isNewMerchant` locals.

Changed missing `AppLucideIcons.sparkles` and `AppLucideIcons.calendarDays` to existing Material icons.

Changed chip icon from missing `AppLucideIcons.tag` to existing `CategoryView.icon`.

Fixed category update call to use existing repository API:

```text
updateCategory(transactionId: tx.id, categoryKey: cat.key)
```

The stale invalid call was:

```text
updateCategory(transactionId: tx.id, categoryId: cat.key)
```

Reason: call the existing UI-facing repository method correctly. No repository/provider/domain code was changed.

## Forbidden Scope Confirmation

No files changed under:

```text
app/lib/domain/**
app/lib/data/**
app/lib/engine/**
app/lib/core/router/**
supabase/**
database/schema files
auth/backup/parser/AI/categorization/capture bridge logic
```

No providers or routes were changed.

No business logic was changed.

No fake data or fake features were added.

No new packages were added.

No full stash was applied or popped.

No stash was dropped.

## Stash Safety

Final stash list:

```text
stash@{0}: On feat/accounts-multicurrency: backup: dirty tree before Mali reference Phase 1 tokens
stash@{1}: On feat/accounts-multicurrency: wip: isolate non-phase1 changes before token foundation
```

Both stashes still exist.

## Validation Results

All commands were run from `app/`.

### `flutter analyze`

Result: PASS.

```text
No issues found! (ran in 8.7s)
```

### `flutter test`

Result: PASS.

```text
00:40 +241: All tests passed!
```

Known warning retained:

```text
WARNING (drift): It looks like you've created the database class AppDatabase multiple times.
```

### `flutter build macos --debug`

Result: PASS.

The build was run with escalation because the sandbox blocks writes to Flutter SDK cache files under `/usr/local/share/flutter`.

```text
✓ Built build/macos/Build/Products/Debug/money_companion.app
```

Warnings retained:

- `flutter_secure_storage_macos` and `sign_in_with_apple` do not support Swift Package Manager for macOS yet.
- CocoaPods macOS deployment target warnings for several pods targeting macOS 10.11 or 10.12.

## Remaining Git Status Before Commit

Expected remaining files:

- Six repaired UI Dart files.
- Approved design docs/images from Phase 0/0.5.
- This Phase 0.6 report and self-review.

macOS files were clean after removing validation artifacts again.

## Phase 1 Readiness

Phase 1 Tokens can start after the two allowed commits are created:

1. `fix(ui): repair clean-head build errors before reference migration`
2. `docs: baseline Mali visual reference migration`

Phase 1 has not started in this phase.
