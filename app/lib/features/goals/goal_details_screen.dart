import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../common/vault_widget.dart';
import 'goals_providers.dart';

class GoalDetailsScreen extends ConsumerWidget {
  const GoalDetailsScreen({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalDetailsProvider(goalId));
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الهدف')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (data) {
          if (data == null) {
            return const Center(child: Text('الهدف غير موجود'));
          }
          final c = context.colors;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s4,
              AppSpacing.gutter,
              120,
            ),
            children: [
              Center(child: VaultWidget(progress: data.progress, size: 220)),
              const SizedBox(height: AppSpacing.s4),
              Center(
                child: Text(
                  '${(data.progress * 100).round()}%',
                  style: AppTypography.title1(c.textMain),
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              Center(
                child: Text(
                  'وفّرت ${Formatters.integer(data.goal.savedAmount)} من ${Formatters.integer(data.goal.targetAmount)} ريال',
                  style: AppTypography.subhead(c.textMain),
                ),
              ),
              const SizedBox(height: AppSpacing.s1),
              Center(
                child: Text(
                  data.daysRemaining == null
                      ? 'باقي ${Formatters.integer(data.remainingAmount)} ريال'
                      : 'باقي ${Formatters.integer(data.remainingAmount)} · ${data.daysRemaining} يوم',
                  style: AppTypography.callout(c.textLight),
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              Center(
                child: Text(
                  'موصى: ${Formatters.integer(data.recommendedDailyAmount)} ريال يوميًا',
                  style: AppTypography.bodyStrong(c.primary),
                ),
              ),
              const SizedBox(height: AppSpacing.s6),
              Text('المساهمات', style: AppTypography.title2(c.textMain)),
              const SizedBox(height: AppSpacing.s3),
              if (data.contributions.isEmpty)
                Text(
                  'لا توجد مساهمات بعد.',
                  style: AppTypography.callout(c.textLight),
                )
              else
                for (final contribution in data.contributions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${Formatters.integer(contribution.amount)} ريال',
                      style: AppTypography.subhead(c.textMain),
                    ),
                    subtitle: Text(
                      contribution.note ?? Formatters.fullDate(contribution.createdAt),
                    ),
                  ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddContributionSheet(context, ref),
        label: const Text('أضف للهدف'),
        icon: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showAddContributionSheet(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final noteController = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.gutter,
            right: AppSpacing.gutter,
            top: AppSpacing.s5,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.s5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'المبلغ',
                  suffixText: 'ريال',
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: 'ملاحظة'),
              ),
              const SizedBox(height: AppSpacing.s5),
              FilledButton(
                onPressed: () async {
                  final amount = double.tryParse(controller.text);
                  if (amount == null || amount <= 0) {
                    return;
                  }
                  await ref.read(addGoalContributionUseCaseProvider).call(
                        GoalContributionEntity(
                          id: IdGenerator.next(),
                          goalId: goalId,
                          amount: amount,
                          createdAt: DateTime.now().toUtc(),
                          note: noteController.text.isEmpty
                              ? null
                              : noteController.text,
                        ),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                  refreshGoals(ref);
                  ref.invalidate(goalDetailsProvider(goalId));
                },
                child: const Text('حفظ المساهمة'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    noteController.dispose();
  }
}
