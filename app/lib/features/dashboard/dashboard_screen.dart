import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/mali_tokens.dart';
import '../../core/theme/widgets/attention_card.dart';
import '../../core/theme/widgets/glass_selector.dart';
import '../../core/theme/widgets/insight_card.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/mali_screen.dart';
import '../../core/theme/widgets/liquid_bar.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../../core/theme/widgets/section_header.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/daily_allowance.dart';
import '../../domain/finance/goal_pacing.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/hero_amount_size.dart';
import '../../domain/finance/money_format.dart';
import '../../core/security/app_lock_service.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../app/app_shell.dart';
import '../coupons/coupon_widgets.dart';
import '../coupons/coupons_providers.dart';
import '../goals/goals_providers.dart';
import '../plans/plan_form_sheet.dart';
import '../plans/plans_providers.dart';
import '../plans/plans_screen.dart';
import '../common/app_empty_state.dart';
import '../common/premium_loading.dart';
// hide SectionHeader — we use the Calm Capital archetype of the same name.
import '../common/widgets.dart' hide SectionHeader;
import '../settings/settings_providers.dart';
import '../capture/capture_entry_sheet.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';
import 'home_sections_providers.dart';
import 'widgets/budgets_card.dart';
import 'widgets/coupons_corner.dart';
import 'widgets/daily_spend_card.dart';
import 'widgets/monthly_spend_card.dart';
import 'widgets/obligations_card.dart';
import 'widgets/transactions_panel.dart';

