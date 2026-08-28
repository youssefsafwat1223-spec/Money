// MALI-026 (Phase-9F-2 §12/§19) — the parent-authority graph heals: a server goal
// with currency=NULL quarantines (parent) and its contribution parks (child, no
// canonical parent, no base fallback). After the owner explicitly repairs the goal
// to KWD, an authoritative canonical re-pull applies the goal, the parent quarantine
// clears, the parked contribution replays with the parent's persisted KWD, decodes
// to EXACT minorUnits, clears its park, and applies exactly once.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_server_currency_repair.dart';

const _goal = PlanningOutboxQueue.goalsEntityType;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _GoalPageRemote implements PlanningRemoteSource {
  _GoalPageRemote(this.rows);
  final List<Map<String, dynamic>> rows;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String t,
          {required SyncCursor after, int limit = 200}) async =>
      (t == 'user_goals' && after.id.isEmpty) ? rows : const [];
}

class _FakeChildRemote implements PlanningChildRemote {
  final rows = <String, List<Map<String, dynamic>>>{};
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
      {required SyncCursor after, int limit = 200}) async {
    final all = [...(rows[table] ?? const <Map<String, dynamic>>[])];
    return all.where((r) {
      if (after.id.isEmpty) return true;
      final u = r['updated_at'] as String;
      if (u != after.updatedAt) return u.compareTo(after.updatedAt) > 0;
      return (r['id'] as String).compareTo(after.id) > 0;
    }).take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>> callRpc(String n, Map<String, dynamic> p) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> findPlanLink(
          {required String userId,
          required String planId,
          required String transactionId}) async =>
      null;
  @override
  Future<void> tombstonePlanLink(String serverId) async {}
}

class _FakeRepairRemote implements PlanningRepairRemote {
  _FakeRepairRemote(this.rows);
  final Map<String, Map<String, dynamic>> rows;
  @override
  Future<Map<String, dynamic>?> resolveCurrencyIfNull(
      {required String table,
      required String serverId,
      required String userId,
      required String currency}) async {
    final row = rows[serverId];
    if (row == null || row['currency'] != null) return null;
    row['currency'] = currency;
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<Map<String, dynamic>?> refetchRow(
          {required String table,
          required String serverId,
          required String userId}) async =>
      rows[serverId] == null ? null : Map<String, dynamic>.from(rows[serverId]!);
}

Map<String, dynamic> _goalRow(String id, String? currency) => {
      'id': id,
      'name': 'goal-$id',
      'currency': currency,
      'target_amount_text': '1000.000',
      'saved_amount_text': '0.000',
      'last_notified_saved_amount_text': '0.000',
      'auto_save_amount_text': null,
      'vault_skin': 'classic',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': null,
    };

Map<String, dynamic> _contribRow(String id, String goalServerId) => {
      'id': id,
      'local_id': id,
      'goal_id': goalServerId,
      'amount': 12.345,
      'amount_text': '12.345', // exact KWD 3dp
      'created_at': '2026-08-01T00:00:00.000Z',
      'note': null,
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': null,
    };

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningPullService _pull(AppDatabase db, PlanningRemoteSource r) =>
    PlanningPullService(
        db: db,
        isEnabled: (e) => e == _goal,
        getAuthUserId: () async => 'user-1',
        remoteSource: r,
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

PlanningChildSyncService _child(AppDatabase db, _FakeChildRemote r) =>
    PlanningChildSyncService(
      db: db,
      queue: PlanningOutboxQueue(
          db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => 'user-1'),
      isEnabled: (_) => true,
      isPullEnabled: (entityType) =>
          entityType == PlanningOutboxQueue.goalContributionsEntityType,
      getAuthUserId: () async => 'user-1',
      remote: r,
      pullCapability: () => ExactTransportCapability.verifiedExact,
    
      // C-3: covers pull MECHANICS; consent is asserted in
      // financial_pull_consent_test.dart.
      mayEgress: () async => true,
    );

Future<int> _n(AppDatabase db, String sql) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
        .read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('goal NULL → parent quarantines + contribution parks → repair to KWD → '
      'goal applies, park drains, contribution EXACT KWD, once', () async {
    final db = await _openDb();
    addTearDown(db.close);

    // 1) parent goal has NULL currency → quarantined, not applied locally.
    await _pull(db, _GoalPageRemote([_goalRow('g1', null)])).pull();
    expect(await _n(db, "goals WHERE server_id='g1'"), 0);
    expect(await _n(db,
        "parked_child_rows WHERE table_name='user_goals' AND server_id='g1' AND reason='unresolved_currency'"), 1);

    // 2) contribution for g1 → child parks (no canonical parent; NO base fallback).
    final childRemote = _FakeChildRemote();
    childRemote.rows['user_goal_contributions'] = [_contribRow('gc1', 'g1')];
    await _child(db, childRemote).sync();
    expect(await _n(db, "goal_contributions WHERE server_id='gc1'"), 0);
    expect(await _n(db,
        "parked_child_rows WHERE table_name='goal_contributions' AND server_id='gc1'"), 1);

    // 3) owner explicitly repairs the parent goal → KWD (guarded, canonical re-pull).
    final server = {'g1': _goalRow('g1', null)};
    final repair = PlanningServerCurrencyRepairService(
      db: db,
      pull: _pull(db, _GoalPageRemote(const [])),
      remote: _FakeRepairRemote(server),
      getAuthUserId: () async => 'user-1',
    );
    final outcome =
        await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'KWD');
    expect(outcome, PlanningRepairOutcome.resolved);
    // goal applied locally with KWD; parent quarantine cleared.
    expect(
        (await db.customSelect("SELECT currency c FROM goals WHERE server_id='g1'").getSingle())
            .read<String>('c'),
        'KWD');
    expect(await _n(db,
        "parked_child_rows WHERE table_name='user_goals' AND server_id='g1'"), 0);

    // 4) child re-sync → parked contribution replays with the parent's KWD.
    await _child(db, childRemote).sync();
    // goal_contributions has NO currency column — the parent goal is the sole
    // authority; the exact minorUnits reflect the parent's KWD (3dp) scale.
    final gc = await db
        .customSelect("SELECT amount_minor m FROM goal_contributions WHERE server_id='gc1'")
        .getSingle();
    expect(gc.read<int>('m'), 12345); // exact KWD 3dp, from parent authority
    expect(await _n(db,
        "parked_child_rows WHERE table_name='goal_contributions' AND server_id='gc1'"), 0);

    // 5) exactly once under replay.
    await _child(db, childRemote).sync();
    expect(await _n(db, "goal_contributions WHERE server_id='gc1'"), 1);
  });
}
