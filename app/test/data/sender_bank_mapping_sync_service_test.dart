import 'dart:async';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import '../features/capture/ledger_admission_fixture.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient, AuthClientOptions;
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
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
  Future<void> Function()? onUpsert; // runs while the push is "on the wire"

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
    await onUpsert?.call();
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
  _senderMappingStageA();
  _senderFiniteControls();
  _senderLifecycleControls();
  _senderBoundaryControls();
  _senderBatchIntentControl();
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

        // C-3: these cover push/pull MECHANICS; consent enforcement is
        // asserted separately in sender_bank_mapping_consent_test.dart.
        mayEgress: () async => true,
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

  group('A-2 (G3) in-flight edit', () {
    group('real admitted sender mechanism 17', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('a mapping edited while its push is on the wire stays pending',
        () async {
      await seedLocal('snd');
      await seedLocal('untouched');
      server.onUpsert = () async {
        // Every local edit bumps updated_at and re-flags the row pending.
        await db.customStatement('''
          UPDATE sender_bank_mappings
          SET bank_key = 'edited', updated_at = '2026-01-02T00:00:00Z',
              sync_status = 'pending'
          WHERE normalized_sender_id = 'snd';
        ''');
      };
      final (pushed, failed) = await service().push();
      expect(failed, 0);
      expect(pushed, 2);
      final edited = await db
          .customSelect("SELECT sync_status, bank_key FROM sender_bank_mappings "
              "WHERE normalized_sender_id = 'snd';")
          .getSingle();
      expect(edited.read<String>('sync_status'), 'pending',
          reason: 'the newer edit must be pushed next cycle, not marked synced');
      expect(edited.read<String>('bank_key'), 'edited');
      // The untouched mapping still settles normally.
      expect(await localCount("sync_status = 'synced'"), 1);

      server.onUpsert = null;
      await service().push();
      expect(await localCount("sync_status = 'synced'"), 2);
      expect(server.rows['snd']!['bank_key'], 'edited');
    });
    });
  });

  group('MALI-029 push batching', () {
    group('real admitted sender mechanism 16', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
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
    });

    group('real admitted sender mechanism 15', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
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

    test(
        'equal timestamps across a page boundary are not skipped (id tiebreak)',
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
          await localCount("normalized_sender_id='x' AND deleted_at IS NULL"),
          1);
      server.put('x', deleted: true); // device B deletes it
      final r = await service().pull();
      expect(r.tombstoned, 1);
      expect(
          await localCount(
              "normalized_sender_id='x' AND deleted_at IS NOT NULL"),
          1);
    });

    group('real admitted sender mechanism 14', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('a local deletion is pushed as a tombstone', () async {
      await seedLocal('y', deletedAt: '2026-02-02T02:02:02Z');
      final (pushed, failed) = await service().push();
      expect(pushed, 1);
      expect(failed, 0);
      expect(server.rows['y']?['deleted_at'], isNotNull);
    });
    });

    group('real admitted sender mechanism 13', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
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

    group('real admitted sender mechanism 12', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('after push, a concurrent local edit wins (newest server timestamp)',
        () async {
      await seedLocal('m', status: 'confirmed', syncStatus: 'pending');
      server.put('m', bank: 'OTHER'); // concurrent remote
      await service().sync(); // push (local) then pull
      expect(server.rows['m']?['bank_key'], 'alrajhi');
    });
    });
  });

  group('typed errors', () {
    group('real admitted sender mechanism 11', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test(
        'an unrelated unique-constraint error does NOT falsely resolve the item',
        () async {
      await seedLocal('u', status: 'confirmed');
      server.failUpsertWith =
          const PostgrestException(message: 'dup', code: '23505');
      final (pushed, failed) = await service().push();
      expect(pushed, 0);
      expect(failed, 1);
      expect(await localCount("id='loc-u' AND sync_status='failed'"), 1);
    });
    });

    group('real admitted sender mechanism 10', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
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

    group('real admitted sender mechanism 9', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
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
  });

  group('accepted_by provenance', () {
    Future<SenderBankMappingEntity> suggest(
            DriftSenderBankMappingRepository repo, String id) =>
        repo.saveSuggestion(SenderBankMappingDraft(
          senderId: id,
          suggestedBankName: 'Bank',
          suggestedCountry: 'SA',
          confidence: 0.9,
        ));

    group('real admitted sender mechanism 8', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('push payload of a user-confirmed mapping has no accepted_by',
        () async {
      final repo = DriftSenderBankMappingRepository(db);
      final s = await suggest(repo, 'conf');
      await repo.confirm(mappingId: s.id, bankKey: 'alrajhi');
      await service().push();
      expect(server.rows['CONF']!['status'], 'confirmed');
      expect(server.rows['CONF']!.containsKey('accepted_by'), isFalse);
    });
    });

    group('real admitted sender mechanism 7', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('batch of user-confirmed + legacy rows has no accepted_by', () async {
      final repo = DriftSenderBankMappingRepository(db);
      final s = await suggest(repo, 'conf');
      await repo.confirm(mappingId: s.id, bankKey: 'alrajhi');
      await seedLocal('legacy1');
      await seedLocal('legacy2');
      await service().push();
      expect(server.upsertCalls, 1);
      expect(server.rows.keys, containsAll(['CONF', 'legacy1', 'legacy2']));
      for (final r in server.rows.values) {
        expect(r.containsKey('accepted_by'), isFalse);
      }
    });
    });

    group('real admitted sender mechanism 6', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('AI path still writes ai_validated and pushes it', () async {
      final repo = DriftSenderBankMappingRepository(db);
      await repo.upsertAiValidated(
          senderId: 'AISND',
          bankKey: 'alrajhi',
          bankName: 'Bank',
          country: 'SA');
      await service().push();
      expect(server.rows['AISND']!['accepted_by'], 'ai_validated');
    });
    });

    group('real admitted sender mechanism 5', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('ai_validated -> user confirm => accepted_by user, pushed', () async {
      final repo = DriftSenderBankMappingRepository(db);
      await repo.upsertAiValidated(
          senderId: 'AIUSR',
          bankKey: 'alrajhi',
          bankName: 'Bank',
          country: 'SA');
      final ai = (await repo.getBySender('AIUSR'))!;
      expect(ai.acceptedBy, 'ai_validated');
      final confirmed =
          await repo.confirm(mappingId: ai.id, bankKey: 'alrajhi');
      expect(confirmed.acceptedBy, 'user');
      expect(confirmed.isUserAccepted, isTrue);
      await service().push();
      expect(server.rows['AIUSR']!['accepted_by'], 'user');
    });
    });

    group('real admitted sender mechanism 4', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('legacy NULL confirm stays NULL, payload has no accepted_by',
        () async {
      final repo = DriftSenderBankMappingRepository(db);
      final s = await suggest(repo, 'legnull');
      final confirmed = await repo.confirm(mappingId: s.id, bankKey: 'alrajhi');
      expect(confirmed.acceptedBy, isNull);
      await service().push();
      expect(server.rows['LEGNULL']!.containsKey('accepted_by'), isFalse);
    });
    });

    group('real admitted sender mechanism 3', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test(
        'guard (flag OFF): confirm/reject/saveSuggestion/upsertRemote/pull '
        'never yield accepted_by in any push payload', () async {
      final repo = DriftSenderBankMappingRepository(db);
      final a = await suggest(repo, 'aaa');
      await repo.confirm(mappingId: a.id, bankKey: 'alrajhi');
      final b = await suggest(repo, 'bbb');
      await repo.reject(mappingId: b.id, cooldown: const Duration(days: 30));
      await suggest(repo, 'ccc'); // stays a pending suggestion
      final now = DateTime.utc(2026, 1, 1);
      await repo.upsertRemote(SenderBankMappingEntity(
        id: 'r1',
        senderId: 'ddd',
        normalizedSenderId: 'ddd',
        bankKey: 'alrajhi',
        suggestedBankName: 'Bank',
        suggestedCountry: 'SA',
        confidence: 0.9,
        status: SenderBankMappingStatus.confirmed,
        source: SenderBankMappingSource.userManual,
        firstSeenAt: now,
        lastSeenAt: now,
        confirmedAt: now,
        createdAt: now,
        updatedAt: now,
        syncStatus: SenderBankMappingSyncStatus.pending,
      ));
      server.put('eee'); // remote row pulled via the pull/upsertRemote path
      await service().pull();
      await service().push();
      expect(server.rows.keys, containsAll(['AAA', 'BBB', 'eee']));
      for (final r in server.rows.values) {
        expect(r.containsKey('accepted_by'), isFalse);
      }
    });
    });

    group('real admitted sender mechanism 2', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('push omits accepted_by when null (legacy/user row)', () async {
      await seedLocal('legacy');
      await service().push();
      expect(server.rows['legacy']!.containsKey('accepted_by'), isFalse);
    });
    });

    group('real admitted sender mechanism 1', () {
      LedgerAdmissionFixture? admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('user-1');
        db = admission!.database;
      });
      tearDown(() async { await admission?.finish(); });
      test('push includes accepted_by when set', () async {
      await seedLocal('aisender');
      await db.customStatement(
          "UPDATE sender_bank_mappings SET accepted_by = 'ai_validated' "
          "WHERE normalized_sender_id = 'aisender';");
      await service().push();
      expect(server.rows['aisender']!['accepted_by'], 'ai_validated');
    });
    });

    test('pull reads accepted_by (import and update) and tolerates absence',
        () async {
      server.put('remote-ai');
      server.rows['remote-ai']!['accepted_by'] = 'ai_validated';
      server.put('remote-old');
      await service().pull();
      Future<String?> local(String n) async => (await db
              .customSelect('SELECT accepted_by FROM sender_bank_mappings '
                  "WHERE normalized_sender_id = '$n';")
              .getSingle())
          .readNullable<String>('accepted_by');
      expect(await local('remote-ai'), 'ai_validated');
      expect(await local('remote-old'), isNull);

      server.put('remote-old');
      server.rows['remote-old']!['accepted_by'] = 'user';
      await service().pull();
      expect(await local('remote-old'), 'user');
    });
  });
}


