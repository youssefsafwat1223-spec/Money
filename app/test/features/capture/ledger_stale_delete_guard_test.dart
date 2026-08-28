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

// MALI-026 (Phase-9K) — the ledger parent tombstone must be GUARDED, never an
// unconditional id-only overwrite. A stale delete replayed against a row that a
// newer update advanced past our base must NOT tombstone it. Capability injected
// ON where noted; production ships OFF (kServerRevisionCas=false).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// A single-object body (used for the GET row-state reads, which keep maybeSingle).
http.Response _object(Map<String, dynamic> m, http.BaseRequest req) =>
    http.Response(jsonEncode(m), 200,
        headers: const {'content-type': 'application/json'}, request: req);

// MALI-026 (Phase-9M): a LIST body — how a guarded PATCH (and a GET) actually
// return their affected rows. This models cardinality directly, not an English
// PGRST116 message.
http.Response _arr(List<Map<String, dynamic>> l, http.BaseRequest req) =>
    http.Response(jsonEncode(l), 200,
        headers: const {'content-type': 'application/json'}, request: req);

// Zero matched rows → an EMPTY LIST (works for both a guarded PATCH → null and a
// GET maybeSingle → null); version-independent, no PGRST116.
http.Response _zeroRow(http.BaseRequest req) => _arr(const [], req);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() => db.close());

  // A transaction already synced at [revision] with a known server_updated_at
  // base, then deleted locally (delete enqueued, carrying both base tokens).
  Future<LedgerOutboxQueue> seedSyncedDelete({
    int? revision = 5,
    String base = '2026-08-01T00:00:00.000Z',
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at,
        server_id, server_updated_at, server_revision, sync_status
      ) VALUES (
        'tx1', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
        '$now', '$now', 'srv-tx1', '$base', ${revision ?? 'NULL'}, 'synced'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
    final q = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
    );
    final tx = (await DriftTransactionRepository(db).getById('tx1'))!;
    await q.enqueue(OutboxOperation.delete, tx);
    return q;
  }

  Future<String?> txStatus() async => (await db
          .customSelect("SELECT sync_status FROM transactions WHERE id='tx1';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<int> outboxCount() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox;')
          .getSingle())
      .read<int>('n');

  SupabaseClient client(
    List<String> seen, {
    required http.Response Function(http.BaseRequest) onPatch,
    http.Response Function(http.BaseRequest)? onGet,
  }) =>
      SupabaseClient(
        'https://example.supabase.co',
        'anon',
        accessToken: () async => 'token',
        httpClient: MockClient((req) async {
          seen.add('${req.method} ${req.url.query} body=${req.body}');
          if (req.method == 'PATCH') return onPatch(req);
          return (onGet ?? (r) => _zeroRow(r))(req);
        }),
      );

  Future<LedgerPushResult> push(SupabaseClient c, {required bool casEnabled}) =>
      LedgerPushService(
        db: db,
        queue: (LedgerOutboxQueue(
          db: db,
          isPushEnabled: () => true,
          getAuthUserId: () async => 'user-1',
        )),
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        getClient: () => c,
        revisionCasEnabled: casEnabled,
      
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    ).push();

  test(
      'A/§8 CAS-on + matching revision: tombstone sends the revision predicate '
      '+ deleted_at, and succeeds', () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    final c = client(seen,
        onPatch: (req) => _arr([
              {'id': 'srv-tx1', 'updated_at': 't2', 'revision': 6}
            ], req));
    final r = await push(c, casEnabled: true);
    expect(r.pushed, 1);
    expect(r.conflicts, 0);
    final patch = seen.firstWhere((s) => s.startsWith('PATCH'));
    expect(patch, contains('revision=eq.5'),
        reason: 'the guarded tombstone must carry the base-revision CAS');
    expect(patch, contains('deleted_at'));
    expect(await outboxCount(), 0);
  });

  test(
      'B/§9 UPDATE→stale-delete (CAS-on, revision advanced): a zero-row '
      'tombstone becomes a CONFLICT, the server row is NOT tombstoned',
      () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    // The server moved to revision 9 (a newer accepted update), so the
    // revision=eq.5 tombstone matches 0 rows; the row is still live.
    final c = client(seen,
        onPatch: _zeroRow, onGet: (req) => _object({'deleted_at': null}, req));
    final r = await push(c, casEnabled: true);
    expect(r.conflicts, 1);
    expect(r.pushed, 0);
    expect(await txStatus(), 'conflict',
        reason: 'the delete intent is preserved, recoverable');
    // We fetched the row state to classify (never a blind delete).
    expect(seen.any((s) => s.startsWith('GET')), isTrue);
  });

  test(
      'C/§6 two-delete idempotency (CAS-on, already tombstoned): a zero-row '
      'tombstone on an already-deleted row is a benign success', () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    final c = client(seen,
        onPatch: _zeroRow,
        onGet: (req) =>
            _object({'deleted_at': '2026-08-02T00:00:00.000Z'}, req));
    final r = await push(c, casEnabled: true);
    expect(r.pushed, 1, reason: 'converged — the row is already gone');
    expect(r.conflicts, 0);
    expect(await outboxCount(), 0);
  });

  test(
      'D/§6.C absent (CAS-on): a zero-row tombstone whose row is gone is '
      'fail-closed (conflict), never a silent success', () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    final c = client(seen, onPatch: _zeroRow, onGet: _zeroRow); // GET → null
    final r = await push(c, casEnabled: true);
    expect(r.conflicts, 1);
    expect(r.pushed, 0);
    expect(await txStatus(), 'conflict');
  });

  test(
      'E CAS-off + matching base: the tombstone guards on updated_at (never '
      'id-only) and succeeds', () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    final c = client(seen,
        onPatch: (req) => _arr([
              {'id': 'srv-tx1', 'updated_at': 't2'}
            ], req));
    final r = await push(c, casEnabled: false);
    expect(r.pushed, 1);
    final patch = seen.firstWhere((s) => s.startsWith('PATCH'));
    expect(patch, contains('updated_at=eq.'),
        reason: 'the OFF path guards on the last-known updated_at');
    expect(patch, contains('deleted_at'));
  });

  test(
      'F CAS-off + moved base: a zero-row guarded tombstone becomes a conflict',
      () async {
    await seedSyncedDelete(revision: 5);
    final seen = <String>[];
    final c = client(seen,
        onPatch: _zeroRow, onGet: (req) => _object({'deleted_at': null}, req));
    final r = await push(c, casEnabled: false);
    expect(r.conflicts, 1);
    expect(r.pushed, 0);
    expect(await txStatus(), 'conflict');
  });
}
