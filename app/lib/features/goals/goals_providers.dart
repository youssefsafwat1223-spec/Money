import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';

final goalsListProvider = FutureProvider<List<GoalEntity>>((ref) async {
  return ref.watch(goalRepositoryProvider).getAll();
});

final goalDetailsProvider =
    FutureProvider.family<GoalDetailsEntity?, String>((ref, goalId) async {
  ref.watch(goalsListProvider);
  return ref.watch(goalDetailsUseCaseProvider).call(goalId);
});

void refreshGoals(WidgetRef ref) {
  ref.invalidate(goalsListProvider);
}
