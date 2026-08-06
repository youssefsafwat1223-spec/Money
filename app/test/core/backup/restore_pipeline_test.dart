import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/ownership_guard.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5) — the restore preparation/mutation
// pipeline: immutable plan, in-transaction verification, atomic rollback, ownership
// races, operation replay, and privacy. Uses in-memory DBs (single connection →
// logical maintenance, no leaseManager) except the lifecycle test which uses a real
// file-lease manager.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _uid = 'local_data_owner_uid';
const _gen = 'local_data_owner_generation';

Future<void> _setAdmission(String? uid, String? gen) async {
  const s = FlutterSecureStorage();
  uid == null ? await s.delete(key: _uid) : await s.write(key: _uid, value: uid);
  gen == null ? await s.delete(key: _gen) : await s.write(key: _gen, value: gen);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  Future<int> count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');

  Future<double> netExpense(AppDatabase db) async => (await db
          .customSelect(
              "SELECT COALESCE(SUM(CASE WHEN type='refund' THEN -amount "
              "WHEN type IN ('payment','withdrawal') THEN amount ELSE 0 END),0) AS t "
              "FROM transactions WHERE status='confirmed';")
          .getSingle())
      .read<double>('t');

  Future<void> seedTxns(AppDatabase db) async {
    final categoryId = (await db
            .customSelect("SELECT id FROM categories LIMIT 1;")
            .getSingle())
        .read<String>('id');
    const now = '2026-06-01T00:00:00.000Z';
    for (final t in [
      ('tx1', 100.0, 'payment'),
      ('tx2', 200.0, 'payment'),
      ('tx3', 50.0, 'refund'),
    ]) {
      await db.customInsert(
        'INSERT INTO transactions(id, amount, currency, raw_merchant, category_id, '
        'type, source, occurred_at, raw_message, parse_confidence, status, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        variables: [
          Variable.withString(t.$1),
          Variable.withReal(t.$2),
          Variable.withString('SAR'),
          Variable.withString('Shop'),
          Variable.withString(categoryId),
          Variable.withString(t.$3),
          Variable.withString('manual'),
          Variable.withString(now),
          Variable.withString('SECRET-RAW-SMS-CANARY'),
          Variable.withReal(1.0),
          Variable.withString('confirmed'),
          Variable.withString(now),
          Variable.withString(now),
        ],
      );
    }
  }

  Future<RestorePlan> planFrom(AppDatabase src,
      {int envelopeVersion = 3, String operationId = 'op-1'}) async {
    final snapshot = await BackupSnapshotBuilder(src).build();
    return RestorePreparation.build(
      snapshot: snapshot,
      envelopeVersion: envelopeVersion,
      sourceBytes: const [1, 2, 3, 4],
      operationId: operationId,
    );
  }

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('success + verification', () {
    test('a v3/current snapshot restores and verifies counts + financial totals',
        () async {
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final expectedTotal = await netExpense(src); // 100 + 200 - 50 = 250
      expect(expectedTotal, 250);

      final dst = await open();
      addTearDown(dst.close);
      final plan = await planFrom(src);
      final result = await RestoreService(dst).execute(plan: plan);

      expect(result.outcome, RestoreOutcome.success);
      expect(await count(dst, 'transactions'), 3);
      expect(await netExpense(dst), 250);
    });
  });

  group('atomic rollback — original DB unchanged', () {
    test('a plan carrying a duplicate transaction id fails in-transaction '
        'verification and rolls back (rollbackCompleted)', () async {
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final dst = await open();
      addTearDown(dst.close);
      // Marker rows in the destination that must survive a rolled-back restore.
      await dst.customStatement(
          "UPDATE user_settings SET country = 'MARKER';");
      final beforeSettings = (await dst
              .customSelect('SELECT country AS c FROM user_settings;')
              .getSingle())
          .read<String>('c');

      final snapshot = await BackupSnapshotBuilder(src).build();
      final plan = RestorePreparation.build(
        snapshot: snapshot,
        envelopeVersion: 3,
        sourceBytes: const [9],
        operationId: 'op-dup',
      );
      // Corrupt: append a DUPLICATE transaction id. The plan expects N+1 rows, but
      // INSERT OR REPLACE dedupes to N → the in-transaction count check fails and
      // the whole restore rolls back before commit.
      final corruptedTables =
          Map<String, List<Map<String, Object?>>>.from(plan.tables);
      final txns = corruptedTables['transactions']!
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      txns.add(Map<String, Object?>.from(txns.first)); // duplicate id
      corruptedTables['transactions'] = txns;
      final corruptPlan = RestorePlan(
        operationId: 'op-dup',
        envelopeVersion: 3,
        snapshotSchemaVersion: 3,
        sourceFingerprint: plan.sourceFingerprint,
        tables: corruptedTables,
        warnings: const [],
      );

      final result = await RestoreService(dst).execute(plan: corruptPlan);
      expect(result.outcome, RestoreOutcome.rollbackCompleted);
      // The destination is UNCHANGED — the marker survived, no transactions leaked.
      final afterSettings = (await dst
              .customSelect('SELECT country AS c FROM user_settings;')
              .getSingle())
          .read<String>('c');
      expect(afterSettings, beforeSettings);
      expect(await count(dst, 'transactions'), 0);
    });
  });

  group('preflight / whitelist (before any mutation)', () {
    test('an unknown table is rejected by preparation', () async {
      expect(
        () => RestorePreparation.build(
          snapshot: {
            'schemaVersion': 3,
            'tables': {
              'accounts': [],
              'categories': [<String, dynamic>{'id': 'c', 'key': 'k'}],
              'user_settings': [<String, dynamic>{'id': 's'}],
              'evil_unknown_table': [<String, dynamic>{'x': 1}],
            },
          },
          envelopeVersion: 3,
          sourceBytes: const [1],
          operationId: 'op',
        ),
        throwsA(isA<BackupException>()),
      );
    });

    test('a sensitive-looking field is rejected by preparation', () async {
      expect(
        () => RestorePreparation.build(
          snapshot: {
            'schemaVersion': 3,
            'tables': {
              'accounts': [<String, dynamic>{'id': 'a', 'db_secret_key': 'X'}],
              'categories': [<String, dynamic>{'id': 'c', 'key': 'k'}],
              'user_settings': [<String, dynamic>{'id': 's'}],
            },
          },
          envelopeVersion: 3,
          sourceBytes: const [1],
          operationId: 'op',
        ),
        throwsA(isA<BackupException>()),
      );
    });

    test('a future snapshot schema is rejected by preparation', () async {
      expect(
        () => RestorePreparation.build(
          snapshot: {'schemaVersion': 99, 'tables': {}},
          envelopeVersion: 3,
          sourceBytes: const [1],
          operationId: 'op',
        ),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('ownership races (§10)', () {
    test('an admission change before mutation aborts without mutation '
        '(ownershipChanged)', () async {
      await _setAdmission('user-A', 'genA');
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final dst = await open();
      addTearDown(dst.close);

      final guard = OwnershipGuard();
      final token = await guard.capture();
      await _setAdmission('user-B', 'genB'); // ownership changed

      final plan = await planFrom(src, operationId: 'op-own');
      final result = await RestoreService(dst).execute(
        plan: plan,
        ownershipGuard: guard,
        admissionToken: token,
      );
      expect(result.outcome, RestoreOutcome.ownershipChanged);
      expect(await count(dst, 'transactions'), 0, reason: 'no mutation occurred');
    });
  });

  group('operation replay (§9)', () {
    test('a committed operation is not destructively replayed (idempotent '
        'success); the same op id with a different source is rejected', () async {
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final dst = await open();
      addTearDown(dst.close);
      final service = RestoreService(dst);

      final plan = await planFrom(src, operationId: 'op-replay');
      expect((await service.execute(plan: plan)).outcome, RestoreOutcome.success);

      // Same op id + same fingerprint → idempotent success, no second mutation.
      final again = await service.execute(plan: plan);
      expect(again.outcome, RestoreOutcome.success);
      expect(await count(dst, 'transactions'), 3);

      // Same op id + DIFFERENT source fingerprint → rejected.
      final mismatched = RestorePlan(
        operationId: 'op-replay',
        envelopeVersion: 3,
        snapshotSchemaVersion: 3,
        sourceFingerprint: 'a-different-fingerprint',
        tables: plan.tables,
        warnings: const [],
      );
      expect((await service.execute(plan: mismatched)).outcome,
          RestoreOutcome.validationFailed);
    });
  });

  group('lifecycle — file-exclusive maintenance timeout (§7)', () {
    test('a held secondary lease makes restore time out (maintenanceTimeout) with '
        'the destination unchanged; releasing it lets a retry succeed', () async {
      final dir = Directory.systemTemp.createTempSync('mali_restore_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final lm = DatabaseLeaseManager(
        leaseDir: '${dir.path}/leases',
        intentPath: '${dir.path}/db.maint',
        settleWindow: const Duration(milliseconds: 40),
        pollStep: const Duration(milliseconds: 15),
      );
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final dst = await open();
      addTearDown(dst.close);

      final held = await lm.acquireShared(); // a live secondary that never releases
      final plan = await planFrom(src, operationId: 'op-timeout');
      final timedOut = await RestoreService(dst).execute(
        plan: plan,
        leaseManager: lm,
        exclusiveTimeout: const Duration(milliseconds: 200),
      );
      expect(timedOut.outcome, RestoreOutcome.maintenanceTimeout);
      expect(await count(dst, 'transactions'), 0, reason: 'no mutation');

      await held.release();
      final ok = await RestoreService(dst).execute(
        plan: plan,
        leaseManager: lm,
        exclusiveTimeout: const Duration(seconds: 2),
      );
      expect(ok.outcome, RestoreOutcome.success);
      expect(await count(dst, 'transactions'), 3);
    });
  });

  group('privacy (§16 canaries)', () {
    test('the plan and result expose no passphrase / key / path / financial value',
        () async {
      final src = await open();
      addTearDown(src.close);
      await seedTxns(src);
      final plan = await planFrom(src, operationId: 'op-privacy');
      final result = await RestoreService(await open()).execute(plan: plan);

      for (final s in [plan.toString(), result.toString()]) {
        // No raw bank-SMS canary, and no fingerprint/secret leakage.
        expect(s, isNot(contains('SECRET-RAW-SMS-CANARY')));
        expect(s, isNot(contains(plan.sourceFingerprint)));
      }
      // The plan's transaction rows never carry raw_message (backup excludes it).
      for (final row in plan.tables['transactions'] ?? const []) {
        expect(row.containsKey('raw_message'), isFalse);
      }
    });
  });
}
