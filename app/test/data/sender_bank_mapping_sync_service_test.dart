import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

// MALI-072n / MALI-008 — durable sender-mapping sync: keyset pagination,
// tombstone propagation, documented LWW conflict policy, typed errors.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A fake that models the server: rows keyed by normalized_sender_id with a
/// server-authoritative monotonic updated_at and optional error injection.
class _FakeServer implements SenderMappingRemoteStore {
  final Map<String, Map<String, dynamic>> rows = {}; // normalized -> row
  int _tick = 0;
  int upsertCalls = 0;
  int? failFetchOnCall; // throw on the Nth fetch (1-based)
  int _fetchCalls = 0;
  Object? failUpsertWith; // throw this on upsert

  // Normalised (millisecond) ISO so it round-trips through the cursor exactly.
  String _now() => DateTime.utc(2026, 1, 1, 0, 0, ++_tick).toIso8601String();

  static int _cmpTs(String a, String b) =>
      DateTime.parse(a).compareTo(DateTime.parse(b));

  // Server-side write (simulates device B) with a fresh server timestamp.
  void put(String normalized, {bool deleted = false, String bank = 'alrajhi'}) {
    rows[normalized] = {
      'id': 'srv-$normalized',
      'user_id': 'user-1',
      'sender_id': normalized,
      'normalized_sender_id': normalized,
      'bank_key': bank,
      'suggested_bank_name': 'Bank',
      'suggested_country': 'SA',
      'confidence': 0.9,
      'reason': null,
      'status': 'confirmed',
      'source': 'user_manual',
      'first_seen_at': '2026-01-01T00:00:00Z',
      'last_seen_at': '2026-01-01T00:00:00Z',
      'confirmed_at': '2026-01-01T00:00:00Z', // CHECK: confirmed ⇒ confirmed_at
      'rejected_at': null,
      'rejection_expires_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': _now(),
      'deleted_at': deleted ? _now() : null,
    };
  }

