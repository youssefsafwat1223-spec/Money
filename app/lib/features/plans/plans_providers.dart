import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';

/// A plan paired with its current spending so the UI can show live progress.
class PlanProgress {
  const PlanProgress(this.plan, this.spent);

  final PlanEntity plan;
  final Money spent;

  Money get remaining => plan.budgetAmountMoney - spent;
  double get ratio => plan.budgetAmountMoney.isZero
      ? 0
      : (spent.toDouble() / plan.budgetAmountMoney.toDouble())
          .clamp(0, 1)
          .toDouble();
  bool get isOver => spent.compareTo(plan.budgetAmountMoney) > 0;

  /// Suggested daily allowance for the rest of the plan.
  Money get perDayLeft {
    final days = plan.daysLeft;
    final left = remaining;
    final zero = Money.zero(plan.currency);
    if (days <= 0 || left.compareTo(zero) <= 0) return zero;
    return left.applyRate(
      rateNumerator: BigInt.one,
      rateDenominator: BigInt.from(days),
    );
  }
}

final plansWithSpentProvider = FutureProvider<List<PlanProgress>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  final repo = ref.watch(planRepositoryProvider);
  final plans = await repo.getAll();
  final result = <PlanProgress>[];
  for (final plan in plans) {
    result.add(PlanProgress(plan, await repo.spentForPlan(plan)));
  }
  return result;
});

final planProgressProvider =
    FutureProvider.family<PlanProgress?, String>((ref, id) async {
  ref.watch(dbRevisionProvider);
  final repo = ref.watch(planRepositoryProvider);
  final plan = await repo.getById(id);
  if (plan == null) return null;
  return PlanProgress(plan, await repo.spentForPlan(plan));
});

final planTransactionsProvider =
    FutureProvider.family<List<TransactionEntity>, String>((ref, id) async {
  ref.watch(dbRevisionProvider);
  ref.watch(plansWithSpentProvider);
  final repo = ref.watch(planRepositoryProvider);
  final plan = await repo.getById(id);
  if (plan == null) return const [];
  return repo.transactionsForPlan(plan);
});
