import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';

final goalsListProvider = FutureProvider<List<GoalEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final accountId = (selectedAccount ?? defaultAccount)?.id;
  final goals = await ref.watch(goalRepositoryProvider).getAll();
  return goals
      .where((goal) =>
          goal.status == 'active' &&
          (accountId == null || goal.accountId == accountId))
      .toList(growable: false);
});

final goalDetailsProvider =
    FutureProvider.family<GoalDetailsEntity?, String>((ref, goalId) async {
  ref.watch(goalsListProvider);
  return ref.watch(goalDetailsUseCaseProvider).call(goalId);
});

void refreshGoals(WidgetRef ref) {
  ref.invalidate(goalsListProvider);
}
