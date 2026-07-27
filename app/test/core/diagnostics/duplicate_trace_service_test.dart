import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/diagnostics/duplicate_trace_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _tx(
  AppDatabase db, {
  required String id,
  double amount = 150.0,
  String occurredAt = '2026-07-20T10:30:00.000Z',
  String merchant = 'STC',
  String source = 'bank',
  String? serverId,
  String rawMessage = 'SMS body',
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(id, amount, currency, raw_merchant, type, source,
      occurred_at, comparison_timestamp, raw_message, parse_confidence, status,
      created_at, updated_at, server_id)
    VALUES ('$id', $amount, 'SAR', '$merchant', 'payment', '$source',
      '$occurredAt', '$occurredAt', '$rawMessage', 0.9, 'confirmed',
      '$now', '$now', ${serverId == null ? 'NULL' : "'$serverId'"});
  ''');
}

Future<void> _dedupMarker(AppDatabase db, String hash, String txId) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at)
    VALUES ('$hash', '$txId', '$now', '$now');
  ''');
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await db.customStatement('DELETE FROM transactions;');
    await db.customStatement('DELETE FROM dedup_hashes;');
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
  });

  tearDown(() async => db.close());

  test('no duplicates → clean report', () async {
    await _tx(db, id: 't1');
    final report = await DuplicateTraceService(db).run();
    expect(report, contains('no duplicate transaction groups'));
  });

  test('two local rows sharing a server_id → Import collision (Pull)',
      () async {
    await _tx(db, id: 't1', serverId: 'S1');
    await _tx(db, id: 't2', serverId: 'S1', rawMessage: '');
    final report = await DuplicateTraceService(db).run();
    expect(report, contains('DUP GROUP #1'));
    expect(report, contains('CLASSIFICATION: Import collision'));
    expect(report, contains('SECOND ROW PRODUCED BY: Pull'));
    // Both rows appear with their evidence.
    expect(report, contains('local_id=t1'));
    expect(report, contains('local_id=t2'));
  });

  test('two capture rows with distinct payload markers → Double capture',
      () async {
    await _tx(db, id: 't1', source: 'bank');
    await _tx(db, id: 't2', source: 'bank');
    await _dedupMarker(db, 'capture_payload:P1', 't1');
    await _dedupMarker(db, 'capture_payload:P2', 't2');
    final report = await DuplicateTraceService(db).run();
    expect(report, contains('CLASSIFICATION: Double capture'));
    expect(report, contains('SECOND ROW PRODUCED BY: Capture'));
  });

  test('groups only rows that share the logical fingerprint', () async {
    await _tx(db, id: 't1', amount: 150.0, serverId: 'S1');
    await _tx(db, id: 't2', amount: 150.0, serverId: 'S1');
    await _tx(db, id: 't3', amount: 999.0); // different amount → own group
    final report = await DuplicateTraceService(db).run();
    expect(report, contains('duplicate groups: 1'));
    expect(report, isNot(contains('local_id=t3')));
  });
}