/// Home — the Calm Capital flagship dashboard (docs/MALI_DESIGN_SYSTEM.md).
///
/// Rebuilt from scratch: the whole screen is composed from the archetype
/// primitives over a single read-only source, [dashboardDataProvider]. No sync,
/// DB, or parser behavior lives here — this is presentation only.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    // valueOrNull (not maybeWhen) so privacyMode holds through a reload instead
    // of flashing hidden→shown on every account switch / sync.
    final privacyMode = settings?.privacyModeEnabled ?? false;

    return MaliScreen(
      padding: EdgeInsets.zero,
      safeArea: false,
      // الهيرو الأزرق هو مصدر اللون في الصفحة دي — من غير هالة زرقا كمان
      // في الخلفية ورا المحتوى.
      ambient: false,
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardDataProvider),
        child: async.when(
          skipLoadingOnReload: true,
          loading: () => const SkeletonList(rows: 5, withHero: true),
          error: (error, stack) {
            // الرسالة العامة بتخفي السبب — نطبعه في الديباج عشان يتشاف في
            // الكونسول بدل ما نخمّن.
            assert(() {
              debugPrint('[dashboard] load failed: $error\n$stack');
              return true;
            }());
            if (error is AuthRepoException) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                AppSession.instance.handleAuthRequiredFailure();
              });
              return _errorList(
                title: context.l10n.homeSessionExpiredTitle,
                description: context.l10n.homeSessionExpiredBody,
                retryLabel: context.l10n.homeSignIn,
                onRetry: () => AppSession.instance.handleAuthRequiredFailure(),
              );
            }
            return _errorList(
              title: context.l10n.homeLoadFailed,
              description: context.l10n.homeLoadFailedBody,
              retryLabel: context.l10n.annRetry,
              onRetry: () => ref.invalidate(dashboardDataProvider),
            );
          },
          data: (data) => _HomeBody(
            data: data,
            displayName: settings?.displayName,
            avatarPath: settings?.avatarPath,
            privacyMode: privacyMode,
          ),
        ),
      ),
    );
  }

  Widget _errorList({
    required String title,
    required String description,
    required String retryLabel,
    required VoidCallback onRetry,
  }) =>
      ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          const SizedBox(height: AppSpacing.s7),
          AppErrorState(
            title: title,
            description: description,
            retryLabel: retryLabel,
            onRetry: onRetry,
          ),
        ],
      );
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({
    required this.data,
    required this.displayName,
    required this.avatarPath,
    required this.privacyMode,
  });

  final DashboardData data;
  final String? displayName;
  final String? avatarPath;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Calm Capital "split" layout: a fixed blue summary zone (balance + today's
    // pulse) with the scrollable content sheet sliding up over it.
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _BlueZone(
          data: data,
          displayName: displayName,
          avatarPath: avatarPath,
          privacyMode: privacyMode,
        ),
        _Sheet(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _filters(context, ref),
              const SizedBox(height: AppSpacing.s4),
              const AnnouncementBanner(),
              const _SetupNudgeCard(),
              // The ledger-shaped sections go quiet when the period has no
              // rows; everything the user OWNS — budgets, subscriptions,
              // goals, plans — keeps rendering.
              //
              // This used to be one `data.isEmpty` gate around the whole body,
              // so a range with no transactions hid the budgets the user set,
              // the subscriptions they are still paying, and the goals they are
              // still saving for. Those facts are not a function of the
              // selected period, and hiding them read as the app losing data.
              if (data.isEmpty)
                _empty(context)
              else ...[
                const SizedBox(height: AppSpacing.s4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SectionHeader(title: context.l10n.homeDailySpend),
                ),
                const SizedBox(height: AppSpacing.s3),
                _dailySpend(context, ref),
                const SizedBox(height: AppSpacing.s4),
                _afterHero(context, ref),
                _TransactionsSection(data: data, privacyMode: privacyMode),
                const SizedBox(height: AppSpacing.s6),
                _MonthlySection(data: data, privacyMode: privacyMode),
              ],
              // THE BANNER — after the first content block, whether that block
              // is the ledger sections or the empty-state card.
              //
              // It used to be a direct sibling of `_Sheet` at the very foot of
              // the page, for sliver laziness: the slot was far below the fold
              // and materialising it early would have requested an ad the user
              // might never reach. Here it is deliberately inside the sheet and
              // therefore built with it — which is correct now that the slot is
              // in the upper-middle of the page and visible on arrival. Laziness
              // only ever mattered because the old position was unreachable.
              const SizedBox(height: AppSpacing.s6),
              // NO horizontal padding here. `_Sheet` already insets its child by
              // `AppSpacing.gutter` on both sides, so wrapping the banner in
              // another gutter made the slot 310pt on a 390pt screen — under the
              // 320 minimum `BannerAdController.request()` enforces, which
              // refused the request before `resolveHeight` and left the slot at
              // zero height. The banner inherits the sheet's inset instead.
              const QirshAdBanner(placement: AdPlacement.dashboard),
              // UX-010 — a section with nothing in it still renders its header
              // and says which of the two it is, rather than vanishing.
              const SizedBox(height: AppSpacing.s6),
              _BudgetsSection(data: data, privacyMode: privacyMode),
              const SizedBox(height: AppSpacing.s6),
              _SubscriptionSection(privacyMode: privacyMode),
              const SizedBox(height: AppSpacing.s6),
              _GoalSection(goal: data.activeGoal, privacyMode: privacyMode),
              const SizedBox(height: AppSpacing.s6),
              const _PlansSection(),
              const SizedBox(height: AppSpacing.s6),
              const _DashboardCouponsRail(),
              const SizedBox(height: AppSpacing.s6),
            ],
          ),
        ),
        // The nav-bar clearance that used to close `_Sheet`. Moved out so it
        // sits BELOW the banner — an ad the floating bar covers is an obscured
        // ad.
        const SizedBox(height: 112),
      ],
    );
  }

  // ── Filters (range + account) ──────────────────────────────────────────────

  Widget _filters(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).valueOrNull;
    final selectedId = ref.watch(dashboardAccountProvider);
    final String accountLabel;
    if (accounts == null || accounts.isEmpty) {
      accountLabel = context.l10n.homeAllAccounts;
    } else {
      final selected = accounts.firstWhere(
        (a) => a.id == selectedId,
        orElse: () => accounts.firstWhere((a) => a.isDefault,
            orElse: () => accounts.first),
      );
      // UX-007 — name the account, do not describe its currency.
      //
      // This read «حساب ريال» for every riyal account, so switching الراجحي →
      // مدى changed every headline figure on Home (2,120.00 → 2,736.05) while
      // the chip said the same thing. The user could not tell what the numbers
      // referred to. The QA classed it an INFORMATION gap, not styling.
      //
      // The currency stays as secondary context because Home totals are
      // per-currency and the two accounts may differ.
      accountLabel =
          '${selected.name} · ${_currencyLabel(context, selected.currency)}';
    }
    return Row(
      children: [
        Expanded(
          child: GlassSelector(
            icon: AppLucideIcons.calendarDays,
            label: data.range.labelIn(Localizations.localeOf(context).languageCode),
            onTap: () => _showRangeSheet(context, ref, data.range),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: GlassSelector(
            icon: AppLucideIcons.wallet,
            label: accountLabel,
            onTap: () {
              HapticFeedback.selectionClick();
              context.push('/accounts');
            },
          ),
        ),
      ],
    );
  }

  // ── «المصروفات اليومية» ────────────────────────────────────────────────────

  Widget _dailySpend(BuildContext context, WidgetRef ref) {
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};
    return DailySpendCard(
      todaySpend: data.todaySpend,
      lastSevenDays: data.lastSevenDays,
      averageSevenDays: averageDailySpend(data.lastSevenDays, data.currency),
      availableToday: data.availableToday,
      todayVsYesterday: data.todayVsYesterday,
      todayTransactions: data.todayTransactions,
      todayIsTruncated: data.todayIsTruncated,
      catalog: data.catalog,
      currencyLabel: Currency.label(context, data.currency.toUpperCase()),
      privacyMode: privacyMode,
      merchantLogos: logos,
      onTransactionTap: (tx) =>
          TransactionDetailsScreen.showSheet(context, tx.id),
    );
  }

  // ── Below-hero context cards (attention + safe-to-spend + insight) ─────────
  // The balance + today's pulse now live in the blue zone ([_BlueZone]); these
  // supporting cards sit at the top of the content sheet.

  Widget _afterHero(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final ratio = data.weekChangeRatio;
    final spentMore = ratio > 0.001;
    final trendText = (ratio.abs() > 0.001)
        ? context.l10n.homeVsLastWeek((ratio.abs() * 100).round())
        : null;

    final hasBudget =
        !data.monthlyBudgetLimit.isZero && !data.monthlyBudgetLimit.isNegative;
    final remaining =
        hasBudget ? (1 - data.monthlyBudgetRatio).clamp(0.0, 1.0) : null;
    final over = hasBudget && data.monthlyBudgetRatio >= 1.0;
    final tight = hasBudget && data.monthlyBudgetRatio >= 0.8;
    final verdict = !hasBudget
        ? context.l10n.homeSetMonthlyBudget
        : over
            ? context.l10n.homeOverMonthBudget
            : tight
                ? context.l10n.homeSpendAboveUsual
                : context.l10n.homeSteady;
    final ringColor = over ? c.danger : (tight ? c.warning : c.income);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.pendingReviewCount > 0) ...[
          AttentionCard(
            icon: AppLucideIcons.inbox,
            title:
                context.l10n.homePendingReviewTitle(data.pendingReviewCount),
            subtitle: context.l10n.homeReviewToStayAccurate,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(shellIndexProvider.notifier).state = 1;
              ref.read(transactionsPendingFilterProvider.notifier).state = true;
            },
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        // Compact "safe to spend" — a thin raised bar (not a floating card).
        // Hierarchy: small contextual label → main status → ring indicator.
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3, vertical: 10),
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: t.cardBorder),
          ),
          child: Row(
            children: [
              RingProgress(
                value: remaining,
                size: 36,
                strokeWidth: 4,
                color: ringColor,
                child: Text(
                  remaining == null ? '—' : '${(remaining * 100).round()}%',
                  style: AppTypography.micro(t.textOnCanvasPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n.homeAvailableFromMonthBudget,
                        style: AppTypography.caption(t.textOnCanvasMuted)),
                    const SizedBox(height: 2),
                    Text(verdict,
                        style: AppTypography.subhead(
                            !hasBudget ? c.textMuted : ringColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (trendText != null) ...[
          const SizedBox(height: AppSpacing.s4),
          InsightCard(
            label: context.l10n.rptWeekSummary,
            message: spentMore
                ? context.l10n.homeWeekSpentMore((ratio.abs() * 100).round())
                : context.l10n.homeWeekSpentLess((ratio.abs() * 100).round()),
          ),
        ],
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s5),
        child: AppEmptyState(
          icon: AppLucideIcons.receipt,
          title: context.l10n.homeNoTxTitle,
          subtitle:
              context.l10n.homeNoTxBody,
        ),
      );

  String _currencyLabel(BuildContext context, String currency) =>
      Currency.label(context, currency.toUpperCase());

  // ── Range sheet (preserved from the previous screen) ───────────────────────

  Future<void> _showRangeSheet(
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
            title: context.l10n.txnPickRange,
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
                          label: Text(_presetLabel(context, preset)),
                          selected: current.preset == preset,
                          onSelected: (_) {
                            if (preset == TransactionsDatePreset.custom) {
                              setState(() {});
                              return;
                            }
                            ref
                                .read(transactionsDateRangeProvider.notifier)
                                .state = transactionsRangeForPreset(
                              preset,
                              customFallback: defaultTransactionsRange(),
                            );
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
                            title: Text(context.l10n.txnFrom),
                            subtitle: Text(Formatters.fullDate(from, context)),
                            trailing: const Icon(AppLucideIcons.calendarDays),
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
                            title: Text(context.l10n.txnTo),
                            subtitle: Text(Formatters.fullDate(to, context)),
                            trailing: const Icon(AppLucideIcons.calendarDays),
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
                        to: DateTime(to.year, to.month, to.day, 23, 59, 59),
                      );
                      Navigator.of(context).pop();
                    },
              child: Text(context.l10n.txnApplyCustomRange),
            ),
          );
        },
      )),
    );
  }

  String _presetLabel(BuildContext context, TransactionsDatePreset preset) =>
      switch (preset) {
        TransactionsDatePreset.today => context.l10n.txnRangeToday,
        TransactionsDatePreset.thisWeek => context.l10n.txnRangeThisWeek,
        TransactionsDatePreset.thisMonth => context.l10n.txnRangeThisMonth,
        TransactionsDatePreset.previousMonth => context.l10n.txnRangeLastMonth,
        TransactionsDatePreset.last7Days => context.l10n.txnRange7,
        TransactionsDatePreset.last30Days => context.l10n.txnRange30,
        TransactionsDatePreset.last90Days => context.l10n.txnRange90,
        TransactionsDatePreset.thisYear => context.l10n.txnRangeThisYear,
        TransactionsDatePreset.previousYear => context.l10n.txnRangeLastYear,
        TransactionsDatePreset.custom => context.l10n.txnRangeCustom,
      };
}

