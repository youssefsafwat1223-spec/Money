import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    return (rows[table]?.values ?? const <Map<String, dynamic>>[])
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      rows[table]?[localId];

  @override
  Future<Map<String, dynamic>?> casTombstone(
          String table, String serverId, int expectedRevision) async =>
      {'id': serverId, 'revision': expectedRevision + 1};

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
          String table, String serverId, String? expectedUpdatedAt) async =>
      {'id': serverId};

  @override
  Future<Map<String, dynamic>?> fetchRowState(
          String table, String serverId) async =>
      null;

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    final localId = row['local_id'] as String;
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': now};
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    for (final r in rows[table]?.values ?? const <Map<String, dynamic>>[]) {
      if (r['id'] == serverId) return r['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
          String table, String serverId, Map<String, dynamic> row) =>
      upsert(table, row);

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: no concurrent writer is modelled here; guard REJECTION is covered in
    // planning_guarded_update_atomicity_test.dart.
    return updateByServerId(table, serverId, row);
  }


  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(String table,
          String serverId, int expectedRevision, Map<String, dynamic> row) =>
      throw UnimplementedError('CAS is exercised by the dedicated CAS test');
}

Future<AppDatabase> _openDb() => AppDatabase.open(
    executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

PlanningPushService _push(
        AppDatabase db, PlanningOutboxQueue q, _FakeRemote r) =>
    PlanningPushService(
        db: db,
        queue: q,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: r);

PlanningPullService _pull(AppDatabase db, _FakeRemote r) => PlanningPullService(
    db: db,
    isEnabled: (_) => true,
    // C-3: these cover settings-pull MECHANICS; consent enforcement is
    // asserted in financial_pull_consent_test.dart.
    mayEgress: () async => true,
    getAuthUserId: () async => 'user-1',
    remoteSource: r);

Future<String?> _col(AppDatabase db, String col) async {
  final row = await db
      .customSelect('SELECT $col AS v FROM user_settings LIMIT 1;')
      .getSingle();
  return row.readNullable<String>('v');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRemote remote;
  late PlanningOutboxQueue queue;
  late DriftUserSettingsRepository settings;

  setUp(() async {
    db = await _openDb();
    remote = _FakeRemote();
    queue = _queue(db);
    settings = DriftUserSettingsRepository(db, outboxQueue: queue);
  });
  tearDown(() async => db.close());

  /// Binds the local singleton to the server row — production state after the
  /// first pull. enqueueSettings only accepts updates once bound (unbound
  /// updates are post-wipe defaults and must never clobber cloud settings).
  Future<void> bind() => db.customStatement(
      "UPDATE user_settings SET server_id = 'server-user_settings';");

  test(
      'changing a cloud setting pushes cloud + profile columns, never '
      'device-local/security ones', () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(
        s.copyWith(theme: 'dark', currency: 'AED', displayName: 'يوسف'));

    final result = await _push(db, queue, remote).push();
    expect(result.failed, 0);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['theme'], 'dark');
    expect(serverRow['currency'], 'AED');
    // Profile fields sync since migration 0063 — a sign-out wipe used to
    // destroy the user's name/phone/birth date permanently.
    expect(serverRow['display_name'], 'يوسف');
    expect(serverRow.containsKey('phone_number'), isTrue);
    expect(serverRow.containsKey('date_of_birth'), isTrue);
    // Device-local / security columns must NEVER be sent.
    expect(serverRow.containsKey('db_encryption_key_ref'), isFalse);
    expect(serverRow.containsKey('avatar_path'), isFalse);
    // Singleton: constant local_id.
    expect(serverRow['local_id'], 'user_settings');
  });

  test('pull updates cloud columns but preserves device-local columns',
      () async {
    // Seed a local avatar_path + key ref that must survive a pull.
    await db.customStatement(
      "UPDATE user_settings SET avatar_path='/local/avatar.png', "
      "db_encryption_key_ref='device-key-ref', theme='light';",
    );
    remote.rows['user_settings'] = {
      'user_settings': {
        'id': 'server-user_settings',
        'local_id': 'user_settings',
        'display_name': 'يوسف',
        'phone_number': null, // server never had it → local value must survive
        'theme': 'dark',
        'currency': 'USD',
        'language': 'en',
        'country': 'US',
        'input_method': 'manual',
        'notifications_json': '{}',
        'privacy_mode_enabled': true,
        'ai_consent_granted': true,
        'cloud_processing_enabled': true,
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'deleted_at': null,
      },
    };
    await db.customStatement(
      "UPDATE user_settings SET phone_number='0500000000';",
    );

    await _pull(db, remote).pull();

    expect(await _col(db, 'theme'), 'dark'); // cloud updated
    expect(await _col(db, 'currency'), 'USD');
    // Profile restored from the server (the sign-out wipe survivor path).
    expect(await _col(db, 'display_name'), 'يوسف');
    // Server-null profile field keeps the local value instead of erasing it.
    expect(await _col(db, 'phone_number'), '0500000000');
    // Device-local preserved.
    expect(await _col(db, 'avatar_path'), '/local/avatar.png');
    expect(await _col(db, 'db_encryption_key_ref'), 'device-key-ref');
  });

  test('multi-device: device A change pulls to device B as one settings row',
      () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(theme: 'dark'));
    await _push(db, queue, remote).push();

    final dbB = await _openDb();
    addTearDown(() async => dbB.close());
    await _pull(dbB, remote).pull();

    expect(await _col(dbB, 'theme'), 'dark');
    // Still exactly one settings row (singleton, not duplicated).
    final count = await dbB
        .customSelect('SELECT COUNT(*) AS c FROM user_settings;')
        .getSingle();
    expect(count.read<int>('c'), 1);
  });

  test('local pending edit is not overwritten by pull (conflict guard)',
      () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(theme: 'dark')); // sets pending
    // Server has a different value but local edit is still pending.
    remote.rows['user_settings'] = {
      'user_settings': {
        'id': 'server-user_settings',
        'local_id': 'user_settings',
        'theme': 'light',
        'currency': 'SAR',
        'language': 'ar',
        'country': 'SA',
        'input_method': 'auto',
        'notifications_json': '{}',
        'privacy_mode_enabled': false,
        'ai_consent_granted': true,
        'cloud_processing_enabled': true,
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'deleted_at': null,
      },
    };

    final result = await _pull(db, remote).pull();

    expect(result.conflicts, greaterThanOrEqualTo(1));
    expect(await _col(db, 'theme'), 'dark'); // local edit preserved
  });

  test(
      'unbound singleton (post-wipe defaults) is NEVER pushed as an update — '
      'cloud settings cannot be clobbered before the first pull', () async {
    // No bind(): server_id is NULL, as right after a sign-out wipe. Automatic
    // writers (notification history) save settings within seconds of sign-in.
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(country: 'SA', currency: 'SAR'));

    final result = await _push(db, queue, remote).push();
    expect(result.pushed, 0, reason: 'nothing may be queued while unbound');
    expect(remote.rows['user_settings'], isNull,
        reason: 'the reseeded defaults must not overwrite the cloud row');
  });
}
