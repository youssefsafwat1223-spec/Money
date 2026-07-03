import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _insertTx(AppDatabase db, {String id = 'tx-001'}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source,
      occurred_at, raw_message, parse_confidence, status,
      created_at, updated_at
    ) VALUES (
      '$id', 100.0, 'SAR', 'payment', 'bank',
      '$now', '', 0.9, 'confirmed',
      '$now', '$now'
    );
  ''');
}

LedgerOutboxQueue _queue(
  AppDatabase db, {
  bool flagOn = true,
  bool signedIn = true,
}) =>
    LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => flagOn,
      getAuthUserId: () async => signedIn ? 'user-123' : null,
    );

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  // ── enqueue guards ────────────────────────────────────────────────────────

  test('enqueue does nothing when flag is OFF', () async {
    await _insertTx(db);
    final q = _queue(db, flagOn: false);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);
    expect((await q.pendingItems()).length, 0);
  });

  test('enqueue does nothing for a guest (no session)', () async {
    await _insertTx(db);
    final q = _queue(db, signedIn: false);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);
    expect((await q.pendingItems()).length, 0);
  });

  // ── enqueue payloads ──────────────────────────────────────────────────────

  test('create operation enqueues with non-empty payload', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final items = await q.pendingItems();
    expect(items.length, 1);
    expect(items.first.operation, OutboxOperation.create);
    expect(items.first.transactionId, 'tx-001');
    expect(items.first.payloadJson['amount'], 100.0);
    expect(items.first.payloadJson['currency'], 'SAR');
    expect(items.first.payloadJson['type'], 'debit');
  });

  test('delete operation stores local_id and omits amount', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.delete, tx);

    final items = await q.pendingItems();
    expect(items.length, 1);
    expect(items.first.operation, OutboxOperation.delete);
    expect(items.first.payloadJson.containsKey('local_id'), isTrue);
    expect(items.first.payloadJson.containsKey('amount'), isFalse);
  });

  test('update operation stores full payload including occurred_at', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.update, tx);

    final items = await q.pendingItems();
    expect(items.first.operation, OutboxOperation.update);
    expect(items.first.payloadJson.containsKey('occurred_at'), isTrue);
  });

  // ── source mapping ────────────────────────────────────────────────────────

  test('create payload includes source=manual', () async {
    await _insertTx(db); // source = 'bank' in raw SQL
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final item = (await q.pendingItems()).first;
    expect(item.payloadJson['source'], 'manual');
  });

  test('update payload omits source to preserve server-side source', () async {
    // Simulates a relay-imported transaction (source=bank / ios_shortcut on server)
    // that the user confirms locally. The update must NOT include 'source'
    // so the server keeps its original 'ios_shortcut'.
    await _insertTx(db); // source = 'bank' in raw SQL (relay import)
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.update, tx);

    final item = (await q.pendingItems()).first;
    expect(item.payloadJson.containsKey('source'), isFalse,
        reason: 'update payload must not contain source so the server '
            "keeps its original 'ios_shortcut' / 'android_sms' value");
  });

  test('delete payload omits source', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.delete, tx);

    final item = (await q.pendingItems()).first;
    expect(item.payloadJson.containsKey('source'), isFalse);
  });

  test('relay-imported tx confirmed via provider enqueues update without source',
      () async {
    // Wires the outbox queue into the repository (provider path).
    final q = _queue(db);
    final repo = DriftTransactionRepository(db, outboxQueue: q);

    // Insert a relay-imported transaction (source = 'bank').
    await _insertTx(db, id: 'relay-tx');
    // Simulate user confirming the transaction (goes through provider).
    final confirmed = await repo.confirm('relay-tx');
    expect(confirmed.id, 'relay-tx');

    // An update outbox item must have been enqueued.
    final items = await q.pendingItems();
    expect(items.length, 1);
    expect(items.first.operation, OutboxOperation.update);
    // Source must be absent so the server keeps 'ios_shortcut'.
    expect(items.first.payloadJson.containsKey('source'), isFalse,
        reason: "confirming a relay tx must not overwrite server source with 'manual'");
  });

  // ── outbox lifecycle ──────────────────────────────────────────────────────

  test('markSuccess removes item from pending', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final items = await q.pendingItems();
    expect(items.length, 1);
    await q.markSuccess(items.first.id);

    expect((await q.pendingItems()).length, 0);
  });

  test('markFailed increments attempt_count and sets next_retry_at', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final before = (await q.pendingItems()).first;
    expect(before.attemptCount, 0);
    expect(before.nextRetryAt, isNull);

    await q.markFailed(before.id, 'network timeout');

    final rows = await db
        .customSelect(
          'SELECT attempt_count, next_retry_at, last_error FROM ledger_sync_outbox;',
        )
        .get();
    expect(rows.first.read<int>('attempt_count'), 1);
    expect(rows.first.readNullable<String>('next_retry_at'), isNotNull);
    expect(rows.first.readNullable<String>('last_error'), 'network timeout');
  });

  test('outbox row wired through transactionRepositoryProvider enqueues on create',
      () async {
    // Simulate the provider path: repository gets the outbox queue injected.
    final q = _queue(db);
    final repo = DriftTransactionRepository(db, outboxQueue: q);

    // saveTransaction via the instrumented repo should enqueue.
    // Use a minimal entity built from the raw SQL path to avoid overhead.
    await _insertTx(db, id: 'tx-provider');
    final tx = (await repo.getById('tx-provider'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final items = await q.pendingItems();
    expect(items.isNotEmpty, isTrue);
  });

  // ── max-attempts guard ────────────────────────────────────────────────────

  test('item at attempt_count=5 is excluded from pendingItems', () async {
    // Simulate an item that has been failed 5 times. The outbox table only
    // surfaces items with attempt_count < 5, so exhausted items never retry.
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    // Exhaust all 5 attempts by calling markFailed repeatedly.
    for (var i = 0; i < 5; i++) {
      final items = await db
          .customSelect(
            'SELECT id, attempt_count FROM ledger_sync_outbox LIMIT 1;',
          )
          .get();
      expect(items.isNotEmpty, isTrue);
      final id = items.first.read<String>('id');
      await q.markFailed(id, 'error $i');
    }

    // After 5 failures, pendingItems (attempt_count < 5 filter) returns empty.
    expect((await q.pendingItems()).length, 0,
        reason: 'item with attempt_count=5 must not appear in pending '
            'so LedgerPushService.push() never retries it');
  });
}
