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
import 'goal_form_screen.dart';
import 'goals_providers.dart';

class GoalDetailsScreen extends ConsumerWidget {
  const GoalDetailsScreen({super.key, required this.goalId});

  final String goalId;

  static Future<void> showSheet(BuildContext context, String goalId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GoalDetailsSheet(goalId: goalId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الهدف')),
      body: _GoalDetailsContent(goalId: goalId),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddContributionSheet(context, ref, goalId),
        label: const Text('أضف للهدف'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

class _GoalDetailsSheet extends StatelessWidget {
  const _GoalDetailsSheet({required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: c.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.cardLg),
        ),
        child: Container(
        height: media.size.height * 0.86,
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.cardLg),
          ),
          border: Border.all(color: c.primary.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.s3),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s4,
                AppSpacing.gutter,
                AppSpacing.s2,
              ),
              child: Row(
                children: [
                  Text('تفاصيل الهدف', style: AppTypography.title2(c.textMain)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(child: _GoalDetailsContent(goalId: goalId, sheetMode: true)),
          ],
        ),
      ),
      ),
    );
  }
}

class _GoalDetailsContent extends ConsumerWidget {
  const _GoalDetailsContent({
    required this.goalId,
    this.sheetMode = false,
  });

  final String goalId;
  final bool sheetMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalDetailsProvider(goalId));
    return async.when(
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
              140,
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
              if (sheetMode) ...[
                const SizedBox(height: AppSpacing.s5),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            _showAddContributionSheet(context, ref, goalId),
                        icon: const Icon(Icons.add),
                        label: const Text('أضف للهدف'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => GoalFormScreen.showSheet(
                          context,
                          goal: data.goal,
                        ),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('تعديل'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s2),
                OutlinedButton.icon(
                  onPressed: () => _confirmDeleteGoal(context, ref, goalId),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.danger,
                    side: BorderSide(color: c.danger),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف الهدف'),
                ),
              ],
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
    );
  }
}

Future<void> _confirmDeleteGoal(
  BuildContext context,
  WidgetRef ref,
  String goalId,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('حذف الهدف؟'),
      content: const Text('سيتم حذف الهدف ومساهماته نهائياً.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('حذف'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  await ref.read(deleteGoalUseCaseProvider).call(goalId);
  refreshGoals(ref);
  ref.invalidate(goalDetailsProvider(goalId));
  if (context.mounted) {
    Navigator.of(context).pop();
  }
}

Future<void> _showAddContributionSheet(
  BuildContext context,
  WidgetRef ref,
  String goalId,
) async {
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
