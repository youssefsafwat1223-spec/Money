import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';

// MALI-014 / MALI-076n (Batch-5 closure) §Blocker-5 — the restore state machine:
// confirmation required before mutation, cancellation changes nothing, success only
// after a committed outcome, typed failures map to safe UI phases, acknowledgement.

RestorePlan _plan() => RestorePlan(
      operationId: 'op-ui',
      envelopeVersion: 3,
      snapshotSchemaVersion: 3,
      sourceFingerprint: 'fp',
      tables: const {},
      warnings: const ['legacy_schema_v2'],
    );

void main() {
  test(
      'preparation ends at the confirmation gate; mutation does NOT run until '
      'confirm()', () async {
    var mutated = false;
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async {
        mutated = true;
        return const RestoreResult(RestoreOutcome.success,
            operationId: 'op-ui');
      },
    );
    await c.beginPreparation();
    expect(c.value.phase, RestoreUiPhase.readyForConfirmation);
    expect(c.value.warnings, contains('legacy_schema_v2'));
    expect(mutated, isFalse,
        reason: 'no mutation before explicit confirmation');
  });

  test('cancel at the confirmation gate changes nothing (no mutation)',
      () async {
    var mutated = false;
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async {
        mutated = true;
        return const RestoreResult(RestoreOutcome.success);
      },
    );
    await c.beginPreparation();
    c.cancel();
    expect(c.value.phase, RestoreUiPhase.cancelled);
    await c.confirm(); // ignored — not in readyForConfirmation
    expect(mutated, isFalse);
  });

  test('a preparation failure (e.g. wrong passphrase) is failedWithoutChanges',
      () async {
    final c = RestoreController(
      prepare: () async => throw Exception('auth'),
      mutate: (_) async => const RestoreResult(RestoreOutcome.success),
    );
    await c.beginPreparation();
    expect(c.value.phase, RestoreUiPhase.failedWithoutChanges);
  });

  test('confirm → success shows completed and acknowledges idempotently',
      () async {
    final acked = <String>[];
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.success, operationId: 'op-ui'),
      acknowledge: (id) async => acked.add(id),
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.completed);
    expect(acked, ['op-ui']);
  });

  test(
      'a committed-pending-acknowledgement outcome also completes + acknowledges',
      () async {
    final acked = <String>[];
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async => const RestoreResult(
          RestoreOutcome.committedPendingAcknowledgement,
          operationId: 'op-ui'),
      acknowledge: (id) async => acked.add(id),
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.completed);
    expect(acked, ['op-ui']);
  });

  test(
      'a committed-pending-backup-state outcome is truthful and not acknowledged',
      () async {
    var acked = false;
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async => const RestoreResult(
        RestoreOutcome.committedPendingBackupState,
        operationId: 'op-ui',
        warnings: ['backup_key_state_pending'],
      ),
      acknowledge: (_) async => acked = true,
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.committedPendingBackupState);
    expect(c.value.phase, isNot(RestoreUiPhase.failedWithoutChanges));
    expect(c.value.message, contains('اكتملت استعادة البيانات'));
    expect(acked, isFalse);

    c.cancel();
    expect(c.value.phase, RestoreUiPhase.committedPendingBackupState,
        reason: 'a committed result can never be relabelled cancelled');
  });

  test('a maintenance timeout maps to failedWithoutChanges', () async {
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async =>
          const RestoreResult(RestoreOutcome.maintenanceTimeout),
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.failedWithoutChanges);
  });

  test('a recoveryRequired outcome maps to recoveryRequired', () async {
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async => const RestoreResult(RestoreOutcome.recoveryRequired),
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.recoveryRequired);
  });

  test('ownership change during restore maps to failedWithoutChanges (no ack)',
      () async {
    var acked = false;
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async => const RestoreResult(RestoreOutcome.ownershipChanged),
      acknowledge: (_) async => acked = true,
    );
    await c.beginPreparation();
    await c.confirm();
    expect(c.value.phase, RestoreUiPhase.failedWithoutChanges);
    expect(acked, isFalse);
  });

  test('confirm() is single-use — a second confirm after completion is a no-op',
      () async {
    var mutateCount = 0;
    final c = RestoreController(
      prepare: () async => _plan(),
      mutate: (_) async {
        mutateCount++;
        return const RestoreResult(RestoreOutcome.success,
            operationId: 'op-ui');
      },
    );
    await c.beginPreparation();
    await c.confirm();
    await c.confirm(); // no-op (not in readyForConfirmation)
    expect(mutateCount, 1);
  });
}
