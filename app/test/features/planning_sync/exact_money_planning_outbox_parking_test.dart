import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

// MALI-026 (Phase-8 B8-2.10 §8/§9/§10/§11) — exact-money PUSH is
// parked in the REAL planning outbox until transport is verified, then the SAME
// durable row replays with its exact decimal-string payload. Schema-v29 legacy
// mode remains the JSON-number wire shape and never parks.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeAccountsSink implements AccountsRemoteSink {
  _FakeAccountsSink({this.failIfCalled = false});

  final bool failIfCalled;
  final sentRows = <Map<String, dynamic>>[];

  void _recordCall() {
    if (failIfCalled) {
      throw StateError('network must not be called while parked');
    }
  }

  @override
  Future<Map<String, dynamic>> upsertAccount(
    Map<String, dynamic> row,
  ) async {
    _recordCall();
    sentRows.add(Map<String, dynamic>.from(row));
    return {
      'id': 'server-${row['local_id']}',
      'updated_at': '2026-08-11T00:00:00.000Z',
    };
  }

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
    String userId,
    String id,
  ) async {
    _recordCall();
    return null;
  }

  @override
  Future<Map<String, dynamic>?> casTombstoneAccount(
      String serverId, int expectedRevision) async {
    _recordCall();
    return {'id': serverId, 'revision': expectedRevision + 1};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
      String serverId, String? expectedUpdatedAt) async {
    _recordCall();
    return {'id': serverId};
  }

  @override
  Future<Map<String, dynamic>?> fetchAccountState(String serverId) async {
    _recordCall();
    return null;
  }

  @override
  Future<String?> fetchAccountUpdatedAt(String serverId) async {
    _recordCall();
    return null;
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateAccount(
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) =>
      // C-6: the fake has no concurrent writer, so the atomic guarded update
      // and the targeted update are equivalent here. The ATOMICITY itself is
      // asserted structurally in guarded_update_atomicity_test.dart.
      updateAccountByServerId(serverId, row);

  @override
  Future<Map<String, dynamic>> updateAccountByServerId(
    String serverId,
    Map<String, dynamic> row,
  ) async {
    _recordCall();
    sentRows.add(Map<String, dynamic>.from(row));
    return {
      'id': serverId,
      'updated_at': '2026-08-11T00:00:00.000Z',
    };
  }

  @override
  Future<Map<String, dynamic>?> casUpdateAccount(
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) async {
    _recordCall();
    sentRows.add(Map<String, dynamic>.from(row));
    return {
      'id': serverId,
      'updated_at': '2026-08-11T00:00:00.000Z',
      'revision': expectedRevision + 1,
    };
  }

  @override
  Future<void> setDefaultAccount(String serverAccountId) async => _recordCall();
}

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);
const _legacy = FixedPlanningCutoverCoordinator(PlanningCutoverState.legacy);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  PlanningOutboxQueue queue(PlanningCutoverCoordinator coordinator) =>
      PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-123',
        coordinator: coordinator,
      );

  Future<void> enqueueAccount(PlanningOutboxQueue q) async {
    final now = DateTime.utc(2026, 8, 11);
    await db.customStatement('''
      INSERT INTO accounts(
        id, name, currency, type, initial_balance, current_balance,
        is_default, sort_order, created_at, updated_at, sync_status
      ) VALUES (
        'account-001', 'Main', 'SAR', 'bank', 100.01, 100.01,
        0, 1, ${sqlString(dateTimeToSql(now))},
        ${sqlString(dateTimeToSql(now))}, 'local_only'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
    await q.enqueueAccount(
      PlanningSyncOperation.create,
      AccountEntity(
        id: 'account-001',
        name: 'Main',
        currency: 'SAR',
        type: AccountType.bank,
        initialBalanceMoney: Money.parse('100.01', 'SAR'),
        currentBalanceMoney: Money.parse('100.01', 'SAR'),
        isDefault: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<Map<String, dynamic>> payload() async {
    final row = await db
        .customSelect(
          "SELECT payload_json FROM planning_sync_outbox WHERE entity_type = 'account' LIMIT 1;",
        )
        .getSingle();
    return (jsonDecode(row.read<String>('payload_json')) as Map).cast();
  }

  Future<String?> accountSyncStatus() async => (await db
          .customSelect(
            "SELECT sync_status AS s FROM accounts WHERE id = 'account-001';",
          )
          .getSingle())
      .readNullable<String>('s');

  AccountsPushService push({
    required PlanningOutboxQueue queue,
    required PlanningCutoverCoordinator coordinator,
    required ExactTransportCapability capability,
    required AccountsRemoteSink sink,
  }) {
    return AccountsPushService(
      db: db,
      queue: queue,
      isEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      remoteSink: sink,
      coordinator: coordinator,
      pushCapability: () => capability,
    
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    );
  }

  test('§10 legacy enqueue keeps account initial_balance as a JSON number',
      () async {
    final q = queue(_legacy);
    await enqueueAccount(q);

    final amount = (await payload())['initial_balance'];
    expect(amount, isA<num>());
    expect(amount, 100.01);
  });

  test('§10 canonical enqueue writes the exact account decimal string',
      () async {
    final q = queue(_canonical);
    await enqueueAccount(q);

    final amount = (await payload())['initial_balance'];
    expect(amount, isA<String>());
    expect(amount, '100.01');
  });

  test('§8 canonical + unknown push parks without send, sync, or attempt',
      () async {
    final q = queue(_canonical);
    await enqueueAccount(q);
    final sink = _FakeAccountsSink(failIfCalled: true);

    final result = await push(
      queue: q,
      coordinator: _canonical,
      capability: ExactTransportCapability.unknown,
      sink: sink,
    ).push();

    expect(result.parked, 1);
    expect(result.pushed, 0);
    expect(sink.sentRows, isEmpty);
    expect(await q.parkedCount(), 1);
    expect(await q.pendingItems(), isEmpty);
    expect(await accountSyncStatus(), 'pending');
    final row = await db.customSelect('''
          SELECT status, failure_class, attempt_count
          FROM planning_sync_outbox WHERE entity_id = 'account-001';
        ''').getSingle();
    expect(row.read<String>('status'), 'parked');
    expect(
      row.read<String>('failure_class'),
      exactMoneyTransportUnverifiedReason,
    );
    expect(row.read<int>('attempt_count'), 0);
  });

  test('§9 verified exact transport replays the same durable account row',
      () async {
    final q = queue(_canonical);
    await enqueueAccount(q);
    await push(
      queue: q,
      coordinator: _canonical,
      capability: ExactTransportCapability.unknown,
      sink: _FakeAccountsSink(failIfCalled: true),
    ).push();
    expect(await q.parkedCount(), 1);

    // Simulated restart: a fresh queue and push service use the same durable DB.
    final q2 = queue(_canonical);
    final sink = _FakeAccountsSink();
    final result = await push(
      queue: q2,
      coordinator: _canonical,
      capability: ExactTransportCapability.verifiedExact,
      sink: sink,
    ).push();

    expect(result.pushed, 1);
    expect(sink.sentRows, hasLength(1));
    expect(sink.sentRows.single['initial_balance'], isA<String>());
    expect(sink.sentRows.single['initial_balance'], '100.01');
    expect(await q2.parkedCount(), 0);
    final count = await db
        .customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;')
        .getSingle();
    expect(count.read<int>('n'), 0);
    expect(await accountSyncStatus(), 'synced');
  });

  test('legacy v29 + unknown sends the number and completes', () async {
    final q = queue(_legacy);
    await enqueueAccount(q);
    final sink = _FakeAccountsSink();

    final result = await push(
      queue: q,
      coordinator: _legacy,
      capability: ExactTransportCapability.unknown,
      sink: sink,
    ).push();

    expect(result.parked, 0);
    expect(result.pushed, 1);
    expect(sink.sentRows.single['initial_balance'], isA<num>());
    expect(sink.sentRows.single['initial_balance'], 100.01);
    expect(await q.parkedCount(), 0);
    expect(await accountSyncStatus(), 'synced');
  });
}