  // Force equal server timestamps on two rows (page-boundary tie test).
  void putEqualTimestamp(String a, String b, String ts) {
    for (final n in [a, b]) {
      put(n);
      rows[n]!['updated_at'] = ts;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    _fetchCalls++;
    if (failFetchOnCall == _fetchCalls) {
      throw const PostgrestException(message: 'network', code: '503');
    }
    // Compare timestamps as DateTime (as Postgres does server-side), NOT as raw
    // strings — the cursor is normalised to millisecond ISO ('…01.000Z') while
    // rows may read '…01Z', so a string compare would never advance the cursor.
    final all = rows.values.toList()
      ..sort((x, y) {
        final t = _cmpTs(x['updated_at'] as String, y['updated_at'] as String);
        return t != 0 ? t : (x['id'] as String).compareTo(y['id'] as String);
      });
    final filtered = all.where((r) {
      if (after.id.isEmpty) return true;
      final c = _cmpTs(r['updated_at'] as String, after.updatedAt);
      return c > 0 || (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
    });
    return filtered.take(limit).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> upsert(
      List<Map<String, dynamic>> incoming) async {
    upsertCalls++;
    if (failUpsertWith != null) throw failUpsertWith!;
    final out = <Map<String, dynamic>>[];
    for (final r in incoming) {
      final n = r['normalized_sender_id'] as String;
      final stored = {...r, 'id': 'srv-$n', 'updated_at': _now()};
      rows[n] = stored;
      out.add(stored);
    }
    return out;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeServer server;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    server = _FakeServer();
  });
  tearDown(() => db.close());

  SenderBankMappingSyncService service({int pageSize = 200}) =>
      SenderBankMappingSyncService(
        db: db,
        remoteStore: server,
        currentUserId: () => 'user-1',
        pageSize: pageSize,
      );

  Future<void> seedLocal(
    String normalized, {
    String status = 'confirmed',
    String syncStatus = 'pending',
    String? deletedAt,
  }) async {
    // The table's CHECK requires confirmed_at when status='confirmed'
    // (and rejected_at when 'rejected').
    final confirmedAt =
        status == 'confirmed' ? "'2026-01-01T00:00:00Z'" : 'NULL';
    final rejectedAt = status == 'rejected' ? "'2026-01-01T00:00:00Z'" : 'NULL';
    await db.customStatement('''
      INSERT INTO sender_bank_mappings(
        id, sender_id, normalized_sender_id, bank_key, suggested_bank_name,
        suggested_country, confidence, reason, status, source,
        first_seen_at, last_seen_at, confirmed_at, rejected_at,
        created_at, updated_at, sync_status, deleted_at
      ) VALUES (
        'loc-$normalized', '$normalized', '$normalized', 'alrajhi', 'Bank', 'SA',
        0.9, NULL, '$status', 'user_manual', '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z', $confirmedAt, $rejectedAt,
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
        '$syncStatus', ${deletedAt == null ? 'NULL' : "'$deletedAt'"}
      );
    ''');
  }

  Future<int> localCount(String where) async => (await db
          .customSelect(
              'SELECT COUNT(*) AS n FROM sender_bank_mappings WHERE $where;')
          .getSingle())
      .read<int>('n');

  group('MALI-029 push batching', () {
    test('N pending mappings push in ONE upsert (not one per row)', () async {
      for (var i = 0; i < 25; i++) {
        await seedLocal('snd$i');
      }
      final (pushed, failed) = await service().push();
      expect(pushed, 25);
      expect(failed, 0);
      expect(server.upsertCalls, 1,
          reason: '25 mappings → one batched upsert, not 25');
      expect(await localCount("sync_status = 'synced'"), 25);
    });

    test('on batch failure it falls back to the per-row path (isolation)',
        () async {
      server.failUpsertWith = StateError('server down');
      for (var i = 0; i < 3; i++) {
        await seedLocal('bad$i');
      }
      final (pushed, failed) = await service().push();
      expect(pushed, 0);
      expect(failed, 3);
      // 1 failed batch attempt + 3 per-row attempts → the fallback path ran.
      expect(server.upsertCalls, greaterThan(1),
          reason: 'batch failure must fall back to per-row, not drop the work');
      expect(await localCount("sync_status = 'failed'"), 3);
    });
  });

  group('keyset pagination', () {
    test('more mappings than one page are all pulled (cursor advances)',
        () async {
      server
        ..put('s1')
        ..put('s2')
        ..put('s3');
      final r = await service(pageSize: 2).pull();
      expect(r.imported, 3);
      expect(await localCount('deleted_at IS NULL'), 3);
    });

    test('equal timestamps across a page boundary are not skipped (id tiebreak)',
        () async {
      server.putEqualTimestamp('a', 'b', '2026-05-05T05:05:05Z');
      server.put('c'); // later timestamp
      final r = await service(pageSize: 1).pull();
      expect(r.imported, 3, reason: 'the id tiebreak keeps the keyset stable');
    });
  });

  group('deletion propagation', () {
    test('a remote tombstone soft-deletes the local mapping', () async {
      server.put('x');
      await service().pull();
      expect(
          await localCount("normalized_sender_id='x' AND deleted_at IS NULL"), 1);
      server.put('x', deleted: true); // device B deletes it
      final r = await service().pull();
      expect(r.tombstoned, 1);
      expect(
          await localCount("normalized_sender_id='x' AND deleted_at IS NOT NULL"),
          1);
    });

    test('a local deletion is pushed as a tombstone', () async {
      await seedLocal('y', deletedAt: '2026-02-02T02:02:02Z');
      final (pushed, failed) = await service().push();
      expect(pushed, 1);
      expect(failed, 0);
      expect(server.rows['y']?['deleted_at'], isNotNull);
    });

    test('deletion replay is idempotent (pushing the tombstone twice is safe)',
        () async {
      await seedLocal('z', deletedAt: '2026-02-02T02:02:02Z');
      await service().push();
      await db.customStatement(
          "UPDATE sender_bank_mappings SET sync_status='pending' WHERE id='loc-z';");
      final (pushed, failed) = await service().push();
      expect(pushed, 1);
      expect(failed, 0);
      expect(server.rows['z']?['deleted_at'], isNotNull);
    });
  });

  group('conflict policy (LWW, pending-safe)', () {
    test('a pending local edit is NOT overwritten by an older remote value',
        () async {
      await seedLocal('m', status: 'confirmed', syncStatus: 'pending');
      server.rows['m'] = {
        'id': 'srv-m',
        'normalized_sender_id': 'm',
        'sender_id': 'm',
        'bank_key': 'STALE',
        'suggested_bank_name': 'B',
        'suggested_country': 'SA',
        'confidence': 0.5,
        'status': 'confirmed',
        'source': 'remote',
        'first_seen_at': '2026-01-01T00:00:00Z',
        'last_seen_at': '2026-01-01T00:00:00Z',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2020-01-01T00:00:00Z',
        'deleted_at': null,
      };
      await service().pull();
      final bank = (await db
              .customSelect(
                  "SELECT bank_key FROM sender_bank_mappings WHERE id='loc-m';")
              .getSingle())
          .readNullable<String>('bank_key');
      expect(bank, 'alrajhi',
          reason: 'pending local edit preserved, not clobbered');
    });

    test('after push, a concurrent local edit wins (newest server timestamp)',
        () async {
      await seedLocal('m', status: 'confirmed', syncStatus: 'pending');
      server.put('m', bank: 'OTHER'); // concurrent remote
      await service().sync(); // push (local) then pull
      expect(server.rows['m']?['bank_key'], 'alrajhi');
    });
  });

  group('typed errors', () {
    test('an unrelated unique-constraint error does NOT falsely resolve the item',
        () async {
      await seedLocal('u', status: 'confirmed');
      server.failUpsertWith =
          const PostgrestException(message: 'dup', code: '23505');
      final (pushed, failed) = await service().push();
      expect(pushed, 0);
      expect(failed, 1);
      expect(await localCount("id='loc-u' AND sync_status='failed'"), 1);
    });

    test('a transient network error keeps the item for retry, not synced',
        () async {
      await seedLocal('n', status: 'confirmed');
      server.failUpsertWith =
          const PostgrestException(message: 'timeout', code: '503');
      final (pushed, failed) = await service().push();
      expect(pushed, 0);
      expect(failed, 1);
      expect(await localCount("id='loc-n' AND sync_status='synced'"), 0);
    });
  });

  group('crash / restart safety', () {
    test('partial-page failure does not skip rows — restart resumes', () async {
      server
        ..put('p1')
        ..put('p2')
        ..put('p3');
      server.failFetchOnCall = 2; // first page ok, second page throws
      final first = await service(pageSize: 1).pull();
      expect(first.imported, 1, reason: 'only the first page applied');
      server.failFetchOnCall = null;
      final second = await service(pageSize: 1).pull();
      expect(await localCount('deleted_at IS NULL'), 3,
          reason: 'no row skipped');
      expect(second.imported, 2);
    });

    test('process failure after server acceptance: retry is idempotent',
        () async {
      await seedLocal('c', status: 'confirmed');
      // Server accepted the upsert but the client "crashed" before marking
      // synced — the row is on the server AND still pending locally.
      await server.upsert([
        {
          'normalized_sender_id': 'c',
          'user_id': 'user-1',
          'sender_id': 'c',
          'suggested_bank_name': 'B',
          'suggested_country': 'SA',
          'confidence': 0.9,
          'status': 'confirmed',
          'source': 'user_manual',
          'first_seen_at': '2026-01-01T00:00:00Z',
          'last_seen_at': '2026-01-01T00:00:00Z',
          'created_at': '2026-01-01T00:00:00Z',
        }
      ]);
      final before = server.rows.length;
      final (pushed, failed) = await service().push();
      expect(pushed, 1);
      expect(failed, 0);
      expect(server.rows.length, before,
          reason: 'upsert is idempotent — no duplicate row');
      expect(await localCount("id='loc-c' AND sync_status='synced'"), 1);
    });
  });
}