// Current-API batch mutation witnesses only. A rejected batch is not a
// collection of per-row mutation receipts, and draft SQL is not deployment proof.
void _senderMappingStageA() {
  const uid='sender-stageA-owner';
  const names=['sender-one','sender-two'];
  final created=DateTime.utc(2026,10,1,10);
  final confirmed=DateTime.utc(2026,10,1,10,1);
  Future<void> seed(AppDatabase db) async {
    final repo=DriftSenderBankMappingRepository(db);
    for(final name in names) {
      final mapping=await repo.saveSuggestion(SenderBankMappingDraft(senderId:name,
          bankKey:'synthetic-bank',suggestedBankName:'Synthetic Bank',suggestedCountry:'SA',
          confidence:0.9,source:SenderBankMappingSource.userManual,now:created));
      await repo.confirm(mappingId:mapping.id,bankKey:'synthetic-bank',now:confirmed);
    }
  }
  Future<List<Map<String,Object?>>> rows(AppDatabase db) async => [
    for(final row in await db.customSelect('SELECT * FROM sender_bank_mappings ORDER BY normalized_sender_id;').get())row.data,
  ];
  List<Map<String,dynamic>> payload(List<Map<String,Object?>> snapshots) => [
    for(final row in snapshots){
      'user_id':uid,'sender_id':row['sender_id'],'normalized_sender_id':row['normalized_sender_id'],
      'bank_key':row['bank_key'],'suggested_bank_name':row['suggested_bank_name'],
      'suggested_country':row['suggested_country'],'confidence':row['confidence'],'reason':row['reason'],
      'status':row['status'],'source':row['source'],'first_seen_at':row['first_seen_at'],
      'last_seen_at':row['last_seen_at'],'confirmed_at':row['confirmed_at'],'rejected_at':row['rejected_at'],
      'rejection_expires_at':row['rejection_expires_at'],'created_at':row['created_at'],'deleted_at':row['deleted_at'],
      if(row['accepted_by']!=null)'accepted_by':row['accepted_by'],
    },
  ];
  void mutationWitness(http.Request request,List<Map<String,dynamic>> expected) {
    expect(request.method,'POST');expect(request.url.path,'/rest/v1/sender_bank_mappings');
    expect(request.url.queryParameters['on_conflict'],'user_id,normalized_sender_id');
    expect(request.url.queryParameters['select'],'*');
    expect(request.headers['prefer'],contains('resolution=merge-duplicates'));
    expect(request.headers['prefer'],contains('return=representation'));
    expect(jsonDecode(request.body),expected);
    for(final row in (jsonDecode(request.body) as List).cast<Map<String,dynamic>>()) {
      expect(row['user_id'],uid);expect(row.containsKey('id'),isFalse);expect(row.containsKey('updated_at'),isFalse);
    }
  }
  group('E4 sender mapping mutation StageA',() {
    TestWidgetsFlutterBinding.ensureInitialized();
    for(final disposition in ['QD001','QD002','success','ordinary503']) {
      test('$disposition concrete batch follows original owner authority',() async {
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        final location=admission.location;
        final requests=<http.Request>[];final responses=<Object>[];
        Future<SenderMappingSyncResult>? producer;
        try {
          await seed(db);final before=await rows(db);final expected=payload(before);
          final cap=admission.fixture.session.captureLocalWorkAuthority()!;expect(cap.isCurrent,isTrue);
          final raw=<String,Object?>{'code':disposition=='ordinary503'?'503':disposition,
            'message':'synthetic mapping refusal','details':null,'hint':null};
          final receipts=[for(var i=0;i<expected.length;i++){
            ...expected[i],'id':i==0?'550e8400-e29b-41d4-a716-446655440301':'550e8400-e29b-41d4-a716-446655440302',
            'updated_at':DateTime.utc(2026,10,2,0,i).toIso8601String(),
          }];
          final client=admission.ownClient(SupabaseClient('https://example.supabase.co','anon',
              authOptions:const AuthClientOptions(autoRefreshToken:false),httpClient:MockClient((request)async {
            requests.add(request);
            final Object body=request.method=='GET'?<Object>[]:disposition=='success'?receipts:raw;
            responses.add(body);
            return http.Response(jsonEncode(body),request.method=='GET'||disposition=='success'?200:
                disposition=='ordinary503'?503:400,headers:{'content-type':'application/json'},request:request);
          })));
          final sync=SenderBankMappingSyncService(db:db,remoteStore:SupabaseSenderBankMappingRemoteStore(client),
              currentUserId:()=>uid,mayEgress:()async=>true);
          producer=sync.sync();
          final completed=await producer.then<Object>((value)=>value,onError:(Object e)=>e);
          final result=completed is SenderMappingSyncResult?completed:null;
          expect(requests,isNotEmpty);mutationWitness(requests.first,expected);
          expect(responses.first,disposition=='success'?receipts:raw);
          if(disposition=='QD001'||disposition=='QD002') {
            // Primary behavior RED. Later checks remain unreached if the
            // current implementation leaves this capability live.
            expect(completed,isA<SenderMappingDeliveryStopped>());
            expect((completed as SenderMappingDeliveryStopped).reason,SenderMappingDeliveryStopReason.denial);
            expect(completed.accepted,isTrue);expect(completed.complete,isTrue);
            expect(cap.isCurrent,isFalse,reason:'particular rejected batch retires the original owner');
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!.state,
                disposition=='QD001'?AccountFenceState.pending:AccountFenceState.gone);
            expect(requests,hasLength(1),reason:'no singleton fallback or following pull after accepted denial');
            final retained=await LedgerAdmissionFixture.inspectClosed(db,location,rows);
            expect(retained,before);
            for(final row in retained){expect(row['sync_attempt_count'],0);expect(row['sync_status'],'pending');}
          }else if(disposition=='success') {
            expect(result!.pushed,2);expect(result.failed,0);
            expect(requests.where((r)=>r.method=='POST'),hasLength(1));
            expect(requests.where((r)=>r.method=='GET'),hasLength(1));
            expect(requests.last.url.path,'/rest/v1/sender_bank_mappings');expect(responses.last,isEmpty);
            final after=await rows(db);expect(after,hasLength(2));
            for(var i=0;i<after.length;i++) {
              expect(after[i]['sync_status'],'synced');expect(after[i]['sync_attempt_count'],0);
              expect(after[i]['sync_next_retry_at'],isNull);expect(after[i]['sync_failure_class'],isNull);
              expect(after[i]['sync_permanent'],0);expect(after[i]['synced_at'],isNotNull);
              expect(after[i]['server_updated_at'],receipts[i]['updated_at']);
              expect(after[i]['updated_at'],receipts[i]['updated_at']);
              for(final key in expected[i].keys.where((key)=>key!='user_id')){expect(after[i][key],before[i][key]);}
            }
            expect(cap.isCurrent,isTrue);expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
          }else {
            expect(result!.pushed,0);expect(result.failed,2);
            final posts=requests.where((r)=>r.method=='POST').toList();expect(posts,hasLength(3));
            mutationWitness(posts[1],[expected[0]]);mutationWitness(posts[2],[expected[1]]);
            expect(requests.where((r)=>r.method=='GET'),hasLength(1));expect(responses.take(3),everyElement(raw));
            final after=await rows(db);
            for(var i=0;i<after.length;i++) {
              expect(after[i]['sync_status'],'failed');expect(after[i]['sync_attempt_count'],1);
              expect(after[i]['sync_next_retry_at'],isNotNull);expect(after[i]['sync_failure_class'],'serverError');
              expect(after[i]['sync_permanent'],0);expect(after[i]['synced_at'],isNull);
              for(final key in before[i].keys.where((key)=>!const{
                'sync_status','sync_attempt_count','sync_next_retry_at','sync_failure_class','sync_permanent',
              }.contains(key))){expect(after[i][key],before[i][key]);}
            }
            expect(cap.isCurrent,isTrue);expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
          }
        }finally{try{if(producer!=null){await producer.onError((Object error,StackTrace stack){
          if(error is SenderMappingDeliveryStopped&&error.reason==SenderMappingDeliveryStopReason.denial){return const SenderMappingSyncResult();}
          Error.throwWithStackTrace(error,stack);
        });}}finally{await admission.finish();}}
      });
    }
  });
}

