import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/supabase_bill_repository.dart';
import 'package:money_companion/data/repositories/supabase_budget_repository.dart';
import 'package:money_companion/data/repositories/supabase_goal_repository.dart';
import 'package:money_companion/data/repositories/supabase_plan_repository.dart';
import 'package:money_companion/data/repositories/supabase_smart_inbox_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/features/planning_sync/services/planning_primary_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _db() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

SupabaseClient _client(MockClient http) => SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: http,
      accessToken: () async => 'qa-token',
    );

Response _json(Object value, BaseRequest request, {int status = 200}) =>
    Response(
      jsonEncode(value),
      status,
      headers: const {
        'content-type': 'application/json',
        'content-range': '0-0/*',
      },
      request: request,
    );

Map<String, dynamic> _budgetRow() => {
      'id': '10000000-0000-4000-8000-000000000001',
      'user_id': 'qa-user',
      'local_id': '20000000-0000-4000-8000-000000000001',
      'server_account_id': null,
      'category_id': 'all_expenses',
      'amount': 500,
      'period': 'monthly',
      'start_date': '2026-07-01T00:00:00.000Z',
      'is_active': true,
      'alert_80_sent': false,
      'alert_100_sent': false,
      'show_on_header': true,
      'created_at': '2026-07-01T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };

Map<String, dynamic> _goalRow() => {
      'id': '30000000-0000-4000-8000-000000000001',
      'user_id': 'qa-user',
      'local_id': '40000000-0000-4000-8000-000000000001',
      'server_account_id': null,
      'name': 'Emergency',
      'target_amount': 1000,
      'saved_amount': 50,
      'deadline': null,
      'vault_skin': 'gold',
      'status': 'active',
      'auto_save_amount': null,
      'auto_save_period': null,
      'auto_save_last_run': null,
      'created_at': '2026-07-01T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };

Map<String, dynamic> _billRow() => {
      'id': '50000000-0000-4000-8000-000000000001',
      'user_id': 'qa-user',
      'local_id': '60000000-0000-4000-8000-000000000001',
      'server_account_id': null,
      'merchant_id': null,
      'name': 'Internet',
      'amount': 300,
      'currency': 'EGP',
      'type': 'installment',
      'frequency': 'monthly',
      'next_due_date': '2026-08-01T00:00:00.000Z',
      'reminder_on': true,
      'is_confirmed': true,
      'custom_interval_days': null,
      'note': null,
      'status': 'active',
      'total_installments': 12,
      'paid_count': 1,
      'manual_paid_amount': null,
      'total_purchase_amount': 3600,
      'lender_name': null,
      'interest_rate': null,
      'created_at': '2026-07-01T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('budget create is server-first and mirrors after success', () async {
    final db = await _db();
    addTearDown(db.close);
    var calls = 0;
    final http = MockClient((request) async {
      calls++;
      if (request.method == 'GET') return _json(<Object>[], request);
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/user_budgets');
      return _json(_budgetRow(), request);
    });
    final repo = SupabaseBudgetRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );

    final saved = await repo.save(BudgetEntity(
      id: 'local-budget-id',
      categoryId: BudgetEntity.allExpensesCategoryId,
      amount: 500,
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7),
      isActive: true,
      alert80Sent: false,
      alert100Sent: false,
      showOnHeader: true,
    ));

    expect(calls, 2);
    expect(saved.id, '10000000-0000-4000-8000-000000000001');
    final cache = await db
        .customSelect(
          'SELECT server_id, amount FROM budgets;',
        )
        .get();
    expect(cache, hasLength(1));
    expect(cache.single.read<String>('server_id'), saved.id);
    expect(cache.single.read<double>('amount'), 500);
  });

  test('goal create never sends a short local id to the UUID id filter',
      () async {
    final db = await _db();
    addTearDown(db.close);
    final http = MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.queryParameters['local_id'], 'eq.local-goal-id');
        expect(request.url.queryParameters, isNot(contains('id')));
        return _json(<Object>[], request);
      }
      expect(request.method, 'POST');
      return _json(_goalRow(), request);
    });
    final repo = SupabaseGoalRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );

    final saved = await repo.save(GoalEntity(
      id: 'local-goal-id',
      name: 'Emergency',
      targetAmount: 1000,
      savedAmount: 0,
      vaultSkin: 'gold',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 13),
    ));

    expect(saved.id, _goalRow()['id']);
  });

  test('subscription create never sends a short local id to the UUID id filter',
      () async {
    final db = await _db();
    addTearDown(db.close);
    final http = MockClient((request) async {
      if (request.method == 'GET') {
        expect(
          request.url.queryParameters['local_id'],
          'eq.local-subscription-id',
        );
        expect(request.url.queryParameters, isNot(contains('id')));
        return _json(<Object>[], request);
      }
      expect(request.method, 'POST');
      return _json(_billRow(), request);
    });
    final repo = SupabaseBillRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );

    final saved = await repo.save(BillEntity(
      id: 'local-subscription-id',
      name: 'Internet',
      amount: 300,
      currency: 'EGP',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 8),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 7, 13),
    ));

    expect(saved.id, _billRow()['id']);
  });

  test('goal contribution RPC is idempotently mirrored without double count',
      () async {
    final db = await _db();
    addTearDown(db.close);
    final contributionRow = {
      'id': '70000000-0000-4000-8000-000000000001',
      'goal_id': _goalRow()['id'],
      'local_id': '80000000-0000-4000-8000-000000000001',
      'amount': 50,
      'note': 'save',
      'created_at': '2026-07-13T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };
    final http = MockClient((request) async {
      expect(request.url.path, '/rest/v1/rpc/add_goal_contribution');
      return _json(
        {'goal': _goalRow(), 'contribution': contributionRow},
        request,
      );
    });
    final repo = SupabaseGoalRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );
    final contribution = GoalContributionEntity(
      id: '80000000-0000-4000-8000-000000000001',
      goalId: _goalRow()['id'] as String,
      amount: 50,
      createdAt: DateTime.utc(2026, 7, 13),
      note: 'save',
    );

    await repo.addContribution(contribution);
    await repo.addContribution(contribution);

    final goal = await db
        .customSelect(
          'SELECT saved_amount FROM goals WHERE server_id IS NOT NULL;',
        )
        .getSingle();
    final count = await db
        .customSelect(
          'SELECT COUNT(*) AS total FROM goal_contributions;',
        )
        .getSingle();
    expect(goal.read<double>('saved_amount'), 50);
    expect(count.read<int>('total'), 1);
  });

  test('bill payment RPC mirrors payment and authoritative paid count',
      () async {
    final db = await _db();
    addTearDown(db.close);
    final paymentRow = {
      'id': '90000000-0000-4000-8000-000000000001',
      'subscription_id': _billRow()['id'],
      'transaction_id': null,
      'local_id': 'a0000000-0000-4000-8000-000000000001',
      'amount': 300,
      'currency': 'EGP',
      'period_start': '2026-07-01T00:00:00.000Z',
      'period_end': '2026-07-31T23:59:59.000Z',
      'paid_at': '2026-07-13T00:00:00.000Z',
      'installment_index': 1,
      'note': null,
      'created_at': '2026-07-13T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };
    final http = MockClient((request) async => _json(
          {'subscription': _billRow(), 'payment': paymentRow},
          request,
        ));
    final repo = SupabaseBillRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );

    await repo.recordPayment(BillPaymentEntity(
      id: 'a0000000-0000-4000-8000-000000000001',
      billId: _billRow()['id'] as String,
      amount: 300,
      currency: 'EGP',
      periodStart: DateTime.utc(2026, 7),
      periodEnd: DateTime.utc(2026, 7, 31, 23, 59, 59),
      paidAt: DateTime.utc(2026, 7, 13),
      installmentIndex: 1,
    ));

    final bill = await db
        .customSelect(
          'SELECT paid_count FROM subscriptions WHERE server_id IS NOT NULL;',
        )
        .getSingle();
    final payment = await db
        .customSelect(
          'SELECT server_id FROM bill_payments;',
        )
        .getSingle();
    expect(bill.read<int>('paid_count'), 1);
    expect(payment.read<String>('server_id'), paymentRow['id']);
  });

  test('plan link uses stable pair idempotency key', () async {
    final db = await _db();
    addTearDown(db.close);
    Map<String, dynamic>? body;
    const planId = 'b0000000-0000-4000-8000-000000000001';
    const transactionId = 'c0000000-0000-4000-8000-000000000001';
    final http = MockClient((request) async {
      if (request.method == 'GET') return _json(<Object>[], request);
      body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      return _json({
        'id': 'd0000000-0000-4000-8000-000000000001',
        'user_id': 'qa-user',
        'plan_id': planId,
        'transaction_id': transactionId,
        'client_request_id': '$planId:$transactionId',
        'created_at': '2026-07-13T00:00:00.000Z',
        'updated_at': '2026-07-13T00:00:00.000Z',
        'deleted_at': null,
      }, request);
    });
    final repo = SupabasePlanRepository(
      db: db,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
    );

    await repo.linkTransactionToPlan(
      planId: planId,
      transactionId: transactionId,
    );

    expect(body?['client_request_id'], '$planId:$transactionId');
  });

  test('planning relation with an unmigrated account fails before network',
      () async {
    final db = await _db();
    addTearDown(db.close);
    var requests = 0;
    final repo = SupabaseBudgetRepository(
      db: db,
      getClient: () => _client(MockClient((request) async {
        requests++;
        return _json(<Object>[], request);
      })),
      getAuthUserId: () async => 'qa-user',
    );

    await expectLater(
      repo.save(BudgetEntity(
        id: 'local-budget',
        categoryId: BudgetEntity.allExpensesCategoryId,
        accountId: 'unmigrated-local-account',
        amount: 100,
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 7),
        isActive: true,
        alert80Sent: false,
        alert100Sent: false,
        showOnHeader: false,
      )),
      throwsA(isA<Exception>()),
    );
    expect(requests, 0);
  });

  test('server account UUID is accepted on a fresh device without Drift cache',
      () async {
    final db = await _db();
    addTearDown(db.close);
    const accountId = 'f0000000-0000-4000-8000-000000000001';
    Map<String, dynamic>? inserted;
    final repo = SupabaseBudgetRepository(
      db: db,
      getClient: () => _client(MockClient((request) async {
        if (request.method == 'GET') return _json(<Object>[], request);
        inserted = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        );
        return _json(
            {..._budgetRow(), 'server_account_id': accountId}, request);
      })),
      getAuthUserId: () async => 'qa-user',
    );

    await repo.save(BudgetEntity(
      id: 'fresh-device-budget',
      categoryId: BudgetEntity.allExpensesCategoryId,
      accountId: accountId,
      amount: 100,
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7),
      isActive: true,
      alert80Sent: false,
      alert100Sent: false,
      showOnHeader: false,
    ));

    expect(inserted?['server_account_id'], accountId);
  });

  test('smart inbox direct read skips unknown types and mirrors known rows',
      () async {
    final db = await _db();
    addTearDown(db.close);
    final known = {
      'id': 'e0000000-0000-4000-8000-000000000001',
      'user_id': 'qa-user',
      'transaction_id': null,
      'payload_id': 'payload-review',
      'type': 'needs_review',
      'title': 'Review',
      'body': 'Check transaction',
      'status': 'open',
      'confidence': 0.5,
      'metadata': <String, dynamic>{},
      'created_at': '2026-07-13T00:00:00.000Z',
      'updated_at': '2026-07-13T00:00:00.000Z',
      'deleted_at': null,
    };
    final unknown = {...known, 'id': 'unknown-id', 'type': 'future_type'};
    final repo = SupabaseSmartInboxRepository(
      db: db,
      getClient: () => _client(
        MockClient((request) async => _json([known, unknown], request)),
      ),
      getAuthUserId: () async => 'qa-user',
    );

    final items = await repo.getOpen();

    expect(items, hasLength(1));
    expect(items.single.id, known['id']);
    expect(await db.count('smart_inbox_items'), 1);
  });

  test('planning backfill reports unresolved account and does not guess FK',
      () async {
    final db = await _db();
    addTearDown(db.close);
    const accountId = 'local-account-without-server-id';
    await db.customStatement('''
      INSERT INTO accounts(
        id, name, currency, type, is_default, sort_order, created_at, updated_at
      ) VALUES (?, 'Local', 'EGP', 'bank', 1, 0, ?, ?);
    ''', [accountId, '2026-07-01T00:00:00.000Z', '2026-07-01T00:00:00.000Z']);
    await db.customStatement('''
      INSERT INTO budgets(
        id, category_id, amount, period, start_date, is_active,
        alert_80_sent, alert_100_sent, show_on_header, account_id
      ) VALUES ('local-budget-backfill', ?, 100, 'monthly', ?, 1, 0, 0, 0, ?);
    ''', [
      BudgetEntity.allExpensesCategoryId,
      '2026-07-01T00:00:00.000Z',
      accountId,
    ]);
    var requests = 0;
    final service = PlanningPrimaryBackfillService(
      db: db,
      getClient: () => _client(MockClient((request) async {
        requests++;
        return _json(<Object>[], request);
      })),
      getAuthUserId: () async => 'qa-user',
    );

    final report = await service.run();

    expect(requests, 0);
    expect(
      report.failures,
      contains('budgets:local-budget-backfill:missing_parent'),
    );
    final budget = await db
        .customSelect('SELECT server_id FROM budgets LIMIT 1;')
        .getSingleOrNull();
    expect(budget?.readNullable<String>('server_id'), isNull);
  });
}
