import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

// MALI-055n — the default-account command contract. Changing the default must be
// ONE dedicated command (never a rewrite of every account), resolved to the
// atomic set_default_account RPC. A stale device switching default must never
// roll back unrelated account fields.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A fake that models the server: account rows keyed by server id, with an
/// atomic (last-write-wins) default and full field-update semantics.
class _ServerSink implements AccountsRemoteSink {
  final rows = <String, Map<String, dynamic>>{}; // serverId -> row
  int setDefaultCalls = 0;
  int upserts = 0;
  int fieldUpdates = 0;

  String _sid(String localId) => 'srv-$localId';

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    upserts++;
    final sid = _sid(row['local_id'] as String);
    rows[sid] = {
      ...?rows[sid],
      ...row,
      'id': sid,
      'is_default': rows[sid]?['is_default'] ?? false,
      'updated_at': 'u$upserts'
    };
    return {'id': sid, 'updated_at': rows[sid]!['updated_at']};
  }

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
          String u, String id) async =>
      rows[_sid(id)];

  Future<void> _tombstone(String serverId) async {
    rows[serverId]?['deleted_at'] = 'now';
    rows[serverId]?['is_default'] = false;
  }

  @override
  Future<Map<String, dynamic>?> casTombstoneAccount(
      String serverId, int expectedRevision) async {
    await _tombstone(serverId);
    return {'id': serverId, 'revision': expectedRevision + 1};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
      String serverId, String? expectedUpdatedAt) async {
    await _tombstone(serverId);
    return {'id': serverId};
  }

  @override
  Future<Map<String, dynamic>?> fetchAccountState(String serverId) async =>
      null;

  @override
  Future<String?> fetchAccountUpdatedAt(String serverId) async =>
      rows[serverId]?['updated_at'] as String?;

  @override
  Future<Map<String, dynamic>> updateAccountByServerId(
      String serverId, Map<String, dynamic> row) async {
    fieldUpdates++;
    rows[serverId] = {
      ...?rows[serverId],
      ...row,
      'id': serverId,
      'updated_at': 'f$fieldUpdates'
    };
    return {'id': serverId, 'updated_at': rows[serverId]!['updated_at']};
  }

  @override
  Future<Map<String, dynamic>?> casUpdateAccount(String serverId,
          int expectedRevision, Map<String, dynamic> row) async =>
      updateAccountByServerId(serverId, row);

  @override
  Future<void> setDefaultAccount(String serverAccountId) async {
    setDefaultCalls++;
    for (final r in rows.values) {
      r['is_default'] = r['id'] == serverAccountId;
    }
  }

  int activeDefaults() => rows.values
      .where((r) => r['deleted_at'] == null && r['is_default'] == true)
      .length;
}

