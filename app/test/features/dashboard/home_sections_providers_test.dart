import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/dashboard/home_sections_providers.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

TransactionEntity _tx({
  required String id,
  required double amount,
  required TransactionTypeEntity type,
  required DateTime occurredAt,
  String? categoryId,
  String accountId = 'acc-1',
  String? rawMerchant,
  TransactionStatus status = TransactionStatus.confirmed,
}) {
  return TransactionEntity(
    id: id,
    amount: amount,
    currency: 'EGP',
    accountId: accountId,
    categoryId: categoryId,
    rawMerchant: rawMerchant,
    type: type,
    source: TransactionSourceEntity.imported,
    occurredAt: occurredAt,
    rawMessage: 'test',
    parseConfidence: 1,
    status: status,
    createdAt: occurredAt,
    updatedAt: occurredAt,
  );
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = await _openDb();
    // Mirror BootstrapRunner's real-startup step: initialize the global
    // feature-flag singleton before building providers that may read flags.
    await initFeatureFlagService(db, installIdOverride: 'test-install');
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedDefaultAccount() async {
    final accountRepo = DriftAccountRepository(db);
    await accountRepo.create(AccountEntity(
      id: 'acc-1',
      name: 'الحساب الرئيسي',
      currency: 'EGP',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
  }

  group('todayExpensesProvider', () {
    test(
        'includes only today\'s confirmed expenses, excludes income/'
        'transfers/other days, newest first', () async {
      await seedDefaultAccount();
      final categoryRepo = DriftCategoryRepository(db);
      final food = await categoryRepo.createCategory(
        nameAr: 'الطعام',
        icon: 'utensils',
        color: '#FF0000',
        isIncome: false,
      );
      final txRepo = DriftTransactionRepository(db);

      final now = DateTime.now();
      final today9am = DateTime(now.year, now.month, now.day, 9);
      final today5pm = DateTime(now.year, now.month, now.day, 17);
      final yesterday = today9am.subtract(const Duration(days: 1));

      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'tx-today-morning',
          amount: 20,
          type: TransactionTypeEntity.payment,
          occurredAt: today9am,
          rawMerchant: 'McDonalds',
        ),
        categoryKey: food.key,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'tx-today-evening',
          amount: 45,
          type: TransactionTypeEntity.payment,
          occurredAt: today5pm,
          rawMerchant: 'KFC',
        ),
        categoryKey: food.key,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'tx-today-income',
          amount: 500,
          type: TransactionTypeEntity.income,
          occurredAt: today9am,
        ),
        categoryKey: null,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'tx-today-transfer',
          amount: 100,
          type: TransactionTypeEntity.transfer,
          occurredAt: today9am,
        ),
        categoryKey: null,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'tx-yesterday',
          amount: 30,
          type: TransactionTypeEntity.payment,
          occurredAt: yesterday,
        ),
        categoryKey: food.key,
      );

      final result = await container.read(todayExpensesProvider.future);

      expect(result.map((t) => t.id).toList(), [
        'tx-today-evening',
        'tx-today-morning',
      ]);
    });
  });

  group('monthlyExpenseGroupsProvider', () {
    test(
        'groups this month\'s confirmed expenses by category, excludes '
        'income/transfers/other months, sorted by highest total, attaches '
        'matching budget', () async {
      await seedDefaultAccount();
      final categoryRepo = DriftCategoryRepository(db);
      final food = await categoryRepo.createCategory(
        nameAr: 'الطعام',
        icon: 'utensils',
        color: '#FF0000',
        isIncome: false,
      );
      final transport = await categoryRepo.createCategory(
        nameAr: 'المواصلات',
        icon: 'car',
        color: '#00FF00',
        isIncome: false,
      );
      final txRepo = DriftTransactionRepository(db);

      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month, 10);
      final lastMonth = DateTime(now.year, now.month - 1, 10);

      // Food: 20 + 45 = 65 (higher total)
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'food-1',
          amount: 20,
          type: TransactionTypeEntity.payment,
          occurredAt: thisMonth,
        ),
        categoryKey: food.key,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'food-2',
          amount: 45,
          type: TransactionTypeEntity.payment,
          occurredAt: thisMonth,
        ),
        categoryKey: food.key,
      );
      // Transport: 30 (lower total)
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'transport-1',
          amount: 30,
          type: TransactionTypeEntity.payment,
          occurredAt: thisMonth,
        ),
        categoryKey: transport.key,
      );
      // Excluded: income, transfer, last month
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'income-this-month',
          amount: 1000,
          type: TransactionTypeEntity.income,
          occurredAt: thisMonth,
        ),
        categoryKey: null,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'transfer-this-month',
          amount: 200,
          type: TransactionTypeEntity.transfer,
          occurredAt: thisMonth,
        ),
        categoryKey: null,
      );
      await txRepo.saveTransaction(
        transaction: _tx(
          id: 'food-last-month',
          amount: 999,
          type: TransactionTypeEntity.payment,
          occurredAt: lastMonth,
        ),
        categoryKey: food.key,
      );

      final budgetRepo = DriftBudgetRepository(db);
      await budgetRepo.save(BudgetEntity(
        id: 'budget-food',
        categoryId: food.id,
        amount: 100,
        period: BudgetPeriod.monthly,
        startDate: DateTime(now.year, now.month, 1),
        isActive: true,
        lastNotifiedSpentAmount: 0,
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      ));

      final groups = await container.read(monthlyExpenseGroupsProvider.future);

      expect(groups.length, 2);
      // Highest spend first — matches the existing "topCategories" ranking
      // convention used elsewhere in the app (Reports, dashboard donut).
      expect(groups[0].categoryId, food.id);
      expect(groups[0].total, 65);
      expect(groups[1].categoryId, transport.id);
      expect(groups[1].total, 30);
      // Food has a matching monthly budget (100) — 65 spent, 35 remaining.
      expect(groups[0].budget, isNotNull);
      expect(groups[0].budget!.remaining, 35);
      // Transport has no budget.
      expect(groups[1].budget, isNull);
    });
  });

  group('homeSubscriptionsProvider', () {
    test('shows only active subscriptions, nearest due date first', () async {
      await seedDefaultAccount();
      final billRepo = DriftBillRepository(db);
      final now = DateTime.now();
      await billRepo.save(BillEntity(
        id: 'bill-far',
        name: 'Netflix',
        amountMoney: Money.fromLegacyReal(55, 'EGP'),
        currency: 'EGP',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: now.add(const Duration(days: 20)),
        reminderOn: true,
        isConfirmed: true,
        createdAt: now,
      ));
      await billRepo.save(BillEntity(
        id: 'bill-near',
        name: 'Spotify',
        amountMoney: Money.fromLegacyReal(30, 'EGP'),
        currency: 'EGP',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: now.add(const Duration(days: 2)),
        reminderOn: true,
        isConfirmed: true,
        createdAt: now,
      ));
      await billRepo.save(BillEntity(
        id: 'bill-paused',
        name: 'Paused Sub',
        amountMoney: Money.fromLegacyReal(10, 'EGP'),
        currency: 'EGP',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: now.add(const Duration(days: 1)),
        reminderOn: true,
        isConfirmed: true,
        createdAt: now,
        status: BillStatus.paused,
      ));
      await billRepo.save(BillEntity(
        id: 'installment-1',
        name: 'Installment',
        amountMoney: Money.fromLegacyReal(100, 'EGP'),
        currency: 'EGP',
        type: BillType.installment,
        frequency: BillFrequency.monthly,
        nextDueDate: now.add(const Duration(days: 1)),
        reminderOn: true,
        isConfirmed: true,
        createdAt: now,
      ));

      final result = await container.read(homeSubscriptionsProvider.future);

      expect(result.map((b) => b.id).toList(), ['bill-near', 'bill-far']);
    });
  });

  group('homeGoalsProvider', () {
    test('shows only active goals, closest deadline first', () async {
      // getDefault() always resolves to *some* account (auto-provisioned if
      // none exists) — goalsListProvider filters by that account id, so the
      // fixtures need a deterministic seeded account to match against.
      await seedDefaultAccount();
      final goalRepo = DriftGoalRepository(db);
      final now = DateTime.now();
      await goalRepo.save(GoalEntity(
        id: 'goal-no-deadline-high-progress',
        name: 'بدون موعد',
        targetAmount: 100,
        savedAmount: 90,
        accountId: 'acc-1',
        vaultSkin: 'default',
        status: 'active',
        createdAt: now,
      ));
      await goalRepo.save(GoalEntity(
        id: 'goal-far-deadline',
        name: 'موعد بعيد',
        targetAmount: 100,
        savedAmount: 10,
        deadline: now.add(const Duration(days: 60)),
        accountId: 'acc-1',
        vaultSkin: 'default',
        status: 'active',
        createdAt: now,
      ));
      await goalRepo.save(GoalEntity(
        id: 'goal-near-deadline',
        name: 'موعد قريب',
        targetAmount: 100,
        savedAmount: 10,
        deadline: now.add(const Duration(days: 5)),
        accountId: 'acc-1',
        vaultSkin: 'default',
        status: 'active',
        createdAt: now,
      ));
      await goalRepo.save(GoalEntity(
        id: 'goal-archived',
        name: 'مؤرشف',
        targetAmount: 100,
        savedAmount: 50,
        accountId: 'acc-1',
        vaultSkin: 'default',
        status: 'archived',
        createdAt: now,
      ));

      final result = await container.read(homeGoalsProvider.future);

      expect(result.map((g) => g.id).toList(), [
        'goal-near-deadline',
        'goal-far-deadline',
        'goal-no-deadline-high-progress',
      ]);
    });
  });

  group('homePlansProvider', () {
    test('shows only active plans, nearest end date first', () async {
      await seedDefaultAccount();
      final planRepo = DriftPlanRepository(db);
      final now = DateTime.now();
      await planRepo.save(PlanEntity(
        id: 'plan-far',
        name: 'خطة بعيدة',
        budgetAmountMoney: Money.fromLegacyReal(1000, 'EGP'),
        currency: 'EGP',
        startDate: now,
        endDate: now.add(const Duration(days: 30)),
        accountIds: const ['acc-1'],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: now,
      ));
      await planRepo.save(PlanEntity(
        id: 'plan-near',
        name: 'خطة قريبة',
        budgetAmountMoney: Money.fromLegacyReal(500, 'EGP'),
        currency: 'EGP',
        startDate: now,
        endDate: now.add(const Duration(days: 3)),
        accountIds: const ['acc-1'],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: now,
      ));
      await planRepo.save(PlanEntity(
        id: 'plan-closed',
        name: 'خطة مغلقة',
        budgetAmountMoney: Money.fromLegacyReal(200, 'EGP'),
        currency: 'EGP',
        startDate: now,
        endDate: now.add(const Duration(days: 1)),
        accountIds: const ['acc-1'],
        cardLast4s: const [],
        status: PlanStatus.closed,
        createdAt: now,
      ));

      final result = await container.read(homePlansProvider.future);

      expect(result.map((p) => p.plan.id).toList(), ['plan-near', 'plan-far']);
    });
  });
}
