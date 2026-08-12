import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_payload.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// MALI-056n — full canonical round-trip: Drift row → outbox payload → server
// representation (captured from the push) → pulled meaning (via the codec the
// pull uses). Proves withdrawal/unknown/refund/etc. survive without semantic
// conversion, plus old-payload and unsupported-version compatibility.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() => db.close());

  LedgerOutboxQueue queue() => LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
      );

  Future<void> insertTx(
    String id, {
    required TransactionTypeEntity type,
    required TransactionSourceEntity source,
    String status = 'confirmed',
    String direction = 'debit',
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, direction, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at
      ) VALUES (
        '$id', 100.0, 'SAR', '${type.name}', '${source.name}', '$direction',
        '$now', '', 0.9, '$status', '$now', '$now'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
  }

  // Pushes the single pending item through a MockClient, returning the captured
  // server row (as it would be stored on the server).
  Future<Map<String, dynamic>> pushAndCapture(LedgerOutboxQueue q) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    Map<String, dynamic>? sent;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        final decoded = jsonDecode(request.body);
        sent = Map<String, dynamic>.from(
            decoded is List ? decoded.single as Map : decoded as Map);
        return http.Response(
          jsonEncode({'id': 'srv', 'updated_at': now}),
          200,
          headers: const {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    final r = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      getClient: () => client,
    ).push();
    expect(r.pushed, 1, reason: 'push should succeed');
    return sent!;
  }

  // Applies the pull codec to a captured server row → the recovered client type.
  TransactionTypeEntity recoverType(Map<String, dynamic> serverRow) {
    final md = serverRow['metadata'];
    return LedgerPayloadCodec.typeFromPull(
      canonicalType: md is Map ? md['canonical_type'] as String? : null,
      serverTransactionType: serverRow['transaction_type'] as String,
    );
  }

  TransactionSourceEntity recoverSource(Map<String, dynamic> serverRow) {
    final md = serverRow['metadata'];
    return LedgerPayloadCodec.sourceFromPull(
      canonicalSource: md is Map ? md['canonical_source'] as String? : null,
      serverSource: serverRow['source'] as String? ?? 'unknown',
    );
  }

  group('round-trip: every type survives Drift → server → pull', () {
    for (final type in TransactionTypeEntity.values) {
      test('$type', () async {
        final q = queue();
        await insertTx('t', type: type, source: TransactionSourceEntity.card);
        final tx = (await DriftTransactionRepository(db).getById('t'))!;
        await q.enqueue(OutboxOperation.create, tx);
        final server = await pushAndCapture(q);
        expect(recoverType(server), type,
            reason: '$type must not be collapsed to another type');
      });
    }
  });

  test('withdrawal is NOT collapsed to payment (the core MALI-010 bug)',
      () async {
    final q = queue();
    await insertTx('t',
        type: TransactionTypeEntity.withdrawal,
        source: TransactionSourceEntity.card);
    final tx = (await DriftTransactionRepository(db).getById('t'))!;
    await q.enqueue(OutboxOperation.create, tx);
    final server = await pushAndCapture(q);
    // Coarse column is expense (server has no withdrawal), but the canonical
    // metadata preserves the exact meaning.
    expect(server['transaction_type'], 'expense');
    expect((server['metadata'] as Map)['canonical_type'], 'withdrawal');
    expect(recoverType(server), TransactionTypeEntity.withdrawal);
  });

  test('unknown does NOT silently become payment', () async {
    final q = queue();
    await insertTx('t',
        type: TransactionTypeEntity.unknown,
        source: TransactionSourceEntity.unknown);
    final tx = (await DriftTransactionRepository(db).getById('t'))!;
    await q.enqueue(OutboxOperation.create, tx);
    final server = await pushAndCapture(q);
    expect(recoverType(server), TransactionTypeEntity.unknown);
  });

  group('source round-trip', () {
    for (final source in TransactionSourceEntity.values) {
      test('$source', () async {
        final q = queue();
        await insertTx('t', type: TransactionTypeEntity.payment, source: source);
        final tx = (await DriftTransactionRepository(db).getById('t'))!;
        await q.enqueue(OutboxOperation.create, tx);
        final server = await pushAndCapture(q);
        expect(recoverSource(server), source);
      });
    }
  });

  test('status round-trips (pending is preserved to the server row)', () async {
    final q = queue();
    await insertTx('t',
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.bank,
        status: 'pending');
    final tx = (await DriftTransactionRepository(db).getById('t'))!;
    await q.enqueue(OutboxOperation.create, tx);
    final server = await pushAndCapture(q);
    expect(server['status'], 'pending');
  });

  test('five consecutive offline edits coalesce to one create payload', () async {
    final q = queue();
    await insertTx('t',
        type: TransactionTypeEntity.refund, source: TransactionSourceEntity.card);
    final tx = (await DriftTransactionRepository(db).getById('t'))!;
    await q.enqueue(OutboxOperation.create, tx);
    for (var i = 0; i < 5; i++) {
      await q.enqueue(OutboxOperation.update, tx);
    }
    final n = (await db
            .customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox;')
            .getSingle())
        .read<int>('n');
    expect(n, 1);
    final server = await pushAndCapture(q);
    expect(recoverType(server), TransactionTypeEntity.refund);
  });

  group('payload version compatibility', () {
    test('an old payload with no version pushes via the legacy mapping', () async {
      // Simulate a row queued by a pre-canonical build: legacy 'type' only.
      final now = dateTimeToSql(DateTime.now().toUtc());
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(
          id, transaction_id, operation, payload_json, attempt_count, status,
          created_at, updated_at
        ) VALUES (
          'ob1', 't', 'create',
          '${jsonEncode({
                'local_id': 't',
                'amount': 50.0,
                'currency': 'SAR',
                'type': 'refund',
                'occurred_at': now,
                'source': 'import',
              })}',
          0, 'pending', '$now', '$now'
        );
      ''');
      final server = await pushAndCapture(queue());
      // Legacy 'refund' maps to server refund; no canonical metadata.
      expect(server['transaction_type'], 'refund');
      expect(recoverType(server), TransactionTypeEntity.refund);
    });

    test('an unsupported FUTURE payload version dead-letters as unsupportedSchema',
        () async {
      final now = dateTimeToSql(DateTime.now().toUtc());
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(
          id, transaction_id, operation, payload_json, attempt_count, status,
          created_at, updated_at
        ) VALUES (
          'ob1', 't', 'create',
          '${jsonEncode({
                'local_id': 't',
                'payload_version': 99,
                'amount': 50.0,
                'currency': 'SAR',
              })}',
          0, 'pending', '$now', '$now'
        );
      ''');
      final q = queue();
      // No network call should happen; push must not misinterpret it.
      final r = await LedgerPushService(
        db: db,
        queue: q,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        getClient: () => throw StateError('must not reach the network'),
      ).push();
      expect(r.pushed, 0);
      final fc = (await db
              .customSelect(
                  "SELECT failure_class FROM ledger_sync_outbox WHERE id='ob1';")
              .getSingle())
          .readNullable<String>('failure_class');
      expect(fc, OutboxFailureClass.unsupportedSchema.name);
    });
  });
}
