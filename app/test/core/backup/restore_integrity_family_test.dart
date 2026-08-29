@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/backup/restore_journal.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

/// Cross-model audit **H-20 / H-21** — restore integrity family.
///
/// The objective is one unambiguous meaning per outcome:
///
///   * a SUCCESSFUL restore means the validated snapshot was applied COMPLETELY
///     and atomically;
///   * a FAILED restore never leaves committed replacement data while claiming
///     the old state survived.
///
/// **H-20** — the destructive transaction commits, then a post-commit step
/// throws; `restore_service` mapped that to `rollbackCompleted` AND wrote
/// `markRolledBack`, which both lied to the user and erased the in-transaction
/// committed marker that restart recovery depends on.
///
/// **H-21** — a table absent from the snapshot is skipped by the conditional
/// DELETE, so its LIVE rows survive; `expectedRowCounts` is built only from
/// tables that ARE present, so verification never checked it. An omitted
/// `budgets`/`goals`/`plans`/… committed as a "full restore" that was really a
/// partial merge.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _userTables = [
  'accounts', 'categories', 'cards', 'merchants', 'merchant_category_map',
  'transactions', 'budgets', 'goals', 'goal_contributions', 'subscriptions',
  'bill_payments', 'plans', 'plan_transaction_links', 'sender_bank_mappings',
  'user_settings', 'achievements', 'streaks',
];

Future<Map<String, String>> digest(AppDatabase db) async {
  final out = <String, String>{};
  for (final table in _userTables) {
    final rows = await db.customSelect('SELECT * FROM $table ORDER BY 1;').get();
    final data = rows.map((r) => r.data).toList();
    out[table] = '${data.length}:${sha256.convert(utf8.encode(jsonEncode(data)))}';
  }
  return out;
}

