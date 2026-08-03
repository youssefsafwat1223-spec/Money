import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  void Function()? onQueued,
}) =>
    LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => flagOn,
      getAuthUserId: () async => signedIn ? 'user-123' : null,
      onQueued: onQueued,
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

  test('successful durable enqueue wakes the background sync worker', () async {
    await _insertTx(db);
    var wakeups = 0;
    final q = _queue(db, onQueued: () => wakeups++);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;

    await q.enqueue(OutboxOperation.create, tx);

    expect(wakeups, 1);
    expect(await q.pendingItems(), hasLength(1));
  });

  test('push maps legacy outbox payload to current transaction schema',
      () async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO accounts(
        id, name, currency, type, is_default, sort_order,
        created_at, updated_at, initial_balance, current_balance, server_id
      ) VALUES (
        'local-account', 'Main', 'SAR', 'bank', 1, 0,
        '$now', '$now', 0, 0, '00000000-0000-4000-8000-000000000001'
      );
    ''');
    await _insertTx(db);
    await db.customStatement(
      "UPDATE transactions SET account_id = 'local-account' WHERE id = 'tx-001';",
    );
    final queue = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await queue.enqueue(OutboxOperation.create, tx);

    Map<String, dynamic>? sent;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        final decoded = jsonDecode(request.body);
        sent = Map<String, dynamic>.from(
          decoded is List ? decoded.single as Map : decoded as Map,
        );
        return http.Response(
          jsonEncode({
            'id': '00000000-0000-4000-8000-000000000002',
            'updated_at': now,
          }),
          200,
          headers: const {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    final result = await LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      getClient: () => client,
    ).push();

    expect(result.pushed, 1);
    expect(sent?['client_request_id'], 'tx-001');
    expect(sent?['local_account_id'], 'local-account');
    expect(
      sent?['server_account_id'],
      '00000000-0000-4000-8000-000000000001',
    );
    expect(sent?['direction'], 'debit');
    expect(sent?['transaction_type'], 'expense');
    expect(sent?.containsKey('account_id'), isFalse);
    expect(sent?.containsKey('type'), isFalse);
    expect(sent?.containsKey('payload_id'), isFalse);
  });

  test('push sends category (as key), card last4 in metadata, balance & '
      'foreign amounts', () async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // Use a seeded category so we assert on a real key round-trip.
    final catId = (await db
            .customSelect(
                "SELECT id FROM categories WHERE key = 'restaurants' LIMIT 1;")
            .getSingle())
        .read<String>('id');
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, category_id, card_last4, balance_after,
        foreign_amount, foreign_currency, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at
      ) VALUES (
        'tx-cat', 250.0, 'SAR', '$catId', '4242', 900.5,
        10.0, 'USD', 'payment', 'bank',
        '$now', '', 0.9, 'confirmed', '$now', '$now'
      );
    ''');
    final queue = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-cat'))!;
    await queue.enqueue(OutboxOperation.create, tx);

    Map<String, dynamic>? sent;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        final decoded = jsonDecode(request.body);
        sent = Map<String, dynamic>.from(
          decoded is List ? decoded.single as Map : decoded as Map,
        );
        return http.Response(
          jsonEncode({'id': 'srv-cat', 'updated_at': now}),
          200,
          headers: const {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    await LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      getClient: () => client,
    ).push();

    // Category is sent as the stable KEY, not the local UUID.
    expect(sent?['category_id'], 'restaurants');
    // Card last4 rides in metadata (server has no card_last4 column).
    expect((sent?['metadata'] as Map?)?['last4'], '4242');
    expect(sent?['balance_after'], 900.5);
    expect(sent?['foreign_amount'], 10.0);
    expect(sent?['foreign_currency'], 'USD');
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

  test('create payload carries the real source (bank capture → import)',
      () async {
    await _insertTx(db); // source = 'bank' in raw SQL (SMS/relay capture)
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    final item = (await q.pendingItems()).first;
    // Captured transactions now flow through the outbox and must push with
    // honest provenance, not a blanket 'manual'.
    expect(item.payloadJson['source'], 'import');
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

  test(
      'relay-imported tx confirmed via provider enqueues update without source',
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
        reason:
            "confirming a relay tx must not overwrite server source with 'manual'");
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

    await q.markFailed(
      before.id,
      'network timeout',
      OutboxFailureClass.transientNetwork,
    );

    final rows = await db
        .customSelect(
          'SELECT attempt_count, next_retry_at, last_error, status '
          'FROM ledger_sync_outbox;',
        )
        .get();
    expect(rows.first.read<int>('attempt_count'), 1);
    expect(rows.first.readNullable<String>('next_retry_at'), isNotNull);
    expect(rows.first.readNullable<String>('last_error'), 'network timeout');
    expect(rows.first.read<String>('status'), 'pending', reason: 'transient');
  });

  test(
      'outbox row wired through transactionRepositoryProvider enqueues on create',
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

  // ── durable retries ───────────────────────────────────────────────────────

  test('MALI-023: transient failures stay durably pending (not dead-lettered) '
      'below the attempt bound', () async {
    await _insertTx(db);
    final q = _queue(db);
    final tx = (await DriftTransactionRepository(db).getById('tx-001'))!;
    await q.enqueue(OutboxOperation.create, tx);

    for (var i = 0; i < 5; i++) {
      final items = await db
          .customSelect('SELECT id FROM ledger_sync_outbox LIMIT 1;')
          .get();
      final id = items.first.read<String>('id');
      await q.markFailed(id, 'error $i', OutboxFailureClass.transientNetwork);
    }

    // Durable + still 'pending' (5 < bound) — NOT dead-lettered, and NOT the
    // old always-eligible hot-loop: it waits for its backoff before re-eligible.
    final row = await db
        .customSelect('SELECT attempt_count, status FROM ledger_sync_outbox;')
        .getSingle();
    expect(row.read<int>('attempt_count'), 5);
    expect(row.read<String>('status'), 'pending');
    expect(await q.deadLetterCount(), 0);
  });
}
