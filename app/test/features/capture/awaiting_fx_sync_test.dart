import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/domain/finance/money_transport.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// A-6 (app half) — awaiting-FX transactions (amount 0 + foreign amount/currency)
// are held durably and visibly until the server is verified to accept them.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

enum _Rpc { verified, missing, absentKey, offline }

void main() {
  late AppDatabase db;
  late LedgerOutboxQueue q;
  late List<String> calls; // "METHOD path"
  late List<Map<String, dynamic>> inserted;
  var rpc = _Rpc.missing;
  var insertMode = 'ok'; // ok | check23514
  var consent = true;
  late SyncHealth health;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    q = LedgerOutboxQueue(
        db: db, isPushEnabled: () => true, getAuthUserId: () async => 'u1');
    calls = [];
    inserted = [];
    rpc = _Rpc.missing;
    insertMode = 'ok';
    consent = true;
    health = SyncHealth();
  });
  tearDown(() async => db.close());

  Future<void> insertTx(String id,
      {double amount = 0, bool foreign = true}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at,
        foreign_amount, foreign_currency
      ) VALUES (
        '$id', $amount, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
        '$now', '$now', ${foreign ? '100.0' : 'NULL'}, ${foreign ? "'USD'" : 'NULL'}
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
  }

  Future<void> enqueue(String id,
      [OutboxOperation op = OutboxOperation.create]) async {
    await q.enqueue(
        op, (await DriftTransactionRepository(db).getById(id))!);
  }

  SupabaseClient client() {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'tok',
      httpClient: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        http.Response json(int code, Object body) => http.Response(
            jsonEncode(body), code,
            headers: const {'content-type': 'application/json'},
            request: request);
        if (request.url.path.endsWith('/rpc/qirsh_server_capabilities')) {
          switch (rpc) {
            case _Rpc.verified:
              return json(200, {'awaiting_fx_transactions': true});
            case _Rpc.absentKey:
              return json(200, {'something_else': true});
            case _Rpc.missing:
              return json(404, {
                'code': 'PGRST202',
                'message': 'Could not find the function',
              });
            case _Rpc.offline:
              throw http.ClientException('offline');
          }
        }
        if (insertMode == 'check23514') {
          return json(400, {
            'code': '23514',
            'message': 'new row violates check constraint',
          });
        }
        final decoded = jsonDecode(request.body);
        inserted.add(Map<String, dynamic>.from(
            decoded is List ? decoded.single as Map : decoded as Map));
        return json(200, {'id': 'srv-1', 'updated_at': now});
      }),
    );
  }

  ServerCapabilitiesService caps({DateTime Function()? clock}) =>
      ServerCapabilitiesService(
        getAuthUserId: () async => 'u1',
        getClient: client,
        mayEgress: () async => consent,
        health: health,
        getServerUrl: () => 'https://example.supabase.co',
        clock: clock,
      );

  LedgerPushService push(ServerCapabilitiesService? c) => LedgerPushService(
        db: db,
        queue: q,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'u1',
        getClient: client,
        mayEgress: () async => consent,
        health: health,
        capabilities: c,
      );

  Future<Map<String, Object?>> outboxRow() async {
    final r = await db
        .customSelect('SELECT status, failure_class, attempt_count, last_error '
            'FROM ledger_sync_outbox LIMIT 1;')
        .getSingle();
    return r.data;
  }

  int txCalls() => calls.where((c) => c.contains('user_transactions')).length;

  test('RPC missing => unsupported => awaiting row parked, no insert sent',
      () async {
    await insertTx('a');
    await enqueue('a');
    final result = await push(caps()).push();

    expect(result.parked, 1);
    expect(result.pushed, 0);
    expect(txCalls(), 0, reason: 'tripwire: no user_transactions call');
    final row = await outboxRow();
    expect(row['status'], 'parked');
    expect(row['failure_class'], kParkAwaitingServerFxSupport);
    expect(row['attempt_count'], 0);
    final counts = await SyncHealth.queueCounts(db);
    expect(counts.parkedByReason[kParkAwaitingServerFxSupport], 1);
    expect(counts.deadLetter, 0);
  });

  test('RPC key absent => unsupported => parked', () async {
    rpc = _Rpc.absentKey;
    final c = caps();
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.unsupported);
    await insertTx('a');
    await enqueue('a');
    expect((await push(c).push()).parked, 1);
    expect(txCalls(), 0);
  });

  test('probe offline => unknown => parked, and probe is cached once per key',
      () async {
    rpc = _Rpc.offline;
    var now = DateTime(2026, 1, 1);
    final c = caps(clock: () => now);
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.unknown);
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.unknown);
    expect(calls.length, 1, reason: 'unknown re-probes are throttled');
    now = now.add(const Duration(minutes: 3));
    rpc = _Rpc.verified;
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.verified);
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.verified);
    expect(calls.length, 2, reason: 'verified is cached for the session');
  });

  test('capability verified => awaiting row is pushed with amount 0', () async {
    rpc = _Rpc.verified;
    await insertTx('a');
    await enqueue('a');
    final result = await push(caps()).push();
    expect(result.pushed, 1);
    expect(inserted.single['amount'], 0);
    expect(inserted.single['foreign_amount'], 100);
    expect(inserted.single['foreign_currency'], 'USD');
    expect((await db.customSelect('SELECT 1 FROM ledger_sync_outbox').get()),
        isEmpty);
  });

  test('parked rows are re-armed and pushed once the capability flips',
      () async {
    await insertTx('a');
    await enqueue('a');
    final c = caps(clock: () => DateTime(2026, 1, 1));
    expect((await push(c).push()).parked, 1);
    expect(txCalls(), 0);

    rpc = _Rpc.verified;
    await c.awaitingFxTransactions(force: true);
    final result = await push(c).push();
    expect(result.pushed, 1);
    expect(txCalls(), 1);
  });

  test('23514 on an awaiting row (capability believed verified) => parked, '
      'not dead-lettered, capability flips to unsupported', () async {
    rpc = _Rpc.verified;
    insertMode = 'check23514';
    await insertTx('a');
    await enqueue('a');
    final c = caps();
    final result = await push(c).push();
    expect(result.parked, 1);
    expect(result.failed, 0);
    final row = await outboxRow();
    expect(row['status'], 'parked');
    expect(row['failure_class'], kParkAwaitingServerFxSupport);
    expect(row['attempt_count'], 0);
    expect(c.cachedAwaitingFx('u1'), ServerCapabilityState.unsupported);
    expect((await SyncHealth.queueCounts(db)).deadLetter, 0);
  });

  test('non-awaiting 23514 still dead-letters (observable)', () async {
    insertMode = 'check23514';
    await insertTx('p', amount: 50, foreign: false);
    await enqueue('p');
    final result = await push(caps()).push();
    expect(result.failed, 1);
    final row = await outboxRow();
    expect(row['status'], 'dead_letter');
    expect(row['failure_class'], kFailServerCheckViolation);
    expect((await SyncHealth.queueCounts(db)).deadLetter, 1);
  });

  group('dead-letter recovery', () {
    Future<void> deadLetter(String id, String failureClass,
        {String? lastError}) async {
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status='dead_letter', "
          "failure_class='$failureClass', attempt_count=0, "
          "last_error=${lastError == null ? 'NULL' : "'$lastError'"} "
          "WHERE transaction_id='$id';");
    }

    test('CHECK-class awaiting dead letter => parked; others untouched',
        () async {
      await insertTx('a');
      await enqueue('a');
      await deadLetter('a', kFailServerCheckViolation);
      // Priced row with the same failure class: must stay dead.
      await insertTx('p', amount: 50, foreign: false);
      await enqueue('p');
      await deadLetter('p', kFailServerCheckViolation);
      // Awaiting row dead-lettered for a different reason: must stay dead.
      await insertTx('d');
      await enqueue('d');
      await deadLetter('d', kFailDuplicateBusinessKey);

      await push(caps()).push();

      Future<String> status(String id) async => (await db
              .customSelect("SELECT status AS s FROM ledger_sync_outbox "
                  "WHERE transaction_id='$id'")
              .getSingle())
          .read<String>('s');
      expect(await status('a'), 'parked');
      expect(await status('p'), 'dead_letter');
      expect(await status('d'), 'dead_letter');
      expect(txCalls(), 0);
    });

    test('legacy permanentValidation from 23514 is recovered; other legacy '
        'validation is not', () async {
      await insertTx('a');
      await enqueue('a');
      await deadLetter('a', 'permanentValidation',
          lastError: 'PostgrestException(message: x, code: 23514)');
      await insertTx('b');
      await enqueue('b');
      await deadLetter('b', 'permanentValidation',
          lastError: 'PostgrestException(message: x, code: 23502)');
      await push(caps()).push();
      final rows = await db
          .customSelect('SELECT transaction_id AS t, status AS s '
              'FROM ledger_sync_outbox')
          .get();
      final byTx = {
        for (final r in rows) r.read<String>('t'): r.read<String>('s'),
      };
      expect(byTx['a'], 'parked');
      expect(byTx['b'], 'dead_letter');
    });
  });

  test('pricing a parked awaiting row coalesces, unparks and pushes a normal '
      'priced create', () async {
    await insertTx('a');
    await enqueue('a');
    final c = caps();
    expect((await push(c).push()).parked, 1);

    // The user prices it (amount > 0, foreign kept).
    await db.customStatement(
        "UPDATE transactions SET amount = 375.0, amount_minor = 37500 "
        "WHERE id = 'a';");
    await enqueue('a', OutboxOperation.update);

    expect((await db.customSelect('SELECT 1 FROM ledger_sync_outbox').get())
        .length, 1, reason: 'folded into the parked row');
    final row = await outboxRow();
    expect(row['status'], 'pending');

    final result = await push(c).push(); // capability still unsupported
    expect(result.pushed, 1);
    expect(txCalls(), 1);
    expect(inserted.single['amount'], 375);
    expect(inserted.single.containsKey('client_request_id'), isTrue);
  });

  test('consent off => capability probe makes zero calls', () async {
    consent = false;
    final c = caps();
    expect(await c.awaitingFxTransactions(), ServerCapabilityState.unknown);
    expect(calls, isEmpty);
    await insertTx('a');
    await enqueue('a');
    final result = await push(c).push();
    expect(result.parked, 0);
    expect(calls, isEmpty);
  });

  group('pull', () {
    Map<String, dynamic> row({String amount = '0.00', String? foreign}) => {
          'currency': 'SAR',
          'amount_text': amount,
          'foreign_amount_text': foreign,
          'foreign_currency': foreign == null ? null : 'USD',
        };

    test('awaiting-FX row (amount 0 + foreign) deserializes', () {
      final m = deserializeLedgerTransactionMoney(row(foreign: '100.00'));
      expect(m.amountMoney.isZero, isTrue);
      expect(m.foreignMoney!.toDecimalString(), '100.00');
    });

    test('pushed awaiting row round-trips as awaiting on pull', () async {
      rpc = _Rpc.verified;
      await insertTx('a');
      await enqueue('a');
      await push(caps()).push();
      final s = inserted.single;
      final pulled = deserializeLedgerTransactionMoney({
        'currency': s['currency'],
        'amount_text': (s['amount'] as num).toStringAsFixed(2),
        'foreign_amount_text': (s['foreign_amount'] as num).toStringAsFixed(2),
        'foreign_currency': s['foreign_currency'],
      });
      expect(pulled.amountMoney.isZero && pulled.foreignMoney != null, isTrue);
    });

    test('zero amount without a foreign amount is rejected', () {
      expect(() => deserializeLedgerTransactionMoney(row()),
          throwsA(isA<MoneyTransportException>()));
    });

    test('a normal priced row is unchanged', () {
      final m = deserializeLedgerTransactionMoney(row(amount: '12.50'));
      expect(m.amountMoney.toDecimalString(), '12.50');
      expect(m.foreignMoney, isNull);
    });
  });
}