// ─── Blue summary zone (balance + today's pulse) ──────────────────────────────

/// The fixed blue hero at the top of Home: greeting, total-expense balance,
/// and today's pulse — white content on a mode-aware blue gradient. The content
/// sheet ([_Sheet]) slides up over its bottom edge.
class _BlueZone extends ConsumerWidget {
  const _BlueZone({
    required this.data,
    required this.privacyMode,
    this.displayName,
    this.avatarPath,
  });

  final DashboardData data;
  final bool privacyMode;
  final String? displayName;
  final String? avatarPath;

  static const _income = Color(0xFF4ADE80);
  static const _expenseNet = Color(0xFFFCA5A5);

  String _name(BuildContext context) {
    final n = displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final email = AppSession.instance.email;
    if (email == null || email.trim().isEmpty) return context.l10n.homeMoneyFriend;
    final local = email.split('@').first.trim();
    if (local.isEmpty || local.toLowerCase() == 'user') return context.l10n.homeMoneyFriend;
    return local.replaceAll(RegExp(r'[._]'), ' ');
  }

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'م';
    if (parts.length == 1) return parts.first.characters.first;
    return '${parts.first.characters.first}${parts[1].characters.first}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPad = MediaQuery.paddingOf(context).top;
    final name = _name(context);
    final path = avatarPath?.trim();
    final file = (path == null || path.isEmpty) ? null : File(path);
    final hasImage = file != null && file.existsSync();

