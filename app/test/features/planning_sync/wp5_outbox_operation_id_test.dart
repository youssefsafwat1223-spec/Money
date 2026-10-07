import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

// WP-5 — the operation receipt id and the explicit CAS base revision of a
// queued mutation (both outboxes), and the settings changed-field set.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

GoalEntity _goal(String name) => GoalEntity(
      id: 'g1',
      name: name,
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money.parse('300', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() => db.close());

  LedgerOutboxQueue ledgerQ() => LedgerOutboxQueue(
      db: db, isPushEnabled: () => true, getAuthUserId: () async => 'user-1');
  PlanningOutboxQueue planningQ() => PlanningOutboxQueue(
      db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => 'user-1');

  Future<Map<String, Object?>> ledgerRow() async => (await db
          .customSelect('SELECT operation_id, base_revision, in_flight_seq, '
              'op_seq, payload_json FROM ledger_sync_outbox')
          .getSingle())
      .data;

  Future<void> seedTx() async {
    final now = dateTimeToSql(DateTime.utc(2026, 8, 1));
    await db.customStatement('''
      INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at,
        server_id, server_updated_at, server_revision, sync_status)
      VALUES ('tx1', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9,
        'confirmed', '$now', '$now', 'srv-tx1', '2026-08-01T00:00:00.000Z', 5,
        'synced');
    ''');
    await backfillNonPlanningMoneyV30(db);
  }

  group('ledger outbox', () {
    test('every queued mutation gets an operation id and the edit base revision',
        () async {
      await seedTx();
      final tx = (await DriftTransactionRepository(db).getById('tx1'))!;
      await ledgerQ().enqueue(OutboxOperation.update, tx);
      final r = await ledgerRow();
      expect(r['operation_id'], isA<String>());
      expect(r['base_revision'], 5);
    });

    test('an edit gets a NEW operation id; the old one is remembered only if '
        'it may already have been sent', () async {
      await seedTx();
      final repo = DriftTransactionRepository(db);
      final q = ledgerQ();
      await q.enqueue(OutboxOperation.update, (await repo.getById('tx1'))!);
      final first = (await ledgerRow())['operation_id'];

      // Never on the wire: edit folds in, no prior id kept.
      await q.enqueue(OutboxOperation.update, (await repo.getById('tx1'))!);
      var r = await ledgerRow();
      expect(r['operation_id'], isNot(first));
      expect(jsonDecode(r['payload_json'] as String), isNot(contains('prior_op_ids')));

      // Handed to a push (possibly sent), then edited again.
      final second = r['operation_id'];
      await q.pendingItems();
      await q.enqueue(OutboxOperation.update, (await repo.getById('tx1'))!);
      r = await ledgerRow();
      expect(r['operation_id'], isNot(second));
      expect((jsonDecode(r['payload_json'] as String) as Map)['prior_op_ids'],
          [second]);
    });

    test('a retry of the same op_seq reuses the operation id; a row queued '
        'before v41 gets one lazily and keeps it', () async {
      await seedTx();
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
          attempt_count, status, created_at, updated_at, op_seq)
        VALUES ('legacy', 'tx1', 'update', '{}', 0, 'pending', '2026-07-01',
          '2026-07-01', 1);
      ''');
      final q = ledgerQ();
      final a = (await q.pendingItems()).single;
      expect(a.operationId, isNotNull);
      await db.customStatement('UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
      final b = (await q.pendingItems()).single;
      expect(b.operationId, a.operationId);
    });

    test('an ACK that finds an edit folded in flight advances base_revision',
        () async {
      await seedTx();
      final repo = DriftTransactionRepository(db);
      final q = ledgerQ();
      await q.enqueue(OutboxOperation.update, (await repo.getById('tx1'))!);
      final item = (await q.pendingItems()).single;
      await q.enqueue(OutboxOperation.update, (await repo.getById('tx1'))!);
      await q.acknowledge(item, serverId: 'srv-tx1', serverRevision: 6);
      expect((await ledgerRow())['base_revision'], 6);
    });
  });

  group('planning outbox', () {
    Future<Map<String, Object?>> row() async => (await db
            .customSelect('SELECT operation_id, base_revision, payload_json '
                'FROM planning_sync_outbox')
            .getSingle())
        .data;

    test('operation id + base revision; new id per edit; prior id only when '
        'possibly sent', () async {
      final repo = DriftGoalRepository(db, outboxQueue: planningQ());
      await repo.save(_goal('A'));
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await db.customStatement(
          "UPDATE goals SET server_id='srv-g1', server_revision=7, "
          "server_updated_at='t', sync_status='synced' WHERE id='g1';");
      final q = planningQ();
      await q.enqueueGoal(PlanningSyncOperation.update, (await repo.getById('g1'))!);
      var r = await row();
      expect(r['base_revision'], 7);
      final first = r['operation_id'] as String;
      await q.pendingItems(); // handed to a push
      await q.enqueueGoal(PlanningSyncOperation.update, (await repo.getById('g1'))!);
      r = await row();
      expect(r['operation_id'], isNot(first));
      expect((jsonDecode(r['payload_json'] as String) as Map)['prior_op_ids'], [first]);
    });
  });

  group('settings changed fields (per-field LWW)', () {
    Future<List<String>> changed() async => (((jsonDecode((await db
                    .customSelect("SELECT payload_json FROM planning_sync_outbox "
                        "WHERE entity_type='settings'")
                    .getSingle())
                .read<String>('payload_json')) as Map)['changed_fields']) as List)
        .cast<String>();

    Future<void> bind() async {
      await db.customStatement(
          "UPDATE user_settings SET server_id='srv-s', sync_status='synced';");
      await db.customStatement('DELETE FROM planning_sync_outbox;');
    }

    test('only the fields this save changed; consent only when changed; the '
        'folded row keeps the union', () async {
      final repo = DriftUserSettingsRepository(db, outboxQueue: planningQ());
      await bind();
      var s = await repo.getSettings();
      await repo.saveSettings(s.copyWith(theme: 'dark'));
      expect(await changed(), ['theme']);

      s = await repo.getSettings();
      await repo.saveSettings(s.copyWith(language: 'xx'));
      expect(await changed(), unorderedEquals(['theme', 'language']),
          reason: 'folded edits send every field any of them changed');
    });
  });
}