class _SenderTestStore implements SenderMappingRemoteStore {
  _SenderTestStore(this.send);
  final Future<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>) send;
  int pulls = 0;
  @override
  Future<List<Map<String, dynamic>>> upsert(List<Map<String, dynamic>> rows) => send(rows);
  @override
  Future<List<Map<String, dynamic>>> fetchRows({required SyncCursor after, int limit = 200}) async {
    pulls++;
    return [];
  }
}

void _senderFiniteControls() {
  const uid = 'sender-finite-owner';
  const stamp = '2026-10-10T10:00:00Z';
  Future<void> seed(AppDatabase db) async {
    final repo = DriftSenderBankMappingRepository(db);
    for (final name in ['a', 'b']) {
      final row = await repo.saveSuggestion(SenderBankMappingDraft(senderId: name,
          suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
      await repo.confirm(mappingId: row.id, bankKey: 'bank');
    }
  }
  Future<List<Map<String, Object?>>> rows(AppDatabase db) async => [
    for (final row in await db.customSelect('SELECT * FROM sender_bank_mappings ORDER BY normalized_sender_id;').get()) row.data,
  ];
  List<Map<String, dynamic>> receipt(List<Map<String, dynamic>> sent) => [
    for (final row in sent) {...row, 'id': 'opaque-${row['normalized_sender_id']}', 'updated_at': stamp},
  ];
  Future<void> withFixture(Future<void> Function(LedgerAdmissionFixture, AppDatabase, List<Future<void>>) run,
      {LedgerDatabaseProbe? probe}) async {
    final fixture = await LedgerAdmissionFixture.open(uid, probe);
    final producers = <Future<void>>[];
    try { await seed(fixture.database); await run(fixture, fixture.database, producers); }
    finally {
      try { await Future.wait(producers); }
      finally { await fixture.finish(); }
    }
  }
  group('E4 sender finite controls', () {
    for (final kind in ['missing', 'duplicate', 'foreign', 'malformed']) {
      test('complete receipt validation $kind preserves entire batch without fallback', () async {
        await withFixture((f, db, owned) async {
          final before = await rows(db);
          var sends = 0;
          final store = _SenderTestStore((sent) async {
            sends++;
            final result = receipt(sent);
            if (kind == 'missing') result.removeLast();
            if (kind == 'duplicate') result[1] = result.first;
            if (kind == 'foreign') result[1] = {...result[1], 'user_id': 'foreign'};
            if (kind == 'malformed') result[1] = {...result[1], 'updated_at': 'bad'};
            return result;
          });
          final health = SyncHealth(db: db);
          final result = await SenderBankMappingSyncService(db: db, remoteStore: store,
              currentUserId: () => uid, mayEgress: () async => true, health: health).push();
          expect(result, (0, 0)); expect(sends, 1); expect(await rows(db), before);
          expect(health.of(SyncDomain.senderMappings).lastPushSuccessAt, isNull);
          expect(health.of(SyncDomain.senderMappings).consecutiveFailures, 1);
        });
      });
    }
    for (final exhaust in [false, true]) {
      test('actual SDK busy ${exhaust ? 'exhaustion' : 'success'} uses one bounded immutable batch', () async {
        await withFixture((f, db, owned) async {
          final before = await rows(db);
          final requests = <http.Request>[];
          final client = f.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
              authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient((request) async {
            requests.add(request);
            final sent = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
            return http.Response(jsonEncode(!exhaust && requests.length == 3 ? receipt(sent) : {
              'code': '55P03', 'message': 'busy', 'details': null, 'hint': null,
            }), !exhaust && requests.length == 3 ? 200 : 400,
                headers: {'content-type': 'application/json'}, request: request);
          })));
          final health = SyncHealth(db: db);
          final service = SenderBankMappingSyncService(db: db,
              remoteStore: SupabaseSenderBankMappingRemoteStore(client), currentUserId: () => uid,
              mayEgress: () async => true, health: health,
              fenceRetry: AccountFenceRetry(delay: (_) async {}));
          expect(await service.push(), exhaust ? (0, 0) : (2, 0));
          expect(requests, hasLength(3));
          expect(requests.every((r) => r.method == 'POST' && r.body == requests.first.body), isTrue);
          final after = await rows(db);
          if (exhaust) {
            for (var i = 0; i < before.length; i++) {
              expect(after[i]['sync_next_retry_at'], isNotNull);
              for (final key in before[i].keys.where((k) => k != 'sync_next_retry_at')) {
                expect(after[i][key], before[i][key], reason: key);
              }
            }
            expect(health.of(SyncDomain.senderMappings).lastPushSuccessAt, isNull);
            expect(health.of(SyncDomain.senderMappings).consecutiveFailures, 1);
            expect(await service.push(), (0, 0)); expect(requests, hasLength(3));
          } else { expect(after.every((r) => r['sync_status'] == 'synced'), isTrue); }
          expect(f.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)), isNull);
        });
      });
    }
    test('same timestamp newer semantic edit survives successful old response', () async {
      await withFixture((f, db, owned) async {
        var sentCount = 0;
        final store = _SenderTestStore((sent) async {
          sentCount++;
          await db.customStatement("UPDATE sender_bank_mappings SET bank_key='new-bank' WHERE normalized_sender_id='A';");
          return receipt(sent);
        });
        expect(await SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).push(), (2, 0));
        final after = await rows(db);
        expect(sentCount, 1); expect(after.first['bank_key'], 'new-bank');
        expect(after.first['sync_status'], 'pending'); expect(after.last['sync_status'], 'synced');
      });
    });
    test('same timestamp newer semantic edit survives late ordinary failure', () async {
      await withFixture((f, db, owned) async {
        final before = await rows(db);
        var sends = 0;
        final store = _SenderTestStore((sent) async {
          sends++;
          if (sends == 1) {
            await db.customStatement("UPDATE sender_bank_mappings SET bank_key='new-bank' WHERE normalized_sender_id='A';");
          }
          throw const PostgrestException(message: 'offline', code: '503');
        });
        expect(await SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).push(), (0, 1));
        final after = await rows(db);
        expect(sends, 2); expect(after.first['bank_key'], 'new-bank');
        for (final key in before.first.keys.where((k) => k != 'bank_key')) {
          expect(after.first[key], before.first[key], reason: key);
        }
        expect(after.last['sync_attempt_count'], 1);
      });
    });
    test('local ACK failure is not replayed remotely or converted to failed intent', () async {
      final probe = LedgerDatabaseProbe();
      await withFixture((f, db, owned) async {
        final before = await rows(db);
        var sends = 0; var reached = false;
        probe.before = (sql) async {
          if (sql.contains("SET sync_status = 'synced'")) { reached = true; throw StateError('controlled ACK'); }
        };
        final store = _SenderTestStore((sent) async { sends++; return receipt(sent); });
        try {
          expect(await SenderBankMappingSyncService(db: db, remoteStore: store,
              currentUserId: () => uid, mayEgress: () async => true).push(), (2, 0));
        } finally { probe.before = null; }
        expect(reached, isTrue); expect(sends, 1); expect(await rows(db), before);
      }, probe: probe);
    });
    test('custom raw refusal cannot inherit actual mutation provenance', () async {
      await withFixture((f, db, owned) async {
        final before = await rows(db); var sends = 0;
        final store = _SenderTestStore((_) async { sends++; throw const PostgrestException(message: 'custom', code: 'QD002'); });
        final result = await SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).sync()
            .then<Object>((v) => v, onError: (Object e) => e);
        expect(result, isA<SenderMappingDeliveryStopped>());
        expect((result as SenderMappingDeliveryStopped).reason, SenderMappingDeliveryStopReason.nonMutationRefusal);
        expect(sends, 1); expect(store.pulls, 0); expect(await rows(db), before);
        expect(f.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)), isNull);
      });
    });
  });
}