    final period = ref.watch(heroPeriodProvider);
    final heroValue = switch (period) {
      HeroPeriod.day => data.todaySpend,
      HeroPeriod.week => data.weekSpend,
      HeroPeriod.month => data.spentThisMonth,
    };
    final heroLabel = switch (period) {
      HeroPeriod.day => context.l10n.homeTodaySpend,
      HeroPeriod.week => context.l10n.homeWeekSpend,
      HeroPeriod.month => context.l10n.homeMonthSpend,
    };
    // The comparison shown is the one that period actually HAS. There is no
    // calendar month-over-month aggregate on this provider — `savedThisMonth`
    // compares against a window that follows the range filter, not the previous
    // month — so the month tab shows no trend rather than a wrong one.
    final ratio = switch (period) {
      HeroPeriod.day => data.todayVsYesterday,
      HeroPeriod.week => data.weekChangeRatio,
      HeroPeriod.month => null,
    };
    final trendSuffix =
        period == HeroPeriod.day ? context.l10n.homeVsYesterday : context.l10n.homeVsLastWeekShort;
    final hasTrend = ratio != null && ratio.abs() > 0.001;
    final todayNet = data.todayIncome - data.todaySpend;
    String signed(Money value) =>
        '${value.isNegative ? '−' : '+'}${Formatters.amount((value.isNegative ? -value : value).toDouble())}';
    final currencyLabel = Currency.label(context, data.currency.toUpperCase());

