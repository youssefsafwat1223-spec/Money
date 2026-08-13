// MALI-026 (Phase-9F-2 §5-§11,§14) — owner repair of server NULL-currency planning
// rows: guarded first-writer-wins NULL→currency, authoritative canonical re-pull,
// quarantine clears only on success, failure keeps it, telemetry decrements. Direct
// budget AND goal coverage (no goal-equivalence). No float equality.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_server_currency_repair.dart';
import 'package:money_companion/features/planning_sync/services/planning_unresolved_currency.dart';

const _budget = PlanningOutboxQueue.budgetsEntityType;
const _goal = PlanningOutboxQueue.goalsEntityType;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// One-shot page remote for seeding the initial NULL-currency quarantine.
class _PageRemote implements PlanningRemoteSource {
  _PageRemote(this.byTable);
  final Map<String, List<Map<String, dynamic>>> byTable;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String t,
          {required SyncCursor after, int limit = 200}) async =>
      after.id.isEmpty ? (byTable[t] ?? const []) : const [];
}

/// Fake server for repair: holds mutable rows; models first-writer-wins.
class _FakeRepairRemote implements PlanningRepairRemote {
  _FakeRepairRemote(this.rows, {this.throwOnUpdate = false});
  final Map<String, Map<String, dynamic>> rows; // serverId -> row
  final bool throwOnUpdate;
  int updates = 0;

