import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../budgets/budget_form_screen.dart';
import '../cards/brand_mark.dart';
import '../cards/cards_carousel.dart';
import '../capture/capture_entry_sheet.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/widgets.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goal_form_screen.dart';
import '../settings/settings_providers.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final privacyMode = ref.watch(userSettingsProvider).maybeWhen(
          data: (settings) => settings.privacyModeEnabled,
          orElse: () => false,
        );
    final c = context.colors;
    final accounts = ref.watch(accountsProvider).maybeWhen(
      data: (a) => a,
      orElse: () => <AccountEntity>[],
    );

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dashboardDataProvider),
      child: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 5),
        error: (error, stackTrace) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'تعذر تحميل لوحة التحكم الآن.',
                    style: AppTypography.title2(c.textMain),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'تحقق من البيانات أو حاول التحديث مرة أخرى.',
                    style: AppTypography.body(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  OutlinedButton.icon(
                    onPressed: () => ref.invalidate(dashboardDataProvider),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            )
          ],
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            GestureDetector(
              onHorizontalDragEnd: (details) {
                if (accounts.isEmpty) return;
                final allOptions = <String?>[null, ...accounts.map<String>((a) => a.id)];
                final current = ref.read(dashboardAccountProvider);
                final currentIdx = allOptions.indexOf(current);
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() < 200) return;
                final nextIdx = velocity < 0
                    ? (currentIdx + 1) % allOptions.length
                    : (currentIdx - 1 + allOptions.length) % allOptions.length;
                HapticFeedback.selectionClick();
                ref.read(dashboardAccountProvider.notifier).state =
                    allOptions[nextIdx];
              },
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF046E9B),
                    Color(0xFF034E73),
                    Color(0xFF012438),
                  ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(34)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF034F73).withValues(alpha: 0.25),
                    blurRadius: 26,
                    offset: const Offset(0, 14),
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
                      const SizedBox(height: 14),
                      const PremiumMotion(child: _AccountSwitcher()),
                      const SizedBox(height: 16),
                      PremiumMotion(
                        delay: const Duration(milliseconds: 80),
                        child: _walletSummary(
                          context,
                          ref,
                          data,
                          privacyMode: privacyMode,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ),
            const SizedBox(height: AppSpacing.s5),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.hasMultipleCurrencies) ...[
                    PremiumMotion(
                      child: _currencyTotalsCard(
                        context,
                        data,
                        privacyMode: privacyMode,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                  ],
                  if (data.activeGoal != null) ...[
                    PremiumMotion(
                      child: _goalCard(
                        context,
                        data,
                        privacyMode: privacyMode,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                  ],
                  if (data.isEmpty)
                    _emptyState(context)
                  else ...[
                    if (data.pendingReviewCount > 0) ...[
                      PremiumMotion(
                        child: _reviewCard(
                          context,
                          data,
                          privacyMode: privacyMode,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                    ],
                    PremiumMotion(
                      delay: const Duration(milliseconds: 40),
                      child: _smartInsightCard(
                        context,
                        data,
                        privacyMode: privacyMode,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                    PremiumMotion(
                      delay: const Duration(milliseconds: 55),
                      child: _periodSnapshotCard(
                        context,
                        data,
                        privacyMode: privacyMode,
                      ),
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
                      PremiumMotion(
                        child: _subscriptionsPreview(
                          context,
                          data,
                          privacyMode: privacyMode,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                    ],
                    PremiumMotion(child: _whereMoneyWent(context, data)),
                    const SizedBox(height: AppSpacing.s5),
                    PremiumMotion(
                      delay: const Duration(milliseconds: 80),
                      child: _recent(
                        context,
                        ref,
                        data,
                        privacyMode: privacyMode,
                      ),
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
                              subtitle:
                                  Text(Formatters.fullDate(from, context)),
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
        (range.from.year == range.to.year &&
            range.from.month == range.to.month)) {
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

  String _money(
    double amount,
    String currency, {
    bool privacyMode = false,
  }) =>
      privacyMode
          ? '•••• ${_currencyLabel(currency)}'
          : '${Formatters.amount(amount)} ${_currencyLabel(currency)}';

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
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1,
              ),
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
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
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
        gradient: const LinearGradient(
          colors: [Color(0xFF011C2B), Color(0xFF023A57)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: c.accent.withValues(alpha: 0.24),
          width: 1.0,
        ),
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
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
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
                  context: context,
                  label: 'المصروف',
                  amount: data.spentThisMonth,
                  privacyMode: privacyMode,
                  currency: data.currency,
                  onDark: true,
                ),
              ),
              Container(
                height: 48,
                width: 1,
                color: Colors.white.withValues(alpha: 0.14),
              ),
              Expanded(
                child: _heroMetric(
                  context: context,
                  label: 'الدخل',
                  amount: data.incomeThisMonth,
                  privacyMode: privacyMode,
                  currency: data.currency,
                  onDark: true,
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
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppLucideIcons.plus, color: c.accent, size: 16),
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
                      : _money(
                          data.balance!,
                          data.currency,
                          privacyMode: privacyMode,
                        ),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _glassPill(
                  icon: AppLucideIcons.arrowLeftRight,
                  title: positive ? 'وفّرت' : 'زيادة صرف',
                  value: privacyMode
                      ? _money(
                          data.savedThisMonth.abs(),
                          data.currency,
                          privacyMode: true,
                        )
                      : '${positive ? '+' : '−'}${_money(data.savedThisMonth.abs(), data.currency)}',
                  valueColor: positive ? c.success : c.accent,
                ),
              ),
            ],
          ),
          if (data.budgetsForHeader.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            _HeaderBudgetSwiper(
              entries: data.budgetsForHeader,
              currency: data.currency,
              privacyMode: privacyMode,
            ),
          ],
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

  Widget _heroMetric({
    required BuildContext context,
    required String label,
    required double amount,
    required bool privacyMode,
    required String currency,
    bool onDark = false,
  }) {
    final c = context.colors;
    final main = onDark ? Colors.white : c.textMain;
    final muted = onDark ? Colors.white70 : c.textLight;
    return Column(
      children: [
        Text(
          label,
          style: AppTypography.caption(muted)
              .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        privacyMode
            ? Text(
                '••••',
                style: AppTypography.amountHero(main),
              )
            : AnimatedAmountText(
                amount: amount,
                color: main,
                suffix: ' ${_currencyLabel(currency)}',
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

  Widget _reviewCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () {
        HapticFeedback.selectionClick();
        if (data.pendingReview.isNotEmpty) {
          TransactionDetailsScreen.showSheet(
              context, data.pendingReview.first.id);
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
                    'إجماليها ${_money(data.pendingReviewTotal, data.currency, privacyMode: privacyMode)}. راجعها لتبقى تقاريرك أدق.',
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

  Widget _smartInsightCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
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
            : 'صرفك قريب من الأسبوع الماضي، والتوقع الشهري ${_money(data.projectedMonthSpend, data.currency, privacyMode: privacyMode)}.';
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

  Widget _periodSnapshotCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.calendar_month_outlined,
                  color: c.primary,
                  size: 21,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  'لمحة سريعة',
                  style: AppTypography.bodyStrong(c.textMain),
                ),
              ),
              Text(
                'اليوم / الأسبوع',
                style: AppTypography.caption(c.textLight),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'صرف اليوم',
                  value: _money(
                    data.todaySpend,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.danger,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'دخل اليوم',
                  value: _money(
                    data.todayIncome,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'صرف الأسبوع',
                  value: _money(
                    data.weekSpend,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'دخل الأسبوع',
                  value: _money(
                    data.weekIncome,
                    data.currency,
                    privacyMode: privacyMode,
                  ),
                  tone: c.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _snapshotMetric(
    BuildContext context, {
    required String title,
    required String value,
    required Color tone,
  }) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tone.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.caption(c.textLight)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyStrong(tone),
          ),
        ],
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

  Widget _subscriptionsPreview(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => _showSubscriptionsSheet(
        context,
        data,
        privacyMode: privacyMode,
      ),
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
                  'إجمالي متوقع ${_money(data.subscriptionsMonthlyTotal, data.currency, privacyMode: privacyMode)} شهرياً.',
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
      ),
    );
  }

  Widget _currencyTotalsCard(
    BuildContext context,
    DashboardData data, {
    required bool privacyMode,
  }) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.primary.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppLucideIcons.wallet, size: 18, color: c.primary),
              const SizedBox(width: 8),
              Text('إجماليات حسب العملة',
                  style: AppTypography.bodyStrong(c.textMain)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'عندك عملات مختلفة، فبنعرضها منفصلة (من غير تحويل).',
            style: AppTypography.caption(c.textLight),
          ),
          const SizedBox(height: AppSpacing.s3),
          for (final total in data.currencyTotals) ...[
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(total.currency,
                      style: AppTypography.caption(c.primary)
                          .copyWith(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Text(Currency.arabicLabel(total.currency),
                    style: AppTypography.caption(c.textLight)),
                const Spacer(),
                Text(
                  privacyMode
                      ? '•••• ${Currency.arabicLabel(total.currency)}'
                      : 'صرف ${_money(total.expense, total.currency)}',
                  style: AppTypography.subhead(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (total != data.currencyTotals.last)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.s2),
                child: SizedBox(height: 0),
              ),
          ],
        ],
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
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
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
                Icon(Icons.savings_outlined, color: c.primary),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(goal.name,
                      style: AppTypography.headline(c.textMain)),
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
        CategoryDonutChart(
          slices: chartSlices,
          currencyLabel: _currencyLabel(data.currency),
        ),
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

  Widget _recent(
    BuildContext context,
    WidgetRef ref,
    DashboardData data, {
    required bool privacyMode,
  }) {
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
            hideAmount: privacyMode,
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

// ─── Header Budget Swiper ────────────────────────────────────────────────────

class _HeaderBudgetSwiper extends StatefulWidget {
  const _HeaderBudgetSwiper({
    required this.entries,
    required this.currency,
    required this.privacyMode,
  });

  final List<BudgetHeaderEntry> entries;
  final String currency;
  final bool privacyMode;

  @override
  State<_HeaderBudgetSwiper> createState() => _HeaderBudgetSwiperState();
}

class _HeaderBudgetSwiperState extends State<_HeaderBudgetSwiper> {
  late final PageController _ctrl;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
    _ctrl.addListener(() {
      final p = _ctrl.page?.round() ?? 0;
      if (p != _page) setState(() => _page = p);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiple = widget.entries.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 80,
          child: PageView.builder(
            controller: _ctrl,
            itemCount: widget.entries.length,
            itemBuilder: (context, index) => _BudgetBarPage(
              entry: widget.entries[index],
              privacyMode: widget.privacyMode,
            ),
          ),
        ),
        if (multiple) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.entries.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: _page == i ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _page == i
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _BudgetBarPage extends StatelessWidget {
  const _BudgetBarPage({required this.entry, required this.privacyMode});

  final BudgetHeaderEntry entry;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = entry.ratio.clamp(0.0, 1.0);
    final percent = (entry.ratio * 100).clamp(0, 999).round();
    final isOver = entry.ratio >= 1.0;
    final barColor = isOver ? c.danger : (entry.ratio > 0.8 ? c.accent : c.success);
    final periodLabel = switch (entry.period) {
      BudgetPeriod.daily => 'اليوم',
      BudgetPeriod.weekly => 'الأسبوع',
      BudgetPeriod.monthly => 'الشهر',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ميزانية $periodLabel · ${entry.label}',
                  style: AppTypography.caption(Colors.white70),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (entry.accountName != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    entry.accountName!,
                    style: AppTypography.caption(Colors.white60)
                        .copyWith(fontSize: 10),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                '$percent%',
                style: AppTypography.caption(barColor)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            privacyMode
                ? '•••• من ••••'
                : '${Formatters.amount(entry.spent)} من ${Formatters.amount(entry.limit)}',
            style: AppTypography.caption(Colors.white60),
          ),
        ],
      ),
    );
  }
}

// ─── Account Switcher ────────────────────────────────────────────────────────

/// مبدّل الحساب أعلى الـ Dashboard — «كل الحسابات» + شريحة لكل حساب بعملته.
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
        return SizedBox(
          height: 42,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _AccountChip(
                      label: 'كل الحسابات',
                      selected: selectedId == null,
                      onTap: () => ref
                          .read(dashboardAccountProvider.notifier)
                          .state = null,
                    ),
                    for (final account in accounts)
                      _AccountChip(
                        label:
                            '${account.name} · ${Currency.arabicLabel(account.currency)}',
                        selected: selectedId == account.id,
                        onTap: () => ref
                            .read(dashboardAccountProvider.notifier)
                            .state = account.id,
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
                      color: Colors.white.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                    ),
                    child: Icon(
                      AppLucideIcons.walletCards,
                      color: context.colors.accent,
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
            color: selected ? c.accent : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? c.accent : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppTypography.caption(
              selected ? Colors.black : Colors.white,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
