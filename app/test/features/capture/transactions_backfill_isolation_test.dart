import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/transactions_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// A-6: the historic-data backfill must never send an awaiting-FX row directly
// and must isolate a permanently-rejected row instead of aborting the run.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late AppDatabase db;
  late List<Map<String, dynamic>> inserts;
  var rejectMerchant = 'BAD';
  var rejectCode = '23514';
  var rejectStatus = 400;
  var networkDown = false;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
    inserts = [];
    rejectMerchant = 'BAD';
    rejectCode = '23514';
    rejectStatus = 400;
    networkDown = false;
  });
  tearDown(() async => db.close());

  Future<void> seed(String id, String merchant,
      {double amount = 10, bool foreign = false, String? accountId}) async {
    const now = '2026-08-24T10:00:00.000Z';
    await db.customStatement('''
      INSERT INTO transactions(id, amount, currency, type, source, direction,
        raw_merchant, occurred_at, raw_message, parse_confidence, status,
        created_at, updated_at, foreign_amount, foreign_currency, account_id)
      VALUES('$id', $amount, 'SAR', 'payment', 'bank', 'debit', '$merchant',
        '$now', '', 1, 'confirmed', '$now', '$now',
        ${foreign ? '100.0' : 'NULL'}, ${foreign ? "'USD'" : 'NULL'},
        ${accountId == null ? 'NULL' : "'$accountId'"});
    ''');
    await backfillNonPlanningMoneyV30(db);
  }

  SupabaseClient client() => SupabaseClient(
        'https://example.supabase.co',
        'anon',
        accessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          if (networkDown) throw const SocketException('down');
          Response json(int code, Object? body) => Response(
              jsonEncode(body), code,
              headers: const {'content-type': 'application/json'},
              request: request);
          if (request.method == 'GET') return json(200, null);
          final decoded = jsonDecode(request.body);
          final body = Map<String, dynamic>.from(
              decoded is List ? decoded.single as Map : decoded as Map);
          inserts.add(body);
          if (body['merchant'] == rejectMerchant) {
            return json(rejectStatus,
                {'code': rejectCode, 'message': 'rejected'});
          }
          return json(201, {
            'id': 'srv-${inserts.length}',
            'amount_text': '10.00',
            'currency': 'SAR',
            'balance_after_text': null,
            'foreign_amount_text': null,
            'foreign_currency': null,
            'direction': body['direction'],
            'transaction_type': body['transaction_type'],
          });
        }),
      );

  TransactionsBackfillService service() => TransactionsBackfillService(
        db: db,
        getAuthUserId: () async => 'user-a',
        getLocalDataOwnerUid: () async => 'user-a',
        getClient: client,
      );

  Future<Map<String, String>> statuses() async {
    final rows = await db
        .customSelect('SELECT id, sync_status AS s, server_id FROM transactions '
            "WHERE id IN ('ok1','ok2','bad','aw');")
        .get();
    return {for (final r in rows) r.read<String>('id'): r.readNullable<String>('s') ?? ''};
  }

  test('one awaiting-FX row + normal rows: normal rows upload, awaiting row is '
      'handed to the outbox and parked (never sent directly)', () async {
    await seed('ok1', 'A');
    await seed('aw', 'W', amount: 0, foreign: true);
    await seed('ok2', 'B');

    final report = await service().run();

    expect(report.created, 2);
    expect(report.queuedAwaitingFxLocalIds, ['aw']);
    expect(inserts.map((b) => b['merchant']).toSet(), {'A', 'B'});
    expect(inserts.any((b) => b['amount'] == 0), isFalse);
    final s = await statuses();
    expect(s['ok1'], 'synced');
    expect(s['ok2'], 'synced');
    expect(s['aw'], 'pending');

    // The outbox row exists as a create and parks under the A-6 rule.
    final q = LedgerOutboxQueue(
        db: db, isPushEnabled: () => true, getAuthUserId: () async => 'user-a');
    final inserted = inserts.length;
    final result = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-a',
      getClient: client,
      mayEgress: () async => true,
    ).push();
    expect(result.parked, 1);
    expect(inserts.length, inserted, reason: 'parked row is not sent');
    final counts = await SyncHealth.queueCounts(db);
    expect(counts.parkedByReason[kParkAwaitingServerFxSupport], 1);

    // Idempotent: a re-run neither re-sends nor re-queues.
    final again = await service().run();
    expect(again.total, 0);
  });

  test('a permanent per-row failure does not stop the others and is '
      'observable as a dead letter', () async {
    await seed('ok1', 'A');
    await seed('bad', 'BAD');
    await seed('ok2', 'B');

    final report = await service().run();

    expect(report.failedLocalIds, ['bad']);
    expect(report.isClean, isFalse);
    expect(report.created, 2);
    final s = await statuses();
    expect(s['ok1'], 'synced');
    expect(s['ok2'], 'synced');
    expect(s['bad'], isNot('synced'));
    final counts = await SyncHealth.queueCounts(db);
    expect(counts.deadLetter, 1);
    final row = await db
        .customSelect('SELECT failure_class AS f FROM ledger_sync_outbox '
            "WHERE status = 'dead_letter'")
        .getSingle();
    expect(row.read<String>('f'), kFailServerCheckViolation);

    // The dead-lettered row is not retried by the next run.
    expect((await service().run()).total, 0);
  });

  test('a business-key duplicate (23505) is isolated too', () async {
    rejectCode = '23505';
    rejectStatus = 409;
    await seed('bad', 'BAD');
    await seed('ok1', 'A');
    final report = await service().run();
    expect(report.failedLocalIds, ['bad']);
    expect(report.created, 1);
  });

  test('transient network error still stops the run (retried later)',
      () async {
    await seed('ok1', 'A');
    networkDown = true;
    await expectLater(service().run(), throwsA(isA<RepoException>()));
    expect((await statuses())['ok1'], isNot('synced'));
    expect((await SyncHealth.queueCounts(db)).deadLetter, 0);
  });

  test('a permanently-rejected (unsynced) account does not block another '
      'account\'s history; its transactions are reported unresolved, never '
      'sent', () async {
    const now = '2026-08-24T10:00:00.000Z';
    await db.customStatement('DELETE FROM accounts;');
    await db.customStatement('''
      INSERT INTO accounts(id, name, currency, type, created_at, updated_at,
          server_id)
      VALUES ('acctA', 'A', 'SAR', 'bank', '$now', '$now', 'srv-A'),
             ('acctB', 'B', 'SAR', 'bank', '$now', '$now', NULL);
    ''');
    await seed('ok1', 'A', accountId: 'acctA');
    await seed('ok2', 'A2', accountId: 'acctA');
    await seed('bad', 'B', accountId: 'acctB');

    final report = await service().run();

    expect(report.created, 2);
    expect(report.unresolvedAccountLocalIds, ['bad']);
    expect(report.isClean, isFalse); // reconcile counts this => partial
    expect(inserts.map((b) => b['merchant']).toSet(), {'A', 'A2'});
    expect(inserts.every((b) => b['server_account_id'] == 'srv-A'), isTrue);
    final s = await statuses();
    expect(s['ok1'], 'synced');
    expect(s['ok2'], 'synced');
    expect(s['bad'], isNot('synced'));
  });
}
