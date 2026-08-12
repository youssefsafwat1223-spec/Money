import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/planning_sync/services/planning_primary_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Batch-3 Precondition B: PlanningPrimaryBackfillService issues remote INSERTs on
// production-reachable paths (reconcile + restore). It must carry the SAME local-
// data ownership guard as AccountsBackfillService/TransactionsBackfillService so a
// previous user's local rows can never be uploaded under a newly-authenticated uid
// — independent of any sibling service's guard or call ordering.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

SupabaseClient _refusingClient() {
  throw StateError('must not contact Supabase when the ownership guard '
      'should have refused first');
}

/// Empty every local planning table so the per-row loops (the only place the
/// Supabase client is ever contacted) never execute in the "proceeds" cases.
Future<void> _clearPlanningTables(AppDatabase db) async {
  for (final table in [
    'plan_transaction_links',
    'bill_payments',
    'goal_contributions',
    'budgets',
    'goals',
    'subscriptions',
    'plans',
  ]) {
    await db.customStatement('DELETE FROM $table;');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(null);
    await AppSession.instance.wipeAndReset();
  });

  test(
      'A→B: refuses to backfill planning data when the owner marker conflicts '
      'with the authenticated uid — and never touches Supabase', () async {
    final db = await _openDb();
    addTearDown(db.close);

    final service = PlanningPrimaryBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: _refusingClient, // throws if any remote call is attempted
    );

    // The guard throws BEFORE the first phase, so zero remote calls occur —
    // proven by _refusingClient never being reached (no StateError surfaces).
    await expectLater(
      service.run(),
      throwsA(isA<ValidationRepoException>()),
    );
  });

  test('proceeds when the owner marker is null (accepted legacy migration state)',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _clearPlanningTables(db);

    final service = PlanningPrimaryBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => null,
      getClient: _refusingClient,
    );

    final report = await service.run();
    expect(report.isClean, isTrue);
    expect(report.created, isEmpty);
    expect(report.matched, isEmpty);
  });

  test('proceeds when the owner marker matches the authenticated uid', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _clearPlanningTables(db);

    final service = PlanningPrimaryBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();
    expect(report.isClean, isTrue);
    expect(report.created, isEmpty);
  });

  // MALI-026 (B8-3 §13): planning money has base/external currency authority, so
  // budgets/goals carry a per-row currency (and `_minor`) ONLY after the P3
  // repair. A migrated-but-un-repaired (P1) row has currency = NULL / `_minor` =
  // NULL. The exact backfill must DEFER such a row — never push unknown-currency
  // money, never fail-close on the NULL minor mid-loop (which would abort the
  // whole phase, blocking repaired siblings). It must skip it before any remote
  // call.
  test(
      'defers an un-repaired (P1) budget whose currency is still NULL — no '
      'remote push, no phase abort', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _clearPlanningTables(db);

    final categoryId = (await db
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    await db.customStatement(
      'INSERT INTO budgets(id, category_id, amount, period, start_date, '
      'is_active, currency, amount_minor) '
      "VALUES('b-unrepaired', ?, 100.0, 'monthly', '2026-01-01T00:00:00Z', 1, "
      'NULL, NULL);',
      [categoryId],
    );

    final service = PlanningPrimaryBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => null,
      getClient: _refusingClient, // deferral must happen before any remote call
    );

    final report = await service.run();

    // Deferred as a soft skip, nothing created. _refusingClient never threw
    // (no `budgets: StateError` entry), proving no remote INSERT was attempted.
    expect(report.created, isEmpty);
    expect(
      report.failures,
      contains('budgets:b-unrepaired:planning_currency_unrepaired'),
    );
    expect(
      report.failures.where((f) => f.contains('StateError')),
      isEmpty,
    );
  });
}
