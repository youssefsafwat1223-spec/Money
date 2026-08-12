import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _insertTx(AppDatabase db, String id) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement(
    "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
    "raw_message, parse_confidence, status, created_at, updated_at) VALUES "
    "('$id', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed', "
    "'$now', '$now');",
  );
  await backfillNonPlanningMoneyV30(db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late LedgerOutboxQueue q;
  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    q = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
    );
  });
  tearDown(() => db.close());

  Future<int> outboxRows([String where = '']) async {
    final clause = where.isEmpty ? '' : ' WHERE $where';
    return (await db
            .customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox$clause;')
            .getSingle())
        .read<int>('n');
  }

  Future<String> op(String txId) async => (await db
          .customSelect(
              "SELECT operation FROM ledger_sync_outbox WHERE transaction_id='$txId';")
          .getSingle())
      .read<String>('operation');

  Future<TransactionEntity> tx(String id) async =>
      (await DriftTransactionRepository(db).getById(id))!;

  group('MALI-052n coalescing', () {
    test('two/five consecutive offline edits coalesce to ONE row', () async {
      await _insertTx(db, 'tx1');
      final t = await tx('tx1');
      await q.enqueue(OutboxOperation.create, t);
      for (var i = 0; i < 5; i++) {
        await q.enqueue(OutboxOperation.update, t);
      }
      expect(await outboxRows(), 1, reason: 'one row, one base token');
      expect(await op('tx1'), 'create', reason: 'create+update stays create');
    });

    test('edit then delete coalesces to a single delete', () async {
      await _insertTx(db, 'tx1');
      final t = await tx('tx1');
      // Pretend it was already synced so a delete is a real server op.
      await db.customStatement(
        "UPDATE transactions SET server_id='srv', sync_status='synced' "
        "WHERE id='tx1';",
      );
      await q.enqueue(OutboxOperation.update, await tx('tx1'));
      await q.enqueue(OutboxOperation.delete, t);
      expect(await outboxRows(), 1);
      expect(await op('tx1'), 'delete');
    });

    test('create then delete before any sync drops the row entirely', () async {
      await _insertTx(db, 'tx1');
      final t = await tx('tx1');
      await q.enqueue(OutboxOperation.create, t);
      await q.enqueue(OutboxOperation.delete, t);
      expect(await outboxRows(), 0, reason: 'never reached server → nothing to do');
    });

    test('two different rows remain independently queued', () async {
      await _insertTx(db, 'tx1');
      await _insertTx(db, 'tx2');
      await q.enqueue(OutboxOperation.create, await tx('tx1'));
      await q.enqueue(OutboxOperation.create, await tx('tx2'));
      await q.enqueue(OutboxOperation.update, await tx('tx1'));
      expect(await outboxRows(), 2, reason: 'coalescing is per-entity');
    });
  });

  group('MALI-023 retry / dead-letter', () {
    Future<String> enqueueOne() async {
      await _insertTx(db, 'tx1');
      await q.enqueue(OutboxOperation.create, await tx('tx1'));
      return (await q.pendingItems()).first.id;
    }

    test('a permanent (validation) failure dead-letters immediately', () async {
      final id = await enqueueOne();
      await q.markFailed(id, 'bad', OutboxFailureClass.permanentValidation);
      expect(await q.pendingItems(), isEmpty, reason: 'not eligible');
      expect(await q.deadLetterCount(), 1);
    });

    test('a transient failure stays pending with a future backoff (no storm)',
        () async {
      final id = await enqueueOne();
      await q.markFailed(id, 'net', OutboxFailureClass.transientNetwork);
      expect(await outboxRows("status='pending'"), 1);
      expect(await q.deadLetterCount(), 0);
      // Not eligible until the backoff elapses (the old bug made it always eligible).
      expect(await q.pendingItems(), isEmpty);
    });

    test('transient failures dead-letter after the bound, then re-arm restores '
        'them (app/schema upgrade)', () async {
      final id = await enqueueOne();
      for (var i = 0; i < kOutboxMaxAttempts; i++) {
        await q.markFailed(id, 'net $i', OutboxFailureClass.transientNetwork);
      }
      expect(await q.deadLetterCount(), 1);

      final rearmed = await q.reArmDeadLetter();
      expect(rearmed, 1);
      expect(await q.deadLetterCount(), 0);
      expect(await q.pendingItems(), hasLength(1), reason: 're-armed & eligible');
    });

    test('a poison (permanent) row does not block unrelated valid rows',
        () async {
      await _insertTx(db, 'poison');
      await _insertTx(db, 'good');
      await q.enqueue(OutboxOperation.create, await tx('poison'));
      await q.enqueue(OutboxOperation.create, await tx('good'));
      final poisonId = (await db
              .customSelect(
                  "SELECT id FROM ledger_sync_outbox WHERE transaction_id='poison';")
              .getSingle())
          .read<String>('id');
      await q.markFailed(poisonId, 'bad', OutboxFailureClass.corruptedPayload);

      final pending = await q.pendingItems();
      expect(pending, hasLength(1));
      expect(pending.first.transactionId, 'good',
          reason: 'the healthy row is still processed');
      expect(await q.deadLetterCount(), 1);
    });
  });

  group('classifyOutboxError', () {
    test('maps error types/codes to the right class', () {
      expect(classifyOutboxError(const SocketException('x')),
          OutboxFailureClass.transientNetwork);
      expect(classifyOutboxError(StateError('goal_parent_not_synced')),
          OutboxFailureClass.missingDependency);
      expect(
          classifyOutboxError(
              const PostgrestException(message: 'dup', code: '23505')),
          OutboxFailureClass.conflict);
      expect(
          classifyOutboxError(const PostgrestException(message: 'x', code: '429')),
          OutboxFailureClass.rateLimit);
      expect(
          classifyOutboxError(const PostgrestException(message: 'x', code: '401')),
          OutboxFailureClass.auth);
      expect(
          classifyOutboxError(const PostgrestException(message: 'x', code: '500')),
          OutboxFailureClass.serverError);
      expect(
          classifyOutboxError(const PostgrestException(message: 'x', code: '23502')),
          OutboxFailureClass.permanentValidation);
      expect(
          classifyOutboxError(const PostgrestException(message: 'x', code: '42703')),
          OutboxFailureClass.unsupportedSchema);
      expect(classifyOutboxError(const FormatException('x')),
          OutboxFailureClass.corruptedPayload);
      expect(OutboxFailureClass.permanentValidation.isPermanent, isTrue);
      expect(OutboxFailureClass.conflict.isConflict, isTrue);
      expect(OutboxFailureClass.transientNetwork.isPermanent, isFalse);
    });
  });
}
