import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart' show BudgetPeriod;
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/report_models.dart';
import '../cards/bank_mark.dart';
import '../cards/brand_mark.dart';
import '../cards/my_cards_screen.dart';
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
import '../../core/security/app_lock_service.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_screen.dart';
import '../settings/settings_providers.dart';
import '../app/app_shell.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';

String _monthsLabel(int n) {
  if (n == 1) return 'شهر';
  if (n == 2) return 'شهرين';
  if (n <= 10) return '$n أشهر';
  return '$n شهراً';
}

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
              skipLoadingOnReload: true,
              loading: () => const PremiumSkeletonPage(cardCount: 5),
              error: (error, stackTrace) {
                // The true cause here is a missing/invalid session, not a
                // transient load failure — retrying the same fetch would
                // fail identically forever. Route to sign-in instead of
                // showing a retry button that can never succeed.
                if (error is AuthRepoException) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    AppSession.instance.handleAuthRequiredFailure();
                  });
                  return ListView(
                    padding: const EdgeInsets.all(AppSpacing.gutter),
                    children: [
                      AppErrorState(
                        title: 'الرجاء تسجيل الدخول مرة أخرى',
                        description:
                            'انتهت صلاحية الجلسة، سجّل دخولك للمتابعة.',
                        retryLabel: 'تسجيل الدخول',
                        onRetry: () =>
                            AppSession.instance.handleAuthRequiredFailure(),
                      ),
                    ],
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  children: [
                    AppErrorState(
                      title: 'تعذر تحميل لوحة التحكم الآن',
                      description: 'تحقق من البيانات أو حاول التحديث مرة أخرى.',
                      retryLabel: 'إعادة المحاولة',
                      onRetry: () => ref.invalidate(dashboardDataProvider),
                    ),
                  ],
                );
              },
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
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PremiumMotion(child: _AccountSwitcher()),
                        SizedBox(height: AppSpacing.s4),
                      ],
                    ),
                  ),
                  const AnnouncementBanner(),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                    child: _SetupNudgeCard(),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Account summary (income vs. expense) — first
                        if (!data.isEmpty) ...[
                          PremiumMotion(
                            delay: const Duration(milliseconds: 50),
                            child: _financialOverviewCard(context, ref, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                        ],
                        // 2. All budgets
                        if (data.budgetProgress.isNotEmpty) ...[
                          PremiumMotion(
                            delay: const Duration(milliseconds: 55),
                            child: _allBudgetsSection(context, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                        ],
                        // 3. Daily expenses
                        if (!data.isEmpty) ...[
                          PremiumMotion(
                            delay: const Duration(milliseconds: 60),
                            child: _weeklySpendVisualCard(context, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                        ],
                        // 4. Coupons
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
                          PremiumMotion(
                            child: _whereMoneyWent(context, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          if (data.topMerchants.isNotEmpty) ...[
                            PremiumMotion(
                              delay: const Duration(milliseconds: 75),
                              child: _merchantRankingVisualCard(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s4),
                          ],
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
                          if (data.weekChangeRatio.abs() >= 0.05) ...[
                            PremiumMotion(
                              delay: const Duration(milliseconds: 40),
                              child: _smartInsightCard(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                          PremiumMotion(
                            delay: const Duration(milliseconds: 100),
                            child: _qirshScoreCard(context, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s5),
                          // 5. Subscriptions
                          if (data.subscriptions.isNotEmpty) ...[
                            PremiumMotion(
                              child: _subscriptionsPreview(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                          // 6. Goals
                          if (data.activeGoal != null) ...[
                            PremiumMotion(
                              child: _goalCard(context, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s5),
                          ],
                          // 7. Plans — last
                          PremiumMotion(
                            delay: const Duration(milliseconds: 95),
                            child: _plansEntryCard(context),
                          ),
                          const SizedBox(height: AppSpacing.s5),
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
      builder: (context) => navySheetTheme(StatefulBuilder(
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
      )),
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
    return transactionsRangeForPreset(
      preset,
      customFallback: defaultTransactionsRange(),
    );
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

  Widget _financialOverviewCard(
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final isCtaDark = Theme.of(context).brightness == Brightness.light;
    final onCta = c.onCta;

    final net = data.rangeIncome - data.rangeExpense;
    final isPositive = net >= 0;
    final netTone = isPositive
        ? (isCtaDark ? const Color(0xFF34D399) : c.success)
        : (isCtaDark ? const Color(0xFFFCA5A5) : c.danger);
    final sign = isPositive ? '+' : '-';
    final netText = privacyMode
        ? '••••'
        : '$sign${_money(net.abs(), data.currency, privacyMode: false)}';

    // Visual expense/income proportion — a quick read on the balance between
    // the two before even looking at the numbers.
    final total = data.rangeExpense + data.rangeIncome;
    final expenseShare = total <= 0 ? 0.5 : (data.rangeExpense / total);

    return AppCard(
      color: c.cta,
      border: Border.all(color: onCta.withValues(alpha: 0.12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: onCta.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.query_stats_rounded, color: onCta, size: 21),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ملخص الحساب', style: AppTypography.bodyStrong(onCta)),
                    const SizedBox(height: 2),
                    Text(_rangeLabel(data.range, context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(
                            onCta.withValues(alpha: 0.70))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          // Hero figure: the net (income − expense) for the range — the one
          // number that answers "how did this period go?".
          Text(
            isPositive ? 'صافي وفّرته' : 'صافي تجاوزته',
            style: AppTypography.caption(onCta.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                isPositive
                    ? Icons.trending_up_rounded
                    : Icons.trending_down_rounded,
                size: 22,
                color: netTone,
              ),
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(netText,
                      style: AppTypography.display(netTone),
                      textDirection: TextDirection.ltr),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          // Proportion bar: expense share vs. income share of the period.
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  Expanded(
                    flex: (expenseShare * 1000).round().clamp(1, 999),
                    child: ColoredBox(
                        color: (isCtaDark ? const Color(0xFFFCA5A5) : c.danger)
                            .withValues(alpha: 0.85)),
                  ),
                  Expanded(
                    flex: ((1 - expenseShare) * 1000).round().clamp(1, 999),
                    child: ColoredBox(
                        color: (isCtaDark ? const Color(0xFF34D399) : c.success)
                            .withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'المصروفات',
                  value: _money(data.rangeExpense, data.currency,
                      privacyMode: privacyMode),
                  tone: c.danger,
                  darkBg: isCtaDark,
                  action: Icon(Icons.arrow_downward_rounded,
                      size: 14,
                      color: (isCtaDark ? const Color(0xFFFCA5A5) : c.danger)
                          .withValues(alpha: 0.9)),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'الدخل',
                  value: _money(data.rangeIncome, data.currency,
                      privacyMode: privacyMode),
                  tone: c.success,
                  darkBg: isCtaDark,
                  action: Icon(Icons.arrow_upward_rounded,
                      size: 14,
                      color: (isCtaDark ? const Color(0xFF34D399) : c.success)
                          .withValues(alpha: 0.9)),
                ),
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
                      gradient: c.primaryGradient,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(AppLucideIcons.inbox,
                        color: c.onPrimary, size: 26),
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
      builder: (_) => navySheetTheme(AppSheetScaffold(
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
                            Text('تكرر ${_monthsLabel(item.monthsSeen)}',
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
      )),
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

  Widget _whereMoneyWent(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final chartSlices = [
      for (final slice in data.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total,
          percent: slice.percent,
          count: slice.count,
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
            centerLabel: _money(data.spentThisMonth, data.currency,
                privacyMode: privacyMode),
            height: 136,
            compactCenter: true,
            framed: false,
          ),
        ],
      ),
    );
  }

  /// كل الميزانيات الفعّالة (يومية/أسبوعية/شهرية/سنوية، عامة أو حسب تصنيف)
  /// مع نسبة الصرف من كل حد، بنفس منطق تلوين شاشة الميزانيات
  /// (context.colors.budgetState).
  Widget _allBudgetsSection(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return AppCard(
      onTap: () => context.push('/budgets'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pie_chart_rounded, color: c.cta, size: 21),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text('كل الميزانيات',
                    style: AppTypography.bodyStrong(c.textMain)),
              ),
              Icon(Icons.chevron_left_rounded, color: c.textLight, size: 20),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          for (var i = 0; i < data.budgetProgress.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.s3),
            _budgetProgressRow(context, data.budgetProgress[i],
                currency: data.currency, privacyMode: privacyMode),
          ],
        ],
      ),
    );
  }

  Widget _budgetProgressRow(
    BuildContext context,
    DashboardBudgetEntry budget, {
    required String currency,
    required bool privacyMode,
  }) {
    final c = context.colors;
    final periodLabel = switch (budget.period) {
      BudgetPeriod.daily => 'يومي',
      BudgetPeriod.weekly => 'أسبوعي',
      BudgetPeriod.monthly => 'شهري',
      BudgetPeriod.yearly => 'سنوي',
    };
    final tone = c.budgetState(budget.ratio);
    final spentText = _money(budget.spent, currency, privacyMode: privacyMode);
    final limitText = _money(budget.limit, currency, privacyMode: privacyMode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                        text: budget.label,
                        style: AppTypography.subhead(c.textMain)),
                    TextSpan(
                        text: ' · $periodLabel',
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('${(budget.ratio * 100).toStringAsFixed(0)}%',
                style: AppTypography.caption(tone)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: budget.ratio.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: c.surfaceMuted,
            valueColor: AlwaysStoppedAnimation(tone),
          ),
        ),
        const SizedBox(height: 4),
        Text('$spentText / $limitText',
            style: AppTypography.caption(c.textLight)),
      ],
    );
  }

  Widget _weeklySpendVisualCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bar_chart_rounded, color: c.success, size: 21),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('استهلاك الأسبوع الحالي',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyStrong(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text('آخر 7 أيام حسب الحساب المختار',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          WeeklyCapsuleBarChart(
            days: data.weeklyDailySpend,
            currencyLabel: _currencyLabel(data.currency),
            privacyMode: privacyMode,
            height: 168,
            barWidth: 24,
            maxBarHeight: 76,
          ),
        ],
      ),
    );
  }

  Widget _merchantRankingVisualCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final maxTotal = data.topMerchants.fold<double>(
      1,
      (max, merchant) => merchant.total > max ? merchant.total : max,
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppLucideIcons.store, color: c.success, size: 21),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('مصروفاتك في المتاجر',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyStrong(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text('أكبر أماكن الصرف في الفترة',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          for (final merchant in data.topMerchants.take(4)) ...[
            _MerchantMiniRow(
              merchant: merchant,
              maxTotal: maxTotal,
              currency: data.currency,
              privacyMode: privacyMode,
            ),
            if (merchant != data.topMerchants.take(4).last)
              const SizedBox(height: AppSpacing.s2),
          ],
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
    final items = data.recent.take(10).toList();
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

  Widget _qirshScoreCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    final score = data.qirshScore;
    final color = score >= 80
        ? c.success
        : score >= 60
            ? c.warning
            : c.danger;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('درجة قرش',
                    style: AppTypography.bodyStrong(c.textMain)),
              ),
              AnimatedAmountText(
                amount: score.toDouble(),
                color: color,
                style: AppTypography.title1(color)
                    .copyWith(fontWeight: FontWeight.w900),
              ),
              Text(' / 100', style: AppTypography.caption(c.textMuted)),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              _scorePill(c, 'الميزانية', data.budgetScore),
              const SizedBox(width: AppSpacing.s2),
              _scorePill(c, 'الادخار', data.savingsScore),
              const SizedBox(width: AppSpacing.s2),
              _scorePill(c, 'الانتظام', data.streakScore),
              const SizedBox(width: AppSpacing.s2),
              _scorePill(c, 'التنوع', data.diversityScore),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scorePill(AppColors c, String label, double score) {
    final color = score >= 80
        ? c.success
        : score >= 60
            ? c.warning
            : c.danger;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text('${score.round()}',
                style: AppTypography.caption(color)
                    .copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style: AppTypography.caption(c.textMuted),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
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

// ─── Setup Nudge ─────────────────────────────────────────────────────────────

/// إخفاء بطاقة "كمّل إعدادك". عند الضغط على X تُؤجَّل لمدة [_setupNudgeSnooze]
/// حتى لا تضايق المستخدم، وتختفي نهائياً بمجرد إتمام الخطوتين.
const Duration _setupNudgeSnooze = Duration(days: 30);
const String _setupNudgeSnoozedUntilKey = 'setup_nudge_snoozed_until';

/// إخفاء فوري لهذه الجلسة بعد الضغط على X (قبل أن يُعاد قراءة التخزين).
final _setupNudgeDismissedProvider = StateProvider<bool>((_) => false);

/// وقت انتهاء التأجيل المخزَّن — البطاقة مخفية طالما لم يحن بعد.
final _setupNudgeSnoozedProvider = FutureProvider<bool>((_) async {
  const storage = FlutterSecureStorage();
  final raw = await storage.read(key: _setupNudgeSnoozedUntilKey);
  final until = raw == null ? null : DateTime.tryParse(raw);
  return until != null && DateTime.now().toUtc().isBefore(until);
});

Future<void> _snoozeSetupNudge(WidgetRef ref) async {
  const storage = FlutterSecureStorage();
  final until = DateTime.now().toUtc().add(_setupNudgeSnooze);
  await storage.write(
    key: _setupNudgeSnoozedUntilKey,
    value: until.toIso8601String(),
  );
  ref.read(_setupNudgeDismissedProvider.notifier).state = true;
  ref.invalidate(_setupNudgeSnoozedProvider);
}

final _appLockEnabledProvider = FutureProvider<bool>(
  (_) => AppLockService.instance.isEnabled(),
);

/// الخطوات المؤجَّلة من الـ onboarding (قفل البصمة + أول هدف ادخار).
class _SetupNudgeCard extends ConsumerWidget {
  const _SetupNudgeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(_setupNudgeDismissedProvider)) {
      return const SizedBox.shrink();
    }
    // مخفية أثناء فترة التأجيل بعد الإغلاق. أثناء تحميل التخزين نخفيها مبدئياً
    // حتى لا تومض ثم تختفي.
    if (ref.watch(_setupNudgeSnoozedProvider).valueOrNull ?? true) {
      return const SizedBox.shrink();
    }
    final hasGoals =
        ref.watch(goalsListProvider).valueOrNull?.isNotEmpty ?? true;
    final lockEnabled = ref.watch(_appLockEnabledProvider).valueOrNull ?? true;
    if (hasGoals && lockEnabled) {
      return const SizedBox.shrink();
    }
    final c = context.colors;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('كمّل إعداد قرش ✨',
                      style: AppTypography.bodyStrong(c.textPrimary)),
                ),
                InkWell(
                  onTap: () => _snoozeSetupNudge(ref),
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(Icons.close_rounded,
                      size: 18, color: c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                if (!lockEnabled)
                  _SetupNudgeChip(
                    icon: Icons.fingerprint_rounded,
                    label: 'فعّل قفل البصمة',
                    onTap: () =>
                        ref.read(shellIndexProvider.notifier).state = 3,
                  ),
                if (!hasGoals)
                  _SetupNudgeChip(
                    icon: Icons.savings_outlined,
                    label: 'أضف هدف ادخار',
                    onTap: () =>
                        ref.read(shellIndexProvider.notifier).state = 2,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupNudgeChip extends StatelessWidget {
  const _SetupNudgeChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.accent),
            const SizedBox(width: 6),
            Text(label,
                style: AppTypography.footnote(c.accent)
                    .copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
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
                        accountName: account.name,
                        accountType: account.type,
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
    required this.accountName,
    required this.accountType,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String accountName;
  final AccountType accountType;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bankColor = bankColorFor(accountName);
    final hasBankLogo = bankShortCodeFor(accountName) != null;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.only(left: 8, right: 14, top: 5, bottom: 5),
          decoration: BoxDecoration(
            color: selected ? c.cta : c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: selected ? c.cta : c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasBankLogo) ...[
                BankMark(
                  accountName: accountName,
                  accountType: accountType,
                  size: 22,
                ),
                const SizedBox(width: 6),
              ] else ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.7)
                        : bankColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: AppTypography.caption(
                  selected ? c.onCta : c.textSecondary,
                ).copyWith(fontWeight: FontWeight.w800),
              ),
            ],
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
        gradient: hasImage ? null : c.primaryGradient,
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

class _MerchantMiniRow extends StatelessWidget {
  const _MerchantMiniRow({
    required this.merchant,
    required this.maxTotal,
    required this.currency,
    required this.privacyMode,
  });

  final MerchantSpend merchant;
  final double maxTotal;
  final String currency;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio =
        maxTotal <= 0 ? 0.0 : (merchant.total / maxTotal).clamp(0.0, 1.0);
    final amountText = privacyMode
        ? '•••• ${Currency.arabicLabel(currency.toUpperCase())}'
        : '${Formatters.amount(merchant.total)} '
            '${Currency.arabicLabel(currency.toUpperCase())}';
    return Row(
      children: [
        BrandMark(name: merchant.name, size: 36),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      merchant.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textPrimary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Text(
                    amountText,
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(c.primary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DashboardCouponsRail extends ConsumerWidget {
  const _DashboardCouponsRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardCouponsProvider);
    return async.when(
      skipLoadingOnReload: true,
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
