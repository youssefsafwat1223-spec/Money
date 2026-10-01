import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// A-4 (G10): pull never overwrites pending/failed rows; mapping pushes use
/// bounded retry state with a terminal, observable permanent failure.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _Store implements SenderMappingRemoteStore {
  List<Map<String, dynamic>> remote = [];
  Object? upsertError;
  int upsertCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async =>
      after.id.isEmpty ? remote : const [];

  @override
  Future<List<Map<String, dynamic>>> upsert(
      List<Map<String, dynamic>> rows) async {
    upsertCalls++;
    if (upsertError != null) throw upsertError!;
    return [
      for (final r in rows) {...r, 'id': 'srv', 'updated_at': '2026-02-01T00:00:00Z'}
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Store store;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    store = _Store();
  });
  tearDown(() => db.close());

  SenderBankMappingSyncService service() => SenderBankMappingSyncService(
        db: db,
        remoteStore: store,
        currentUserId: () => 'user-1',
        mayEgress: () async => true,
      );

  Future<void> seed(String n, String syncStatus,
      {int attempts = 0, String? nextRetry, int permanent = 0}) async {
    await db.customStatement('''
      INSERT INTO sender_bank_mappings(
        id, sender_id, normalized_sender_id, bank_key, suggested_bank_name,
        suggested_country, confidence, status, source, first_seen_at,
        last_seen_at, confirmed_at, created_at, updated_at, sync_status,
        sync_attempt_count, sync_next_retry_at, sync_permanent
      ) VALUES (
        'loc-$n', '$n', '$n', 'localbank', 'Bank', 'SA', 0.9, 'confirmed',
        'user_manual', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
        '$syncStatus', $attempts,
        ${nextRetry == null ? 'NULL' : "'$nextRetry'"}, $permanent
      );
    ''');
  }

  Future<Map<String, Object?>> row(String n) async => (await db
          .customSelect(
              "SELECT * FROM sender_bank_mappings WHERE normalized_sender_id = '$n';")
          .getSingle())
      .data;

  Map<String, dynamic> remoteRow(String n, {String? deletedAt}) => {
        'id': 'srv-$n',
        'sender_id': n,
        'normalized_sender_id': n,
        'bank_key': 'remotebank',
        'suggested_bank_name': 'Remote',
        'suggested_country': 'SA',
        'confidence': 0.5,
        'status': 'confirmed',
        'source': 'remote',
        'first_seen_at': '2026-01-01T00:00:00Z',
        'last_seen_at': '2026-01-01T00:00:00Z',
        'confirmed_at': '2026-01-01T00:00:00Z',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-03-01T00:00:00Z',
        'deleted_at': deletedAt,
      };

  group('pull', () {
    for (final status in ['pending', 'failed']) {
      test('never overwrites a $status row', () async {
        await seed('a', status);
        store.remote = [remoteRow('a')];
        await service().pull('user-1');
        final r = await row('a');
        expect(r['bank_key'], 'localbank');
        expect(r['sync_status'], status);
      });

      test('never tombstones a $status row', () async {
        await seed('a', status);
        store.remote = [remoteRow('a', deletedAt: '2026-03-01T00:00:00Z')];
        await service().pull('user-1');
        expect((await row('a'))['deleted_at'], isNull);
      });
    }

    test('still overwrites a synced row', () async {
      await seed('a', 'synced');
      store.remote = [remoteRow('a')];
      await service().pull('user-1');
      expect((await row('a'))['bank_key'], 'remotebank');
    });
  });

  group('push retry state', () {
    test('a transient failure backs off and is not retried before it is due',
        () async {
      await seed('a', 'pending');
      store.upsertError = const SocketException('offline');
      await service().push('user-1');
      final r = await row('a');
      expect(r['sync_status'], 'failed');
      expect(r['sync_attempt_count'], 1);
      expect(r['sync_next_retry_at'], isNotNull);
      expect(r['sync_permanent'], 0);
      expect(r['sync_failure_class'], 'transientNetwork');

      final callsBefore = store.upsertCalls;
      await service().push('user-1');
      expect(store.upsertCalls, callsBefore, reason: 'backoff not elapsed');
    });

    test('a due failed row is retried and settles on success', () async {
      await seed('a', 'failed',
          attempts: 2, nextRetry: '2020-01-01T00:00:00Z');
      final pushed = await service().push('user-1');
      expect(pushed.$1, 1);
      final r = await row('a');
      expect(r['sync_status'], 'synced');
      expect(r['sync_attempt_count'], 0);
      expect(r['sync_next_retry_at'], isNull);
    });

    test('reaching the attempt cap makes the failure terminal and observable',
        () async {
      await seed('a', 'failed',
          attempts: 11, nextRetry: '2020-01-01T00:00:00Z');
      store.upsertError = const SocketException('offline');
      await service().push('user-1');
      final r = await row('a');
      expect(r['sync_permanent'], 1);
      expect(r['sync_status'], 'failed');
      expect(r['sync_next_retry_at'], isNull);

      final calls = store.upsertCalls;
      store.upsertError = null;
      await service().push('user-1');
      expect(store.upsertCalls, calls, reason: 'terminal rows are not retried');
      expect((await row('a'))['sync_status'], 'failed');
    });

    test('a permanent error class is terminal on the first failure', () async {
      await seed('a', 'pending');
      store.upsertError =
          const PostgrestException(message: 'check', code: '23514');
      await service().push('user-1');
      final r = await row('a');
      expect(r['sync_permanent'], 1);
      expect(r['sync_failure_class'], 'server_check_violation');
    });

    test('a terminal row is never overwritten by pull', () async {
      await seed('a', 'failed', attempts: 12, permanent: 1);
      store.remote = [remoteRow('a')];
      await service().pull('user-1');
      expect((await row('a'))['bank_key'], 'localbank');
    });
  });
}
