import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/entities/category_spend.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/repositories/budget_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/budget_progress_usecase.dart';

class _FakeBudgetRepository implements BudgetRepository {
  _FakeBudgetRepository(this.budgets, {this.releaseGetAll});

  final List<BudgetEntity> budgets;
  final Completer<void>? releaseGetAll;
  var getAllCalls = 0;

  @override
  Future<int> countActive() async => budgets.where((it) => it.isActive).length;

  @override
  Future<void> delete(String id) async {
    budgets.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<BudgetEntity>> getAll() async {
    getAllCalls += 1;
    final release = releaseGetAll;
    if (release != null && !release.isCompleted) {
      await release.future;
    }
    return budgets;
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    for (final budget in budgets) {
      if (budget.id == id) {
        return budget;
      }
    }
    return null;
  }

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    final index = budgets.indexWhere((item) => item.id == budget.id);
    if (index == -1) {
      budgets.add(budget);
    } else {
      budgets[index] = budget;
    }
    return budget;
  }
}

class _FakeTransactionRepository implements TransactionRepository {
  _FakeTransactionRepository({
    required this.currentSpend,
    required this.previousSpend,
  });

  final double currentSpend;
  final double previousSpend;

  @override
  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    if (from.day == 12) {
      return previousSpend;
    }
    return currentSpend;
  }

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> confirm(String id) {
    throw UnimplementedError();
  }

  @override
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    if (from.day == 12) {
      return previousSpend;
    }
    return currentSpend;
  }

  @override
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<double?> latestBalanceAfter({String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateAmount({
    required String transactionId,
    required double amount,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required double amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getAll() {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getPage(
      {required int offset, int limit = 500}) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> getById(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getRecent(
      {int limit = 5, String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteTransaction(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<CardSummary>> getCardSummaries() {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getByCard(String last4) {
    throw UnimplementedError();
  }
}

void main() {

  test('uses injected batch spent summary for current budget periods',
      () async {
    final repo = _FakeBudgetRepository([
      BudgetEntity(
        id: 'budget-1',
        categoryId: 'restaurants',
        amount: 100,
        period: BudgetPeriod.monthly,
        startDate: DateTime(2026, 7),
        isActive: true,
        lastNotifiedSpentAmount: 0.0,
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      ),
    ]);
    var calls = 0;
    final useCase = BudgetProgressUseCase(
      budgetRepository: repo,
      transactionRepository: _FakeTransactionRepository(
        currentSpend: 999,
        previousSpend: 0,
      ),
      fetchBatchSpent: ({required from, required to}) async {
        calls++;
        return {'budget-1': 25};
      },
    );

    final snapshot = await useCase(now: DateTime(2026, 7, 14, 12));

    expect(calls, 1);
    expect(snapshot.entries.single.spent, 25);
    expect(snapshot.entries.single.ratio, 0.25);
  });

  test('BudgetProgress يحسب الميزانية العامة من كل المصروفات', () async {
    final repo = _FakeBudgetRepository([
      BudgetEntity(
        id: 'budget-all',
        categoryId: BudgetEntity.allExpensesCategoryId,
        amount: 300,
        period: BudgetPeriod.daily,
        startDate: DateTime.utc(2026, 6, 14, 0),
        isActive: true,
        lastNotifiedSpentAmount: 0.0,
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      ),
    ]);
    final useCase = BudgetProgressUseCase(
      budgetRepository: repo,
      transactionRepository: _FakeTransactionRepository(
        currentSpend: 150,
        previousSpend: 20,
      ),
    );

    final snapshot = await useCase.call(now: DateTime.utc(2026, 6, 14, 10));

    expect(snapshot.entries.single.spent, 150);
    expect(snapshot.entries.single.ratio, 0.5);
    expect(snapshot.entries.single.budget.isAllExpenses, isTrue);
  });

