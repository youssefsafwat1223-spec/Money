// MALI-026 (Phase-9F-2 §13) — an unresolved server row and its repair obligation
// survive a real DB close+reopen: quarantine persists, the repair item is still
// visible after reopen, and an explicit repair then converges canonically and
// clears the quarantine. File-backed Drift (same technique as the 9F durability
// test).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
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
      'target_amount_text': '12.345',
      'saved_amount_text': '0.000',
      'last_notified_saved_amount_text': '0.000',
      'auto_save_amount_text': null,
      'vault_skin': 'classic',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': null,
    };

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

Future<int> _n(AppDatabase db, String sql) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
        .read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('quarantine + repair obligation survive DB close+reopen; repair then '
      'converges', () async {
    final dir = Directory.systemTemp.createTempSync('p9f2_restart');
    final path = '${dir.path}/r.sqlite';
    try {
      // Session 1: pull NULL goal → quarantine, then close.
      final db1 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      await _pull(db1, _GoalPageRemote([_goalRow('g1', null)])).pull();
      expect(await _n(db1, "parked_child_rows WHERE server_id='g1'"), 1);
      await db1.close();

      // Session 2: reopen the SAME file — the repair item is still visible.
      final db2 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      addTearDown(db2.close);
      final repair = PlanningServerCurrencyRepairService(
        db: db2,
        pull: _pull(db2, _GoalPageRemote(const [])),
        remote: _FakeRepairRemote({'g1': _goalRow('g1', null)}),
        getAuthUserId: () async => 'user-1',
      );
      final items = await repair.items();
      expect(items.single.serverId, 'g1');

      // Explicit repair → canonical convergence → quarantine clears.
      final outcome = await repair.resolve(
          entityType: 'goal', serverId: 'g1', currency: 'KWD');
      expect(outcome, PlanningRepairOutcome.resolved);
      expect(
          (await db2.customSelect("SELECT target_amount_minor m FROM goals WHERE server_id='g1'").getSingle())
              .read<int>('m'),
          12345);
      expect(await _n(db2, "parked_child_rows WHERE server_id='g1'"), 0);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