    final meltBg = _sheetBg(context);
    // الأزرق بيكمّل تحت حدود الهيرو (بيترسم قبل الشيت فبيفضل وراه): الذوبان
    // بيحصل خلف أول كروت الصفحة لحد نص الشاشة تقريبًا، من غير شريط أزرق فاضي.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: -_heroMeltOverflow,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                stops: const [0.0, 0.55, 1.0],
                // أزرق اللوجو (#021B79) هو اللون الأساسي للهيرو.
                colors: AppBrandBlue.headerStops(isDark),
              ),
            ),
            // الميلت: الأزرق بيدوب رأسيًا في خلفية المحتوى بدل ما الشيت يقطعه
            // بحافة — نفس لغة الموكب («الهيدر سايح على تحت»).
            foregroundDecoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.55, 1.0],
                colors: [
                  meltBg.withValues(alpha: 0),
                  meltBg.withValues(alpha: 0),
                  meltBg,
                ],
              ),
            ),
            // Depth pass (static, reduce-motion safe): a soft ambient light
            // from the top corner and a gentle darkening downward — the hero
            // reads dimensional instead of flat, with no texture noise.
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.95, -1.1),
                  radius: 1.35,
                  colors: [
                    Colors.white.withValues(alpha: isDark ? 0.09 : 0.16),
                    Colors.white.withValues(alpha: 0),
                    const Color(0xFF06122E)
                        .withValues(alpha: isDark ? 0.30 : 0.12),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, topPad + 12, 20, AppSpacing.s5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: AppSpacing.avatar,
                    height: AppSpacing.avatar,
                    alignment: Alignment.center,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22)),
                    ),
                    child: hasImage
                        ? Image.file(file, fit: BoxFit.cover)
                        : Text(_initials(name),
                            style: AppTypography.subhead(Colors.white)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.l10n.homeGreeting,
                            style: AppTypography.footnote(
                                Colors.white.withValues(alpha: 0.75))),
                        const SizedBox(height: 2),
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.cardTitle(Colors.white)),
                      ],
                    ),
                  ),
                  // UX-008 — «عايز أحط الأيقونة بتاعة التطبيق من فوق كده خالص…
                  // زي باقي التطبيقات». Home was the one screen that never
                  // presented the product's identity: the empty space between
                  // the greeting and the «+» button is exactly the area the
                  // owner pointed at.
                  //
                  // The gold coin is used on the navy hero, not the blue one:
                  // `getCoin` picks by THEME brightness, and this surface is
                  // dark in both themes, so the light-theme blue coin would
                  // disappear into it. `excludeFromSemantics` because the mark
                  // is decorative — announcing "Qirsh logo" before the
                  // greeting would put branding ahead of content for a screen
                  // reader.
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Image.asset(
                      AppAssets.qirshCoinGold,
                      width: 26,
                      height: 26,
                      excludeFromSemantics: true,
                    ),
                  ),
                  const _AddButton(),
                ],
              ),
              const SizedBox(height: 16),
              _PeriodSegments(
                selected: period,
                onSelect: (value) =>
                    ref.read(heroPeriodProvider.notifier).state = value,
              ),
              const SizedBox(height: 14),
              // Financial hierarchy: label → amount (the clear focus) → trend.
              Row(
                children: [
                  Text(heroLabel,
                      style: AppTypography.caption(
                          Colors.white.withValues(alpha: 0.75))),
                  const SizedBox(width: 6),
                  _eye(context, ref),
                ],
              ),
              const SizedBox(height: 4),
              Builder(builder: (context) {
                // R-8 — the largest, most-checked figure in the app was
                // formatted through a double at a hardcoded two decimals.
                final heroText =
                    privacyMode ? '••••••' : formatMoney(heroValue);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      // FittedBox: at large text scales the full value scales
                      // down to fit — a financial figure is never truncated.
                      // UX-035: it now scales down FROM a size already chosen
                      // for the value's length, so a long figure starts legible
                      // instead of shrinking continuously toward «0 0 0».
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          heroText,
                          maxLines: 1,
                          style: AppTypography.amountHero(Colors.white).copyWith(
                            fontSize: heroAmountFontSize(heroText.length),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(currencyLabel,
                          style: AppTypography.footnote(
                              Colors.white.withValues(alpha: 0.72))),
                    ),
                  ],
                );
              }),
              if (hasTrend) ...[
                const SizedBox(height: 9),
                _trendChip(ratio, trendSuffix),
              ],
              const SizedBox(height: 14),
              // Today's pulse — restrained glass chrome on the hero: translucent
              // fill + hairline rim + top sheen. No BackdropFilter on purpose:
              // blurring the flat gradient behind it is invisible cost (same
              // rationale as MaliGlass headerAction).
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.14),
                      Colors.white.withValues(alpha: 0.08),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Row(
                  children: [
                    _pulseCell(
                        context.l10n.homeTodayIncome,
                        privacyMode
                            ? '••••'
                            : '+${Formatters.amount(data.todayIncome.toDouble())}',
                        _income),
                    _pulseDivider(),
                    _pulseCell(
                        context.l10n.homeTodaySpend,
                        privacyMode
                            ? '••••'
                            : '−${Formatters.amount(data.todaySpend.toDouble())}',
                        Colors.white),
                    _pulseDivider(),
                    _pulseCell(
                        context.l10n.rptNet,
                        privacyMode ? '••••' : signed(todayNet),
                        todayNet.isNegative ? _expenseNet : _income),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Secondary weekly-comparison chip under the hero amount. Percentages are
  /// capped for display so an unusual spike can never break the layout.
  Widget _trendChip(double ratio, String suffix) {
    final spentMore = ratio > 0;
    final pct = (ratio.abs() * 100).round();
    final label = pct > 999 ? '+999%' : '$pct%';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                spentMore ? AppLucideIcons.arrowUp : AppLucideIcons.arrowDown,
                size: 12,
                color: spentMore ? _expenseNet : _income,
              ),
              const SizedBox(width: 4),
              Text(
                '$label $suffix',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    AppTypography.micro(Colors.white.withValues(alpha: 0.85)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pulseCell(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              // Full amounts always visible — scale down, never truncate.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value,
                    maxLines: 1, style: AppTypography.subhead(color)),
              ),
            ),
            const SizedBox(height: 2),
            Text(label,
                style:
                    AppTypography.micro(Colors.white.withValues(alpha: 0.70))),
          ],
        ),
      );

  Widget _pulseDivider() => Container(
        width: 1,
        height: 24,
        color: Colors.white.withValues(alpha: 0.14),
      );

  Widget _eye(BuildContext context, WidgetRef ref) => InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: () async {
          HapticFeedback.selectionClick();
          final settings = ref.read(userSettingsProvider).valueOrNull;
          if (settings == null) return;
          await ref.read(userSettingsRepositoryProvider).saveSettings(
              settings.copyWith(privacyModeEnabled: !privacyMode));
        },
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            privacyMode ? AppLucideIcons.eyeOff : AppLucideIcons.eye,
            size: 16,
            color: Colors.white.withValues(alpha: 0.8),
          ),
        ),
      );
}

/// The hero's اليوم / الأسبوع / الشهر switch.
///
/// Its own widget rather than the shared `SegmentedControl` for two reasons:
/// it lives on the blue hero (white-on-blue, not the canvas palette), and the
/// shared control is a bare `GestureDetector` with no button/selected
/// semantics — which a primary control on the app's first screen cannot be.
/// Each option here is a real [Semantics] button announcing its selected
/// state, with a 44px touch target.
class _PeriodSegments extends StatelessWidget {
  const _PeriodSegments({required this.selected, required this.onSelect});

  final HeroPeriod selected;
  final ValueChanged<HeroPeriod> onSelect;