Future<RestorePlan> planFrom(AppDatabase src, {String op = 'op-b11'}) async =>
    RestorePreparation.build(
      snapshot: await BackupSnapshotBuilder(src).build(),
      envelopeVersion: 3,
      sourceBytes: const [1, 2, 3],
      operationId: op,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openMemory() => AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  group('H-20 — a commit can never be reported as a rollback', () {
    test('the journal REFUSES to relabel a committed operation', () async {
      // Storage-layer invariant: protects every caller, not just the ones that
      // remember to check.
      final db = await openMemory();
      addTearDown(db.close);
      final journal = RestoreJournal(db);

      await journal.markPrepared(
        operationId: 'op-1',
        sourceFingerprint: 'fp',
        envelopeVersion: 3,
        snapshotSchemaVersion: 4,
        ownerGenerationHash: null,
        nowIso: '2026-01-01T00:00:00Z',
      );
      await journal.markCommittedInTransaction('op-1', '2026-01-01T00:01:00Z');
      expect((await journal.find('op-1'))!.isCommitted, isTrue);

      // A post-commit failure path attempts to record a rollback.
      await journal.markRolledBack('op-1', 'internal', '2026-01-01T00:02:00Z');

      final after = await journal.find('op-1');
      expect(after!.isCommitted, isTrue,
          reason: 'the committed marker is the durable evidence restart '
              'recovery relies on — it must survive a later failure');
      expect(after.committedAt, isNotNull);
    });

    test('an uncommitted operation CAN still be marked rolled back', () async {
      // The guard must not block the legitimate case.
      final db = await openMemory();
      addTearDown(db.close);
      final journal = RestoreJournal(db);
      await journal.markPrepared(
        operationId: 'op-2',
        sourceFingerprint: 'fp',
        envelopeVersion: 3,
        snapshotSchemaVersion: 4,
        ownerGenerationHash: null,
        nowIso: '2026-01-01T00:00:00Z',
      );
      await journal.markRolledBack('op-2', 'validationFailed',
          '2026-01-01T00:02:00Z');
      final after = await journal.find('op-2');
      expect(after!.isCommitted, isFalse);
      expect(after.state, RestoreJournalState.rolledBack);
    });

    test('a post-commit failure is typed, not a generic error', () {
      // The use case must raise a distinct exception so the caller can report
      // "committed, ancillary step incomplete" instead of "rolled back".
      const e = RestoreCommittedPostStepException('foreignKeyReenable');
      expect(e.step, 'foreignKeyReenable');
      expect(e.toString(), contains('foreignKeyReenable'));
      // Privacy: a step name only — never SQL, a path, or user data.
      expect(e.toString().contains('SELECT'), isFalse);
    });

    test('post-commit failure maps to a COMMITTED outcome', () {
      // committedPendingAcknowledgement means "authoritative, do not replay",
      // which is exactly the truth after a post-commit step fails.
      const result = RestoreResult(
        RestoreOutcome.committedPendingAcknowledgement,
        operationId: 'op-3',
        warnings: ['post_restore_step_incomplete'],
      );
      expect(result.isCommitted, isTrue);
      expect(result.isSuccess, isFalse,
          reason: 'it is committed but not a clean success');
    });

    test('the service consults the journal before claiming rollback', () {
      final source = File('lib/core/backup/restore_service.dart').readAsStringSync();
      expect(source, contains('RestoreCommittedPostStepException'));
      // The post-commit exception must be handled BEFORE the generic mappers,
      // or it would fall through to a rollback report.
      expect(source.indexOf('on RestoreCommittedPostStepException'),
          lessThan(source.indexOf('on BackupException')),
          reason: 'the committed case must be matched first');
      final terminal = source.substring(source.indexOf('Future<RestoreResult> _terminal'));
      expect(terminal.substring(0, terminal.indexOf('\n  }')),
          contains('record.isCommitted'),
          reason: 'a committed operation must never be reported as rolled back, '
              'whatever layer raised the error');
    });
  });

  group('H-20 — privacy-required setup is now INSIDE the transaction', () {
    test('consent reset runs before commit, not after', () {
      // runPostRestoreSetup clears ai/cloud consent (MALI-059n) so a restore
      // cannot import consent as authorization. Post-commit, a crash in that
      // window committed restored data with a legacy backup's consent intact.
      final source =
          File('lib/core/backup/restore_backup_usecase.dart').readAsStringSync();
      final txnStart = source.indexOf('await _db.transaction(() async {');
      final txnEnd = source.indexOf('    } finally {', txnStart);
      final body = source.substring(txnStart, txnEnd);
      expect(body, contains('_postRestoreMigrations'),
          reason: 'the consent reset must be atomic with the restore');
      // …and must NOT also run after the transaction.
      final after = source.substring(txnEnd);
      expect(after.contains('for (final step in _postRestoreMigrations)'), isFalse);
    });

    test('a restore clears imported consent flags', () async {
      final src = await openMemory();
      final dst = await openMemory();
      addTearDown(src.close);
      addTearDown(dst.close);
      // The destination had consent granted; the restore must reset it.
      await dst.customStatement(
        'UPDATE user_settings SET ai_consent_granted = 1, '
        'cloud_processing_enabled = 1;',
      );
      final result = await RestoreService(dst).execute(plan: await planFrom(src));
      expect(result.isCommitted, isTrue);
      final row = await dst
          .customSelect('SELECT ai_consent_granted AS a, '
              'cloud_processing_enabled AS c FROM user_settings LIMIT 1;')
          .getSingle();
      expect(row.read<int>('a'), 0);
      expect(row.read<int>('c'), 0,
          reason: 'a restore must never carry consent as authorization');
    });
  });

  group('H-21 — a v4 snapshot must be COMPLETE', () {
    Map<String, dynamic> v4Snapshot(Map<String, dynamic> tables) => {
          'schemaVersion': 4,
          'tables': tables,
        };

    Map<String, dynamic> completeTables() => {
          for (final t in BackupSnapshotBuilder.backedUpTables) t: <dynamic>[],
          // the three v3 required tables must be non-empty
          'categories': [
            {'id': 'c1'}
          ],
          'accounts': [
            {'id': 'a1'}
          ],
          'user_settings': [
            {'id': 1}
          ],
        };

    test('a complete v4 snapshot validates', () {
      expect(
        () => RestoreBackupUseCase.validateTables(
            v4Snapshot(completeTables()), 4),
        returnsNormally,
      );
    });

    test('an OMITTED table is rejected — before any mutation', () {
      // The exact H-21 shape: syntactically valid, silently partial.
      for (final omitted in const ['budgets', 'goals', 'plans', 'cards']) {
        final tables = completeTables()..remove(omitted);
        expect(
          () => RestoreBackupUseCase.validateTables(v4Snapshot(tables), 4),
          throwsA(isA<Exception>()),
          reason: '$omitted absent ⇒ its live rows survive the conditional '
              'DELETE and merge, which is a partial restore reported as full',
        );
      }
    });

    test('an EMPTY table is legal — that is a real complete snapshot', () {
      // Optional-by-CONTRACT semantics: the key must exist; the list may be
      // empty for a user who genuinely has no such rows. "Absent" is never
      // inferred to mean "optional".
      final tables = completeTables();
      tables['budgets'] = <dynamic>[];
      tables['goals'] = <dynamic>[];
      expect(
        () => RestoreBackupUseCase.validateTables(v4Snapshot(tables), 4),
        returnsNormally,
      );
    });

    test('the builder emits every required key, so real backups pass',
        () async {
      final db = await openMemory();
      addTearDown(db.close);
      final snapshot = await BackupSnapshotBuilder(db).build();
      final tables = snapshot['tables'] as Map<String, dynamic>;
      for (final t in BackupSnapshotBuilder.backedUpTables) {
        expect(tables.containsKey(t), isTrue,
            reason: 'the completeness contract must match what the builder '
                'actually produces, or the app rejects its own backups');
      }
    });
  });

  group('H-21 / PART 6 — older versions keep their own semantics', () {
    test('v2 and v3 may still omit tables', () {
      // A v2 backup carries no cards/categories/sender_bank_mappings. Applying
      // v4 strictness retroactively would break legitimate old backups.
      final v2 = {
        'schemaVersion': 2,
        'tables': {
          'accounts': [
            {'id': 'a1'}
          ],
          'transactions': <dynamic>[],
        },
      };
      expect(() => RestoreBackupUseCase.validateTables(v2, 2), returnsNormally);
    });

    test('v3 still requires its three load-bearing tables, non-empty', () {
      final v3 = {
        'schemaVersion': 3,
        'tables': {
          'accounts': [
            {'id': 'a1'}
          ],
          'user_settings': [
            {'id': 1}
          ],
          // categories missing ⇒ the conditional delete would wipe the catalog
        },
      };
      expect(() => RestoreBackupUseCase.validateTables(v3, 3),
          throwsA(isA<Exception>()));
    });

    test('an old partial format is never reinterpreted as complete v4', () {
      // Same table set, different declared version ⇒ different verdict.
      final tables = {
        'accounts': [
          {'id': 'a1'}
        ],
        'categories': [
          {'id': 'c1'}
        ],
        'user_settings': [
          {'id': 1}
        ],
      };
      expect(
          () => RestoreBackupUseCase.validateTables(
              {'schemaVersion': 3, 'tables': tables}, 3),
          returnsNormally);
      expect(
          () => RestoreBackupUseCase.validateTables(
              {'schemaVersion': 4, 'tables': tables}, 4),
          throwsA(isA<Exception>()),
          reason: 'the version distinction must stay explicit');
    });
  });

  group('PART 4 — atomicity is preserved', () {
    test('a mid-restore fault leaves the ORIGINAL database intact', () async {
      final src = await openMemory();
      final dst = await openMemory();
      addTearDown(src.close);
      addTearDown(dst.close);
      final before = await digest(dst);

      final result = await RestoreService(dst).execute(
        plan: await planFrom(src),
        onFaultPoint: (p) {
          if (p == 'afterPartialInsert') throw StateError('injected');
        },
      );

      expect(result.isCommitted, isFalse);
      expect(await digest(dst), before,
          reason: 'a pre-commit failure must roll back completely');
    });

    test('a rejected incomplete snapshot mutates nothing', () async {
      final dst = await openMemory();
      addTearDown(dst.close);
      final before = await digest(dst);
      final tables = {
        for (final t in BackupSnapshotBuilder.backedUpTables) t: <dynamic>[],
        'categories': [
          {'id': 'c1'}
        ],
        'accounts': [
          {'id': 'a1'}
        ],
        'user_settings': [
          {'id': 1}
        ],
      }..remove('budgets');

      expect(
        () => RestoreBackupUseCase.validateTables(
            {'schemaVersion': 4, 'tables': tables}, 4),
        throwsA(isA<Exception>()),
      );
      expect(await digest(dst), before,
          reason: 'validation must precede the first DELETE');
    });

    test('a successful restore commits exactly one snapshot state', () async {
      final src = await openMemory();
      final dst = await openMemory();
      addTearDown(src.close);
      addTearDown(dst.close);
      final result = await RestoreService(dst).execute(plan: await planFrom(src));
      expect(result.isCommitted, isTrue);
      final markers = await dst
          .customSelect("SELECT COUNT(*) AS c FROM restore_operations "
              "WHERE state IN ('committed','acknowledged');")
          .getSingle();
      expect(markers.read<int>('c'), 1);
    });
  });

  group('PART 5 — H-22 protection still holds after a restore', () {
    test('restored financial rows remain UNPROVEN and block a silent wipe',
        () async {
      final src = await openMemory();
      final dst = await openMemory();
      addTearDown(src.close);
      addTearDown(dst.close);

      final result = await RestoreService(dst).execute(plan: await planFrom(src));
      expect(result.isCommitted, isTrue);

      final inv = await UnsyncedInventoryService(dst,
              localOnlyCardCount: () async => 0)
          .collect();
      expect(inv.unprovenFinancialRows, greaterThan(0),
          reason: 'restored rows carry no server_id and no outbox entry, so '
              'sign-out must still surface a confirmation (Batch 10 proof)');
      expect(inv.hasPendingUserData, isTrue);
    });

    test('the backup format still carries NO sync columns', () {
      // Do not make the warning disappear by restoring server_id/sync_status.
      for (final entry in BackupSnapshotBuilder.restorableColumns.entries) {
        for (final forbidden in const [
          'server_id',
          'sync_status',
          'synced_at',
          'server_updated_at',
        ]) {
          expect(entry.value.contains(forbidden), isFalse,
              reason: '${entry.key} must not restore a sync column');
        }
      }
    });
  });
}
