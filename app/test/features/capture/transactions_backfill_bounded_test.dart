import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/features/capture/services/transactions_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A-1c — the backfill is bounded per run: a fixed row budget and a cooperative
/// deadline. Remaining work is reported (`hasMore`) and continues next run with
/// no duplicates.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _seed(AppDatabase db, int n) async {
  final now = DateTime.now().toUtc().toIso8601String();
  for (var i = 0; i < n; i++) {
    final id = 't${i.toString().padLeft(3, '0')}';
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at) VALUES ('$id', 10, 'SAR', 'expense', 'manual', '$now', "
      "'raw', 1.0, 'active', '$now', '$now');",
    );
  }
  await backfillNonPlanningMoneyV30(db);
}

/// Fake PostgREST: no existing row on lookup; insert echoes an exact row.
class _Server {
  final List<String> insertedClientRequestIds = [];

  SupabaseClient client() => SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        accessToken: () async => 'token',
        httpClient: MockClient((request) async {
          const headers = {'content-type': 'application/json'};
          if (request.method == 'GET') {
            return Response('[]', 200, headers: headers, request: request);
          }
          final body = jsonDecode(request.body);
          final map = (body is List ? body.single : body) as Map;
          insertedClientRequestIds.add(map['client_request_id'] as String);
          return Response(
            jsonEncode({
              'id': 'srv-${map['client_request_id']}',
              'amount_text': '10',
              'currency': 'SAR',
              'balance_after_text': null,
              'foreign_amount_text': null,
              'foreign_currency': null,
              'direction': map['direction'],
              'transaction_type': map['transaction_type'],
            }),
            201,
            headers: headers,
            request: request,
          );
        }),
      );
}

void main() {
  late AppDatabase db;
  late _Server server;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    server = _Server();
  });
  tearDown(() async => db.close());

  TransactionsBackfillService service() => TransactionsBackfillService(
        db: db,
        getClient: server.client,
        getAuthUserId: () async => 'u1',
        getLocalDataOwnerUid: () async => 'u1',
      );

  Future<int> unsynced() async => (await db
          .customSelect(
              'SELECT COUNT(*) n FROM transactions WHERE server_id IS NULL')
          .getSingle())
      .read<int>('n');

  test('processes at most maxRows per run and continues next run with no '
      'duplicates; every row is eventually uploaded', () async {
    await _seed(db, 5);

    final r1 = await service().run(maxRows: 2);
    expect(r1.created, 2);
    expect(r1.hasMore, isTrue);
    expect(r1.isClean, isFalse, reason: 'more work remains => not clean');
    expect(await unsynced(), 3);

    final r2 = await service().run(maxRows: 2);
    expect(r2.created, 2);
    expect(r2.hasMore, isTrue);
    expect(await unsynced(), 1);

    final r3 = await service().run(maxRows: 2);
    expect(r3.created, 1);
    expect(r3.hasMore, isFalse);
    expect(r3.isClean, isTrue);
    expect(await unsynced(), 0);

    // Exactly one insert per local row across all runs.
    expect(server.insertedClientRequestIds.length, 5);
    expect(server.insertedClientRequestIds.toSet().length, 5);

    final r4 = await service().run(maxRows: 2);
    expect(r4.total, 0);
    expect(server.insertedClientRequestIds.length, 5,
        reason: 'a finished backfill sends nothing');
  });

  test('exactly maxRows pending => clean, no spurious continuation', () async {
    await _seed(db, 2);
    final r = await service().run(maxRows: 2);
    expect(r.created, 2);
    expect(r.hasMore, isFalse);
    expect(r.isClean, isTrue);
  });

  test('an expired deadline sends nothing and reports hasMore', () async {
    await _seed(db, 3);
    final r = await service()
        .run(deadline: DateTime.now().subtract(const Duration(seconds: 1)));
    expect(r.created, 0);
    expect(r.hasMore, isTrue);
    expect(server.insertedClientRequestIds, isEmpty);
    expect(await unsynced(), 3, reason: 'nothing is claimed as synced');
  });

  test('history larger than one read page is walked in order across runs',
      () async {
    await _seed(db, 450);
    var runs = 0;
    while (await unsynced() > 0 && runs < 10) {
      await service().run();
      runs++;
    }
    expect(runs, 3, reason: '450 rows / 200 per run');
    expect(server.insertedClientRequestIds.toSet().length, 450);
  });
}