  // Was a `static const` map. Localized copy cannot be const, and a table
  // built once at class-load would freeze whichever language was active then.
  static String _label(BuildContext context, HeroPeriod p) => switch (p) {
        HeroPeriod.day => context.l10n.txnRangeToday,
        HeroPeriod.week => context.l10n.homeWeek,
        HeroPeriod.month => context.l10n.homeMonth,
      };

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final period in HeroPeriod.values)
              _segment(period, _label(context, period), period == selected),
          ],
        ),
      ),
    );
  }

  Widget _segment(HeroPeriod period, String label, bool isSelected) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onSelect(period);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 38, minWidth: 62),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            label,
            style: AppTypography.caption(
              isSelected
                  ? AppBrandBlue.brand
                  : Colors.white.withValues(alpha: 0.72),
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// White add button in the blue zone — opens the add-transaction flow.
class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    return MaliGlass(
      variant: MaliGlassVariant.headerAction,
      onTap: () {
        HapticFeedback.selectionClick();
        showCaptureEntrySheet(context);
      },
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// The content sheet: rounded top, mode-aware surface, sliding up over the
/// blue zone's bottom edge. Holds all the scrollable Home sections.
/// خلفية المحتوى تحت الهيرو — نفس القيمة اللي الهيرو بيدوب فيها، عشان
/// الميلت يبقى بلا أي لحام. (داكن = كانفاس التطبيق الأسود الحقيقي.)
/// كام بكسل الأزرق يكمّل تحت نهاية محتوى الهيرو — نفس منطق
/// `CalmPageHeader._meltOverflow`: اللون يوصل لنص الشاشة والذوبان يحصل خلف
/// أول كروت الصفحة مش في فراغ.
const double _heroMeltOverflow = 220;

Color _sheetBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? context.colors.bg
        : const Color(0xFFF5F7FB);

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // شفاف بالكامل: الهيرو الأزرق بيكمّل وراه ([_heroMeltOverflow]) وبيدوب في
    // كانفاس الصفحة، فأول الكروت بتقعد على الذوبان بدل ما خلفية صلبة تقطعه.
    return Padding(
      // Bottom clearance moved OUT to the list, so it can sit below the ad
      // slot rather than between the last section and it.
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 0, AppSpacing.gutter, 0),
      child: child,
    );
  }
}

// ─── العمليات — القايمة كاملة بسكرول داخلي ────────────────────────────────────

class _TransactionsSection extends ConsumerWidget {
  const _TransactionsSection({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = MaliTokens.of(context);
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};
    final days = groupByDay(data.recent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.s6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.txnTabTransactions,
            trailing: context.l10n.bdgFilterAll,
            onTrailingTap: () =>
                ref.read(shellIndexProvider.notifier).state = 1,
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        // The counter describes the SLICE this panel renders, not the ledger —
        // `recent` is a bounded read, and «قيد المراجعة» is itself capped.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.homeShownTx(data.recent.length) +
                      (data.pendingReviewCount > 0
                          ? ' · ${context.l10n.homePendingSuffix('${data.pendingReviewCount}'
                              '${data.pendingReviewIsCapped ? '+' : ''}')}'
                          : ''),
                  style: AppTypography.micro(t.textOnCanvasMuted),
                ),
              ),
              Text(
                privacyMode
                    ? '••••'
                    : '${formatMoney(data.rangeExpense)} '
                        '${Currency.label(context, data.currency.toUpperCase())}',
                style: AppTypography.micro(t.textOnCanvasSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        TransactionsPanel(
          days: days,
          catalog: data.catalog,
          privacyMode: privacyMode,
          merchantLogos: logos,
          onTap: (tx) => TransactionDetailsScreen.showSheet(context, tx.id),
        ),
      ],
    );
  }
}

// ─── المصروفات الشهرية ────────────────────────────────────────────────────────

class _MonthlySection extends ConsumerWidget {
  const _MonthlySection({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.homeMonthlySpend,
            trailing: context.l10n.homeBudget,
            onTrailingTap: () => context.push('/budgets'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        MonthlySpendCard(
          spent: data.spentThisMonth,
          limit: data.monthlyBudgetLimit,
          ratio: data.monthlyBudgetRatio,
          monthElapsedRatio: data.monthElapsedRatio,
          projectedMonthSpend: data.projectedMonthSpend,
          categories: data.topCategories,
          categoryCount: data.categoryCount,
          currencyLabel: Currency.label(context, data.currency.toUpperCase()),
          privacyMode: privacyMode,
          onCategoryTap: () =>
              ref.read(shellIndexProvider.notifier).state = 4,
        ),
      ],
    );
  }
}

// ─── الميزانيات ───────────────────────────────────────────────────────────────

class _BudgetsSection extends StatelessWidget {
  const _BudgetsSection({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.helpBudgetsTitle,
            trailing: context.l10n.homeManage,
            onTrailingTap: () => context.push('/budgets'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        BudgetsCard(
          entries: data.budgetProgress,
          privacyMode: privacyMode,
          onTap: () => context.push('/budgets'),
        ),
      ],
    );
  }
}

// ─── Subscriptions ────────────────────────────────────────────────────────────

class _SubscriptionSection extends ConsumerWidget {
  const _SubscriptionSection({required this.privacyMode});
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(homeSubscriptionsProvider).valueOrNull;
    final insts = ref.watch(homeInstallmentsProvider).valueOrNull;
    final currency = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    // valueOrNull, not `when`: a reload must not collapse the section to
    // nothing and back — the previous render holds while the next one loads.
    if (subs == null && insts == null) return const SizedBox.shrink();

