// MALI-026 (Phase-9F §12/§16) — unresolved-currency telemetry (counts derived from
// the durable quarantine) and the convergence contract: a quarantined row clears
// ONLY after a successful canonical re-pull (i.e. after the server currency is
// resolved). No floating-point equality for canonical Money.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_unresolved_currency.dart';

const _goal = PlanningOutboxQueue.goalsEntityType;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Mutable cursor-aware fake so a row can be "repaired" (currency set) between pulls.
class _MutableRemote implements PlanningRemoteSource {
  _MutableRemote(this.table, this.rows);
  final String table;
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(String t,
      {required SyncCursor after, int limit = 200}) async {
    if (t != table) return const [];
    return rows.where((r) {
      if (after.id.isEmpty) return true;
      final u = r['updated_at'] as String;
      if (u != after.updatedAt) return u.compareTo(after.updatedAt) > 0;
      return (r['id'] as String).compareTo(after.id) > 0;
    }).take(limit).toList();
  }
}

Map<String, dynamic> _goalRow(String id, String? currency, String updatedAt) => {
      'id': id,
      'local_id': null,
      'name': 'g-$id',
      'currency': currency,
      'target_amount_text': '100.000',
      'saved_amount_text': '0.000',
      'last_notified_saved_amount_text': '0.000',
      'auto_save_amount_text': null,
      'vault_skin': 'classic',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': updatedAt,
      'deleted_at': null,
    };

PlanningPullService _svc(AppDatabase db, PlanningRemoteSource remote) =>
    PlanningPullService(
      db: db,
      isEnabled: (e) => e == _goal,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('telemetry counts split budgets vs goals from the durable quarantine',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    Future<void> quarantine(String table, String id) => db.customStatement(
          "INSERT INTO parked_child_rows(table_name, server_id, row_json, reason, "
          "attempt_count, first_seen_at, updated_at) VALUES ('$table','$id','{}',"
          "'unresolved_currency',0,'2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');",
        );
    await quarantine('user_budgets', 'b1');
    await quarantine('user_budgets', 'b2');
    await quarantine('user_goals', 'g1');
    // a missing_parent child park must NOT be counted as unresolved currency
    await db.customStatement(
        "INSERT INTO parked_child_rows(table_name, server_id, row_json, reason, "
        "attempt_count, first_seen_at, updated_at) VALUES "
        "('goal_contributions','c1','{}','missing_parent',0,'x','x');");

    final counts = await unresolvedPlanningCurrencyCounts(db);
    expect(counts.budgets, 2);
    expect(counts.goals, 1);
    expect(counts.total, 3);
    final items = await unresolvedPlanningCurrencyItems(db);
    expect(items.length, 3);
    expect(items.where((i) => i.entityType == 'budget').length, 2);
    expect(items.where((i) => i.entityType == 'goal').length, 1);
  });

  test('convergence: quarantine clears ONLY after a canonical re-pull '
      '(server currency resolved)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final row = _goalRow('g-X', null, '2026-08-01T00:00:00.000Z');
    final remote = _MutableRemote('user_goals', [row]);

    // 1) pull with NULL currency → quarantined, not applied.
    await _svc(db, remote).pull();
    expect((await unresolvedPlanningCurrencyCounts(db)).goals, 1);
    expect(
        (await db.customSelect("SELECT COUNT(*) n FROM goals").getSingle())
            .read<int>('n'),
        0);

    // 2) owner resolves the currency on the server (modelled: the server row now
    //    carries KWD and its updated_at advanced) → re-pull applies it exactly.
    row['currency'] = 'KWD';
    row['updated_at'] = '2026-08-05T00:00:00.000Z';
    await _svc(db, remote).pull();

    // Applied exactly (KWD 3dp) AND quarantine cleared (converged).
    final minor = (await db
            .customSelect("SELECT target_amount_minor m FROM goals WHERE server_id='g-X'")
            .getSingle())
        .read<int>('m');
    expect(minor, 100000);
    expect((await unresolvedPlanningCurrencyCounts(db)).goals, 0);
  });
}
