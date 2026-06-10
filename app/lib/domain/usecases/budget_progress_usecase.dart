import '../../core/utils/riyadh_time.dart';
import '../entities/budget_entity.dart';
import '../entities/engagement_entities.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';

class BudgetProgressUseCase {
  BudgetProgressUseCase({
    required BudgetRepository budgetRepository,
    required TransactionRepository transactionRepository,
    RecordEngagementUseCase? recordEngagementUseCase,
  })  : _budgetRepository = budgetRepository,
        _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase;

  final BudgetRepository _budgetRepository;
  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;

  Future<BudgetProgressSnapshot> call({DateTime? now}) async {
    final current = now ?? DateTime.now().toUtc();
    final budgets = (await _budgetRepository.getAll())
        .where((budget) => budget.isActive)
        .toList();
    final entries = <BudgetProgressEntry>[];
    final alerts = <BudgetAlertTrigger>[];

    for (final budget in budgets) {
      final normalizedBudget = await _rollBudgetIfNeeded(budget, current);
      final period = _currentPeriodFor(normalizedBudget.period, current);
      final spent = await _spentForBudget(normalizedBudget, period);
      final ratio = normalizedBudget.amount == 0
          ? 0.0
          : spent / normalizedBudget.amount;
      final remaining = normalizedBudget.amount - spent;
      final health = ratio >= 1
          ? BudgetHealth.over
          : ratio >= 0.8
              ? BudgetHealth.warning
              : BudgetHealth.safe;
      final entry = BudgetProgressEntry(
        budget: normalizedBudget,
        spent: spent,
        remaining: remaining,
        ratio: ratio,
        health: health,
        periodStart: period.$1,
        periodEnd: period.$2,
      );
      entries.add(entry);

      if (ratio >= 1 && !normalizedBudget.alert100Sent) {
        final updated = normalizedBudget.copyWith(alert100Sent: true);
        await _budgetRepository.save(updated);
        alerts.add(
          BudgetAlertTrigger(
            budget: updated,
            progress: entry,
            kind: BudgetAlertKind.over100,
          ),
        );
      } else if (ratio >= 0.8 &&
          ratio < 1 &&
          !normalizedBudget.alert80Sent) {
        final updated = normalizedBudget.copyWith(alert80Sent: true);
        await _budgetRepository.save(updated);
        alerts.add(
          BudgetAlertTrigger(
            budget: updated,
            progress: entry,
            kind: BudgetAlertKind.warning80,
          ),
        );
      }
    }

    entries.sort((a, b) => b.ratio.compareTo(a.ratio));
    return BudgetProgressSnapshot(entries: entries, alerts: alerts);
  }

  Future<BudgetEntity> _rollBudgetIfNeeded(
    BudgetEntity budget,
    DateTime now,
  ) async {
    final expectedStart = _currentPeriodFor(budget.period, now).$1;
    if (budget.startDate == expectedStart) {
      return budget;
    }

    final previousPeriod = _periodForStart(budget.period, budget.startDate);
    final previousSpent = await _spentForBudget(budget, previousPeriod);

    if (budget.period == BudgetPeriod.daily &&
        previousSpent <= budget.amount &&
        _recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: EngagementAction.dailyBudgetKept,
        occurredAt: previousPeriod.$2.subtract(const Duration(seconds: 1)),
      );
    }

    final updated = budget.copyWith(
      startDate: expectedStart,
      alert80Sent: false,
      alert100Sent: false,
    );
    return _budgetRepository.save(updated);
  }

  (DateTime, DateTime) _currentPeriodFor(BudgetPeriod period, DateTime now) {
    switch (period) {
      case BudgetPeriod.daily:
        return (RiyadhTime.startOfDay(now), RiyadhTime.endOfDay(now));
      case BudgetPeriod.weekly:
        return (RiyadhTime.startOfWeek(now), RiyadhTime.endOfWeek(now));
      case BudgetPeriod.monthly:
        return (RiyadhTime.startOfMonth(now), RiyadhTime.endOfMonth(now));
    }
  }

  (DateTime, DateTime) _periodForStart(BudgetPeriod period, DateTime start) {
    switch (period) {
      case BudgetPeriod.daily:
        return (start, start.add(const Duration(days: 1)));
      case BudgetPeriod.weekly:
        return (start, start.add(const Duration(days: 7)));
      case BudgetPeriod.monthly:
        final riyadh = RiyadhTime.toRiyadh(start);
        final end = DateTime.utc(riyadh.year, riyadh.month + 1)
            .subtract(RiyadhTime.offset);
        return (start, end);
    }
  }

  Future<double> _spentForBudget(
    BudgetEntity budget,
    (DateTime, DateTime) period,
  ) {
    if (budget.isAllExpenses) {
      return _transactionRepository.expenseTotalBetween(
        from: period.$1,
        to: period.$2,
      );
    }
    return _transactionRepository.categoryExpenseTotalBetween(
      categoryId: budget.categoryId,
      from: period.$1,
      to: period.$2,
    );
  }
}
