import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/app_gradients.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../cards/brand_mark.dart';
import '../cards/my_cards_screen.dart';
import '../budgets/budgets_providers.dart';
import '../capture/capture_entry_sheet.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/transaction_direction.dart';
import '../common/premium_loading.dart';
import '../common/widgets.dart';
import '../common/app_card.dart';
import '../common/app_insight_card.dart';
import '../common/app_empty_state.dart';
import '../coupons/coupon_widgets.dart';
import '../coupons/coupons_providers.dart';
import '../goals/goal_details_screen.dart';
import '../plans/plans_screen.dart';
import '../settings/settings_providers.dart';
import '../app/app_shell.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final privacyMode = settingsAsync.maybeWhen(
      data: (settings) => settings.privacyModeEnabled,
      orElse: () => false,
    );
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // Ambient glow for dark mode
          if (isDark) ...[
            Positioned(
              right: -100,
              top: -100,
              width: 320,
              height: 320,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.cta.withValues(alpha: 0.05),
                      c.cta.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: -120,
              bottom: -120,
              width: 360,
              height: 360,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.accent.withValues(alpha: 0.035),
                      c.accent.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
          RefreshIndicator(
            onRefresh: () async => ref.invalidate(dashboardDataProvider),
            child: async.when(
              loading: () => const PremiumSkeletonPage(cardCount: 5),
              error: (error, stackTrace) => ListView(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                children: [
                  AppErrorState(
                    title: 'تعذر تحميل لوحة التحكم الآن',
                    description: 'تحقق من البيانات أو حاول التحديث مرة أخرى.',
                    retryLabel: 'إعادة المحاولة',
                    onRetry: () => ref.invalidate(dashboardDataProvider),
                  ),
                ],
              ),
              data: (data) => ListView(
                padding: const EdgeInsets.only(bottom: 120),
                children: [
                  _DashboardHeader(
                    data: data,
                    displayName: settings?.displayName,
                    avatarPath: settings?.avatarPath,
                    onAdd: () => showCaptureEntrySheet(context),
                    onRangeTap: () => _showDashboardRangeSheet(
                      context,
                      ref,
                      data.range,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const PremiumMotion(child: _AccountSwitcher()),
                        const SizedBox(height: AppSpacing.s4),
                        PremiumMotion(
                          delay: const Duration(milliseconds: 60),
                          child: _financialOverviewCard(context, ref, data,
                              privacyMode: privacyMode),
                        ),
                        const SizedBox(height: AppSpacing.s5),
                        const PremiumMotion(
                          delay: Duration(milliseconds: 70),
                          child: _DashboardCouponsRail(),
                        ),
                        const SizedBox(height: AppSpacing.s5),
                        if (data.isEmpty)
                          _emptyState(context)
                        else ...[
                          if (data.pendingReviewCount > 0) ...[
                            PremiumMotion(
                              child: _reviewCard(context, ref, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                          PremiumMotion(child: _whereMoneyWent(context, data)),
                          const SizedBox(height: AppSpacing.s5),
                          PremiumMotion(
                            delay: const Duration(milliseconds: 80),
                            child: _recentMiniCard(context, ref, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                          PremiumMotion(
                            delay: const Duration(milliseconds: 90),
                            child: _cardsEntryCard(context),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                          PremiumMotion(
                            delay: const Duration(milliseconds: 95),
                            child: _plansEntryCard(context),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                          if (data.weekChangeRatio.abs() >= 0.05) ...[
                            PremiumMotion(
                              delay: const Duration(milliseconds: 40),
                              child: _smartInsightCard(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                          if (data.activeGoal != null ||
                              data.subscriptions.isNotEmpty) ...[
                            PremiumMotion(
                              child: _nextUpSection(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final c = context.colors;
          return AppSheetScaffold(
            title: 'اختار فترة العرض',
            scrollable: true,
            body: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                            trailing: const Icon(Icons.calendar_month_outlined),
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
                            trailing: const Icon(Icons.calendar_month_outlined),
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
                ],
              ),
            ),
            bottomAction: FilledButton(
              onPressed: to.isBefore(from)
                  ? null
                  : () {
                      ref.read(transactionsDateRangeProvider.notifier).state =
                          TransactionsDateRange(
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
          );
        },
      ),
    );
  }

  String _presetLabel(TransactionsDatePreset preset) => switch (preset) {
        TransactionsDatePreset.today => 'اليوم',
        TransactionsDatePreset.thisWeek => 'هذا الأسبوع',
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last7Days => 'آخر 7 أيام',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.last90Days => 'آخر 90 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };

  TransactionsDateRange _rangeForPreset(TransactionsDatePreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart =
        today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7));
    return switch (preset) {
      TransactionsDatePreset.today => TransactionsDateRange(
          preset: preset,
          from: today,
          to: now,
        ),
      TransactionsDatePreset.thisWeek => TransactionsDateRange(
          preset: preset,
          from: weekStart,
          to: now,
        ),
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
      TransactionsDatePreset.last7Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 7)),
          to: now,
        ),
      TransactionsDatePreset.last30Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 30)),
          to: now,
        ),
      TransactionsDatePreset.last90Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 90)),
          to: now,
        ),
      TransactionsDatePreset.custom => defaultTransactionsRange(),
    };
  }

  String _monthLabel(DateTime date, BuildContext context) {
    return Formatters.monthYear(date, context);
  }

  String _rangeLabel(TransactionsDateRange range, BuildContext context) {
    if (range.preset == TransactionsDatePreset.thisMonth) {
      return _monthLabel(range.from, context);
    }
    if (range.preset != TransactionsDatePreset.custom) return range.label;
    return '${Formatters.fullDate(range.from, context)} - ${Formatters.fullDate(range.to, context)}';
  }

  String _currencyLabel(String currency) =>
      Currency.arabicLabel(currency.toUpperCase());

  String _money(
    double amount,
    String currency, {
    bool privacyMode = false,
  }) =>
      privacyMode
          ? '•••• ${_currencyLabel(currency)}'
          : '${Formatters.amount(amount)} ${_currencyLabel(currency)}';

  /// "صرف من ميزانية الفترة": shows "spent من limit" when a daily/weekly budget
  /// is set for the period, otherwise just the spent amount.
  String _spendVsLimit(
    double spent,
    double? periodLimit,
    String currency, {
    bool privacyMode = false,
  }) {
    final spentText = _money(spent, currency, privacyMode: privacyMode);
    if (privacyMode || periodLimit == null || periodLimit <= 0) {
      return spentText;
    }
    return '${Formatters.amount(spent)} من ${_money(periodLimit, currency)}';
  }

  Widget _financialOverviewCard(
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final limit = data.monthlyBudgetLimit;
    final hasBudget = limit > 0;
    final spent = data.spentThisMonth;
    final ratio = data.monthlyBudgetRatio;

    return AppCard(
      color: c.cta,
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.query_stats_rounded,
                    color: Colors.white, size: 21),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ملخص الحساب',
                        style: AppTypography.bodyStrong(Colors.white)),
                    const SizedBox(height: 2),
                    Text(_rangeLabel(data.range, context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(
                            Colors.white.withValues(alpha: 0.70))),
                  ],
                ),
              ),
              if (hasBudget) _budgetRing(context, ratio, darkBg: true),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Text('مصروفات الفترة',
              style:
                  AppTypography.caption(Colors.white.withValues(alpha: 0.70))),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              _money(spent, data.currency, privacyMode: privacyMode),
              style: AppTypography.title1(Colors.white)
                  .copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          _snapshotMetric(
            context,
            title: 'دخل الفترة',
            value: _money(
              data.incomeThisMonth,
              data.currency,
              privacyMode: privacyMode,
            ),
            tone: c.success,
            darkBg: true,
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: _budgetSpendMetric(
                  context,
                  ref,
                  title: 'صرف اليوم',
                  period: BudgetPeriod.daily,
                  value: _spendVsLimit(
                    data.todaySpend,
                    data.dailyBudgetLimit,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.danger,
                  darkBg: true,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _budgetSpendMetric(
                  context,
                  ref,
                  title: 'صرف الأسبوع',
                  period: BudgetPeriod.weekly,
                  value: _spendVsLimit(
                    data.weekSpend,
                    data.weeklyBudgetLimit,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.accent,
                  darkBg: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          _budgetSpendMetric(
            context,
            ref,
            title: 'صرف الشهر',
            period: BudgetPeriod.monthly,
            value: _spendVsLimit(
              data.spentThisMonth,
              data.monthlyBudgetLimit,
              data.currency,
              privacyMode: privacyMode,
            ),
            tone: c.warning,
            darkBg: true,
          ),
        ],
      ),
    );
  }

  Widget _budgetRing(BuildContext context, double ratio,
      {bool darkBg = false}) {
    final c = context.colors;
    final pct = ratio * 100;
    final over = ratio > 1.0;
    final ringColor = over ? c.warning : (darkBg ? Colors.white : c.cta);
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: CircularProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              strokeWidth: 8,
              backgroundColor: darkBg
                  ? Colors.white.withValues(alpha: 0.20)
                  : c.surfaceMuted,
              valueColor: AlwaysStoppedAnimation(ringColor),
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${pct.toStringAsFixed(1)}%',
                style:
                    AppTypography.subhead(darkBg ? Colors.white : c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w900),
              ),
              Text(
                'مستخدم',
                style: AppTypography.caption(darkBg
                    ? Colors.white.withValues(alpha: 0.70)
                    : c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reviewCard(
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final pending = data.pendingReview.take(2).toList();
    void openReview() {
      HapticFeedback.selectionClick();
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      gradient: AppGradients.brandHero,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(AppLucideIcons.inbox,
                        color: Colors.white, size: 26),
                  ),
                  PositionedDirectional(
                    top: -6,
                    start: -6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(minWidth: 22),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.cta,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.surfaceCard, width: 2),
                      ),
                      child: Text(
                        '${data.pendingReviewCount}',
                        style: AppTypography.caption(c.onCta)
                            .copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text('صندوق المراجعة الذكي',
                              style: AppTypography.bodyStrong(c.textPrimary)),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.auto_awesome_rounded,
                            color: c.cta, size: 16),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'لدينا ${data.pendingReviewCount} عمليات تحتاج لمراجعتك. تأكد من التصنيفات والمبالغ.',
                      style: AppTypography.caption(c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < pending.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _miniPendingCard(context, data, pending[i],
                          privacyMode: privacyMode),
                    ),
                  ],
                  if (pending.length == 1) const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(
              onPressed: openReview,
              style: FilledButton.styleFrom(
                backgroundColor: c.cta,
                foregroundColor: c.onCta,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('مراجعة الآن', style: AppTypography.bodyStrong(c.onCta)),
                  const SizedBox(width: 6),
                  Icon(
                    Directionality.of(context) == TextDirection.rtl
                        ? Icons.arrow_back_rounded
                        : Icons.arrow_forward_rounded,
                    size: 18,
                    color: c.onCta,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniPendingCard(
    BuildContext context,
    DashboardData data,
    TransactionEntity tx, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final cat = data.catalog.byId(tx.categoryId);
    final accent = cat?.color ?? c.cta;
    final name = tx.rawMerchant ?? cat?.nameAr ?? 'عملية';
    final isDebit = transactionIsDebit(tx);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 6),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(cat?.icon ?? AppLucideIcons.receipt,
                    color: accent, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            privacyMode
                ? '••••'
                : '${isDebit ? '−' : '+'} ${_money(tx.amount, tx.currency)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.subhead(isDebit ? c.expense : c.success)
                .copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 2),
          Text(cat?.nameAr ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption(c.textMuted)),
        ],
      ),
    );
  }

  Widget _smartInsightCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
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
            : 'صرفك قريب من الأسبوع الماضي، والتوقع الشهري ${_money(data.projectedMonthSpend, data.currency, privacyMode: privacyMode)}.';
    return AppInsightCard(
      type: isDown
          ? AppInsightType.success
          : (isUp ? AppInsightType.warning : AppInsightType.info),
      title: title,
      message: body,
      icon: isUp ? AppLucideIcons.alertTriangle : AppLucideIcons.medal,
      onTap: () {
        HapticFeedback.selectionClick();
        context.push('/reports');
      },
    );
  }

  Widget _snapshotMetric(
    BuildContext context, {
    required String title,
    required String value,
    required Color tone,
    bool darkBg = false,
    Widget? action,
  }) {
    final c = context.colors;
    final bg = darkBg
        ? Colors.white.withValues(alpha: 0.08)
        : tone.withValues(alpha: 0.08);
    final border = darkBg
        ? Colors.white.withValues(alpha: 0.15)
        : tone.withValues(alpha: 0.18);

    // Use brighter colors on dark background for contrast
    Color displayTone = tone;
    if (darkBg) {
      if (tone == c.success) {
        displayTone = const Color(0xFF34D399); // bright emerald
      } else if (tone == c.danger || tone == c.expense) {
        displayTone = const Color(0xFFFCA5A5); // bright soft red
      } else if (tone == c.accent) {
        displayTone = const Color(0xFFF472B6); // bright pink
      } else {
        displayTone = Colors.white;
      }
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.caption(darkBg
                      ? Colors.white.withValues(alpha: 0.70)
                      : c.textLight),
                ),
              ),
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              maxLines: 2,
              style: AppTypography.bodyStrong(displayTone),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showQuickBudgetSheet(
    BuildContext context,
    WidgetRef ref,
    BudgetPeriod period,
  ) async {
    final amountController = TextEditingController();
    var saving = false;
    final label = switch (period) {
      BudgetPeriod.daily => 'اليوم',
      BudgetPeriod.weekly => 'الأسبوع',
      BudgetPeriod.monthly => 'الشهر',
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final c = sheetContext.colors;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> save() async {
              final amount = double.tryParse(
                amountController.text.trim().replaceAll(',', '.'),
              );
              if (amount == null || amount <= 0 || saving) return;
              setSheetState(() => saving = true);
              final budgetRepo = ref.read(budgetRepositoryProvider);
              final accounts = await ref.read(accountsProvider.future);
              final selectedId = ref.read(dashboardAccountProvider);
              final defaultAccount = accounts.where((account) {
                return account.isDefault;
              }).isEmpty
                  ? (accounts.isEmpty ? null : accounts.first)
                  : accounts.firstWhere((account) => account.isDefault);
              final activeAccountId = accounts.any((a) => a.id == selectedId)
                  ? selectedId
                  : defaultAccount?.id;
              final existing = (await budgetRepo.getAll())
                  .where((budget) =>
                      budget.isAllExpenses &&
                      budget.period == period &&
                      budget.accountId == activeAccountId &&
                      budget.isActive)
                  .fold<BudgetEntity?>(null, (prev, budget) => budget);
              final now = DateTime.now();
              final startDate = switch (period) {
                BudgetPeriod.daily => DateTime(now.year, now.month, now.day),
                BudgetPeriod.weekly => DateTime(now.year, now.month, now.day)
                    .subtract(
                        Duration(days: (now.weekday - DateTime.saturday) % 7)),
                BudgetPeriod.monthly => DateTime(now.year, now.month),
              };
              final budget = BudgetEntity(
                id: existing?.id ?? IdGenerator.next(),
                categoryId: BudgetEntity.allExpensesCategoryId,
                amount: amount,
                period: period,
                startDate: startDate,
                isActive: true,
                alert80Sent: existing?.alert80Sent ?? true,
                alert100Sent: existing?.alert100Sent ?? true,
                showOnHeader: false,
                accountId: activeAccountId,
              );
              await ref.read(saveBudgetUseCaseProvider).call(budget);
              ref.invalidate(dashboardDataProvider);
              ref.invalidate(budgetsViewProvider);
              if (context.mounted) Navigator.of(context).pop();
            }

            return Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.gutter,
                right: AppSpacing.gutter,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: c.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('ميزانية صرف $label',
                          style: AppTypography.title2(c.textMain)),
                      const SizedBox(height: AppSpacing.s3),
                      TextField(
                        controller: amountController,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                          labelText: 'المبلغ',
                          suffixText: Currency.arabicLabel(
                            ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR',
                          ),
                        ),
                        onSubmitted: (_) => save(),
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      FilledButton(
                        onPressed: saving ? null : save,
                        child: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('حفظ'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _budgetSpendMetric(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required BudgetPeriod period,
    required String value,
    required Color tone,
    bool darkBg = false,
  }) {
    return _snapshotMetric(
      context,
      title: title,
      value: value,
      tone: tone,
      darkBg: darkBg,
      action: IconButton(
        tooltip: 'تحديد ميزانية',
        onPressed: () => _showQuickBudgetSheet(context, ref, period),
        icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
        color: Colors.white.withValues(alpha: 0.88),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      ),
    );
  }

  Widget _nextUpSection(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    return Column(
      children: [
        if (data.activeGoal != null)
          _goalCard(context, data, privacyMode: privacyMode),
        if (data.activeGoal != null && data.subscriptions.isNotEmpty)
          const SizedBox(height: AppSpacing.s4),
        if (data.subscriptions.isNotEmpty)
          _subscriptionsPreview(context, data, privacyMode: privacyMode),
      ],
    );
  }

  Widget _subscriptionsPreview(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return AppCard(
      onTap: () => _showSubscriptionsSheet(
        context,
        data,
        privacyMode: privacyMode,
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
                _money(
                  data.subscriptionsMonthlyTotal,
                  data.currency,
                  privacyMode: privacyMode,
                ),
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
                  '${_money(item.averageAmount, data.currency, privacyMode: privacyMode)} / شهر',
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
    );
  }

  Future<void> _showSubscriptionsSheet(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AppSheetScaffold(
        title: 'اشتراكاتك المكتشفة',
        subtitle:
            'إجمالي متوقع ${_money(data.subscriptionsMonthlyTotal, data.currency, privacyMode: privacyMode)} شهرياً.',
        scrollable: true,
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            children: [
              for (final item in data.subscriptions) ...[
                AppCard(
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
                        _money(
                          item.averageAmount,
                          data.currency,
                          privacyMode: privacyMode,
                        ),
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
    );
  }

  Widget _goalCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final goal = data.activeGoal!;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final percent = (progress * 100).round();
    final remaining =
        (goal.targetAmount - goal.savedAmount).clamp(0, double.infinity);
    return AppCard(
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child:
                    Text(goal.name, style: AppTypography.headline(c.textMain)),
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
                : 'باقي ${Formatters.integer(remaining)} ${_currencyLabel(data.currency)} للوصول',
            style: AppTypography.caption(
              remaining == 0 ? c.success : c.textLight,
            ),
          ),
        ],
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
            'بعد أول كام عملية مؤكدة، قرش هيعرض أكثر أماكن صرفك ونِسب كل تصنيف.',
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('نظرة سريعة على المصروفات',
                        style: AppTypography.bodyStrong(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text('أكبر التصنيفات في الفترة المختارة',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          CategoryDonutChart(
            slices: chartSlices,
            currencyLabel: _currencyLabel(data.currency),
            centerLabel: 'إجمالي المصروفات',
            height: 150,
          ),
        ],
      ),
    );
  }

  Widget _miniSectionHeader(
    BuildContext context, {
    required String title,
    required String action,
    required VoidCallback onAction,
  }) {
    final c = context.colors;
    return Row(
      children: [
        Expanded(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyStrong(c.textPrimary)),
        ),
        const SizedBox(width: 4),
        InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onAction();
          },
          child: Text(action,
              style: AppTypography.caption(c.cta)
                  .copyWith(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  Widget _recentMiniCard(
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final items = data.recent.take(4).toList();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _miniSectionHeader(
            context,
            title: 'آخر العمليات',
            action: 'عرض الكل',
            onAction: () => ref.read(shellIndexProvider.notifier).state = 1,
          ),
          const SizedBox(height: AppSpacing.s2),
          if (items.isEmpty)
            Text('لا توجد عمليات بعد.',
                style: AppTypography.caption(context.colors.textMuted))
          else
            for (final tx in items)
              _recentRowMini(context, data, tx, privacyMode: privacyMode),
        ],
      ),
    );
  }

  Widget _recentRowMini(
    BuildContext context,
    DashboardData data,
    TransactionEntity tx, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final cat = data.catalog.byId(tx.categoryId);
    final accent = cat?.color ?? c.cta;
    final name = tx.rawMerchant ?? cat?.nameAr ?? 'عملية';
    final isDebit = transactionIsDebit(tx);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () {
        HapticFeedback.selectionClick();
        TransactionDetailsScreen.showSheet(context, tx.id);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            if (BrandMark.hasBrand(name))
              BrandMark(name: name, size: 30)
            else
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(cat?.icon ?? AppLucideIcons.receipt,
                    color: accent, size: 15),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textPrimary)
                          .copyWith(fontWeight: FontWeight.w700)),
                  Text(Formatters.fullDate(tx.occurredAt, context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              privacyMode
                  ? '••••'
                  : Formatters.signed(tx.amount, isExpense: isDebit),
              maxLines: 1,
              style: AppTypography.caption(isDebit ? c.expense : c.success)
                  .copyWith(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _plansEntryCard(BuildContext context) {
    final c = context.colors;
    return AppCard(
      onTap: () => PlansScreen.open(context),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(Icons.luggage_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: AppSpacing.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('الخطط', style: AppTypography.bodyStrong(c.textMain)),
                Text('ميزانية لرحلة أو مناسبة، بتتابع نفسها',
                    style: AppTypography.footnote(c.textLight)),
              ],
            ),
          ),
          Icon(Icons.chevron_left, color: c.textLight, size: 22),
        ],
      ),
    );
  }

  Widget _cardsEntryCard(BuildContext context) {
    final c = context.colors;
    return AppCard(
      onTap: () => MyCardsScreen.open(context),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(Icons.credit_card, color: Colors.white, size: 22),
          ),
          const SizedBox(width: AppSpacing.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('بطاقاتي', style: AppTypography.bodyStrong(c.textMain)),
                Text('اعرض كل بطاقاتك وأضف عملية',
                    style: AppTypography.footnote(c.textLight)),
              ],
            ),
          ),
          Icon(Icons.chevron_left, color: c.textLight, size: 22),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return AppEmptyState(
      icon: AppLucideIcons.receipt,
      title: 'لا توجد عمليات مضافة',
      subtitle:
          'ألصق رسالة الخصم أو الإيداع التي تصلك من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائياً على جهازك.',
      primaryLabel: 'ألصق رسالة بنك',
      onPrimary: () => showCaptureEntrySheet(context),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    final c = context.colors;
    return AppCard(
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
}

// ─── Account Switcher ────────────────────────────────────────────────────────

/// مبدّل الحساب أعلى الـ Dashboard — الحساب النشط يحدد عملة العرض في التطبيق.
class _AccountSwitcher extends ConsumerWidget {
  const _AccountSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final selectedId = ref.watch(dashboardAccountProvider);
    return accountsAsync.maybeWhen(
      data: (accounts) {
        // اعرض المبدّل بمجرد وجود حساب واحد ليبقى مدخل «إدارة الحسابات» متاحاً.
        if (accounts.isEmpty) return const SizedBox.shrink();
        final container = ProviderScope.containerOf(context, listen: false);
        final defaultAccount = accounts.firstWhere(
          (account) => account.isDefault,
          orElse: () => accounts.first,
        );
        final activeId = accounts.any((account) => account.id == selectedId)
            ? selectedId
            : defaultAccount.id;
        return SizedBox(
          height: 42,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final account in accounts)
                      _AccountChip(
                        label:
                            '${account.name} · ${Currency.arabicLabel(account.currency)}',
                        selected: activeId == account.id,
                        onTap: () async {
                          container
                              .read(dashboardAccountProvider.notifier)
                              .state = account.id;
                          await container
                              .read(accountRepositoryProvider)
                              .setDefault(account.id);
                          container.invalidate(accountsProvider);
                          container.invalidate(baseCurrencyProvider);
                          container.invalidate(dashboardDataProvider);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'إدارة الحسابات',
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    context.push('/accounts');
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: context.colors.surfaceCard,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.colors.border),
                    ),
                    child: Icon(
                      AppLucideIcons.walletCards,
                      color: context.colors.cta,
                      size: 19,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _AccountChip extends StatelessWidget {
  const _AccountChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? c.cta : c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: selected ? c.cta : c.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppTypography.caption(
              selected ? c.onCta : c.textSecondary,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}

// ─── Dashboard Header ────────────────────────────────────────────────────────

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.data,
    this.displayName,
    this.avatarPath,
    required this.onAdd,
    required this.onRangeTap,
  });

  final DashboardData data;
  final String? displayName;
  final String? avatarPath;
  final VoidCallback onAdd;
  final VoidCallback onRangeTap;

  String _displayName() {
    final profileName = displayName?.trim();
    if (profileName != null && profileName.isNotEmpty) {
      return profileName;
    }
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

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'م';
    if (parts.length == 1) return parts.first.substring(0, 1);
    return '${parts.first.substring(0, 1)}${parts[1].substring(0, 1)}';
  }

  String _todayLabel() {
    const weekdays = [
      'الإثنين',
      'الثلاثاء',
      'الأربعاء',
      'الخميس',
      'الجمعة',
      'السبت',
      'الأحد',
    ];
    const months = [
      'يناير',
      'فبراير',
      'مارس',
      'أبريل',
      'مايو',
      'يونيو',
      'يوليو',
      'أغسطس',
      'سبتمبر',
      'أكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    final d = DateTime.now();
    return '${weekdays[d.weekday - 1]}، ${d.day} ${months[d.month - 1]}';
  }

  Widget _avatar(BuildContext context, String name) {
    final c = context.colors;
    final path = avatarPath?.trim();
    final file = path == null || path.isEmpty ? null : File(path);
    final hasImage = file != null && file.existsSync();
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: hasImage ? null : AppGradients.brandHero,
        shape: BoxShape.circle,
        color: hasImage ? c.surface2 : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.file(file, fit: BoxFit.cover)
          : Text(
              _initials(name),
              style: AppTypography.subhead(Colors.white)
                  .copyWith(fontWeight: FontWeight.w900),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = _displayName();
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
          // Greeting row + add button
          Row(
            children: [
              _avatar(context, name),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'مرحباً، $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.title1(c.textMain)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _todayLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'إضافة عملية',
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onAdd();
                  },
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.border),
                    ),
                    child: Icon(AppLucideIcons.plus, color: c.cta, size: 21),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          // Range picker button
          Align(
            alignment: Alignment.center,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () {
                  HapticFeedback.selectionClick();
                  onRangeTap();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.surfaceCard,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: c.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_month_rounded,
                          color: c.cta, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        data.range.label,
                        style: AppTypography.subhead(c.textPrimary)
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.keyboard_arrow_down_rounded,
                          color: c.textMuted, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardCouponsRail extends ConsumerWidget {
  const _DashboardCouponsRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardCouponsProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (offers) {
        if (offers.isEmpty) return const SizedBox.shrink();
        final c = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'كوبونات توفر عليك',
              subtitle: 'عروض شركاء مناسبة لمصروفاتك',
              action: TextButton(
                onPressed: () => context.push('/coupons'),
                child: Text(
                  'عرض الكل',
                  style: AppTypography.caption(c.cta)
                      .copyWith(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            SizedBox(
              height: 206,
              child: ListView.separated(
                clipBehavior: Clip.none,
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                itemCount: offers.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: AppSpacing.s3),
                itemBuilder: (context, index) => CouponCard(
                  offer: offers[index],
                  compact: true,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
