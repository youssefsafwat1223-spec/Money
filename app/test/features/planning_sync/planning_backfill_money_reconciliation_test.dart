import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/features/planning_sync/services/planning_primary_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

SupabaseClient _existingBudgetClient(
  Map<String, dynamic> row,
  List<String> selected,
) {
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    accessToken: () async => 'token',
    httpClient: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, contains('user_budgets'));
      selected.add(request.url.queryParameters['select'] ?? '');
      return Response(
        jsonEncode(row),
        200,
        headers: const {'content-type': 'application/json'},
        request: request,
      );
    }),
  );
}

Future<void> _seedBudget(AppDatabase db) async {
  const now = '2026-08-24T10:00:00.000Z';
  final categoryId = (await db
          .customSelect(
              "SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
          .getSingle())
      .read<String>('id');
  await db.customStatement('''
    INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
      is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
      last_notified_period_start,show_on_header)
    VALUES('budget-h2','$categoryId','SAR',12.34,1234,'monthly','$now',1,
      1.0,100,'$now',0);
  ''');
}

Map<String, dynamic> _matchingRemoteBudget({Object? currency = 'SAR'}) => {
      'id': 'server-budget-h2',
      'currency': currency,
      'amount_text': '12.34',
      'last_notified_spent_amount_text': '1.00',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
      ({
        PlanningBackfillReport report,
        Map<String, Object?> local,
        List<String> selected
      })> run(Map<String, dynamic> remote) async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedBudget(db);
    final selected = <String>[];
    final report = await PlanningPrimaryBackfillService(
      db: db,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: () => _existingBudgetClient(remote, selected),
      coordinator: const FixedPlanningCutoverCoordinator(
        PlanningCutoverState.canonical,
      ),
    ).run(onlyEntities: const {'budgets'});
    final local = (await db
            .customSelect(
              "SELECT server_id,synced_at,sync_status FROM budgets WHERE id='budget-h2';",
            )
            .getSingle())
        .data;
    return (report: report, local: local, selected: selected);
  }

  test('required planning currency remote-null is unproven, never synced',
      () async {
    final result = await run(_matchingRemoteBudget(currency: null));

    expect(result.report.mismatched, ['budgets:budget-h2']);
    expect(result.report.isClean, isFalse);
    expect(result.local['sync_status'], 'conflict');
    expect(result.local['synced_at'], isNull);
    expect(result.selected.single, contains('amount_text:amount::text'));
    expect(
        result.selected.single,
        contains(
            'last_notified_spent_amount_text:last_notified_spent_amount::text'));
  });

  test('all exact planning money and currency matching stamps synced',
      () async {
    final result = await run(_matchingRemoteBudget());

    expect(result.report.mismatched, isEmpty);
    expect(result.report.isClean, isTrue);
    expect(result.local['sync_status'], 'synced');
    expect(result.local['synced_at'], isNotNull);
  });
}
