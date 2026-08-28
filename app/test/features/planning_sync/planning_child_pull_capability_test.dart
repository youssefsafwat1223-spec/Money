import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

enum _ChildFamily {
  goalContribution,
  billPayment,
  planLink,
}

extension on _ChildFamily {
  String get entityType => switch (this) {
        _ChildFamily.goalContribution =>
          PlanningOutboxQueue.goalContributionsEntityType,
        _ChildFamily.billPayment => PlanningOutboxQueue.billPaymentsEntityType,
        _ChildFamily.planLink => PlanningOutboxQueue.planLinksEntityType,
      };

  String get remoteTable => switch (this) {
        _ChildFamily.goalContribution => 'user_goal_contributions',
        _ChildFamily.billPayment => 'user_bill_payments',
        _ChildFamily.planLink => 'user_plan_transaction_links',
      };

  String get localTable => switch (this) {
        _ChildFamily.goalContribution => 'goal_contributions',
        _ChildFamily.billPayment => 'bill_payments',
        _ChildFamily.planLink => 'plan_transaction_links',
      };

  String get cursorKey => 'planning_child_${remoteTable.substring(5)}';

  Map<String, dynamic> get remoteRow => switch (this) {
        _ChildFamily.goalContribution => {
            'id': 'server-gc-1',
            'local_id': 'local-gc-1',
            'goal_id': 'server-goal-1',
            'amount_text': '12.34',
            'created_at': '2026-08-24T09:00:00.000Z',
            'note': null,
            'updated_at': '2026-08-24T10:00:00.000Z',
            'deleted_at': null,
          },
        _ChildFamily.billPayment => {
            'id': 'server-bp-1',
            'local_id': 'local-bp-1',
            'subscription_id': 'server-subscription-1',
            'transaction_id': 'server-transaction-1',
            'amount_text': '12.34',
            'currency': 'EGP',
            'period_start': '2026-08-01',
            'period_end': '2026-08-31',
            'paid_at': '2026-08-24',
            'installment_index': null,
            'note': null,
            'updated_at': '2026-08-24T10:00:00.000Z',
            'deleted_at': null,
          },
        _ChildFamily.planLink => {
            'id': 'server-link-1',
            'plan_id': 'server-plan-1',
            'transaction_id': 'server-transaction-1',
            'created_at': '2026-08-24T09:00:00.000Z',
            'updated_at': '2026-08-24T10:00:00.000Z',
            'deleted_at': null,
          },
      };
}

class _CountingChildRemote implements PlanningChildRemote {
  _CountingChildRemote(this.family);

  final _ChildFamily family;
  final fetchCalls = <String, int>{};

  int get totalFetchCalls =>
      fetchCalls.values.fold(0, (total, calls) => total + calls);

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    fetchCalls.update(table, (calls) => calls + 1, ifAbsent: () => 1);
    if (table != family.remoteTable) return const [];
    final row = family.remoteRow;
    final rowCursor = SyncCursor.fromServerRow(row);
    final afterRow = rowCursor.updatedAt.compareTo(after.updatedAt) > 0 ||
        (rowCursor.updatedAt == after.updatedAt &&
            rowCursor.id.compareTo(after.id) > 0);
    return afterRow ? [row] : const [];
  }

  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async =>
      throw StateError('unexpected push RPC: $name');

  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async =>
      throw StateError('unexpected plan-link push query');

  @override
  Future<void> tombstonePlanLink(String serverId) async =>
      throw StateError('unexpected plan-link tombstone');

  @override
  Future<Map<String, dynamic>> upsertPlanLink(
    Map<String, dynamic> row,
  ) async =>
      throw StateError('unexpected plan-link push');
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

Future<void> _seedParents(AppDatabase db) async {
  const before = '2026-08-23T09:00:00.000Z';
  await db.customStatement('''
    INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
    VALUES ('merchant-1','merchant','merchant','$before','$before');
  ''');
  await db.customStatement('''
    INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,
      saved_amount,saved_amount_minor,last_notified_saved_amount_minor,vault_skin,
      status,created_at,server_id,sync_status)
    VALUES ('goal-1','Goal','EGP',100,10000,0,0,0,'classic','active',
      '$before','server-goal-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO subscriptions(id,merchant_id,amount,period,next_due_date,
      is_confirmed,reminder_on,name,type,currency,frequency,created_at,status,
      server_id,sync_status)
    VALUES ('subscription-1','merchant-1',12.34,'monthly','$before',1,1,
      'Subscription','subscription','EGP','monthly','$before','active',
      'server-subscription-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,
      account_ids,card_last4s,status,created_at,server_id,sync_status)
    VALUES ('plan-1','Plan',100,'EGP','$before','2026-09-30','','','active',
      '$before','server-plan-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO transactions(id,amount,currency,type,source,occurred_at,
      raw_message,parse_confidence,status,created_at,updated_at,server_id,
      sync_status)
    VALUES ('transaction-1',12.34,'EGP','payment','manual','$before','',1,
      'confirmed','$before','$before','server-transaction-1','synced');
  ''');
}

