import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';

/// C-3 / F-025 — sender→bank mappings must not leave the device without consent.
///
/// This service had NO consent check of any kind. With the cloud switch OFF and
/// a signed-in user, it uploaded and downloaded the mapping of SMS senders to
/// banks — i.e. **which banks the user holds**. That is not money, but it is a
/// direct read on the user's financial life, and the privacy screen promises
/// «إيقافها يعطّل … والمزامنة».
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// Records every call. If consent is enforced, this store is never touched.
class _SpyRemoteStore implements SenderMappingRemoteStore {
  int fetchCalls = 0;
  int upsertCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    fetchCalls++;
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> upsert(
    List<Map<String, dynamic>> rows,
  ) async {
    upsertCalls++;
    return const [];
  }
}

void main() {
  late AppDatabase db;
  late _SpyRemoteStore remote;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    remote = _SpyRemoteStore();
  });
  tearDown(() async => db.close());

  SenderBankMappingSyncService service({required bool consent}) =>
      SenderBankMappingSyncService(
        db: db,
        remoteStore: remote,
        currentUserId: () => 'user-1',
        mayEgress: () async => consent,
      );

  test('consent OFF: sync touches the network zero times', () async {
    await service(consent: false).sync();
    expect(remote.fetchCalls, 0, reason: 'no pull may run without consent');
    expect(remote.upsertCalls, 0, reason: 'no push may run without consent');
  });

  test('consent OFF: push and pull are gated INDEPENDENTLY of sync()', () async {
    // Both are public and called directly elsewhere, so gating only the sync()
    // wrapper would leave a live bypass.
    final s = service(consent: false);
    await s.push('user-1');
    await s.pull('user-1');
    expect(remote.fetchCalls, 0);
    expect(remote.upsertCalls, 0);
  });

  test('consent ON: the service is allowed to reach the network', () async {
    await service(consent: true).sync();
    expect(remote.fetchCalls, greaterThan(0),
        reason: 'the gate must not break the feature when consent is granted');
  });

  test('a caller that forgets to pass the gate gets NO network', () async {
    // Fail-closed default. The previous convention in this codebase was the
    // opposite — RemoteBackupController defaults consent to `() => true` and its
    // provider never passes one, which is exactly how backup upload shipped
    // ungated. A forgotten argument must not open an egress path.
    final ungated = SenderBankMappingSyncService(
      db: db,
      remoteStore: remote,
      currentUserId: () => 'user-1',
    );
    await ungated.sync();
    expect(remote.fetchCalls, 0);
    expect(remote.upsertCalls, 0);
  });

  test('revocation mid-session is observed by the next call', () async {
    var consent = true;
    final s = SenderBankMappingSyncService(
      db: db,
      remoteStore: remote,
      currentUserId: () => 'user-1',
      mayEgress: () async => consent,
    );
    await s.sync();
    final afterGranted = remote.fetchCalls;
    expect(afterGranted, greaterThan(0));

    consent = false; // user revokes
    await s.sync();
    expect(remote.fetchCalls, afterGranted,
        reason: 'consent is read fresh at egress, never cached at construction');
  });
}