void _senderLifecycleControls() {
  const uid = 'sender-lifecycle-owner';
  Future<void> seed(AppDatabase db) async {
    final repo = DriftSenderBankMappingRepository(db);
    final row = await repo.saveSuggestion(const SenderBankMappingDraft(senderId: 'one',
        suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
    await repo.confirm(mappingId: row.id, bankKey: 'bank');
  }
  Future<List<Map<String, Object?>>> rows(AppDatabase db) async => [
    for (final row in await db.customSelect('SELECT * FROM sender_bank_mappings;').get()) row.data,
  ];
  group('E4 sender lifecycle controls', () {
    test('actual mutation denial remains authoritative during temporary store unreadiness', () async {
      final f = await LedgerAdmissionFixture.open(uid);
      final db = f.database; final location = f.location;
      final mutation = Completer<void>(); final releaseMutation = Completer<void>();
      final read = Completer<void>(); final releaseRead = Completer<void>();
      Future<Object>? producer; Future<bool>? loading;
      try {
        await seed(db); final before = await rows(db);
        final cap = f.fixture.session.captureLocalWorkAuthority()!;
        final requests = <http.Request>[];
        final client = f.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient((request) async {
          requests.add(request); mutation.complete(); await releaseMutation.future;
          return http.Response(jsonEncode({'code': 'QD002', 'message': 'gone', 'details': null, 'hint': null}), 400,
              headers: {'content-type': 'application/json'}, request: request);
        })));
        producer = SenderBankMappingSyncService(db: db, remoteStore: SupabaseSenderBankMappingRemoteStore(client),
            currentUserId: () => uid, mayEgress: () async => true).sync().then<Object>((v) => v, onError: (Object e) => e);
        await mutation.future;
        f.fixture.storage.gate = (op, key) async {
          if (op == 'read' && key == AccountFenceStore.storageKey && !read.isCompleted) {
            read.complete(); await releaseRead.future;
          }
        };
        loading = AccountFenceAuthority.shared.store.load(); await read.future;
        expect(cap.isCurrent, isFalse);
        releaseMutation.complete();
        await Future<void>.value();
        releaseRead.complete(); await loading;
        final result = await producer;
        expect(result, isA<SenderMappingDeliveryStopped>());
        expect((result as SenderMappingDeliveryStopped).accepted, isTrue); expect(result.complete, isTrue);
        expect(requests, hasLength(1)); expect(requests.single.method, 'POST');
        expect(await LedgerAdmissionFixture.inspectClosed(db, location, rows), before);
      } finally {
        if (!releaseRead.isCompleted) releaseRead.complete();
        if (!releaseMutation.isCompleted) releaseMutation.complete();
        f.fixture.storage.gate = null;
        try { await loading; await producer; } finally { await f.finish(); }
      }
    });
    test('old successful response cannot ACK same-UID successor intent or start pull', () async {
      final f = await LedgerAdmissionFixture.open(uid);
      final db = f.database;
      final reached = Completer<void>(); final release = Completer<void>();
      Future<Object>? producer;
      try {
        await seed(db); final before = await rows(db);
        final old = f.fixture.session.captureLocalWorkAuthority()!;
        final store = _SenderTestStore((sent) async {
          reached.complete(); await release.future;
          return [for (final row in sent) {...row, 'id': 'opaque', 'updated_at': '2026-10-10T00:00:00Z'}];
        });
        producer = SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).sync().then<Object>((v) => v, onError: (Object e) => e);
        await reached.future;
        await f.fixture.signIn(uid);
        expect(old.isCurrent, isFalse); expect(f.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        release.complete(); final result = await producer;
        expect(result, isA<SenderMappingDeliveryStopped>());
        expect((result as SenderMappingDeliveryStopped).reason, SenderMappingDeliveryStopReason.stale);
        expect(store.pulls, 0); expect(await rows(db), before);
      } finally {
        if (!release.isCompleted) release.complete();
        try { await producer; } finally { await f.finish(); }
      }
    });
    test('started ACK transaction reaches terminal settlement before physical close begins', () async {
      final probe = LedgerDatabaseProbe();
      final f = await LedgerAdmissionFixture.open(uid, probe);
      final db = f.database;
      final reached = Completer<void>(); final release = Completer<void>();
      var terminal = false; var earlyClose = false;
      Future<Object>? producer; Future<AccountFenceResult>? denial;
      try {
        await seed(db);
        final handle = (await AccountFenceAuthority.shared.capture(f.fixture.session, f.fixture.host))!;
        final store = _SenderTestStore((sent) async => [
          for (final row in sent) {...row, 'id': 'opaque', 'updated_at': '2026-10-10T00:00:00Z'},
        ]);
        probe.before = (sql) async {
          if (sql.contains("SET sync_status = 'synced'")) {
            reached.complete(); await release.future;
          }
        };
        probe.afterTransactionSettled = () { if (reached.isCompleted) terminal = true; };
        probe.onClose = () { earlyClose = !terminal; };
        producer = SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).sync().then<Object>((v) => v, onError: (Object e) => e);
        await reached.future;
        denial = AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
            operationId: '11223344-5566-4788-8899-aabbccddeeff');
        expect(f.fixture.session.captureLocalWorkAuthority(), isNull); expect(probe.closeAttempts, 0);
        release.complete();
        final result = await denial;
        expect(result.accepted, isTrue); expect(result.complete, isTrue);
        expect(await producer, isA<SenderMappingDeliveryStopped>());
        expect(terminal, isTrue); expect(earlyClose, isFalse); expect(store.pulls, 0);
        expect(probe.transactionStatements.any((s) => s.contains("SET sync_status = 'synced'")), isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        probe.before = null;
        try { await producer; await denial; } finally { await f.finish(); }
      }
    });
  });
}