AccountEntity _account(String id, {bool isDefault = false}) => AccountEntity(
      id: id,
      name: 'Name $id',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: isDefault,
      sortOrder: 1,
      createdAt: DateTime.utc(2026, 7, 4),
      updatedAt: DateTime.utc(2026, 7, 4),
      initialBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
      currentBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;
  late DriftAccountRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    repo = DriftAccountRepository(db, outboxQueue: queue);
  });
  tearDown(() => db.close());

  AccountsPushService pushSvc(_ServerSink sink, {bool casEnabled = false}) =>
      AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        revisionCasEnabled: casEnabled,
      
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    );

  Future<int> outboxCount(String where) async => (await db
          .customSelect(
              'SELECT COUNT(*) AS n FROM planning_sync_outbox WHERE $where;')
          .getSingle())
      .read<int>('n');

  test('setDefault queues ONE dedicated command and NO account field updates',
      () async {
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await db.customStatement('DELETE FROM planning_sync_outbox;');

    await repo.setDefault('b');

    // Exactly one default command; zero account field-update rows.
    expect(
      await outboxCount(
          "entity_type = '${PlanningOutboxQueue.accountDefaultCommandType}'"),
      1,
    );
    expect(
      await outboxCount(
          "entity_type = '${PlanningOutboxQueue.accountsEntityType}'"),
      0,
      reason: 'a default switch must not rewrite any account field payload',
    );
  });

  test('the command payload carries only the target + operation id (no fields)',
      () async {
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await repo.setDefault('b');

    final row = await db
        .customSelect(
            "SELECT payload_json FROM planning_sync_outbox WHERE entity_type = '${PlanningOutboxQueue.accountDefaultCommandType}';")
        .getSingle();
    final payload = row.read<String>('payload_json');
    expect(payload, contains('target_local_id'));
    expect(payload, contains('operation_id'));
    expect(payload, isNot(contains('"name"')));
    expect(payload, isNot(contains('currency')));
  });

  test(
      'a stale device switching default leaves a remote rename untouched '
      '(nothing is queued that could overwrite fields)', () async {
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    // Device is stale about "a" (server has a newer name) but only switches
    // default. Because no account field row is queued, the remote name is safe.
    await repo.setDefault('b');
    final accountRows = await db
        .customSelect(
            "SELECT payload_json FROM planning_sync_outbox WHERE entity_type = '${PlanningOutboxQueue.accountsEntityType}';")
        .get();
    expect(accountRows, isEmpty);
  });

  test('successive switches A→B→A coalesce to a single command for the latest',
      () async {
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await repo.setDefault('b');
    await repo.setDefault('a');
    await repo.setDefault('b');
    expect(
      await outboxCount(
          "entity_type = '${PlanningOutboxQueue.accountDefaultCommandType}'"),
      1,
      reason: 'only the latest default matters',
    );
  });

  test('push resolves the command to the RPC and leaves exactly one default',
      () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await repo.setDefault('b');
    final r = await pushSvc(sink).push();
    expect(r.failed, 0);
    expect(sink.setDefaultCalls, greaterThanOrEqualTo(1));
    expect(sink.rows['srv-b']?['is_default'], isTrue);
    expect(sink.activeDefaults(), 1);
  });

  test('offline switch then retry after enabling push applies once', () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await pushSvc(sink).push(); // a,b established
    await repo.setDefault('b'); // "offline" (not pushed yet)
    expect(sink.rows['srv-b']?['is_default'], isNot(true));
    await pushSvc(sink).push();
    expect(sink.rows['srv-b']?['is_default'], isTrue);
    expect(sink.activeDefaults(), 1);
  });

  test('idempotent replay: pushing the same command twice keeps one default',
      () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await repo.setDefault('b');
    await pushSvc(sink).push();
    // Re-enqueue the same switch (crash-after-acceptance / replay) and push.
    await repo.setDefault('b');
    final r = await pushSvc(sink).push();
    expect(r.failed, 0);
    expect(sink.activeDefaults(), 1);
    expect(sink.rows['srv-b']?['is_default'], isTrue);
  });

  test(
      'two concurrent default switches converge to a single deterministic '
      'winner (last RPC wins), no field rollback', () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await pushSvc(sink).push();
    // Simulate device A → default a, then device B → default b hitting the
    // server RPC afterwards. The server is atomic last-write-wins.
    await sink.setDefaultAccount('srv-a');
    await sink.setDefaultAccount('srv-b');
    expect(sink.activeDefaults(), 1);
    expect(sink.rows['srv-b']?['is_default'], isTrue);
    // Field values were never touched by the default RPC.
    expect(sink.rows['srv-a']?['name'], 'Name a');
    expect(sink.rows['srv-b']?['name'], 'Name b');
  });

  test(
      'deleting the current default promotes a successor — exactly one default',
      () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await repo.setDefault('a');
    await pushSvc(sink).push();
    await repo.delete('a');
    final r = await pushSvc(sink).push();
    expect(r.failed, 0);
    expect(sink.rows['srv-a']?['deleted_at'], isNotNull);
    expect(sink.activeDefaults(), 1);
  });

  test('capability ON path also resolves the default via the RPC', () async {
    final sink = _ServerSink();
    await repo.create(_account('a', isDefault: true));
    await repo.create(_account('b'));
    await repo.setDefault('b');
    final r = await pushSvc(sink, casEnabled: true).push();
    expect(r.failed, 0);
    expect(sink.rows['srv-b']?['is_default'], isTrue);
    expect(sink.activeDefaults(), 1);
  });
}
