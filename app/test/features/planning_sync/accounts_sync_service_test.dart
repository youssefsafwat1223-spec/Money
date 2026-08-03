import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/routed_account_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeAccountsRemote implements AccountsRemoteSink, AccountsRemoteSource {
  final rowsByLocalId = <String, Map<String, dynamic>>{};
  final tombstones = <Map<String, dynamic>>[];
  int upserts = 0;
  int deletes = 0;
  bool throwConflict = false;

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
    String userId,
    String id,
  ) async {
    return rowsByLocalId[id];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final byId = <String, Map<String, dynamic>>{};
    for (final row in [...rowsByLocalId.values, ...tombstones]) {
      byId[row['id'] as String] = row;
    }
    return byId.values.take(limit).toList();
  }

  @override
  Future<void> tombstoneAccount(String serverId) async {
    deletes++;
    final row = rowsByLocalId.values.firstWhere(
      (item) => item['id'] == serverId,
      orElse: () => <String, dynamic>{},
    );
    if (row.isNotEmpty) {
      final deleted = DateTime.now().toUtc().toIso8601String();
      row['deleted_at'] = deleted;
      row['updated_at'] = deleted;
      tombstones.add(Map<String, dynamic>.from(row));
    }
  }

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    if (throwConflict) throw StateError('409 conflict');
    upserts++;
    upsertedRows.add(Map<String, dynamic>.from(row));
    final localId = row['local_id'] as String;
    final now = DateTime.now().toUtc().toIso8601String();
    final saved = {
      ...row,
      'id': rowsByLocalId[localId]?['id'] ?? 'server-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rowsByLocalId[localId] = saved;
    return {'id': saved['id'], 'updated_at': saved['updated_at']};
  }

  final upsertedRows = <Map<String, dynamic>>[];
  final defaultRpcCalls = <String>[];

  @override
  Future<String?> fetchAccountUpdatedAt(String serverId) async {
    for (final row in rowsByLocalId.values) {
      if (row['id'] == serverId) return row['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> updateAccountByServerId(
    String serverId,
    Map<String, dynamic> row,
  ) async {
    if (throwConflict) throw StateError('409 conflict');
    upsertedRows.add(Map<String, dynamic>.from(row));
    final entry = rowsByLocalId.entries
        .firstWhere((item) => item.value['id'] == serverId);
    final now = DateTime.now().toUtc().toIso8601String();
    rowsByLocalId[entry.key] = {
      ...entry.value,
      ...row,
      'id': serverId,
      'updated_at': now,
    };
    return {'id': serverId, 'updated_at': now};
  }

  @override
  Future<Map<String, dynamic>?> casUpdateAccount(
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) async {
    throw UnimplementedError('CAS is exercised by the dedicated CAS test');
  }

  @override
  Future<void> setDefaultAccount(String serverAccountId) async {
    // Mirrors the atomic server RPC: demote everyone, promote the target.
    defaultRpcCalls.add(serverAccountId);
    for (final row in rowsByLocalId.values) {
      row['is_default'] = row['id'] == serverAccountId;
    }
  }
}

class _KeysetAccountsRemote implements AccountsRemoteSource {
  _KeysetAccountsRemote(this.rows);

  final List<Map<String, dynamic>> rows;
  final List<SyncCursor> requestedAfter = [];

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    requestedAfter.add(after);
    final ordered = rows.map(Map<String, dynamic>.from).toList()
      ..sort((left, right) {
        final timestamp = normalizeCursorTimestamp(left['updated_at'])
            .compareTo(normalizeCursorTimestamp(right['updated_at']));
        if (timestamp != 0) return timestamp;
        return (left['id'] as String).compareTo(right['id'] as String);
      });
    return ordered
        .where((row) {
          if (after.id.isEmpty) return true;
          final timestamp = normalizeCursorTimestamp(row['updated_at']);
          final comparison = timestamp.compareTo(after.updatedAt);
          return comparison > 0 ||
              (comparison == 0 &&
                  (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

Map<String, dynamic> _remoteAccountRow(
  int index, {
  String updatedAt = '2026-07-10T00:00:00.000Z',
}) {
  final suffix = index.toString().padLeft(3, '0');
  return {
    'id': 'server-$suffix',
    'local_id': 'account-$suffix',
    'name': 'Remote $suffix',
    'currency': 'SAR',
    'type': 'bank',
    'initial_balance': index,
    'current_balance': index,
    'is_default': false,
    'sort_order': index,
    'created_at': '2026-07-01T00:00:00.000Z',
    'updated_at': updatedAt,
    'deleted_at': null,
  };
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

AccountEntity _account(String id) {
  final now = DateTime.utc(2026, 7, 4, 12);
  return AccountEntity(
    id: id,
    name: 'Main $id',
    currency: 'SAR',
    type: AccountType.bank,
    isDefault: false,
    sortOrder: 1,
    createdAt: now,
    updatedAt: now,
    initialBalance: 100,
    currentBalance: 100,
  );
}

PlanningOutboxQueue _queue(
  AppDatabase db, {
  required bool enabled,
  String? userId = 'user-1',
}) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => enabled,
    getAuthUserId: () async => userId,
  );
}

Future<int> _outboxCount(AppDatabase db) async {
  final row = await db
      .customSelect(
        'SELECT COUNT(*) AS total FROM planning_sync_outbox;',
      )
      .getSingle();
  return row.read<int>('total');
}

Future<String?> _accountSyncStatus(AppDatabase db, String id) async {
  final row = await db
      .customSelect(
        'SELECT sync_status FROM accounts WHERE id = ${sqlString(id)} LIMIT 1;',
      )
      .getSingleOrNull();
  return row?.readNullable<String>('sync_status');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('accounts planning sync', () {
    late AppDatabase db;

    setUp(() async {
      db = await _openDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('planning_accounts_sync OFF does not queue local account writes',
        () async {
      final repo = DriftAccountRepository(
        db,
        outboxQueue: _queue(db, enabled: false),
      );

      final saved = await repo.create(_account('account-off'));

      expect(saved.id, 'account-off');
      expect(await _outboxCount(db), 0);
      expect((await repo.getById('account-off'))?.name, 'Main account-off');
    });

    test('planning_accounts_sync OFF makes push and pull no-op', () async {
      final remote = _FakeAccountsRemote();
      final queue = _queue(db, enabled: true);
      await DriftAccountRepository(db, outboxQueue: queue)
          .create(_account('queued-but-off'));
      expect(await _outboxCount(db), greaterThan(0));

      final push = AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => false,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final pull = AccountsPullService(
        db: db,
        isEnabled: () => false,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      expect((await push.push()).pushed, 0);
      expect((await pull.pull()).imported, 0);
      expect(remote.upserts, 0);
    });

    test('guest user does not queue account writes even when flag is ON',
        () async {
      final repo = DriftAccountRepository(
        db,
        outboxQueue: _queue(db, enabled: true, userId: null),
      );

      await repo.create(_account('guest-account'));

      expect(await _outboxCount(db), 0);
    });

    test('signed-in flag ON queues and pushes account create update delete',
        () async {
      final remote = _FakeAccountsRemote();
      final queue = _queue(db, enabled: true);
      final repo = DriftAccountRepository(db, outboxQueue: queue);
      final push = AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );

      final account = await repo.create(_account('push-account'));
      await repo.update(account.copyWith(name: 'Updated'));
      await repo.create(_account('delete-account'));
      await repo.delete('delete-account');

      // MALI-052n coalescing: push-account's create+update fold into one create
      // (latest name); delete-account's create+delete (both offline, never
      // synced) drop entirely. So exactly one pending row remains.
      expect(await _outboxCount(db), 1);

      final result = await push.push();

      expect(result.pushed, 1);
      expect(result.failed, 0);
      expect(await _outboxCount(db), 0);
      expect(remote.rowsByLocalId['push-account']?['name'], 'Updated');
      expect(
        remote.rowsByLocalId['push-account']?['metadata'],
        isA<Map<String, dynamic>>().having((value) => value, 'value', isEmpty),
      );
      expect(remote.deletes, 0,
          reason: 'delete-account was created+deleted offline → coalesced away');
    });

    test(
        'default switch travels via the atomic RPC, never the upsert row '
        '(MALI-015)', () async {
      final remote = _FakeAccountsRemote();
      final queue = _queue(db, enabled: true);
      final repo = DriftAccountRepository(db, outboxQueue: queue);
      final push = AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );

      await repo.create(_account('acc-a'));
      await repo.create(_account('acc-b'));
      await repo.setDefault('acc-b');

      final result = await push.push();
      expect(result.failed, 0);

      // No upsert row may carry is_default — the partial unique index race
      // is structurally impossible.
      for (final row in remote.upsertedRows) {
        expect(row.containsKey('is_default'), isFalse,
            reason: 'is_default must never ride the upsert');
      }
      // The RPC was invoked and the fake's atomic swap made acc-b the only
      // default server-side.
      expect(remote.defaultRpcCalls, isNotEmpty);
      expect(remote.rowsByLocalId['acc-b']?['is_default'], isTrue);
      final defaults = remote.rowsByLocalId.values
          .where((row) => row['is_default'] == true)
          .length;
      expect(defaults, 1);
    });

    test(
        'deleting the default enqueues the promoted successor '
        '(fresh devices must not pull a default-less account set)', () async {
      final remote = _FakeAccountsRemote();
      final queue = _queue(db, enabled: true);
      final repo = DriftAccountRepository(db, outboxQueue: queue);
      final push = AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );

      await repo.create(_account('def-a'));
      await repo.create(_account('def-b'));
      await repo.setDefault('def-a');
      await push.push();

      await repo.delete('def-a');
      final result = await push.push();
      expect(result.failed, 0);
      expect(remote.deletes, 1,
          reason: 'the default-account delete must reach the server');

      // def-a is tombstoned server-side, and the promoted successor's
      // default flag reached the server via the RPC — exactly one active
      // default remains. (The DB also seeds its own initial account, so we
      // assert on the invariant, not a specific account count.)
      expect(remote.rowsByLocalId['def-a']?['deleted_at'], isNotNull);
      final activeDefaults = remote.rowsByLocalId.values
          .where(
              (row) => row['deleted_at'] == null && row['is_default'] == true)
          .toList();
      expect(activeDefaults, hasLength(1),
          reason: 'fresh devices must pull exactly one default');
    });

    test('pull imports one account and duplicate pull does not duplicate',
        () async {
      final remote = _FakeAccountsRemote();
      remote.rowsByLocalId['remote-account'] = {
        'id': 'server-remote-account',
        'local_id': 'remote-account',
        'name': 'Remote Account',
        'currency': 'AED',
        'type': 'wallet',
        'initial_balance': 10,
        'current_balance': 20,
        'is_default': false,
        'sort_order': 4,
        'created_at': DateTime.utc(2026, 7, 4).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 4, 1).toIso8601String(),
        'deleted_at': null,
      };
      final pull = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      final first = await pull.pull();
      final second = await pull.pull();

      expect(first.imported, 1);
      expect(second.imported, 0);
      final rows = await db
          .customSelect(
            "SELECT * FROM accounts WHERE id = 'remote-account';",
          )
          .get();
      expect(rows.length, 1);
      expect(rows.single.read<String>('server_id'), 'server-remote-account');
    });

    test('tombstone hides local account without hard delete', () async {
      final remote = _FakeAccountsRemote();
      final repo = DriftAccountRepository(db);
      await repo.create(_account('tombstone-account'));
      remote.tombstones.add({
        'id': 'server-tombstone-account',
        'local_id': 'tombstone-account',
        'deleted_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
      });
      final pull = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      final result = await pull.pull();

      expect(result.tombstoned, 1);
      expect(await repo.getById('tombstone-account'), isNull);
      final row = await db
          .customSelect(
            "SELECT deleted_at FROM accounts WHERE id = 'tombstone-account';",
          )
          .getSingle();
      expect(row.readNullable<String>('deleted_at'), isNotNull);
    });

    test('pull marks local pending edit as conflict', () async {
      final remote = _FakeAccountsRemote();
      final repo = DriftAccountRepository(db);
      await repo.create(_account('conflict-account'));
      await db.customStatement(
        "UPDATE accounts SET sync_status = 'pending' WHERE id = 'conflict-account';",
      );
      remote.rowsByLocalId['conflict-account'] = {
        'id': 'server-conflict-account',
        'local_id': 'conflict-account',
        'name': 'Remote Edit',
        'currency': 'SAR',
        'type': 'bank',
        'is_default': false,
        'sort_order': 1,
        'created_at': DateTime.utc(2026, 7, 4).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'deleted_at': null,
      };

      final pull = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      final result = await pull.pull();

      expect(result.conflicts, 1);
      expect(await _accountSyncStatus(db, 'conflict-account'), 'conflict');
      expect((await repo.getById('conflict-account'))?.name,
          'Main conflict-account');
    });

    test('fresh pull paginates 201 equal-timestamp rows and persists last key',
        () async {
      final remote = _KeysetAccountsRemote(
        List.generate(201, _remoteAccountRow),
      );
      final pull = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        pageSize: 200,
      );

      final result = await pull.pull();

      expect(result.imported, 201);
      expect(remote.requestedAfter, hasLength(2));
      expect(remote.requestedAfter.first.id, isEmpty,
          reason: 'a fresh device starts without a durable cursor');
      expect(
        await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM accounts WHERE id LIKE 'account-%';",
            )
            .getSingle()
            .then((row) => row.read<int>('n')),
        201,
      );
      final cursor = await readSyncCursor(db, 'accounts');
      expect(cursor.updatedAt, '2026-07-10T00:00:00.000Z');
      expect(cursor.id, 'server-200');
    });

    test('an older tombstone is applied before more than one page of actives',
        () async {
      await DriftAccountRepository(db).create(_account('victim'));
      final remote = _KeysetAccountsRemote([
        {
          'id': 'server-victim',
          'local_id': 'victim',
          'updated_at': '2026-07-11T00:00:00.000Z',
          'deleted_at': '2026-07-11T00:00:00.000Z',
        },
        ...List.generate(
          5,
          (index) => _remoteAccountRow(
            index,
            updatedAt: '2026-07-12T00:00:00.000Z',
          ),
        ),
      ]);
      final result = await AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        pageSize: 2,
      ).pull();

      expect(result.tombstoned, 1);
      expect(remote.requestedAfter.length, 4,
          reason: 'an exact final page is followed by one empty page');
      final victim = await db
          .customSelect("SELECT deleted_at FROM accounts WHERE id = 'victim';")
          .getSingle();
      expect(victim.readNullable<String>('deleted_at'), isNotNull);
    });

    test('failed page rolls back row writes and cursor, then retries cleanly',
        () async {
      final first = _remoteAccountRow(0);
      final broken = _remoteAccountRow(1)..['initial_balance'] = 'not-a-number';
      final remote = _KeysetAccountsRemote([first, broken]);
      final pull = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        pageSize: 2,
      );

      await pull.pull();

      expect(
        await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM accounts WHERE id IN ('account-000', 'account-001');",
            )
            .getSingle()
            .then((row) => row.read<int>('n')),
        0,
      );
      expect(
        await db
            .customSelect(
              "SELECT entity FROM sync_cursors WHERE entity = 'accounts';",
            )
            .getSingleOrNull(),
        isNull,
      );

      broken['initial_balance'] = 1;
      final retried = await pull.pull();

      expect(retried.imported, 2);
      expect(
        await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM accounts WHERE id IN ('account-000', 'account-001');",
            )
            .getSingle()
            .then((row) => row.read<int>('n')),
        2,
      );
      expect((await readSyncCursor(db, 'accounts')).id, 'server-001');
    });

    // Phase 2: accountRepositoryProvider now returns a RoutedAccountRepository
    // that delegates to Drift when accounts_supabase_primary is OFF (the
    // default) — this replaces the pre-Phase-2 assertion that the provider
    // returned DriftAccountRepository directly.
    test(
        'accountRepositoryProvider routes through RoutedAccountRepository '
        '(Drift by default)', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      final repo = container.read(accountRepositoryProvider);

      expect(repo, isA<RoutedAccountRepository>());
    });
  });
}
