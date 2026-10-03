import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sync-plan T10 (offline delete -> reconnect -> tombstone pushed exactly once)
/// and T13 (app killed with pending ops, including one mid-push -> every op
/// survives and the in-flight one resumes idempotently).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _open(QueryExecutor executor) =>
    AppDatabase.open(executor: executor, keyStore: _MemoryKeyStore());

Future<void> _insertTx(AppDatabase db, String id, {String? serverId}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  final occurred = dateTimeToSql(DateTime.utc(2026, 6, 1, 10));
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at
      ${serverId == null ? '' : ', server_id'}
    ) VALUES (
      '$id', 100.0, 'SAR', 'payment', 'bank', '$occurred', '', 0.9, 'confirmed',
      '$now', '$now'
      ${serverId == null ? '' : ", '$serverId'"}
    );
  ''');
  await backfillNonPlanningMoneyV30(db);
}

LedgerOutboxQueue _queue(AppDatabase db) => LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      coordinator: const SchemaV29PlanningCutoverCoordinator(),
    );

LedgerPushService _push(
        AppDatabase db, LedgerOutboxQueue queue, SupabaseClient client) =>
    LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      getClient: () => client,
      mayEgress: () async => true,
      coordinator: const SchemaV29PlanningCutoverCoordinator(),
    );

SupabaseClient _client(Future<http.Response> Function(http.Request) handler) =>
    SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient(handler),
    );

http.Response _json(Object body, http.Request request) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM ledger_sync_outbox ORDER BY transaction_id;')
          .get())
        r.data
    ];

void main() {
  test(
      'T10: a delete made offline is pushed as exactly ONE tombstone after '
      'reconnect, and never again', () async {
    final db = await _open(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertTx(db, 'tx-1', serverId: 'srv-1');
    final queue = _queue(db);
    final repo = DriftTransactionRepository(db);
    await queue.enqueue(OutboxOperation.delete, (await repo.getById('tx-1'))!);

    var online = false;
    var tombstonesApplied = 0;
    var requests = 0;
    final service = _push(db, queue, _client((request) async {
      requests++;
      if (!online) throw const SocketException('offline');
      if (request.method == 'PATCH' &&
          jsonDecode(request.body)['deleted_at'] != null) {
        tombstonesApplied++;
      }
      return _json([
        {'id': 'srv-1', 'updated_at': '2026-07-01T00:00:00.000Z'}
      ], request);
    }));

    // Offline cycle: nothing lost, still queued as a delete.
    final offline = await service.push();
    expect(offline.failed, 1);
    expect(tombstonesApplied, 0);
    final rows = await _outbox(db);
    expect(rows.single['operation'], 'delete');
    expect(rows.single['status'], 'pending');

    // Reconnect.
    online = true;
    await queue.clearRetryBackoff();
    final reconnect = await service.push();
    expect(reconnect.pushed, 1);
    expect(tombstonesApplied, 1);
    expect(await _outbox(db), isEmpty);

    // Further cycles send nothing.
    final before = requests;
    await service.push();
    await service.push();
    expect(requests, before, reason: 'no re-push of an acknowledged tombstone');
    expect(tombstonesApplied, 1);
  });

  test(
      'T13: killed with pending ops incl. one mid-push -> all ops survive a '
      'restart; the in-flight create resumes idempotently (no duplicate server row)',
      () async {
    final dir = Directory.systemTemp.createTempSync('qirsh_t13_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/app.db');

    // --- process 1: two creates queued, one handed to a push, then "kill".
    var db = await _open(NativeDatabase(file));
    await _insertTx(db, 'tx-a');
    await _insertTx(db, 'tx-b');
    var queue = _queue(db);
    final repo = DriftTransactionRepository(db);
    await queue.enqueue(OutboxOperation.create, (await repo.getById('tx-a'))!);
    await queue.enqueue(OutboxOperation.create, (await repo.getById('tx-b'))!);

    // Server state that survives the app process. The mid-push request REACHED
    // the server (row stored) but the ACK never made it back before the kill.
    final serverRows = <String, String>{}; // client_request_id -> server id
    http.Response upsert(http.Request request) {
      final body = jsonDecode(request.body);
      final rows = body is List ? body : [body];
      final out = <Map<String, Object?>>[];
      for (final row in rows) {
        final crid = (row as Map)['client_request_id'] as String;
        final id = serverRows.putIfAbsent(crid, () => 'srv-$crid');
        out.add({'id': id, 'updated_at': '2026-07-01T00:00:00.000Z'});
      }
      return _json(out.length == 1 ? out.single : out, request);
    }

    final handedOver = (await queue.pendingItems(limit: 1)).single;
    serverRows.putIfAbsent(handedOver.transactionId, () => 'srv-${handedOver.transactionId}');
    expect((await _outbox(db)).where((r) => r['in_flight_seq'] != null), hasLength(1),
        reason: 'one op is durably marked in flight');
    await db.close(); // process killed: no ACK, no markFailed

    // --- process 2: reopen the same file.
    db = await _open(NativeDatabase(file));
    addTearDown(db.close);
    final survivors = await _outbox(db);
    expect(survivors.map((r) => r['transaction_id']), ['tx-a', 'tx-b'],
        reason: 'no pending op is lost across the kill');
    expect(survivors.every((r) => r['status'] == 'pending'), isTrue);

    queue = _queue(db);
    final service = _push(db, queue, _client((request) async => upsert(request)));
    await service.push();

    expect(await _outbox(db), isEmpty, reason: 'both ops drained after restart');
    expect(serverRows.keys.toSet(), {'tx-a', 'tx-b'},
        reason: 'the in-flight create did not produce a second server row');
    final synced = await db
        .customSelect('SELECT id, server_id, sync_status FROM transactions ORDER BY id;')
        .get();
    expect(synced.map((r) => r.read<String>('sync_status')), ['synced', 'synced']);
    expect(synced.map((r) => r.read<String>('server_id')), ['srv-tx-a', 'srv-tx-b']);
  });
}
