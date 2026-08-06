import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';

// MALI-014 §Blocker-1/2/3 (Phase-6 final reconciliation) — confirmation capability +
// post-commit lifecycle: `completed` only after commit → verifying →
// reestablishingDatabase (usable proof) → acknowledgement.

RestorePlan _plan() => RestorePlan(
      operationId: 'op-life',
      envelopeVersion: 3,
      snapshotSchemaVersion: 3,
      sourceFingerprint: 'fp',
      tables: const {},
      warnings: const [],
    );

RestoreController _controller({
  required Future<RestoreResult> Function(RestoreConfirmation) mutate,
  Future<bool> Function()? reestablish,
  Future<void> Function(String)? acknowledge,
}) =>
    RestoreController(
      prepare: () async => _plan(),
      mutate: mutate,
      reestablish: reestablish,
      acknowledge: acknowledge,
    );

void main() {
  test('RestoreConfirmation is single-use', () {
    final c = RestoreConfirmation.forTest(_plan());
    expect(c.consume(), isTrue);
    expect(c.consume(), isFalse, reason: 'a confirmation is consumed exactly once');
  });

  test('the confirm() flow emits the ordered post-commit states before completed',
      () async {
    final trace = <RestoreUiPhase>[];
    final c = _controller(
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.success, operationId: 'op-life'),
      reestablish: () async => true,
      acknowledge: (_) async {},
    );
    c.addListener(() => trace.add(c.value.phase));
    await c.beginPreparation();
    await c.confirm();

    // The ordered subsequence must appear (downloading may collapse; later states
    // must preserve order and completed must be last).
    const expected = [
      RestoreUiPhase.readyForConfirmation,
      RestoreUiPhase.waitingForDatabase,
      RestoreUiPhase.restoring,
      RestoreUiPhase.verifying,
      RestoreUiPhase.reestablishingDatabase,
      RestoreUiPhase.completed,
    ];
    var i = 0;
    for (final phase in trace) {
      if (i < expected.length && phase == expected[i]) i++;
    }
    expect(i, expected.length, reason: 'state order: $trace');
    expect(c.value.phase, RestoreUiPhase.completed);
  });

  test('commit succeeds + reopen/admission succeeds → completed + acknowledged',
      () async {
    final acked = <String>[];
    final c = _controller(
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.success, operationId: 'op-life'),
      reestablish: () async => true,
      acknowledge: (id) async => acked.add(id),
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.completed);
    expect(acked, ['op-life'], reason: 'acknowledge only AFTER usable');
  });

  test('commit succeeds but reopen/admission FAILS → recoveryRequired, NOT '
      'completed, and NOT acknowledged', () async {
    var acked = false;
    final c = _controller(
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.success, operationId: 'op-life'),
      reestablish: () async => false, // database not usable after commit
      acknowledge: (_) async => acked = true,
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.recoveryRequired);
    expect(acked, isFalse,
        reason: 'never acknowledge before the database is usable');
  });

  test('a committedPendingAcknowledgement result (restart discovery) also completes '
      'after a usable proof', () async {
    final c = _controller(
      mutate: (_) async => const RestoreResult(
          RestoreOutcome.committedPendingAcknowledgement, operationId: 'op-life'),
      reestablish: () async => true,
      acknowledge: (_) async {},
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.completed);
  });

  test('a maintenance timeout maps to failedWithoutChanges (never completed)',
      () async {
    final c = _controller(
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.maintenanceTimeout),
      reestablish: () async => true,
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.failedWithoutChanges);
  });

  test('cancel before confirmation destroys the pending confirmation basis — a '
      'later confirm() runs no mutation', () async {
    var mutated = false;
    final c = _controller(
      mutate: (_) async {
        mutated = true;
        return const RestoreResult(RestoreOutcome.success);
      },
      reestablish: () async => true,
    );
    await c.beginPreparation();
    c.cancel();
    expect(c.value.phase, RestoreUiPhase.cancelled);
    await c.confirm();
    expect(mutated, isFalse);
  });

  test('confirm() is single-use — a second confirm after completion is a no-op',
      () async {
    var count = 0;
    final c = _controller(
      mutate: (_) async {
        count++;
        return const RestoreResult(RestoreOutcome.success, operationId: 'op-life');
      },
      reestablish: () async => true,
      acknowledge: (_) async {},
    );
    await c.beginPreparation();
    await c.confirm();
    await c.confirm();
    expect(count, 1);
  });
}
