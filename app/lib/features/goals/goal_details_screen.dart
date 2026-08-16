import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/finance/money_input.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../budgets/budgets_providers.dart';
import '../common/app_header.dart';
import '../common/vault_widget.dart';
import '../dashboard/dashboard_providers.dart';
import 'goal_form_screen.dart';
import 'goals_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

class GoalDetailsScreen extends ConsumerWidget {
  const GoalDetailsScreen({super.key, required this.goalId});

  final String goalId;

  static Future<void> showSheet(BuildContext context, String goalId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_GoalDetailsSheet(goalId: goalId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: const AppHeader(title: 'تفاصيل الهدف'),
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
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              height: media.size.height * 0.86,
              child: Column(
                children: [
                  const SizedBox(height: AppSpacing.s3),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textLight.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
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
                        Text('تفاصيل الهدف',
                            style: AppTypography.sectionTitle(c.textMain)),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                          style: IconButton.styleFrom(
                            backgroundColor: c.surface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                      child:
                          _GoalDetailsContent(goalId: goalId, sheetMode: true)),
                ],
              ),
            ),
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
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => const Center(child: Text('حدث خطأ')),
      data: (data) {
        if (data == null) {
          return const Center(child: Text('الهدف غير موجود'));
        }
        final c = context.colors;
        final cur = Currency.arabicLabel(
            ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
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
                style: AppTypography.bodyStrong(c.textMain),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Center(
              child: Text(
                'وفّرت ${Formatters.integer(data.goal.savedAmount)} من ${Formatters.integer(data.goal.targetAmount)} $cur',
                style: AppTypography.subhead(c.textMain),
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Center(
              child: Text(
                data.daysRemaining == null
                    ? 'باقي ${Formatters.integer(data.remainingAmount.toDouble())} $cur'
                    : 'باقي ${Formatters.integer(data.remainingAmount.toDouble())} · ${data.daysRemaining} يوم',
                style: AppTypography.callout(c.textLight),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Center(
              child: Text(
                'موصى: ${Formatters.integer(data.recommendedDailyAmount.toDouble())} $cur يوميًا',
                style: AppTypography.bodyStrong(c.primary),
              ),
            ),
            if (sheetMode) ...[
              const SizedBox(height: AppSpacing.s4),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.buttonHeight,
                      child: FilledButton.icon(
                        onPressed: () =>
                            _showAddContributionSheet(context, ref, goalId),
                        icon: const Icon(Icons.add),
                        label: const Text('أضف للهدف'),
                        style: FilledButton.styleFrom(
                          backgroundColor: c.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.buttonHeight,
                      child: OutlinedButton.icon(
                        onPressed: () => GoalFormScreen.showSheet(
                          context,
                          goal: data.goal,
                        ),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('تعديل'),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: c.border),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              OutlinedButton.icon(
                onPressed: () => _confirmDeleteGoal(context, ref, goalId),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.danger,
                  side: BorderSide(color: c.danger),
                  minimumSize: const Size.fromHeight(AppSpacing.buttonHeight),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('حذف الهدف'),
              ),
            ],
            const SizedBox(height: AppSpacing.s4),
            Text('المساهمات', style: AppTypography.sectionTitle(c.textMain)),
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
                    '${Formatters.integer(contribution.amount)} $cur',
                    style: AppTypography.subhead(c.textMain),
                  ),
                  subtitle: Text(
                    contribution.note ??
                        Formatters.fullDate(contribution.createdAt, context),
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
  refreshBudgets(ref);
  ref.invalidate(dashboardDataProvider);
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
  final c = context.colors;
  // §14 — the contribution inherits the PARENT GOAL's currency; the amount is
  // parsed exactly into it (the repository rejects any mismatch).
  final goalCurrency =
      ref.read(goalDetailsProvider(goalId)).valueOrNull?.goal.currency ??
          (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
  final cur = Currency.arabicLabel(goalCurrency);
  final isDark = Theme.of(context).brightness == Brightness.dark;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      var saving = false;
      return navySheetTheme(StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> saveContribution() async {
            if (saving) return;
            final amount = double.tryParse(controller.text);
            if (amount == null || amount <= 0) {
              return;
            }
            setSheetState(() => saving = true);
            try {
              await ref.read(addGoalContributionUseCaseProvider).call(
                    GoalContributionEntity(
                      id: IdGenerator.next(),
                      goalId: goalId,
                      amountMoney:
                          parseLocalizedMoney(controller.text, goalCurrency),
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
              refreshBudgets(ref);
              ref.invalidate(dashboardDataProvider);
              ref.invalidate(goalDetailsProvider(goalId));
            } on RepoException catch (error) {
              if (!context.mounted) return;
              AppToast.showError(context, repoExceptionMessage(error));
            } catch (_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('تعذّر حفظ المساهمة الآن.'),
                ),
              );
            } finally {
              if (context.mounted) {
                setSheetState(() => saving = false);
              }
            }
          }

          return Directionality(
            textDirection: TextDirection.rtl,
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              child: MaliGlass(
                variant: MaliGlassVariant.sheet,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: AppSpacing.gutter,
                    right: AppSpacing.gutter,
                    top: AppSpacing.s3,
                    bottom: MediaQuery.of(context).viewInsets.bottom +
                        AppSpacing.s5,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: c.textLight.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Text('إضافة مساهمة',
                                style: AppTypography.sectionTitle(c.textMain)),
                            const Spacer(),
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                              style: IconButton.styleFrom(
                                backgroundColor:
                                    c.surface.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: AppTypography.body(c.textMain),
                        decoration: InputDecoration(
                          labelText: 'المبلغ',
                          suffixText: cur,
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : c.surface2.withValues(alpha: 0.5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: c.border.withValues(alpha: 0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.primary, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      TextField(
                        controller: noteController,
                        style: AppTypography.body(c.textMain),
                        decoration: InputDecoration(
                          labelText: 'ملاحظة',
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : c.surface2.withValues(alpha: 0.5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: c.border.withValues(alpha: 0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.primary, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      SizedBox(
                        height: AppSpacing.buttonHeight,
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: saving ? null : saveContribution,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: saving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Text('حفظ المساهمة',
                                  style:
                                      AppTypography.bodyStrong(Colors.white)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ));
    },
  );
  // Do NOT dispose controllers here – the sheet's exit animation may still
  // reference them. They will be GC'd when the method scope ends.
}