  @override
  Future<Map<String, dynamic>?> resolveCurrencyIfNull({
    required String table,
    required String serverId,
    required String userId,
    required String currency,
  }) async {
    updates++;
    if (throwOnUpdate) throw StateError('network down');
    final row = rows[serverId];
    if (row == null) return null;
    if (row['currency'] != null) return null; // already resolved → 0 rows
    row['currency'] = currency; // our guarded update wins
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<Map<String, dynamic>?> refetchRow({
    required String table,
    required String serverId,
    required String userId,
  }) async {
    final row = rows[serverId];
    return row == null ? null : Map<String, dynamic>.from(row);
  }
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

Map<String, dynamic> _budgetRow(String id, String? currency) => {
      'id': id,
      'category_id': 'other',
      'amount_text': '200.00',
      'currency': currency,
      'last_notified_spent_amount_text': '0.00',
      'period': 'monthly',
      'start_date': '2026-01-01',
      'is_active': true,
      'last_notified_period_start': '2026-01-01T00:00:00Z',
      'show_on_header': false,
      'local_account_id': null,
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': null,
    };

Future<AppDatabase> _openDb() async {
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  await db.customStatement(
      "INSERT OR IGNORE INTO categories(id,key,name_ar,icon,color,is_income,sort_order) "
      "VALUES ('cat-other','other','أخرى','x','#000000',0,999);");
  return db;
}

PlanningPullService _pull(AppDatabase db, PlanningRemoteSource remote) =>
    PlanningPullService(
      db: db,
      isEnabled: (e) => e == _budget || e == _goal,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    );

PlanningServerCurrencyRepairService _repair(
        AppDatabase db, PlanningPullService pull, PlanningRepairRemote remote) =>
    PlanningServerCurrencyRepairService(
      db: db,
      pull: pull,
      remote: remote,
      getAuthUserId: () async => 'user-1',
    );

Future<int> _n(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingle()).read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GOAL repair (KWD): quarantine → guarded resolve → exact apply → clear',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final server = {'g1': _goalRow('g1', null)};
    await _pull(db, _PageRemote({'user_goals': [_goalRow('g1', null)]})).pull();
    final repair = _repair(db, _pull(db, _PageRemote({})), _FakeRepairRemote(server));

    // repair item is visible with display context (no currency guess)
    final items = await repair.items();
    expect(items.single.entityType, 'goal');
    expect(items.single.title, 'goal-g1');
    expect(items.single.amountText, '12.345');

    final outcome =
        await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'KWD');
    expect(outcome, PlanningRepairOutcome.resolved);
    // exact KWD (3dp) 12.345 → 12345 minor; quarantine cleared; telemetry 0.
    expect(
        (await db.customSelect("SELECT target_amount_minor m FROM goals WHERE server_id='g1'").getSingle())
            .read<int>('m'),
        12345);
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g1'"), 0);
    expect((await repair.unresolvedCounts()).goals, 0);
  });

  test('BUDGET repair (SAR): direct coverage — quarantine → resolve → apply → clear',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final server = {'b1': _budgetRow('b1', null)};
    await _pull(db, _PageRemote({'user_budgets': [_budgetRow('b1', null)]})).pull();
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE table_name='user_budgets'"), 1);

    final repair = _repair(db, _pull(db, _PageRemote({})), _FakeRepairRemote(server));
    final outcome =
        await repair.resolve(entityType: 'budget', serverId: 'b1', currency: 'SAR');
    expect(outcome, PlanningRepairOutcome.resolved);
    expect(
        (await db.customSelect("SELECT amount_minor m FROM budgets WHERE server_id='b1'").getSingle())
            .read<int>('m'),
        20000); // 200.00 SAR
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='b1'"), 0);
  });

  test('first-writer-wins: another device already set KWD — our SAR does NOT '
      'overwrite; canonical apply uses KWD', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _pull(db, _PageRemote({'user_goals': [_goalRow('g1', null)]})).pull();
    // server row already resolved to KWD by another device
    final server = {'g1': _goalRow('g1', 'KWD')};
    final remote = _FakeRepairRemote(server);
    final repair = _repair(db, _pull(db, _PageRemote({})), remote);

    final outcome =
        await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'SAR');
    expect(outcome, PlanningRepairOutcome.resolved);
    // applied with the PERSISTED KWD, not our attempted SAR
    expect(
        (await db.customSelect("SELECT currency c FROM goals WHERE server_id='g1'").getSingle())
            .read<String>('c'),
        'KWD');
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g1'"), 0);
  });

  test('failure keeps quarantine (fail-closed, safe retry)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _pull(db, _PageRemote({'user_goals': [_goalRow('g1', null)]})).pull();
    final repair = _repair(db, _pull(db, _PageRemote({})),
        _FakeRepairRemote({'g1': _goalRow('g1', null)}, throwOnUpdate: true));

    final outcome =
        await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'KWD');
    expect(outcome, PlanningRepairOutcome.failedKeepUnresolved);
    // quarantine retained; nothing applied
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g1'"), 1);
    expect(await _n(db, "SELECT COUNT(*) n FROM goals WHERE server_id='g1'"), 0);
  });

  test('unsupported currency is rejected with no server write', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _pull(db, _PageRemote({'user_goals': [_goalRow('g1', null)]})).pull();
    final remote = _FakeRepairRemote({'g1': _goalRow('g1', null)});
    final repair = _repair(db, _pull(db, _PageRemote({})), remote);

    final outcome =
        await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'ZZZ');
    expect(outcome, PlanningRepairOutcome.unsupportedCurrency);
    expect(remote.updates, 0); // no server write attempted
    expect(await _n(db, "SELECT COUNT(*) n FROM parked_child_rows WHERE server_id='g1'"), 1);
  });

  test('telemetry decrements correctly across repairs (2 → 1 → 0)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _pull(
        db,
        _PageRemote({
          'user_budgets': [_budgetRow('b1', null)],
          'user_goals': [_goalRow('g1', null)],
        })).pull();
    final server = {'b1': _budgetRow('b1', null), 'g1': _goalRow('g1', null)};
    final repair = _repair(db, _pull(db, _PageRemote({})), _FakeRepairRemote(server));

    expect((await repair.unresolvedCounts()).total, 2);
    await repair.resolve(entityType: 'budget', serverId: 'b1', currency: 'SAR');
    var c = await repair.unresolvedCounts();
    expect(c.budgets, 0);
    expect(c.goals, 1);
    expect(c.total, 1);
    await repair.resolve(entityType: 'goal', serverId: 'g1', currency: 'KWD');
    expect((await repair.unresolvedCounts()).total, 0);
  });
}
