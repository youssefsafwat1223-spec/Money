import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
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
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';

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
      appBar: AppHeader(title: context.l10n.gdTitle),
      body: _GoalDetailsContent(goalId: goalId),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddContributionSheet(context, ref, goalId),
        label: Text(context.l10n.gdAddToGoal),
        icon: const Icon(AppLucideIcons.plus),
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
      textDirection: Directionality.of(context),
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
                        Text(context.l10n.gdTitle,
                            style: AppTypography.sectionTitle(c.textMain)),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(AppLucideIcons.x),
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
      error: (error, _) => Center(child: Text(context.l10n.txnError)),
      data: (data) {
        if (data == null) {
          return Center(child: Text(context.l10n.gdNotFound));
        }
        final c = context.colors;
        // `arabicLabel`, not `label(context, …)` — so an English reader saw
        // "Saved 12,750 of 15,000 ريال". Found by capturing this screen, which
        // has no route without an id and had therefore never been walked.
        final cur = Currency.label(
            context, ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
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
                context.l10n.gdSavedOfTarget(Formatters.integer(data.goal.savedAmount),
                    Formatters.integer(data.goal.targetAmount), cur),
                style: AppTypography.subhead(c.textMain),
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Center(
              child: Text(
                data.daysRemaining == null
                    ? context.l10n.gdRemaining(
                        Formatters.integer(data.remainingAmount.toDouble()), cur)
                    : context.l10n.gdRemainingWithDays(
                        Formatters.integer(data.remainingAmount.toDouble()),
                        data.daysRemaining!),
                style: AppTypography.callout(c.textLight),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Center(
              child: Text(
                context.l10n.gdRecommendedDaily(
                    Formatters.integer(data.recommendedDailyAmount.toDouble()), cur),
                style: AppTypography.bodyStrong(c.primary),
              ),
            ),
            // Add is gated on sheet mode because the full screen already has a
            // FloatingActionButton for it; EDIT and DELETE are not, and used to
            // be. `/goals/:id` builds this screen with the default
            // `sheetMode: false`, so anyone arriving by deep link or direct
            // navigation could add a contribution but could never edit or
            // delete the goal — the list opens goals as a sheet, which is why
            // it was never noticed.
            const SizedBox(height: AppSpacing.s4),
            Row(
              children: [
                if (sheetMode) ...[
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.buttonHeight,
                      child: FilledButton.icon(
                        onPressed: () =>
                            _showAddContributionSheet(context, ref, goalId),
                        icon: const Icon(AppLucideIcons.plus),
                        label: Text(context.l10n.gdAddToGoal),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                ],
                Expanded(
                  child: SizedBox(
                    height: AppSpacing.buttonHeight,
                    child: OutlinedButton.icon(
                      onPressed: () => GoalFormScreen.showSheet(
                        context,
                        goal: data.goal,
                      ),
                      icon: const Icon(AppLucideIcons.pencil),
                      label: Text(context.l10n.cardEdit),
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
              icon: const Icon(AppLucideIcons.trash2),
              label: Text(context.l10n.gdDeleteGoal),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(context.l10n.gdContributions, style: AppTypography.sectionTitle(c.textMain)),
            const SizedBox(height: AppSpacing.s3),
            if (data.contributions.isEmpty)
              Text(
                context.l10n.gdNoContributions,
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
      title: Text(context.l10n.gdDeleteTitle),
      content: Text(context.l10n.gdDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.setDelete),
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
  final cur = Currency.label(context, goalCurrency);
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
              AppToast.showError(context, repoErrorMessage(context, error));
            } catch (_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.l10n.gdSaveFailed),
                ),
              );
            } finally {
              if (context.mounted) {
                setSheetState(() => saving = false);
              }
            }
          }

          return Directionality(
            textDirection: Directionality.of(context),
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
                            Text(context.l10n.gdAddContribution,
                                style: AppTypography.sectionTitle(c.textMain)),
                            const Spacer(),
                            IconButton(
                              tooltip: context.l10n.annClose,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(AppLucideIcons.x),
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
                          labelText: context.l10n.bdgAmount,
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
                          labelText: context.l10n.txdNote,
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
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: saving
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: c.onInk,
                                  ),
                                )
                              : Text(context.l10n.gdSaveContribution,
                                  style: AppTypography.bodyStrong(c.onInk)),
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
