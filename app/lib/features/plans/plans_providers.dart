import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';

/// A plan paired with its current spending so the UI can show live progress.
class PlanProgress {
  const PlanProgress(this.plan, this.spent);

  final PlanEntity plan;
  final double spent;

  double get remaining => plan.budgetAmount - spent;
  double get ratio => plan.budgetAmount <= 0
      ? 0
      : (spent / plan.budgetAmount).clamp(0, 1).toDouble();
  bool get isOver => spent > plan.budgetAmount;

  /// Suggested daily allowance for the rest of the plan.
  double get perDayLeft {
    final days = plan.daysLeft;
    final left = remaining;
    if (days <= 0 || left <= 0) return 0;
    return left / days;
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
