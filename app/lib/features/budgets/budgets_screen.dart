import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../core/utils/formatters.dart';
import '../common/category_catalog.dart';
import 'budgets_providers.dart';

class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(budgetsViewProvider);
    final c = context.colors;

    return async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (data) {
          if (data.snapshot.entries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s6),
                child: Text(
                  'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.',
                  textAlign: TextAlign.center,
                  style: AppTypography.callout(c.textLight),
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => refreshBudgets(ref),
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              itemCount: data.snapshot.entries.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s4),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      onPressed: () => context.push('/budgets/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('ميزانية جديدة'),
                    ),
                  );
                }
                final entry = data.snapshot.entries[index - 1];
                final category = data.catalog.byId(entry.budget.categoryId);
                return _BudgetCard(entry: entry, category: category);
              },
            ),
          );
        },
      );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.entry,
    required this.category,
  });

  final BudgetProgressEntry entry;
  final CategoryView? category;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progressColor = c.budgetState(entry.ratio);
    final periodLabel = switch (entry.budget.period) {
      _ => switch (entry.budget.period.name) {
          'daily' => 'يومي',
          'weekly' => 'أسبوعي',
          _ => 'شهري',
        }
    };
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => GoRouter.of(context).push('/budgets/${entry.budget.id}/edit'),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (category != null) ...[
                  CircleAvatar(
                    backgroundColor: category!.color.withValues(alpha: 0.14),
                    child: Icon(category!.icon, color: category!.color),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                ],
                Expanded(
                  child: Text(
                    '${category?.nameAr ?? 'تصنيف'} ($periodLabel)',
                    style: AppTypography.headline(c.textMain),
                  ),
                ),
                Text(
                  '${(entry.ratio * 100).round()}%',
                  style: AppTypography.bodyStrong(progressColor),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: entry.ratio.clamp(0, 1).toDouble(),
                minHeight: 10,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(progressColor),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              '${Formatters.integer(entry.spent)} من ${Formatters.integer(entry.budget.amount)} ريال',
              style: AppTypography.subhead(c.textMain),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              entry.remaining >= 0
                  ? 'باقي ${Formatters.integer(entry.remaining)} ريال'
                  : 'تجاوزت بـ ${Formatters.integer(entry.remaining.abs())} ريال',
              style: AppTypography.callout(
                entry.remaining >= 0 ? c.textLight : c.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