void _senderBoundaryControls() {
  const uid = 'sender-boundary-owner';
  Future<void> seed(AppDatabase db) async {
    final repo = DriftSenderBankMappingRepository(db);
    final row = await repo.saveSuggestion(const SenderBankMappingDraft(senderId: 'one',
        suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
    await repo.confirm(mappingId: row.id, bankKey: 'bank');
  }
  Future<List<Map<String, Object?>>> rows(AppDatabase db) async => [
    for (final row in await db.customSelect('SELECT * FROM sender_bank_mappings;').get()) row.data,
  ];
  group('E4 sender final boundary', () {
    test('final SDK owner change during consent wait refuses dispatch without epoch change', () async {
      final f = await LedgerAdmissionFixture.open(uid);
      final db = f.database;
      final reached = Completer<void>(); final release = Completer<void>();
      Future<Object>? producer; var owner = uid; var checks = 0;
      try {
        await seed(db); final before = await rows(db); final requests = <http.Request>[];
        final client = f.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient((request) async {
          requests.add(request);
          final sent = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
          return http.Response(jsonEncode([for (final row in sent) {...row, 'id': 'opaque',
            'updated_at': '2026-10-10T00:00:00Z'}]), 200,
              headers: {'content-type': 'application/json'}, request: request);
        })));
        producer = SenderBankMappingSyncService(db: db, remoteStore: SupabaseSenderBankMappingRemoteStore(client),
            currentUserId: () => owner, mayEgress: () async {
          if (++checks == 2) { reached.complete(); await release.future; }
          return true;
        }).push().then<Object>((v) => v, onError: (Object e) => e);
        await reached.future; owner = 'other-sdk-owner';
        expect(f.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        release.complete(); final result = await producer;
        expect(requests, isEmpty); expect(result, isA<SenderMappingDeliveryStopped>());
        expect(await rows(db), before);
      } finally {
        if (!release.isCompleted) release.complete();
        try { await producer; } finally { await f.finish(); }
      }
    });
    test('local capture read failure is not a remote failure and must not dispatch fallback', () async {
      final probe = LedgerDatabaseProbe(); final f = await LedgerAdmissionFixture.open(uid, probe);
      final db = f.database; var reached = false; var sends = 0;
      try {
        await seed(db); final before = await rows(db);
        probe.before = (sql) async {
          if (!reached && sql.startsWith('SELECT * FROM sender_bank_mappings WHERE id=')) {
            reached = true; throw StateError('controlled intent read');
          }
        };
        final store = _SenderTestStore((sent) async {
          sends++; return [for (final row in sent) {...row, 'id': 'opaque', 'updated_at': '2026-10-10T00:00:00Z'}];
        });
        final result = await SenderBankMappingSyncService(db: db, remoteStore: store,
            currentUserId: () => uid, mayEgress: () async => true).push()
            .then<Object>((v) => v, onError: (Object e) => e);
        expect(reached, isTrue); expect(sends, 0); expect(result, isA<StateError>());
        expect(await rows(db), before);
      } finally { probe.before = null; await f.finish(); }
    });
  });
}

void _senderBatchIntentControl() {
  test('E4 sender closed full-semantic batch rejects changed row and reused ticket', () async {
    const uid = 'sender-ticket-owner';
    final f = await LedgerAdmissionFixture.open(uid);
    final db = f.database; final location = f.location;
    try {
      final repo = DriftSenderBankMappingRepository(db);
      final mapping = await repo.saveSuggestion(const SenderBankMappingDraft(senderId: 'one',
          suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
      await repo.confirm(mappingId: mapping.id, bankKey: 'bank');
      Future<List<Map<String, Object?>>> rows(AppDatabase database) async => [
        for (final row in await database.customSelect('SELECT * FROM sender_bank_mappings;').get()) row.data,
      ];
      final before = await rows(db);
      final authority = AccountFenceAuthority.shared;
      final handle = (await authority.capture(f.fixture.session, f.fixture.host))!;
      final cap = f.fixture.session.captureLocalWorkAuthority()!;
      expect(await authority.captureSenderMappingIntent(handle, db,
          [{...before.single, 'bank_key': 'different'}]), isNull);
      final intent = (await authority.captureSenderMappingIntent(handle, db, before))!;
      final result = await authority.acceptSenderMappingDenial(handle, db, intent, AccountFenceState.pending);
      expect(result.accepted, isTrue); expect(result.complete, isTrue);
      final reused = await authority.acceptSenderMappingDenial(handle, db, intent, AccountFenceState.gone);
      expect(reused.accepted, isFalse); expect(reused.complete, isFalse);
      expect(cap.isCurrent, isFalse); expect(db.lifecycleState, DatabaseLifecycleState.closed);
      expect(await LedgerAdmissionFixture.inspectClosed(db, location, rows), before);
    } finally { await f.finish(); }
  });
}
