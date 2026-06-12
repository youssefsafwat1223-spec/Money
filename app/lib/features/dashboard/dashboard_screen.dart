import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../budgets/budget_form_screen.dart';
import '../cards/brand_mark.dart';
import '../cards/cards_carousel.dart';
import '../capture/capture_entry_sheet.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/vault_widget.dart';
import '../common/widgets.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goal_form_screen.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final c = context.colors;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dashboardDataProvider),
      child: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 5),
        error: (e, _) => ListView(
          children: [
            Padding(
                padding: const EdgeInsets.all(24), child: Text('حدث خطأ: $e'))
          ],
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            // الجزء العلوي البنفسجي الممتد للحواف (Header Card)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.gradA, c.gradB],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(32)),
                boxShadow: [
                  BoxShadow(
                    color: c.primary.withValues(alpha: 0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter, 16, AppSpacing.gutter, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PremiumMotion(child: _greeting(context, data)),
                      const SizedBox(height: 20),
                      PremiumMotion(
                        delay: const Duration(milliseconds: 80),
                        child: _walletSummary(context, ref, data),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.s5),

            // محتوى الصفحة الرئيسي مع الهوامش الجانبية
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.activeGoal != null) ...[
                    PremiumMotion(child: _goalCard(context, data)),
                    const SizedBox(height: AppSpacing.s5),
                  ],
                  if (data.isEmpty)
                    _emptyState(context)
                  else ...[
                    if (data.pendingReviewCount > 0) ...[
                      PremiumMotion(child: _reviewCard(context, data)),
                      const SizedBox(height: AppSpacing.s5),
                    ],
                    PremiumMotion(
                      delay: const Duration(milliseconds: 40),
                      child: _smartInsightCard(context, data),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                    PremiumMotion(
                      delay: const Duration(milliseconds: 70),
                      child: _quickActions(context),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                    const CardsCarousel(),
                    const SizedBox(height: AppSpacing.s5),
                    if (data.subscriptions.isNotEmpty) ...[
                      PremiumMotion(child: _subscriptionsPreview(context, data)),
                      const SizedBox(height: AppSpacing.s5),
                    ],
                    PremiumMotion(child: _whereMoneyWent(context, data)),
                    const SizedBox(height: AppSpacing.s5),
                    PremiumMotion(
                      delay: const Duration(milliseconds: 80),
                      child: _recent(context, ref, data),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDashboardRangeSheet(
    BuildContext context,
    WidgetRef ref,
    TransactionsDateRange current,
  ) async {
    var from = current.from;
    var to = current.to;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final c = context.colors;
          return Directionality(
            textDirection: TextDirection.rtl,
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s2,
                  AppSpacing.gutter,
                  AppSpacing.s6,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'اختار فترة العرض',
                      textAlign: TextAlign.center,
                      style: AppTypography.title2(c.textMain),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in TransactionsDatePreset.values)
                          ChoiceChip(
                            label: Text(_presetLabel(preset)),
                            selected: current.preset == preset,
                            onSelected: (_) {
                              if (preset == TransactionsDatePreset.custom) {
                                setState(() {});
                                return;
                              }
                              ref
                                  .read(transactionsDateRangeProvider.notifier)
                                  .state = _rangeForPreset(preset);
                              Navigator.of(context).pop();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.s3),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(color: c.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: Column(
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('من'),
                              subtitle: Text(Formatters.fullDate(from, context)),
                              trailing:
                                  const Icon(Icons.calendar_month_outlined),
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: from,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now()
                                      .add(const Duration(days: 365)),
                                );
                                if (picked != null) {
                                  setState(() => from = picked);
                                }
                              },
                            ),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('إلى'),
                              subtitle: Text(Formatters.fullDate(to, context)),
                              trailing:
                                  const Icon(Icons.calendar_month_outlined),
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: to,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now()
                                      .add(const Duration(days: 365)),
                                );
                                if (picked != null) setState(() => to = picked);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    FilledButton(
                      onPressed: to.isBefore(from)
                          ? null
                          : () {
                              ref
                                  .read(transactionsDateRangeProvider.notifier)
                                  .state = TransactionsDateRange(
                                preset: TransactionsDatePreset.custom,
                                from: from,
                                to: DateTime(
                                  to.year,
                                  to.month,
                                  to.day,
                                  23,
                                  59,
                                  59,
                                ),
                              );
                              Navigator.of(context).pop();
                            },
                      child: const Text('تطبيق الفترة المخصصة'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _presetLabel(TransactionsDatePreset preset) => switch (preset) {
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };

  TransactionsDateRange _rangeForPreset(TransactionsDatePreset preset) {
    final now = DateTime.now();
    return switch (preset) {
      TransactionsDatePreset.thisMonth => TransactionsDateRange(
          preset: preset,
          from: DateTime(now.year, now.month),
          to: now,
        ),
      TransactionsDatePreset.previousMonth => TransactionsDateRange(
          preset: preset,
          from: DateTime(now.year, now.month - 1),
          to: DateTime(now.year, now.month)
              .subtract(const Duration(seconds: 1)),
        ),
      TransactionsDatePreset.last30Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 30)),
          to: now,
        ),
      TransactionsDatePreset.custom => defaultTransactionsRange(),
    };
  }

  String _displayName() {
    final email = AppSession.instance.email;
    if (email == null || email.trim().isEmpty) return 'صديق مالي';
    final local = email.split('@').first.trim();
    if (local.isEmpty || local.toLowerCase() == 'user') return 'صديق مالي';
    return local
        .replaceAll('.', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  String _monthLabel(DateTime date, BuildContext context) {
    return Formatters.monthYear(date, context);
  }

  String _rangeLabel(TransactionsDateRange range, BuildContext context) {
    if (range.preset == TransactionsDatePreset.thisMonth ||
        (range.from.year == range.to.year && range.from.month == range.to.month)) {
      return _monthLabel(range.from, context);
    }
    if (range.preset != TransactionsDatePreset.custom) return range.label;
    return '${Formatters.fullDate(range.from, context)} - ${Formatters.fullDate(range.to, context)}';
  }

  String _currencyLabel(String currency) => switch (currency.toUpperCase()) {
        'SAR' => 'ريال',
        'AED' => 'درهم',
        'EGP' => 'جنيه',
        'KWD' => 'دينار',
        'QAR' => 'ريال قطري',
        'BHD' => 'دينار بحريني',
        'OMR' => 'ريال عماني',
        'USD' => 'دولار',
        'EUR' => 'يورو',
        _ => currency.toUpperCase(),
      };

  String _money(double amount, String currency) =>
      '${Formatters.amount(amount)} ${_currencyLabel(currency)}';

  Widget _greeting(BuildContext context, DashboardData data) {
    final c = context.colors;
    final hour = DateTime.now().hour;
    final greeting =
        hour < 12 ? 'صباح الخير' : (hour < 18 ? 'مساء الخير' : 'مساء الخير');
    final name = _displayName();
    return Row(
      children: [
        Expanded(
          child: Text('$greeting، $name',
              style: AppTypography.title2(Colors.white).copyWith(
                fontWeight: FontWeight.bold,
              )),
        ),
        InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            context.push('/achievements');
          },
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppLucideIcons.flame,
                  size: 16,
                  color: c.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  '${data.streak.currentStreak} يوم',
                  style: AppTypography.caption(Colors.white).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _walletSummary(
      BuildContext context, WidgetRef ref, DashboardData data) {
    final c = context.colors;
    final positive = data.savedThisMonth >= 0;
    final budgetSet = data.monthlyBudgetLimit > 0;
    final hasTrendMovement =
        data.dailySpendTrend.any((value) => value > 0.0001);
    final trendValues = data.dailySpendTrend.length == 1
        ? <double>[0, data.dailySpendTrend.first]
        : data.dailySpendTrend;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () {
              HapticFeedback.selectionClick();
              _showDashboardRangeSheet(context, ref, data.range);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_rangeLabel(data.range, context),
                      style: AppTypography.subhead(Colors.white)
                          .copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  const Icon(AppLucideIcons.arrowLeftRight,
                      size: 16, color: Colors.white),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _heroMetric(
                  label: 'المصروف',
                  amount: data.spentThisMonth,
                ),
              ),
              Container(
                height: 48,
                width: 1,
                color: Colors.white.withValues(alpha: 0.28),
              ),
              Expanded(
                child: _heroMetric(
                  label: 'الدخل',
                  amount: data.incomeThisMonth,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () {
              HapticFeedback.selectionClick();
              BudgetFormScreen.showSheet(context);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppLucideIcons.plus,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    budgetSet
                        ? 'استخدمت ${(data.monthlyBudgetRatio * 100).clamp(0, 999).round()}% من ميزانية ${data.budgetPeriodLabel}'
                        : 'اضغط لضبط ميزانية كل المصروفات',
                    style: AppTypography.caption(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _glassPill(
                  icon: data.balance == null
                      ? AppLucideIcons.receipt
                      : AppLucideIcons.wallet,
                  title: data.balance == null ? 'عمليات الشهر' : 'كل الحسابات',
                  value: data.balance == null
                      ? '${data.recent.length} عمليات حديثة'
                      : _money(data.balance!, data.currency),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _glassPill(
                  icon: AppLucideIcons.arrowLeftRight,
                  title: positive ? 'وفّرت' : 'زيادة صرف',
                  value:
                      '${positive ? '+' : '−'}${_money(data.savedThisMonth.abs(), data.currency)}',
                  valueColor: positive ? c.success : c.accent,
                ),
              ),
            ],
          ),
          if (data.dailySpendTrend.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'اتجاه الصرف هذا الشهر',
                    style: AppTypography.caption(Colors.white70),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  if (hasTrendMovement)
                    CompactSparkline(
                      values: trendValues,
                      color: c.accent,
                      height: 44,
                    )
                  else
                    Text(
                      'ابدأ بإضافة عمليات أكثر، وهنعرض لك اتجاه الصرف اليومي هنا.',
                      style: AppTypography.caption(Colors.white70),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _heroMetric({required String label, required double amount}) {
    return Column(
      children: [
        Text(
          label,
          style: AppTypography.caption(Colors.white.withValues(alpha: 0.72))
              .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        AnimatedAmountText(
          amount: amount,
          color: Colors.white,
        ),
      ],
    );
  }

  Widget _glassPill({
    required IconData icon,
    required String title,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.caption(Colors.white70)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(valueColor ?? Colors.white)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewCard(BuildContext context, DashboardData data) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () {
        HapticFeedback.selectionClick();
        if (data.pendingReview.isNotEmpty) {
          TransactionDetailsScreen.showSheet(context, data.pendingReview.first.id);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              c.accent.withValues(alpha: 0.20),
              c.surface.withValues(alpha: 0.82),
            ],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: c.accent.withValues(alpha: 0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(AppLucideIcons.alertTriangle, color: c.accent),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data.pendingReviewCount} عمليات تحتاج مراجعة',
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'إجماليها ${_money(data.pendingReviewTotal, data.currency)}. راجعها لتبقى تقاريرك أدق.',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            Icon(AppLucideIcons.arrowLeftRight, color: c.textLight, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _smartInsightCard(BuildContext context, DashboardData data) {
    final c = context.colors;
    final ratio = data.weekChangeRatio;
    final isUp = ratio > 0.05;
    final isDown = ratio < -0.05;
    final title = isDown
        ? 'أداء ممتاز هذا الأسبوع'
        : isUp
            ? 'الصرف أعلى من الأسبوع الماضي'
            : 'في المسار الصحيح';
    final percent = (ratio.abs() * 100).clamp(0, 999).round();
    final body = isDown
        ? 'صرفك أقل بـ $percent% عن الأسبوع الماضي. استمر بنفس الهدوء.'
        : isUp
            ? 'زاد بـ $percent%. راقب أكثر تصنيف صرف قبل نهاية الأسبوع.'
            : 'صرفك قريب من الأسبوع الماضي، والتوقع الشهري ${_money(data.projectedMonthSpend, data.currency)}.';
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        context.push('/reports');
      },
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.primary.withValues(alpha: 0.14)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isUp
                      ? [c.accent, c.accent.withValues(alpha: 0.65)]
                      : [c.success, c.success.withValues(alpha: 0.68)],
                ),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                isUp ? AppLucideIcons.alertTriangle : AppLucideIcons.medal,
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTypography.bodyStrong(c.textMain)),
                  const SizedBox(height: 4),
                  Text(body, style: AppTypography.caption(c.textLight)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _quickActionTile(
            context,
            icon: AppLucideIcons.clipboardPaste,
            label: 'ألصق رسالة',
            onTap: () => showCaptureEntrySheet(context),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: _quickActionTile(
            context,
            icon: AppLucideIcons.wallet,
            label: 'ميزانية',
            onTap: () => BudgetFormScreen.showSheet(context),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: _quickActionTile(
            context,
            icon: AppLucideIcons.target,
            label: 'هدف',
            onTap: () => GoalFormScreen.showSheet(context),
          ),
        ),
      ],
    );
  }

  Widget _quickActionTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: c.primary, size: 21),
            const SizedBox(height: 6),
            Text(label, style: AppTypography.caption(c.textMain)),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionsPreview(BuildContext context, DashboardData data) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => _showSubscriptionsSheet(context, data),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.primary.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'اشتراكاتك القادمة',
                    style: AppTypography.title2(c.textMain),
                  ),
                ),
                Text(
                  _money(data.subscriptionsMonthlyTotal, data.currency),
                  style: AppTypography.bodyStrong(c.primary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            for (final item in data.subscriptions) ...[
              Row(
                children: [
                  BrandMark(name: item.name, size: 34),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textMain),
                    ),
                  ),
                  Text(
                    '${_money(item.averageAmount, data.currency)} / شهر',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
              if (item != data.subscriptions.last)
                const SizedBox(height: AppSpacing.s3),
            ],
            const SizedBox(height: AppSpacing.s3),
            Text(
              'تقدر تضبط التنبيهات وتراجع الاشتراكات من شاشة الفواتير.',
              style: AppTypography.caption(c.textLight),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSubscriptionsSheet(
    BuildContext context,
    DashboardData data,
  ) {
    final c = context.colors;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.72,
            ),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.cardLg),
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s3,
                AppSpacing.gutter,
                AppSpacing.s6,
              ),
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.border,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    Expanded(
                      child: Text('اشتراكاتك المكتشفة',
                          style: AppTypography.title2(c.textMain)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  'إجمالي متوقع ${_money(data.subscriptionsMonthlyTotal, data.currency)} شهرياً.',
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s4),
                for (final item in data.subscriptions) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        BrandMark(name: item.name, size: 46),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.name,
                                  style: AppTypography.bodyStrong(c.textMain)),
                              Text('تكرر ${item.monthsSeen} أشهر',
                                  style: AppTypography.caption(c.textLight)),
                            ],
                          ),
                        ),
                        Text(
                          _money(item.averageAmount, data.currency),
                          style: AppTypography.bodyStrong(c.primary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _goalCard(BuildContext context, DashboardData data) {
    final c = context.colors;
    final goal = data.activeGoal!;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border:
              Border.all(color: c.primary.withValues(alpha: 0.2), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 15,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
        children: [
          // اليسار: مجسم الخزنة الزجاجية المتوهجة
          VaultWidget(progress: progress, size: 110),
          const SizedBox(width: AppSpacing.s4),
          // اليمين: معلومات الهدف بتنسيق نظيف
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (Theme.of(context).brightness == Brightness.dark ? c.accent : c.primary).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: (Theme.of(context).brightness == Brightness.dark ? c.accent : c.primary).withValues(alpha: 0.2), width: 1),
                  ),
                  child: Text(
                    'الهدف الحالي',
                    style: AppTypography.caption(Theme.of(context).brightness == Brightness.dark ? c.accent : c.primary).copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  goal.name,
                  style: AppTypography.title2(c.textMain).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'المبلغ الموفر:',
                  style: AppTypography.caption(c.textLight),
                ),
                const SizedBox(height: 2),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${Formatters.integer(goal.savedAmount)} ',
                        style: AppTypography.headline(c.accent).copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextSpan(
                        text:
                            'من ${Formatters.integer(goal.targetAmount)} ${_currencyLabel(data.currency)}',
                        style: AppTypography.body(c.textMain),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _whereMoneyWent(BuildContext context, DashboardData data) {
    final c = context.colors;
    final chartSlices = [
      for (final slice in data.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total,
          percent: slice.percent,
        ),
    ];
    if (chartSlices.isEmpty) {
      return _infoCard(
        context,
        icon: AppLucideIcons.shapes,
        title: 'تصنيفاتك هتظهر هنا',
        body:
            'بعد أول كام عملية مؤكدة، مالي هيعرض أكثر أماكن صرفك ونِسب كل تصنيف.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('أين ذهبت أموالك؟', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s3),
        CategoryDonutChart(slices: chartSlices),
        const SizedBox(height: AppSpacing.s4),
        for (final slice in data.topCategories) ...[
          _categoryBar(context, slice),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }

  Widget _categoryBar(BuildContext context, CategorySlice slice) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 38),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(slice.category.nameAr,
                        style: AppTypography.subhead(c.textMain)),
                  ),
                  Text('${(slice.percent * 100).round()}%',
                      style: AppTypography.caption(c.textLight)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: slice.percent,
                  minHeight: 8,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(slice.category.color),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context, WidgetRef ref, DashboardData data) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('آخر العمليات', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        for (final tx in data.recent)
          TransactionRow(
            transaction: tx,
            category: data.catalog.byId(tx.categoryId),
            onTap: () {
              HapticFeedback.selectionClick();
              TransactionDetailsScreen.showSheet(context, tx.id);
            },
          ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s5),
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.primary.withValues(alpha: 0.2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.primary.withValues(alpha: 0.1),
              border: Border.all(
                  color: c.primary.withValues(alpha: 0.2), width: 1.5),
            ),
            child: Icon(
              AppLucideIcons.receipt,
              size: 36,
              color: c.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'لا توجد عمليات مضافة',
            style: AppTypography.headline(c.textMain).copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'ألصق رسالة الخصم أو الإيداع التي تصلك من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائياً على جهازك.',
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight).copyWith(
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          _emptyStep(context, '1', 'ألصق رسالة خصم أو إيداع من البنك.'),
          const SizedBox(height: AppSpacing.s2),
          _emptyStep(context, '2', 'راجع التصنيف مرة واحدة لو العملية جديدة.'),
          const SizedBox(height: AppSpacing.s2),
          _emptyStep(context, '3', 'بعدها الداش بورد هيمتلئ تلقائياً.'),
          const SizedBox(height: AppSpacing.s5),
          Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: c.primary.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ElevatedButton.icon(
              onPressed: () => showCaptureEntrySheet(context),
              icon: const Icon(AppLucideIcons.clipboardPaste,
                  color: Colors.white, size: 20),
              label: Text(
                'ألصق رسالة بنك',
                style: AppTypography.bodyStrong(Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: c.primary),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: 4),
                Text(body, style: AppTypography.caption(c.textLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyStep(BuildContext context, String number, String text) {
    final c = context.colors;
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: Text(number, style: AppTypography.caption(c.primary)),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(child: Text(text, style: AppTypography.caption(c.textLight))),
      ],
    );
  }
}