Future<void> _seedLocalOnlyChild(
  AppDatabase db,
  _ChildFamily family,
) async {
  switch (family) {
    case _ChildFamily.goalContribution:
      await db.customStatement('''
        INSERT INTO goal_contributions(
          id,goal_id,amount,amount_minor,created_at,sync_status
        ) VALUES ('local-gc-1','goal-1',1,100,
          '2026-08-23T09:00:00.000Z','local_only');
      ''');
    case _ChildFamily.billPayment:
      await db.customStatement('''
        INSERT INTO bill_payments(
          id,bill_id,amount,amount_minor,currency,period_start,period_end,paid_at,
          transaction_id,sync_status
        ) VALUES ('local-bp-1','subscription-1',1,100,'EGP','2026-08-01',
          '2026-08-31','2026-08-23','transaction-1','local_only');
      ''');
    case _ChildFamily.planLink:
      await db.customStatement('''
        INSERT INTO plan_transaction_links(
          plan_id,transaction_id,created_at,sync_status
        ) VALUES ('plan-1','transaction-1','2026-08-23T09:00:00.000Z',
          'local_only');
      ''');
  }
}

Future<({String? status, String? syncedAt})> _childSyncState(
  AppDatabase db,
  _ChildFamily family,
) async {
  final where = switch (family) {
    _ChildFamily.goalContribution => "id = 'local-gc-1'",
    _ChildFamily.billPayment => "id = 'local-bp-1'",
    _ChildFamily.planLink =>
      "plan_id = 'plan-1' AND transaction_id = 'transaction-1'",
  };
  final row = await db
      .customSelect(
        'SELECT sync_status, synced_at FROM ${family.localTable} WHERE $where;',
      )
      .getSingle();
  return (
    status: row.readNullable<String>('sync_status'),
    syncedAt: row.readNullable<String>('synced_at'),
  );
}

PlanningChildSyncService _service(
  AppDatabase db,
  _CountingChildRemote remote,
  _ChildFamily family,
  ExactTransportCapability pullCapability,
) =>
    PlanningChildSyncService(
      db: db,
      queue: PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
      ),
      isEnabled: (entityType) => entityType == family.entityType,
      isPullEnabled: (entityType) => entityType == family.entityType,
      getAuthUserId: () async => 'user-1',
      remote: remote,
      // A verified PUSH must not substitute for the independent PULL proof.
      pushCapability: () => ExactTransportCapability.verifiedExact,
      pullCapability: () => pullCapability,
    
      // C-3: covers pull MECHANICS; consent is asserted in
      // financial_pull_consent_test.dart.
      mayEgress: () async => true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const initialCursor = SyncCursor(
    updatedAt: '2026-08-23T00:00:00.000Z',
    id: 'before',
  );

  for (final family in _ChildFamily.values) {
    for (final blockedCapability in const [
      ExactTransportCapability.unknown,
      ExactTransportCapability.unsupported,
    ]) {
      test(
          '${family.name}: $blockedCapability pull issues no query, keeps the '
          'cursor, and leaves the child unproven', () async {
        final db = await _openDb();
        addTearDown(db.close);
        await _seedParents(db);
        await _seedLocalOnlyChild(db, family);
        await writeSyncCursor(db, family.cursorKey, initialCursor);
        final remote = _CountingChildRemote(family);

        await _service(db, remote, family, blockedCapability).sync();

        final cursor = await readSyncCursor(db, family.cursorKey);
        expect(cursor.updatedAt, initialCursor.updatedAt);
        expect(cursor.id, initialCursor.id,
            reason: 'blocked pull must not advance its child cursor');
        expect(remote.totalFetchCalls, 0,
            reason: 'blocked pull must not query any child money transport');
        final state = await _childSyncState(db, family);
        expect(state.status, 'local_only');
        expect(state.syncedAt, isNull,
            reason: 'blocked pull must not mark a child row synced');
      });
    }

    test(
        '${family.name}: verifiedExact pull queries, advances the cursor, and '
        'marks the child synced', () async {
      final db = await _openDb();
      addTearDown(db.close);
      await _seedParents(db);
      await _seedLocalOnlyChild(db, family);
      await writeSyncCursor(db, family.cursorKey, initialCursor);
      final remote = _CountingChildRemote(family);

      await _service(
        db,
        remote,
        family,
        ExactTransportCapability.verifiedExact,
      ).sync();

      expect(remote.fetchCalls[family.remoteTable], 1);
      final cursor = await readSyncCursor(db, family.cursorKey);
      expect(cursor.updatedAt, '2026-08-24T10:00:00.000Z');
      expect(cursor.id, family.remoteRow['id']);
      final state = await _childSyncState(db, family);
      expect(state.status, 'synced');
      expect(state.syncedAt, isNotNull);
    });
  }
}
