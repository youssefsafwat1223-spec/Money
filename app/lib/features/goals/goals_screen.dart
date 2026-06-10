import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../common/vault_widget.dart';
import 'goals_providers.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalsListProvider);
    final c = context.colors;

    return async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (goals) {
          if (goals.isEmpty) {
            return Center(
              child: Text(
                'أضف هدفك الأول وابدأ تعبئة الخزنة.',
                style: AppTypography.callout(c.textLight),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => refreshGoals(ref),
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              itemCount: goals.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s4),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      onPressed: () => context.push('/goals/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('هدف جديد'),
                    ),
                  );
                }
                final goal = goals[index - 1];
                final progress =
                    goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () => context.push('/goals/${goal.id}'),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.s5),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        VaultWidget(progress: progress, size: 92),
                        const SizedBox(width: AppSpacing.s4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(goal.name, style: AppTypography.headline(c.textMain)),
                              const SizedBox(height: AppSpacing.s2),
                              Text(
                                '${(progress * 100).round()}%',
                                style: AppTypography.bodyStrong(c.primary),
                              ),
                              const SizedBox(height: AppSpacing.s1),
                              Text(
                                '${Formatters.integer(goal.savedAmount)} / ${Formatters.integer(goal.targetAmount)} ر',
                                style: AppTypography.callout(c.textLight),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
  }
}