    final subscriptions = subs ?? const <BillEntity>[];
    final installments = insts ?? const <BillEntity>[];

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SectionHeader(
        title: context.l10n.homeSubsAndInstalments,
        trailing: context.l10n.bdgFilterAll,
        onTrailingTap: () => context.push('/subscriptions'),
      ),
    );

    // UX-010 — an empty list keeps its header and says so, rather than making
    // the whole section disappear when the account changes.
    if (subscriptions.isEmpty && installments.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: AppSpacing.s2),
          _SectionEmptyNote(context.l10n.homeNoBillsOnAccount),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: AppSpacing.s3),
        ObligationsCard(
          subscriptions: subscriptions,
          installments: installments,
          displayCurrency: currency,
          currencyLabel: Currency.label(context, currency.toUpperCase()),
          privacyMode: privacyMode,
          now: DateTime.now(),
          onTap: (_) => context.push('/subscriptions'),
        ),
      ],
    );
  }
}


// ─── Goal ─────────────────────────────────────────────────────────────────────

/// UX-010 — what an account-scoped Home section shows when it has nothing.
///
/// Not [AppEmptyState]: that is a full-screen archetype with an illustration
/// and a call to action, and three of them stacked on Home would be louder than
/// the content they replace. One quiet line under the section's own header is
/// enough to turn "this section is broken" into "there is nothing here for this
/// account".
class _SectionEmptyNote extends StatelessWidget {
  const _SectionEmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.s2),
      child: Text(text, style: AppTypography.caption(c.textSecondary)),
    );
  }
}

class _GoalSection extends StatelessWidget {
  const _GoalSection({required this.goal, required this.privacyMode});

  /// Null when the selected account has no goal — the section still renders its
  /// header rather than disappearing (UX-010).
  final GoalEntity? goal;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final goal = this.goal;
    if (goal == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SectionHeader(
              title: context.l10n.bdgTabGoals,
              trailing: context.l10n.bdgFilterAll,
              onTrailingTap: () => context.push('/goals'),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          _SectionEmptyNote(context.l10n.homeNoGoalsOnAccount),
        ],
      );
    }
    final ratio = goal.targetAmount > 0
        ? (goal.savedAmount / goal.targetAmount).clamp(0.0, 1.0)
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.bdgTabGoals,
            trailing: context.l10n.bdgFilterAll,
            onTrailingTap: () => context.push('/goals'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/goals'),
          // A goal reads as a LINE filling up, not another ring — the ring
          // stays the budget's shape so the two never get confused at a
          // glance (design-system §15.9).
          child: MaliCard(
            style: MaliSurfaceStyle.floating,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.income.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(AppLucideIcons.target,
                          color: c.income, size: 19),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(goal.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.income.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text('${(ratio * 100).round()}%',
                          style: AppTypography.label(c.income)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                LiquidBar(value: ratio, color: c.income),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        privacyMode
                            ? context.l10n.homeGoalSaved('••••')
                            : context.l10n.homeGoalSaved(
                                Formatters.amount(goal.savedAmount)),
                        style: AppTypography.caption(t.textOnCanvasSecondary),
                      ),
                    ),
                    Text(
                      privacyMode
                          ? context.l10n.homeGoalRemaining('••••')
                          : context.l10n.homeGoalRemaining(Formatters.amount(
                              (goal.targetAmount - goal.savedAmount)
                                  .clamp(0, double.infinity))),
                      style: AppTypography.caption(t.textOnCanvasSecondary),
                    ),
                  ],
                ),
                // UX-025 continued — the rate the deadline DEMANDS, next to
                // where the user's own rate actually lands. A goal with neither
                // is a number; with both it is a plan they can correct.
                ..._pacing(context, c, t, goal),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Renders the pacing line, or nothing when there is nothing honest to say
  /// (no deadline, goal already met, or no contributions yet to project from).
  List<Widget> _pacing(
    BuildContext context,
    AppColors c,
    MaliTokens t,
    GoalEntity goal,
  ) {
    final now = DateTime.now();
    final pacing = goalPacing(
      target: goal.targetMoney,
      saved: goal.savedMoney,
      deadline: goal.deadline,
      now: now,
    );
    final projection = goalProjection(
      target: goal.targetMoney,
      saved: goal.savedMoney,
      createdAt: goal.createdAt,
      deadline: goal.deadline,
      now: now,
    );

    final required = pacing.requiredPerMonth;
    final arrival = projection.arrivesOn;
    if (required == null && arrival == null) return const <Widget>[];

    final parts = <String>[
      if (required != null)
        context.l10n.homeNeedPerMonth(
            privacyMode ? '••••' : formatMoney(required)),
      if (arrival != null)
        context.l10n.homeArrivesOn(Formatters.monthYear(arrival, context)) +
            (projection.isLate
                ? ' — ${context.l10n.homeLateBy(projection.monthsLate!)}'
                : ''),
    ];

    return [
      const SizedBox(height: 9),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            projection.isLate
                ? AppLucideIcons.alertTriangle
                : AppLucideIcons.info,
            size: 14,
            color: projection.isLate ? c.warning : t.textOnCanvasMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: AppTypography.caption(
                projection.isLate ? c.warning : t.textOnCanvasSecondary,
              ).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    ];
  }


}

// ─── Setup nudge ──────────────────────────────────────────────────────────────

const Duration _setupNudgeSnooze = Duration(days: 30);
const String _setupNudgeSnoozedUntilKey = 'setup_nudge_snoozed_until';
final _setupNudgeDismissedProvider = StateProvider<bool>((_) => false);
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
      key: _setupNudgeSnoozedUntilKey, value: until.toIso8601String());
  ref.read(_setupNudgeDismissedProvider.notifier).state = true;
  ref.invalidate(_setupNudgeSnoozedProvider);
}

