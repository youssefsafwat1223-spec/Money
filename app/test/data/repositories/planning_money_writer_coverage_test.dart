import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-026 (Phase-8 B8-2.10 §2) — planning-money writer COMPLETENESS guard.
//
// The authoritative user-mutation boundary for planning money is the two Drift
// repositories, which call PlanningMutationGuard. This test fails if any *new*
// code path writes budgets / goals / goal_contributions money without being
// classified — i.e. it detects a writer that could bypass the guarded boundary.
//
// Every detected planning-money writer must be one of:
//   * guarded-repo  — DriftBudget/GoalRepository (calls the mutation guard);
//   * machine:*     — a non-user reconciliation/bulk path with its OWN gate
//                     (sync parking, import cutover, or the restore preflight).
// A user-facing writer must go through the guarded repo. If this list changes,
// classify the new writer here (and guard it) rather than editing the map blindly.

const _known = <String, String>{
  'lib/data/repositories/drift_budget_repository.dart': 'guarded-repo',
  'lib/data/repositories/drift_goal_repository.dart': 'guarded-repo',
  'lib/features/planning_sync/services/planning_pull_service.dart':
      'machine:sync-pull (parking model)',
  'lib/features/planning_sync/services/planning_child_sync_service.dart':
      'machine:sync-child (parking model)',
  'lib/core/data_portability/drift_financial_importer.dart':
      'machine:import (v30 cutover follow-up)',
  'lib/core/backup/restore_backup_usecase.dart':
      'machine:restore (restore-preflight gated)',
};

// Direct INSERT into a planning table.
final _insertDirect = RegExp(r'INTO (budgets|goals|goal_contributions)\(');
// Money-column UPDATE (excludes category_id / account_id row re-pointing).
final _moneyUpdateBudgets =
    RegExp(r'UPDATE budgets SET [^;]*?(amount|last_notified_spent_amount)');
final _moneyUpdateGoals = RegExp(
    r'UPDATE goals SET [^;]*?(saved_amount|target_amount|auto_save_amount|last_notified_saved_amount)');
// The generic restore writer interpolates the table name.
final _restoreGeneric = RegExp(r'INSERT OR REPLACE INTO \$table');

bool _writesPlanningMoney(String normalized) =>
    _insertDirect.hasMatch(normalized) ||
    _moneyUpdateBudgets.hasMatch(normalized) ||
    _moneyUpdateGoals.hasMatch(normalized) ||
    _restoreGeneric.hasMatch(normalized);

void main() {
  test('every planning-money writer is classified (no unguarded bypass)', () {
    final detected = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized =
          entity.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      if (_writesPlanningMoney(normalized)) {
        detected.add(entity.path.replaceAll(r'\', '/'));
      }
    }

    final unclassified = detected.difference(_known.keys.toSet());
    expect(
      unclassified,
      isEmpty,
      reason: 'New planning-money writer(s) bypassing the guarded boundary: '
          '$unclassified. Route user mutations through the guarded repo, or '
          'add a machine:* classification (with its gate) to _known.',
    );

    final missing = _known.keys.toSet().difference(detected);
    expect(
      missing,
      isEmpty,
      reason: 'Classified writer(s) no longer write planning money: $missing. '
          'Remove them from _known so the guard stays honest.',
    );
  });

  test('the two guarded repos actually call the mutation guard', () {
    for (final path in const [
      'lib/data/repositories/drift_budget_repository.dart',
      'lib/data/repositories/drift_goal_repository.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('_guard.requireMutable('), isTrue,
          reason: '$path must guard its mutating writes');
      expect(src.contains('_guard.requireDeletable('), isTrue,
          reason: '$path must guard its delete');
    }
  });
}
