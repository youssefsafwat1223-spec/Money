import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/plan_entity.dart';
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
import '../budgets/budgets_providers.dart';
import '../cards/bank_mark.dart';
import '../cards/brand_mark.dart';
import '../cards/my_cards_screen.dart';
import '../capture/capture_entry_sheet.dart';
import '../common/category_avatar.dart';
import '../common/category_catalog.dart';
import '../common/motion.dart';
import '../common/transaction_direction.dart';
import '../common/premium_loading.dart';
import '../common/widgets.dart';
import '../common/app_card.dart';
import '../common/app_empty_state.dart';
import '../coupons/coupon_models.dart';
import '../coupons/coupon_widgets.dart';
import '../coupons/coupons_providers.dart';
import '../../core/security/app_lock_service.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_providers.dart';
import '../plans/plans_screen.dart';
import '../settings/settings_providers.dart';
import '../app/app_shell.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';
import 'home_sections_providers.dart';

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
                        // Account summary — compact snapshot only (balance,
                        // period income/expense, net). No proportion bar or
                        // other comparison visual — those live in Reports.
                        if (!data.isEmpty) ...[
                          PremiumMotion(
                            delay: const Duration(milliseconds: 50),
                            child: _financialOverviewCard(context, ref, data,
                                privacyMode: privacyMode),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                        ],
                        if (data.isEmpty)
                          _emptyState(context)
                        else ...[
                          // Smart Inbox — an actionable system state (needs
                          // review), not a reporting widget.
                          if (data.pendingReviewCount > 0) ...[
                            PremiumMotion(
                              child: _reviewCard(context, ref, data,
                                  privacyMode: privacyMode),
                            ),
                            const SizedBox(height: AppSpacing.s4),
                          ],
                          // 1. Daily Expenses
                          const PremiumMotion(
                            delay: Duration(milliseconds: 60),
                            child: _DailyExpensesSection(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          // 2. Coupons
                          const PremiumMotion(
                            delay: Duration(milliseconds: 70),
                            child: _DashboardCouponsRail(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          // 3. Monthly Expenses
                          const PremiumMotion(
                            delay: Duration(milliseconds: 75),
                            child: _MonthlyExpensesSection(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          // 4. Subscriptions
                          const PremiumMotion(
                            delay: Duration(milliseconds: 80),
                            child: _SubscriptionsSection(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          // 5. Goals
                          const PremiumMotion(
                            delay: Duration(milliseconds: 90),
                            child: _GoalsSection(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          // 6. Plans
                          const PremiumMotion(
                            delay: Duration(milliseconds: 95),
                            child: _PlansSection(),
                          ),
                          const SizedBox(height: AppSpacing.s4),
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

  /// Quick eye-icon toggle on the Account Summary card — flips the same
  /// `privacyModeEnabled` setting the Settings screen controls, so both
  /// stay in sync instead of introducing a separate Home-only flag.
  Future<void> _togglePrivacyMode(WidgetRef ref, bool current) async {
    HapticFeedback.selectionClick();
    final settings = ref.read(userSettingsProvider).valueOrNull;
    if (settings == null) return;
    await ref
        .read(userSettingsRepositoryProvider)
        .saveSettings(settings.copyWith(privacyModeEnabled: !current));
    refreshUserSettings(ref);
    ref.invalidate(dashboardDataProvider);
  }

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

    return AppCard(
      color: c.cta,
      border: Border.all(color: onCta.withValues(alpha: 0.12)),
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(isPositive ? 'صافي وفّرته' : 'صافي تجاوزته',
                    style:
                        AppTypography.caption(onCta.withValues(alpha: 0.75))),
              ),
              Text(_rangeLabel(data.range, context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(onCta.withValues(alpha: 0.55))),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(netText,
                      style: AppTypography.title1(netTone)
                          .copyWith(fontWeight: FontWeight.w800),
                      textDirection: TextDirection.ltr),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () => _togglePrivacyMode(ref, privacyMode),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    privacyMode
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                    color: onCta.withValues(alpha: 0.75),
                  ),
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
                  title: 'الدخل',
                  value: _money(data.rangeIncome, data.currency,
                      privacyMode: privacyMode),
                  tone: c.success,
                  darkBg: isCtaDark,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: _snapshotMetric(
                  context,
                  title: 'المصروفات',
                  value: _money(data.rangeExpense, data.currency,
                      privacyMode: privacyMode),
                  tone: c.danger,
                  darkBg: isCtaDark,
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

  Widget _snapshotMetric(
    BuildContext context, {
    required String title,
    required String value,
    required Color tone,
    bool darkBg = false,
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
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s2, vertical: AppSpacing.s2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.caption(
                darkBg ? Colors.white.withValues(alpha: 0.70) : c.textLight),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              maxLines: 1,
              style: AppTypography.subhead(displayTone)
                  .copyWith(fontWeight: FontWeight.w800),
            ),
          ),
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
}

// ─── Operational Home Sections ───────────────────────────────────────────────

class _DailyExpensesSection extends ConsumerWidget {
  const _DailyExpensesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(todayExpensesProvider);
    final budgetsAsync = ref.watch(budgetsViewProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const _SectionErrorCard(title: 'مصروفات اليوم'),
      data: (transactions) {
        return _HomeSectionCard(
          title: 'مصروفات اليوم',
          subtitle: 'آخر العمليات اللي حصلت النهارده',
          actionLabel: 'عرض الكل',
          onAction: () => ref.read(shellIndexProvider.notifier).state = 1,
          emptyTitle: 'لا توجد مصروفات اليوم',
          emptyBody: 'أول عملية هتظهر هنا فور تسجيلها',
          isEmpty: transactions.isEmpty,
          children: [
            for (final tx in transactions.take(3))
              _DailyExpenseTile(
                transaction: tx,
                budget: budgetsAsync.valueOrNull == null
                    ? null
                    : matchBudgetForCategory(
                        budgetsAsync.valueOrNull!.snapshot,
                        tx.categoryId,
                      ),
              ),
          ],
        );
      },
    );
  }
}

class _DailyExpenseTile extends ConsumerWidget {
  const _DailyExpenseTile({required this.transaction, required this.budget});

  final TransactionEntity transaction;
  final BudgetProgressEntry? budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final category = catalog?.byId(transaction.categoryId);
    final c = context.colors;
    final title = transaction.rawMerchant?.trim().isNotEmpty == true
        ? transaction.rawMerchant!.trim()
        : category?.nameAr ?? 'مصروف';

    final merchantName = transaction.rawMerchant;

    final bool isOverBudget = budget != null && budget!.remaining < 0;
    final String? budgetText = budget == null
        ? null
        : (isOverBudget
            ? 'تجاوزت بـ ${_plainMoney(budget!.remaining.abs(), transaction.currency)}'
            : 'متبقي ${_plainMoney(budget!.remaining, transaction.currency)}');

    // Compact 2-line row (~60-72px): line 1 is merchant + amount, line 2 is
    // category/time + remaining budget — everything the spec asks for
    // without a per-row progress bar or a 3-line leading text stack.
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () =>
                TransactionDetailsScreen.showSheet(context, transaction.id),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.s2, horizontal: AppSpacing.s1),
              child: Row(
                children: [
                  merchantName != null && BrandMark.hasBrand(merchantName)
                      ? BrandMark(name: merchantName, size: 36)
                      : CategoryAvatar(
                          merchantName: merchantName,
                          category: category,
                          size: 36,
                        ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.bodyStrong(c.textMain),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s2),
                            _SignedAmount(
                              amount: transaction.amount,
                              currency: transaction.currency,
                              color: c.expense,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${category?.nameAr ?? 'غير مصنفة'} • ${Formatters.time(transaction.occurredAt)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.caption(c.textMuted),
                              ),
                            ),
                            if (budgetText != null) ...[
                              const SizedBox(width: AppSpacing.s2),
                              Text(
                                budgetText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.caption(
                                  isOverBudget ? c.danger : c.success,
                                ).copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Divider(color: c.border.withValues(alpha: 0.5), height: 1),
      ],
    );
  }
}

class _MonthlyExpensesSection extends ConsumerWidget {
  const _MonthlyExpensesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(monthlyExpenseGroupsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const _SectionErrorCard(title: 'مصروفات الشهر'),
      data: (groups) => _HomeSectionCard(
        title: 'مصروفات الشهر',
        subtitle: 'مجمعة حسب التصنيف، بدون رسوم بيانية',
        actionLabel: 'عرض الكل',
        onAction: () => ref.read(shellIndexProvider.notifier).state = 1,
        emptyTitle: 'لا توجد مصروفات مسجلة هذا الشهر',
        isEmpty: groups.isEmpty,
        children: [
          for (final group in groups.take(4))
            _MonthlyCategoryTile(group: group),
        ],
      ),
    );
  }
}

/// Category row for the Monthly Expenses accordion — collapsed by default
/// (icon, category, total, remaining budget in one ~60px row); the
/// transaction preview only renders once tapped open, which is what keeps
/// this section from dominating the whole Home scroll.
class _MonthlyCategoryTile extends ConsumerStatefulWidget {
  const _MonthlyCategoryTile({required this.group});

  final MonthlyCategoryGroup group;

  @override
  ConsumerState<_MonthlyCategoryTile> createState() =>
      _MonthlyCategoryTileState();
}

class _MonthlyCategoryTileState extends ConsumerState<_MonthlyCategoryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final category = catalog?.byId(group.categoryId);
    final txPreview = group.transactions.take(3).toList(growable: false);
    final currency = txPreview.isEmpty ? 'SAR' : txPreview.first.currency;
    final c = context.colors;
    final isOverBudget = group.budget != null && group.budget!.remaining < 0;
    final subtitle = group.budget != null
        ? budgetContextText(group.budget,
            categoryName: category?.nameAr, currency: currency)
        : 'إجمالي هذا الشهر';

    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.s2, horizontal: AppSpacing.s1),
              child: Row(
                children: [
                  CategoryAvatar(category: category, size: 36),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(category?.nameAr ?? 'غير مصنفة',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.bodyStrong(c.textMain)),
                            ),
                            const SizedBox(width: AppSpacing.s2),
                            Text(_plainMoney(group.total, currency),
                                style: AppTypography.bodyStrong(c.textMain)
                                    .copyWith(fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption(
                            group.budget != null
                                ? (isOverBudget ? c.danger : c.success)
                                : c.textMuted,
                          ).copyWith(
                              fontWeight: group.budget != null
                                  ? FontWeight.w700
                                  : FontWeight.w400),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(Icons.keyboard_arrow_down_rounded,
                        size: 20, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                51, 0, AppSpacing.s1, AppSpacing.s2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final tx in txPreview)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tx.rawMerchant ?? 'عملية',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textMain),
                          ),
                        ),
                        Text(_plainMoney(tx.amount, tx.currency),
                            style: AppTypography.caption(c.textSecondary)
                                .copyWith(fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () =>
                      ref.read(shellIndexProvider.notifier).state = 1,
                  child: Text('عرض كل عمليات الفئة',
                      style: AppTypography.caption(c.cta)
                          .copyWith(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        Divider(color: c.border.withValues(alpha: 0.5), height: 1),
      ],
    );
  }
}

class _SubscriptionsSection extends ConsumerWidget {
  const _SubscriptionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeSubscriptionsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const _SectionErrorCard(title: 'الاشتراكات'),
      data: (subscriptions) => _HomeSectionCard(
        title: 'الاشتراكات',
        subtitle: 'أقرب مدفوعات جاية',
        actionLabel: 'عرض الكل',
        onAction: () => context.push('/subscriptions'),
        emptyTitle: 'لا توجد اشتراكات مضافة',
        isEmpty: subscriptions.isEmpty,
        noCard: true,
        children: [
          if (subscriptions.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pagePadding, vertical: 4),
              child: Row(
                children: [
                  for (int i = 0; i < subscriptions.take(3).length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s3),
                    SizedBox(
                      width: 155,
                      child: _SubscriptionCard(bill: subscriptions[i]),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.bill});

  final BillEntity bill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final days = bill.nextDueDate
        .difference(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day))
        .inDays;
    final due = days < 0
        ? 'متأخر ${days.abs()} يوم'
        : days == 0
            ? 'مستحق اليوم'
            : 'متبقي $days يوم';
    final warningColor = days <= 2 ? c.warning : c.success;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s3),
      color: c.surfaceCard,
      border: Border.all(color: c.border.withValues(alpha: 0.15)),
      onTap: () => context.push('/subscriptions'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              BrandMark(name: bill.name, size: 32),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bill.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodyStrong(c.textMain),
                    ),
                    Text(
                      '${Formatters.amount(bill.amount)} ${bill.currency}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textSecondary)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: Text(
                  Formatters.dateGroupLabel(bill.nextDueDate, context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(c.textMuted),
                ),
              ),
              Text(
                due,
                maxLines: 1,
                style: AppTypography.caption(warningColor)
                    .copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GoalsSection extends ConsumerWidget {
  const _GoalsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeGoalsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const _SectionErrorCard(title: 'الأهداف'),
      data: (goals) => _HomeSectionCard(
        title: 'الأهداف',
        subtitle: 'أقرب أهداف محتاجة متابعة',
        actionLabel: 'عرض كل الأهداف',
        onAction: () => context.push('/goals'),
        emptyTitle: 'ابدأ أول هدف مالي ليك',
        isEmpty: goals.isEmpty,
        noCard: true,
        children: [
          if (goals.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pagePadding, vertical: 4),
              child: Row(
                children: [
                  for (int i = 0; i < goals.take(3).length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s3),
                    SizedBox(
                      width: 170,
                      child: _GoalTile(goal: goals[i]),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal});

  final GoalEntity goal;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = goal.targetAmount <= 0
        ? 0.0
        : (goal.savedAmount / goal.targetAmount).clamp(0.0, 1.0);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s3),
      color: c.surfaceCard,
      border: Border.all(color: c.border.withValues(alpha: 0.15)),
      onTap: () => context.push('/goals/${goal.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(goal.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(c.textMain)),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text('${(ratio * 100).round()}%',
                  style: AppTypography.caption(c.accent)
                      .copyWith(fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '${_plainMoney(goal.savedAmount, '')} / ${_plainMoney(goal.targetAmount, '')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _PlansSection extends ConsumerWidget {
  const _PlansSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homePlansProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const _SectionErrorCard(title: 'الخطط'),
      data: (plans) => _HomeSectionCard(
        title: 'الخطط',
        subtitle: 'ميزانيات السفر والمناسبات النشطة',
        actionLabel: 'عرض كل الخطط',
        onAction: () => PlansScreen.open(context),
        emptyTitle: 'لا توجد خطط مالية نشطة',
        isEmpty: plans.isEmpty,
        noCard: true,
        children: [
          if (plans.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pagePadding, vertical: 4),
              child: Row(
                children: [
                  for (int i = 0; i < plans.take(3).length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s3),
                    SizedBox(
                      width: 175,
                      child: _PlanCard(progress: plans[i]),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.progress});

  final PlanProgress progress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final plan = progress.plan;
    final ratio = progress.ratio.clamp(0.0, 1.0);
    final isOver = progress.isOver;
    final tone = isOver ? c.danger : c.primary;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s3),
      color: c.surfaceCard,
      border: Border.all(color: c.border.withValues(alpha: 0.15)),
      onTap: () => PlansScreen.open(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyStrong(c.textMain),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text('${(progress.ratio * 100).round()}%',
                  style: AppTypography.caption(tone)
                      .copyWith(fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            plan.status == PlanStatus.active ? 'نشطة' : 'مغلقة',
            style: AppTypography.caption(
              plan.status == PlanStatus.active ? c.success : c.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(tone),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'ينتهي ${Formatters.dateGroupLabel(plan.endDate, context)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _HomeSectionCard extends StatelessWidget {
  const _HomeSectionCard({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
    required this.emptyTitle,
    required this.isEmpty,
    required this.children,
    this.emptyBody,
    this.noCard = false,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;
  final String emptyTitle;
  final String? emptyBody;
  final bool isEmpty;
  final List<Widget> children;
  final bool noCard;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // A slimmer, single-row header than the shared [SectionHeader] — that
    // widget bakes in its own AppSpacing.gutter horizontal padding, which
    // double-counted against this wrapper's own padding and made every
    // section header taller and more indented than the content below it.
    final horizontalPad = noCard ? AppSpacing.pagePadding : 0.0;
    final header = Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.headline(c.textPrimary)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: onAction,
            child: Text(
              actionLabel,
              style: AppTypography.caption(c.cta)
                  .copyWith(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: AppSpacing.s2),
        if (isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPad),
            child: SizedBox(
              width: double.infinity,
              child: AppEmptyState(
                icon: AppLucideIcons.receipt,
                title: emptyTitle,
                subtitle: emptyBody ?? '',
              ),
            ),
          )
        else
          ...children,
      ],
    );

    if (noCard) {
      return content;
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: content,
    );
  }
}

class _SectionErrorCard extends StatelessWidget {
  const _SectionErrorCard({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => AppCard(
        child: AppErrorState(
          title: 'تعذر تحميل $title',
          description: 'سيتم المحاولة مرة أخرى مع التحديث التالي.',
        ),
      );
}

class _SignedAmount extends StatelessWidget {
  const _SignedAmount({
    required this.amount,
    required this.currency,
    required this.color,
  });

  final double amount;
  final String currency;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
        '-${_plainMoney(amount, currency)}',
        textDirection: TextDirection.ltr,
        style: AppTypography.bodyStrong(color)
            .copyWith(fontWeight: FontWeight.w900),
      );
}

String _plainMoney(double amount, String currency) {
  final suffix = currency.trim().isEmpty
      ? ''
      : ' ${Currency.arabicLabel(currency.toUpperCase())}';
  return '${Formatters.amount(amount)}$suffix';
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
                message: 'بطاقاتي',
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    MyCardsScreen.open(context);
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
                      Icons.credit_card,
                      color: context.colors.cta,
                      size: 18,
                    ),
                  ),
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
        final c = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pagePadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('كوبونات توفر عليك',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.headline(c.textPrimary)
                                .copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 1),
                        Text('عروض شركاء مناسبة لمصروفاتك',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => context.push('/coupons'),
                    child: Text(
                      'عرض الكل',
                      style: AppTypography.caption(c.cta)
                          .copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            if (offers.isEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                child: Text('لا توجد كوبونات متاحة حاليًا',
                    style: AppTypography.caption(c.textMuted)),
              )
            else
              SizedBox(
                height: 112,
                child: ListView.separated(
                  clipBehavior: Clip.none,
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                  itemCount: offers.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.s3),
                  itemBuilder: (context, index) =>
                      _HomeCouponCard(offer: offers[index]),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Compact coupon card for the Home carousel — brand + title + code/expiry
/// only, ~100-120px tall. The full [CouponCard] (used on the dedicated
/// Coupons screen) shows a description and is intentionally taller.
class _HomeCouponCard extends StatelessWidget {
  const _HomeCouponCard({required this.offer});

  final CouponOffer offer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showCouponDetailsSheet(context, offer),
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(AppSpacing.s3),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  BrandMark(name: offer.partnerName, size: 36),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(offer.partnerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textMuted)
                                .copyWith(fontWeight: FontWeight.w700)),
                        Text(offer.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyStrong(c.textPrimary)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s2, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.ctaSoft,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(offer.code,
                        style: AppTypography.caption(c.cta)
                            .copyWith(fontWeight: FontWeight.w800)),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      Formatters.dateGroupLabel(offer.validUntil, context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
