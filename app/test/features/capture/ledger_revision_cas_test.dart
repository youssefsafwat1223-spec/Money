import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// MALI-022 / 0068 — ledger revision compare-and-set contract tests. Capability
// injected ON; production ships OFF (kServerRevisionCas=false).

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

  // A transaction already synced at revision 5, then edited locally.
  Future<LedgerOutboxQueue> seedSyncedEdit() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at,
        server_id, server_updated_at, server_revision, sync_status
      ) VALUES (
        'tx1', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
        '$now', '$now', 'srv-tx1', '2026-08-01T00:00:00.000Z', 5, 'synced'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
    final q = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
    );
    final tx = (await DriftTransactionRepository(db).getById('tx1'))!;
    await q.enqueue(OutboxOperation.update, tx);
    return q;
  }

  Future<String?> txStatus() async => (await db
          .customSelect("SELECT sync_status FROM transactions WHERE id='tx1';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<int?> txRevision() async => (await db
          .customSelect(
              "SELECT server_revision FROM transactions WHERE id='tx1';")
          .getSingle())
      .readNullable<int>('server_revision');

  test(
      'ON + matching revision: sends the revision predicate and stores the '
      'acknowledged new revision', () async {
    final q = await seedSyncedEdit();
    final now = dateTimeToSql(DateTime.now().toUtc());
    String? path;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        path = '${request.url.path}?${request.url.query}';
        // MALI-026 (Phase-9M): a guarded PATCH decodes the LIST representation.
        return http.Response(
          jsonEncode([
            {'id': 'srv-tx1', 'updated_at': now, 'revision': 6}
          ]),
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
      revisionCasEnabled: true,
    
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    ).push();

    expect(r.pushed, 1);
    expect(path, contains('revision=eq.5'),
        reason: 'the CAS predicate must carry the base revision');
    expect(await txStatus(), 'synced');
    expect(await txRevision(), 6, reason: 'acknowledged revision stored');
  });

  test(
      'ON + stale revision: a zero-row CAS becomes a typed conflict, not an '
      'overwrite', () async {
    final q = await seedSyncedEdit();
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        // MALI-026 (Phase-9M): a guarded PATCH matching 0 rows returns an EMPTY
        // LIST (200), version-independently — never a PGRST116 object error.
        return http.Response(
          jsonEncode(const <Map<String, dynamic>>[]),
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
      revisionCasEnabled: true,
    
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    ).push();

    expect(r.conflicts, 1);
    expect(r.pushed, 0);
    expect(await txStatus(), 'conflict');
    expect(await txRevision(), 5, reason: 'local base revision left untouched');
  });

  test(
      'ON + >1 rows (MANY): a PK-guarded CAS matching multiple rows is an '
      'INVARIANT failure — never a conflict, never a silent success', () async {
    final q = await seedSyncedEdit();
    final now = dateTimeToSql(DateTime.now().toUtc());
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      accessToken: () async => 'token',
      httpClient: MockClient((request) async => http.Response(
            jsonEncode([
              {'id': 'srv-tx1', 'updated_at': now, 'revision': 6},
              {'id': 'srv-tx1', 'updated_at': now, 'revision': 6},
            ]),
            200,
            headers: const {'content-type': 'application/json'},
            request: request,
          )),
    );
    final r = await LedgerPushService(
      db: db,
      queue: q,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      getClient: () => client,
      revisionCasEnabled: true,
    
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    ).push();

    expect(r.failed, 1, reason: 'invariant violation surfaces as a failure');
    expect(r.pushed, 0);
    expect(r.conflicts, 0, reason: 'a >1 cardinality is NOT a conflict');
    expect(await txStatus(), isNot('synced'));
  });
}
