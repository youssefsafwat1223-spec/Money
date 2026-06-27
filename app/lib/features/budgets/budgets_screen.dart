import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/account_range_controls.dart';
import '../common/category_catalog.dart';
import '../common/premium_loading.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_card.dart';
import '../common/app_empty_state.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goal_form_screen.dart';
import '../transactions/transaction_details_screen.dart';
import 'allocate_income_sheet.dart';
import 'budget_form_screen.dart';
import 'budgets_providers.dart';

class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(budgetsViewProvider);
    final tab = ref.watch(budgetsPageTabProvider);
    final currencyLabel = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');

    return Scaffold(
      body: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 4),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (data) {
          final historyEntries = data.historyEntries;
          final budgetEntries = tab == 1
              ? historyEntries.map((entry) => entry.progress).toList()
              : data.snapshot.entries;
          // An "all expenses" budget is the overall roll-up; category budgets
          // are its breakdown. Summing both double-counts, so the header total
          // uses the roll-up when present, otherwise the sum of categories.
          final categoryEntries =
              budgetEntries.where((e) => !e.budget.isAllExpenses).toList();
          final allExpensesEntries =
              budgetEntries.where((e) => e.budget.isAllExpenses);
          final used = allExpensesEntries.isNotEmpty
              ? allExpensesEntries.first.spent
              : categoryEntries.fold<double>(0, (sum, e) => sum + e.spent);
          final limit = allExpensesEntries.isNotEmpty
              ? allExpensesEntries.first.budget.amount
              : categoryEntries.fold<double>(
                  0, (sum, e) => sum + e.budget.amount);
          final usedRatio = limit == 0 ? 0 : (used / limit * 100).round();
          final saved =
              data.goals.fold<double>(0, (sum, goal) => sum + goal.savedAmount);
          final target = data.goals
              .fold<double>(0, (sum, goal) => sum + goal.targetAmount);
          final progress = target == 0 ? 0 : (saved / target * 100).round();
          final safeCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.safe)
              .length;
          final warningCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.warning)
              .length;
          final overCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.over)
              .length;

          return RefreshIndicator(
            onRefresh: () async => refreshBudgets(ref),
            child: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _BudgetsHeader(
                          tab: tab,
                          usedRatio: usedRatio,
                          usedAmount: used,
                          limit: limit,
                          saved: saved,
                          target: target,
                          progress: progress,
                          goalsCount: data.goals.length,
                          budgetsCount: budgetEntries.length,
                          safeCount: safeCount,
                          warningCount: warningCount,
                          overCount: overCount,
                          currencyLabel: currencyLabel,
                          onAdd: () {
                            if (tab == 2) {
                              GoalFormScreen.showSheet(context);
                            } else {
                              BudgetFormScreen.showSheet(context);
                            }
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.gutter),
                          child: AccountRangeControls(
                            onAccountChanged: () =>
                                ref.invalidate(budgetsViewProvider),
                            onRangeChanged: () =>
                                ref.invalidate(budgetsViewProvider),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                      ],
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _TabBarDelegate(
                      child: Container(
                        height: 64.0,
                        color: context.colors.bg,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.gutter,
                        ),
                        alignment: Alignment.center,
                        child: AppPillTabBar(
                          tabs: const ['الميزانيات', 'السجل', 'الأهداف'],
                          selectedIndex: tab,
                          onSelected: (value) => ref
                              .read(budgetsPageTabProvider.notifier)
                              .state = value,
                        ),
                      ),
                    ),
                  ),
                ];
              },
              body: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s3,
                  AppSpacing.gutter,
                  120,
                ),
                children: [
                  if (tab == 0) ...[
                    _AllocateIncomeButton(
                      onTap: () => AllocateIncomeSheet.show(context),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    ..._budgetEntryChildren(
                      context,
                      ref,
                      data,
                      entries: data.snapshot.entries,
                      currencyLabel: currencyLabel,
                      showGlobalAccountLabel: false,
                      emptyTitle: 'لا توجد ميزانيات',
                      emptySubtitle:
                          'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.',
                    ),
                  ] else if (tab == 1) ...[
                    ..._budgetHistoryChildren(
                      context,
                      data,
                      entries: historyEntries,
                      currencyLabel: currencyLabel,
                    ),
                  ] else ...[
                    if (data.goals.isEmpty)
                      AppEmptyState(
                        icon: AppLucideIcons.target,
                        title: 'لا توجد أهداف',
                        subtitle:
                            'أضف هدف ادخار عشان قرش يتابع تقدمك جنب ميزانياتك.',
                        primaryLabel: 'إضافة هدف',
                        onPrimary: () => GoalFormScreen.showSheet(context),
                      )
                    else
                      for (final goal in data.goals) ...[
                        _GoalPlannerCard(
                          goal: goal,
                          currencyLabel: currencyLabel,
                        ),
                        const SizedBox(height: AppSpacing.s4),
                      ]
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _budgetHistoryChildren(
    BuildContext context,
    BudgetsView data, {
    required List<BudgetHistoryEntry> entries,
    required String currencyLabel,
  }) {
    if (entries.isEmpty) {
      return [
        AppEmptyState(
          icon: Icons.history_rounded,
          title: 'السجل فاضي',
          subtitle:
              'اختار فترة فيها ميزانيات أو أضف ميزانية جديدة، وكل يوم/أسبوع/شهر هيظهر هنا كسجل منفصل.',
          primaryLabel: 'إضافة ميزانية',
          onPrimary: () => BudgetFormScreen.showSheet(context),
        ),
      ];
    }
    return [
      for (final history in entries) ...[
        _BudgetCard(
          entry: history.progress,
          category: data.catalog.byId(history.budget.categoryId),
          accountName: data.accountName(
            history.budget.accountId,
            showGlobalLabel: true,
          ),
          currencyLabel:
              _entryCurrencyLabel(data, history.progress, currencyLabel),
          periodStateLabel: history.isCurrent ? 'جارية' : 'منتهية',
          onTap: () => _BudgetPeriodDetailsSheet.show(
            context,
            history: history,
            category: data.catalog.byId(history.budget.categoryId),
            accountName: data.accountName(
              history.budget.accountId,
              showGlobalLabel: true,
            ),
            currencyLabel:
                _entryCurrencyLabel(data, history.progress, currencyLabel),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    ];
  }

  List<Widget> _budgetEntryChildren(
    BuildContext context,
    WidgetRef ref,
    BudgetsView data, {
    required List<BudgetProgressEntry> entries,
    required String currencyLabel,
    required bool showGlobalAccountLabel,
    required String emptyTitle,
    required String emptySubtitle,
  }) {
    if (entries.isEmpty) {
      return [
        AppEmptyState(
          icon: Icons.pie_chart_outline,
          title: emptyTitle,
          subtitle: emptySubtitle,
          primaryLabel: 'إضافة ميزانية',
          onPrimary: () => BudgetFormScreen.showSheet(context),
        ),
      ];
    }
    return [
      for (final entry in entries) ...[
        _BudgetCard(
          entry: entry,
          category: data.catalog.byId(entry.budget.categoryId),
          accountName: data.accountName(
            entry.budget.accountId,
            showGlobalLabel: showGlobalAccountLabel,
          ),
          currencyLabel: _entryCurrencyLabel(data, entry, currencyLabel),
          onTap: () => BudgetFormScreen.showSheet(
            context,
            budgetId: entry.budget.id,
          ),
          onDelete: () => _confirmDeleteBudget(context, ref, entry),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    ];
  }

  Future<void> _confirmDeleteBudget(
    BuildContext context,
    WidgetRef ref,
    BudgetProgressEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الميزانية؟'),
        content: const Text('هيتشال سقف الميزانية. العمليات نفسها مش هتتأثر.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(budgetRepositoryProvider).delete(entry.budget.id);
    refreshBudgets(ref);
    ref.invalidate(dashboardDataProvider);
  }

  String _entryCurrencyLabel(
    BudgetsView data,
    BudgetProgressEntry entry,
    String fallback,
  ) {
    final accountId = entry.budget.accountId;
    if (accountId == null) return fallback;
    for (final account in data.accounts) {
      if (account.id == accountId) {
        return Currency.arabicLabel(account.currency);
      }
    }
    return fallback;
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate({required this.child});
  final Widget child;

  @override
  double get minExtent => 64.0;
  @override
  double get maxExtent => 64.0;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: c.surfaceCard,
          shape: BoxShape.circle,
          border: Border.all(color: c.border),
        ),
        child: Icon(Icons.add, color: c.cta, size: 22),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 32,
        color: context.colors.divider,
      );
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: AppTypography.bodyStrong(c.textMain)
                .copyWith(fontFamily: 'Outfit'),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTypography.caption(c.textLight),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _BudgetsHeader extends StatelessWidget {
  const _BudgetsHeader({
    required this.tab,
    required this.usedRatio,
    required this.usedAmount,
    required this.limit,
    required this.saved,
    required this.target,
    required this.progress,
    required this.goalsCount,
    required this.budgetsCount,
    required this.safeCount,
    required this.warningCount,
    required this.overCount,
    required this.currencyLabel,
    required this.onAdd,
  });

  final int tab;
  final int usedRatio;
  final double usedAmount;
  final double limit;
  final double saved;
  final double target;
  final int progress;
  final int goalsCount;
  final int budgetsCount;
  final int safeCount;
  final int warningCount;
  final int overCount;
  final String currencyLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isGoals = tab == 2;
    final isAllLog = tab == 1;
    final title = switch (tab) {
      1 => 'سجل الميزانيات',
      2 => 'الأهداف',
      _ => 'الميزانيات',
    };
    final totalLabel = switch (tab) {
      1 => 'ميزانيات في السجل',
      2 => 'مجموع المدخرات المستهدفة',
      _ => 'إجمالي الميزانيات المرصودة',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              _AddButton(onTap: onAdd),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.cta.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        isGoals
                            ? Icons.track_changes_rounded
                            : Icons.donut_large_rounded,
                        color: c.cta,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            totalLabel,
                            style: AppTypography.caption(c.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isAllLog
                                ? '$budgetsCount ميزانية'
                                : isGoals
                                    ? '${Formatters.amount(target)} $currencyLabel'
                                    : '${Formatters.amount(limit)} $currencyLabel',
                            style: AppTypography.title2(c.textMain).copyWith(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Outfit'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  child: Divider(color: c.border, height: 1),
                ),
                Row(
                  children: isGoals
                      ? [
                          _HeaderMetric(
                              label: 'أهداف نشطة', value: '$goalsCount'),
                          const _Divider(),
                          _HeaderMetric(
                              label: 'نسبة التقدم', value: '$progress%'),
                          const _Divider(),
                          _HeaderMetric(
                            label: 'إجمالي الادخار',
                            value: '${Formatters.amount(saved)} $currencyLabel',
                          ),
                        ]
                      : isAllLog
                          ? [
                              _HeaderMetric(label: 'آمنة', value: '$safeCount'),
                              const _Divider(),
                              _HeaderMetric(
                                  label: 'اقتربت', value: '$warningCount'),
                              const _Divider(),
                              _HeaderMetric(
                                  label: 'تجاوزت', value: '$overCount'),
                            ]
                          : [
                              _HeaderMetric(
                                  label: 'ميزانيات', value: '$budgetsCount'),
                              const _Divider(),
                              _HeaderMetric(
                                  label: 'نسبة الاستهلاك',
                                  value: '$usedRatio%'),
                              const _Divider(),
                              _HeaderMetric(
                                label: 'المصروف الفعلي',
                                value:
                                    '${Formatters.amount(usedAmount)} $currencyLabel',
                              ),
                            ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.entry,
    required this.category,
    required this.accountName,
    required this.currencyLabel,
    required this.onTap,
    this.periodStateLabel,
    this.onDelete,
  });

  final BudgetProgressEntry entry;
  final CategoryView? category;
  final String accountName;
  final String currencyLabel;
  final VoidCallback onTap;
  final String? periodStateLabel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progressColor = c.budgetState(entry.ratio);
    final progress = entry.ratio.clamp(0, 1).toDouble();
    final percent = (entry.ratio * 100).round();
    final isOver = entry.remaining < 0;
    final isGeneral = entry.budget.isAllExpenses;
    final statusLabel = isOver
        ? 'تجاوز'
        : entry.ratio >= 0.8
            ? 'اقتربت'
            : 'آمن';
    final periodLabel = switch (entry.budget.period) {
      _ => switch (entry.budget.period.name) {
          'daily' => 'يومي',
          'weekly' => 'أسبوعي',
          _ => 'شهري',
        }
    };
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: (category?.color ?? progressColor)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(
                  isGeneral
                      ? Icons.account_balance_wallet_outlined
                      : category?.icon ?? Icons.category_outlined,
                  color: category?.color ?? progressColor,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isGeneral ? 'كل المصروفات' : category?.nameAr ?? 'تصنيف',
                      style: AppTypography.headline(c.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'ميزانية $periodLabel',
                          style: AppTypography.footnote(c.textSecondary),
                        ),
                        if (accountName.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.primary.withValues(alpha: 0.10),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text(
                              accountName,
                              style: AppTypography.caption(c.primary)
                                  .copyWith(fontSize: 10),
                            ),
                          ),
                        ],
                        if (periodStateLabel != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: progressColor.withValues(alpha: 0.10),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text(
                              periodStateLabel!,
                              style: AppTypography.caption(progressColor)
                                  .copyWith(fontSize: 10),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${entry.periodStart.day}/${entry.periodStart.month} — ${entry.periodEnd.day}/${entry.periodEnd.month}',
                      style: AppTypography.footnote(c.textSecondary)
                          .copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3,
                  vertical: AppSpacing.s1,
                ),
                decoration: BoxDecoration(
                  color: progressColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  statusLabel,
                  style: AppTypography.caption(progressColor),
                ),
              ),
              if (onDelete != null)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: c.textLight, size: 20),
                  onSelected: (value) {
                    if (value == 'delete') onDelete?.call();
                  },
                  itemBuilder: (context) => [
                    if (onDelete != null)
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 18, color: c.danger),
                            const SizedBox(width: 8),
                            Text('حذف', style: TextStyle(color: c.danger)),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$percent%',
                style: AppTypography.title2(progressColor),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 9,
                      backgroundColor: c.surface2,
                      valueColor: AlwaysStoppedAnimation(progressColor),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.bg.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _BudgetAmountTile(
                    label: 'مصروف',
                    value: '${Formatters.integer(entry.spent)} $currencyLabel',
                    color: c.textPrimary,
                  ),
                ),
                Container(width: 1, height: 34, color: c.border),
                Expanded(
                  child: _BudgetAmountTile(
                    label: isOver ? 'تجاوز' : 'باقي',
                    value: isOver
                        ? '${Formatters.integer(entry.remaining.abs())} $currencyLabel'
                        : '${Formatters.integer(entry.remaining)} $currencyLabel',
                    color: isOver ? c.danger : c.success,
                  ),
                ),
                Container(width: 1, height: 34, color: c.border),
                Expanded(
                  child: _BudgetAmountTile(
                    label: 'الحد',
                    value:
                        '${Formatters.integer(entry.budget.amount)} $currencyLabel',
                    color: c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BudgetPeriodDetailsSheet extends StatelessWidget {
  const _BudgetPeriodDetailsSheet({
    required this.history,
    required this.category,
    required this.accountName,
    required this.currencyLabel,
  });

  final BudgetHistoryEntry history;
  final CategoryView? category;
  final String accountName;
  final String currencyLabel;

  static Future<void> show(
    BuildContext context, {
    required BudgetHistoryEntry history,
    required CategoryView? category,
    required String accountName,
    required String currencyLabel,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BudgetPeriodDetailsSheet(
        history: history,
        category: category,
        accountName: accountName,
        currencyLabel: currencyLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entry = history.progress;
    final progressColor = c.budgetState(entry.ratio);
    final progress = entry.ratio.clamp(0, 1).toDouble();
    final percent = (entry.ratio * 100).round();
    final isOver = entry.remaining < 0;
    final title = entry.budget.isAllExpenses
        ? 'كل المصروفات'
        : category?.nameAr ?? 'ميزانية';
    final periodLabel = _periodLabel(entry.budget.period.name);
    final statusLabel = history.isCurrent
        ? 'الفترة الحالية'
        : isOver
            ? 'فترة تجاوزت الحد'
            : 'فترة منتهية';

    return AppSheetScaffold(
      title: title,
      subtitle:
          '$periodLabel · ${_dateRangeLabel(context, entry.periodStart, entry.periodEnd)}',
      scrollable: true,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: (category?.color ?? progressColor)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    entry.budget.isAllExpenses
                        ? Icons.account_balance_wallet_outlined
                        : category?.icon ?? Icons.category_outlined,
                    color: category?.color ?? progressColor,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(statusLabel,
                          style: AppTypography.bodyStrong(progressColor)),
                      if (accountName.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(accountName,
                            style: AppTypography.caption(c.textSecondary)),
                      ],
                    ],
                  ),
                ),
                Text('$percent%',
                    style: AppTypography.title2(progressColor)
                        .copyWith(fontFamily: 'Outfit')),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(progressColor),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.s3),
              child: Row(
                children: [
                  Expanded(
                    child: _BudgetAmountTile(
                      label: 'الحد',
                      value:
                          '${Formatters.integer(entry.budget.amount)} $currencyLabel',
                      color: c.textPrimary,
                    ),
                  ),
                  Container(width: 1, height: 40, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: 'مصروف',
                      value:
                          '${Formatters.integer(entry.spent)} $currencyLabel',
                      color: c.textPrimary,
                    ),
                  ),
                  Container(width: 1, height: 40, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: isOver ? 'تجاوز' : 'باقي',
                      value: isOver
                          ? '${Formatters.integer(entry.remaining.abs())} $currencyLabel'
                          : '${Formatters.integer(entry.remaining)} $currencyLabel',
                      color: isOver ? c.danger : c.success,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              history.isCurrent
                  ? 'السجل ده لسه بيتحدث لحد نهاية الفترة.'
                  : 'السجل ده محسوب من العمليات الفعلية داخل الفترة دي.',
              style: AppTypography.caption(c.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.s5),
            Text('عمليات الفترة',
                style: AppTypography.bodyStrong(c.textPrimary)),
            const SizedBox(height: AppSpacing.s2),
            if (history.transactions.isEmpty)
              Container(
                padding: const EdgeInsets.all(AppSpacing.s3),
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  'مفيش عمليات مؤكدة اتسجلت ضمن الفترة دي.',
                  style: AppTypography.caption(c.textSecondary),
                  textAlign: TextAlign.center,
                ),
              )
            else
              for (final tx in history.transactions.take(20))
                _BudgetTransactionRow(
                  tx: tx,
                  currencyLabel: Currency.arabicLabel(tx.currency),
                ),
          ],
        ),
      ),
    );
  }

  String _periodLabel(String period) => switch (period) {
        'daily' => 'ميزانية يومية',
        'weekly' => 'ميزانية أسبوعية',
        _ => 'ميزانية شهرية',
      };

  String _dateRangeLabel(BuildContext context, DateTime start, DateTime end) {
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) return Formatters.fullDate(start, context);
    return '${Formatters.fullDate(start, context)} - ${Formatters.fullDate(end, context)}';
  }
}

class _BudgetTransactionRow extends StatelessWidget {
  const _BudgetTransactionRow({
    required this.tx,
    required this.currencyLabel,
  });

  final TransactionEntity tx;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = tx.rawMerchant?.trim().isNotEmpty == true
        ? tx.rawMerchant!.trim()
        : tx.note?.trim().isNotEmpty == true
            ? tx.note!.trim()
            : 'عملية';
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.expense.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  Icon(Icons.receipt_long_outlined, size: 17, color: c.expense),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Formatters.fullDate(tx.occurredAt, context),
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(
              '${Formatters.amount(tx.amount)} $currencyLabel',
              style: AppTypography.caption(c.expense)
                  .copyWith(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalPlannerCard extends StatelessWidget {
  const _GoalPlannerCard({
    required this.goal,
    required this.currencyLabel,
  });

  final GoalEntity goal;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final percent = (progress * 100).round();
    final remaining =
        (goal.targetAmount - goal.savedAmount).clamp(0, double.infinity);

    return AppCard(
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(goal.name,
                    style: AppTypography.headline(c.textPrimary)),
              ),
              Text('$percent%', style: AppTypography.bodyStrong(c.primary)),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1).toDouble(),
              minHeight: 10,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(
                remaining == 0 ? c.success : c.primary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            remaining == 0
                ? 'اكتمل الهدف'
                : 'باقي ${Formatters.integer(remaining)} $currencyLabel للوصول',
            style: AppTypography.caption(
              remaining == 0 ? c.success : c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BudgetAmountTile extends StatelessWidget {
  const _BudgetAmountTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: AppTypography.caption(c.textSecondary)),
        const SizedBox(height: 2),
        Text(
          value,
          textAlign: TextAlign.center,
          style: AppTypography.subhead(color),
        ),
      ],
    );
  }
}

/// Entry point for the «وزّع دخلك» flow at the top of the budgets tab.
class _AllocateIncomeButton extends StatelessWidget {
  const _AllocateIncomeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            gradient: c.primaryGradient,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.pie_chart_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('وزّع دخلك على المظاريف',
                        style: AppTypography.bodyStrong(Colors.white)),
                    const SizedBox(height: 2),
                    Text(
                      'اكتب راتبك ووزّعه بضغطة — وقرش يحسبلك المتاح كل يوم',
                      style: AppTypography.caption(
                          Colors.white.withValues(alpha: 0.80)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
