// MALI-026 (Phase-9F §4/§7/§8/§9/§18) — an ACTIVE budget/goal server row whose
// persisted currency is NULL/unsupported must be NON-FATAL: quarantined row-level,
// healthy rows in the same page still apply, the cursor advances (no head-of-line
// block), quarantine dedups, survives restart, and soft-deleted rows tombstone
// (never quarantine). Uses goals (no category resolution).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

const _goal = PlanningOutboxQueue.goalsEntityType; // 'goal'

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A cursor-aware fake: returns the rows strictly after `after` (like the server),
/// so once the cursor advances past the page a re-pull returns empty.
class _PageRemote implements PlanningRemoteSource {
  _PageRemote(this.table, this.rows);
  final String table;
  final List<Map<String, dynamic>> rows;
  int fetches = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String t, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    if (t != table) return const [];
    fetches++;
    return rows.where((r) => _gt(r, after)).take(limit).toList();
  }

  bool _gt(Map<String, dynamic> r, SyncCursor after) {
    if (after.id.isEmpty) return true;
    final u = r['updated_at'] as String;
    if (u != after.updatedAt) return u.compareTo(after.updatedAt) > 0;
    return (r['id'] as String).compareTo(after.id) > 0;
  }
}

Map<String, dynamic> _goalRow(String id, String? currency,
        {bool deleted = false}) =>
    {
      'id': id,
      'local_id': null,
      'name': 'g-$id',
      'currency': currency, // null → unresolved currency
      'target_amount_text': '100.000',
      'saved_amount_text': '0.000',
      'last_notified_saved_amount_text': '0.000',
      'auto_save_amount_text': null,
      'vault_skin': 'classic',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': deleted ? '2026-08-02T00:00:00.000Z' : null,
    };

PlanningPullService _svc(AppDatabase db, PlanningRemoteSource remote) =>
    PlanningPullService(
      db: db,
      isEnabled: (e) => e == _goal, // test-scoped enable (no provider flip)
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    );

Future<int> _count(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingle()).read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('page A(ok) B(null-currency) C(ok): A+C apply, B quarantines, cursor '
      'advances, re-pull does not re-block', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    final remote = _PageRemote('user_goals', [
      _goalRow('g-A', 'KWD'),
      _goalRow('g-B', null), // unresolved currency
      _goalRow('g-C', 'KWD'),
    ]);

    final r1 = await _svc(db, remote).pull();

    // A + C applied exactly (KWD 3dp: 100.000 → 100000 minor); B not applied.
    expect(await _count(db, "SELECT COUNT(*) n FROM goals WHERE server_id='g-A'"), 1);
    expect(await _count(db, "SELECT COUNT(*) n FROM goals WHERE server_id='g-C'"), 1);
    expect(await _count(db, "SELECT COUNT(*) n FROM goals WHERE server_id='g-B'"), 0);
    final minorA = (await db
            .customSelect("SELECT target_amount_minor m FROM goals WHERE server_id='g-A'")
            .getSingle())
        .read<int>('m');
    expect(minorA, 100000);
    expect(r1.imported, 2);

    // B durably quarantined (reason unresolved_currency, table user_goals).
    expect(
        await _count(db,
            "SELECT COUNT(*) n FROM parked_child_rows WHERE table_name='user_goals' AND server_id='g-B' AND reason='unresolved_currency'"),
        1);

    // Cursor advanced past the whole page (to C = last row).
    final cursor = await readSyncCursor(db, 'planning_$_goal');
    expect(cursor.id, 'g-C');

    // Re-pull: cursor is past the page → no re-fetch of B → no throw, no dup.
    final r2 = await _svc(db, remote).pull();
    expect(r2.imported, 0);
    expect(await _count(db, "SELECT COUNT(*) n FROM goals"), 2);
    // §7 dedup: still exactly one quarantine entry for B.
    expect(
        await _count(db,
            "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g-B'"),
        1);
  });

  test('soft-deleted NULL-currency goal tombstones, never quarantines', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    final remote = _PageRemote(
        'user_goals', [_goalRow('g-del', null, deleted: true)]);

    await _svc(db, remote).pull();

    // No quarantine for a tombstone (deleted rows never require currency).
    expect(
        await _count(db,
            "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g-del'"),
        0);
  });

  test('quarantine survives DB close + reopen (file-backed durability)', () async {
    final dir = Directory.systemTemp.createTempSync('p9f_quarantine');
    final path = '${dir.path}/q.sqlite';
    try {
      final remote =
          _PageRemote('user_goals', [_goalRow('g-B', null)]);
      final db1 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      await _svc(db1, remote).pull();
      expect(
          await _count(db1,
              "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g-B'"),
          1);
      await db1.close();

      // Reopen the SAME file — quarantine persists.
      final db2 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      addTearDown(db2.close);
      expect(
          await _count(db2,
              "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g-B' AND reason='unresolved_currency'"),
          1);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
