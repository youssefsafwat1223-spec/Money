import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// MALI-026 (Phase-8 B8-2.10 §8/§9/§10/§11) — exact-money PUSH is parked in the
// REAL ledger outbox until the transport capability is verified, then the SAME
// durable row replays with the EXACT decimal-string payload. Legacy (v29) is
// unchanged: it never parks and sends the JSON-number shape.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);
const _legacy = FixedPlanningCutoverCoordinator(PlanningCutoverState.legacy);

Future<void> _insertTx(AppDatabase db, {String id = 'tx-001'}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at
    ) VALUES (
      '$id', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
      '$now', '$now'
    );
  ''');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async => db.close());

  LedgerOutboxQueue queue(PlanningCutoverCoordinator c) => LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-123',
        coordinator: c,
      );

  Future<String> payloadAmountRaw() async {
    final row = await db
        .customSelect('SELECT payload_json FROM ledger_sync_outbox LIMIT 1;')
        .getSingle();
    return row.read<String>('payload_json');
  }

  Future<String?> syncStatus(String id) async => (await db
          .customSelect("SELECT sync_status AS s FROM transactions WHERE id='$id';")
          .getSingle())
      .readNullable<String>('s');

  SupabaseClient client(void Function(Map<String, dynamic>) onSend,
      {bool failIfCalled = false}) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'tok',
      httpClient: MockClient((request) async {
        if (failIfCalled) {
          throw StateError('network must not be called while parked');
        }
        final decoded = jsonDecode(request.body);
        onSend(Map<String, dynamic>.from(
            decoded is List ? decoded.single as Map : decoded as Map));
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
  }

  test('§10 legacy enqueue keeps the JSON-number wire shape', () async {
    await _insertTx(db);
    final q = queue(_legacy);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);
    final amount = (jsonDecode(await payloadAmountRaw()) as Map)['amount'];
    expect(amount, isA<num>());
    expect(amount, 100.0);
  });

  test('§10 canonical enqueue serializes the EXACT decimal string', () async {
    await _insertTx(db);
    final q = queue(_canonical);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);
    final amount = (jsonDecode(await payloadAmountRaw()) as Map)['amount'];
    expect(amount, isA<String>());
    expect(amount, '100.00'); // byte-exact, no double
  });

  test('§8 canonical + unverified push → parked, not sent, not synced',
      () async {
    await _insertTx(db);
    final q = queue(_canonical);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);

    final result = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      coordinator: _canonical,
      pushCapability: () => ExactTransportCapability.unknown,
      getClient: () => client((_) {}, failIfCalled: true),
    ).push();

    expect(result.parked, 1);
    expect(result.pushed, 0);
    expect(await q.parkedCount(), 1);
    expect((await q.pendingItems()).isEmpty, isTrue); // excluded from drain
    expect(await syncStatus('tx-001'), 'pending'); // NOT marked synced
    final row = await db
        .customSelect(
            'SELECT failure_class AS f, attempt_count AS a FROM ledger_sync_outbox LIMIT 1;')
        .getSingle();
    expect(row.read<String>('f'), exactMoneyTransportUnverifiedReason);
    expect(row.read<int>('a'), 0); // no retry consumed
  });

  test('§8 canonical + unsupported push → parked (same safe hold)', () async {
    await _insertTx(db);
    final q = queue(_canonical);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);
    final result = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      coordinator: _canonical,
      pushCapability: () => ExactTransportCapability.unsupported,
      getClient: () => client((_) {}, failIfCalled: true),
    ).push();
    expect(result.parked, 1);
    expect(await q.parkedCount(), 1);
  });

  test('§9 parked row replays with the exact string after verification',
      () async {
    await _insertTx(db);
    final q = queue(_canonical);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);

    // 1) park while unknown
    await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      coordinator: _canonical,
      pushCapability: () => ExactTransportCapability.unknown,
      getClient: () => client((_) {}, failIfCalled: true),
    ).push();
    expect(await q.parkedCount(), 1);

    // 2) simulate a restart: a fresh queue + push over the SAME durable db, now
    // with the capability verified.
    Map<String, dynamic>? sent;
    final q2 = queue(_canonical);
    final result = await LedgerPushService(
      db: db,
      queue: q2,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      coordinator: _canonical,
      pushCapability: () => ExactTransportCapability.verifiedExact,
      getClient: () => client((m) => sent = m),
    ).push();

    expect(result.pushed, 1);
    expect(sent, isNotNull);
    expect(sent!['amount'], isA<String>());
    expect(sent!['amount'], '100.00'); // exact decimal string, no legacy number
    expect(await q2.parkedCount(), 0);
    // markSuccess removed the row (no duplicate, no drop-to-dead-letter).
    expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox;')
                .getSingle())
            .read<int>('n'),
        0);
    expect(await syncStatus('tx-001'), 'synced');
  });

  test('legacy (v29) never parks — sends the number and completes', () async {
    await _insertTx(db);
    final q = queue(_legacy);
    await q.enqueue(OutboxOperation.create,
        (await DriftTransactionRepository(db).getById('tx-001'))!);
    Map<String, dynamic>? sent;
    final result = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      coordinator: _legacy,
      pushCapability: () => ExactTransportCapability.unknown,
      getClient: () => client((m) => sent = m),
    ).push();
    expect(result.parked, 0);
    expect(result.pushed, 1);
    expect(sent!['amount'], isA<num>());
    expect(sent!['amount'], 100.0);
  });
}