final _appLockEnabledProvider =
    FutureProvider<bool>((_) => AppLockService.instance.isEnabled());

class _SetupNudgeCard extends ConsumerWidget {
  const _SetupNudgeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(_setupNudgeDismissedProvider)) {
      return const SizedBox.shrink();
    }
    if (ref.watch(_setupNudgeSnoozedProvider).valueOrNull ?? true) {
      return const SizedBox.shrink();
    }
    final hasGoals =
        ref.watch(goalsListProvider).valueOrNull?.isNotEmpty ?? true;
    final lockEnabled = ref.watch(_appLockEnabledProvider).valueOrNull ?? true;
    if (hasGoals && lockEnabled) return const SizedBox.shrink();
    final t = MaliTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(context.l10n.homeFinishSetup,
                      style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                ),
                InkWell(
                  onTap: () => _snoozeSetupNudge(ref),
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(AppLucideIcons.x,
                      size: 18, color: t.textOnCanvasMuted),
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
                    icon: AppLucideIcons.fingerprint,
                    label: context.l10n.homeEnableBiometrics,
                    onTap: () =>
                        ref.read(shellIndexProvider.notifier).state = 3,
                  ),
                if (!hasGoals)
                  _SetupNudgeChip(
                    icon: AppLucideIcons.piggyBank,
                    label: context.l10n.homeAddSavingsGoal,
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
  const _SetupNudgeChip(
      {required this.icon, required this.label, required this.onTap});
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
          color: c.cta.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.cta.withValues(alpha: 0.30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.cta),
            const SizedBox(width: 6),
            Text(label, style: AppTypography.footnote(c.cta)),
          ],
        ),
      ),
    );
  }
}

// ─── Plans ────────────────────────────────────────────────────────────────────

class _PlansSection extends ConsumerWidget {
  const _PlansSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homePlansProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (plans) {
        final t = MaliTokens.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SectionHeader(
                title: context.l10n.homePlans,
                trailing: context.l10n.bdgFilterAll,
                onTrailingTap: () => PlansScreen.open(context),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            if (plans.isEmpty)
              MaliCard(
                style: MaliSurfaceStyle.floating,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l10n.homeNoActivePlans,
                              style: AppTypography.bodyStrong(
                                  t.textOnCanvasPrimary)),
                          const SizedBox(height: 2),
                          Text(context.l10n.homeCreatePlanHint,
                              style:
                                  AppTypography.caption(t.textOnCanvasMuted)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => PlanFormSheet.show(context),
                      style: FilledButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                      ),
                      child: Text(context.l10n.homeNewPlan),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  for (var i = 0; i < plans.take(3).length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.s3),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => PlansScreen.open(context),
                      child: _PlanCard(progress: plans[i]),
                    ),
                  ],
                ],
              ),
          ],
        );
      },
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.progress});
  final PlanProgress progress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final plan = progress.plan;
    final ratio = progress.ratio.clamp(0.0, 1.0);
    final tone = progress.isOver ? c.danger : c.cta;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(AppLucideIcons.plane, color: tone, size: 18),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(plan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
              ),
              Text('${(progress.ratio * 100).round()}%',
                  style: AppTypography.subhead(tone)),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: t.ringTrackNeutral,
              valueColor: AlwaysStoppedAnimation(tone),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                  context.l10n.planSpent(
                      Formatters.amount(progress.spent.toDouble())),
                  style: AppTypography.caption(t.textOnCanvasSecondary)),
              Text(
                  context.l10n.planEnds(
                      Formatters.dateGroupLabel(plan.endDate, context)),
                  style: AppTypography.caption(t.textOnCanvasMuted)),
            ],
          ),
          // The number a plan is actually spent against, day to day. It was
          // already computed (`PlanProgress.perDayLeft`) and never rendered.
          // Zero days left or an exhausted budget yields zero, and a «0» here
          // would read as an instruction rather than an absence — so the line
          // is omitted instead.
          if (!progress.perDayLeft.isZero) ...[
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Icon(AppLucideIcons.wallet,
                    size: 13, color: t.textOnCanvasMuted),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    context.l10n
                        .planPerDayLeft(formatMoney(progress.perDayLeft)),
                    style: AppTypography.caption(t.textOnCanvasSecondary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Coupons ──────────────────────────────────────────────────────────────────

class _DashboardCouponsRail extends ConsumerWidget {
  const _DashboardCouponsRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(dashboardCouponsProvider).valueOrNull;
    // valueOrNull, not `when`: a reload must not blink the section away.
    // Empty (or the feature flag off) renders nothing at all — an empty
    // «ركن التوفير» header would advertise a section that has no content.
    if (offers == null || offers.isEmpty) return const SizedBox.shrink();
    final english = Localizations.localeOf(context).languageCode == 'en';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.homeSavingsCorner,
            trailing: context.l10n.bdgFilterAll,
            onTrailingTap: () => context.push('/coupons'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        CouponsCorner(
          offers: offers,
          preferEnglish: english,
          onOpen: (offer) => showCouponDetailsSheet(context, ref, offer),
          onSeeAll: () => context.push('/coupons'),
        ),
      ],
    );
  }
}