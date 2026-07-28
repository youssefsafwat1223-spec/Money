import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/mali_tokens.dart';
import '../../core/theme/widgets/attention_card.dart';
import '../../core/theme/widgets/budget_ring_rail.dart';
import '../../core/theme/widgets/glass_selector.dart';
import '../../core/theme/widgets/insight_card.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_screen.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../../core/theme/widgets/section_header.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../core/security/app_lock_service.dart';
import '../app/app_shell.dart';
import '../cards/brand_mark.dart';
import '../coupons/coupon_models.dart';
import '../coupons/coupon_widgets.dart';
import '../coupons/coupons_providers.dart';
import '../goals/goals_providers.dart';
import '../plans/plan_form_sheet.dart';
import '../plans/plans_providers.dart';
import '../plans/plans_screen.dart';
import '../common/app_empty_state.dart';
import '../common/category_catalog.dart';
import '../common/premium_loading.dart';
import '../common/transaction_direction.dart';
// hide SectionHeader — we use the Calm Capital archetype of the same name.
import '../common/widgets.dart' hide SectionHeader;
import '../settings/settings_providers.dart';
import '../capture/capture_entry_sheet.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';
import 'home_sections_providers.dart';

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
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardDataProvider),
        child: async.when(
          skipLoadingOnReload: true,
          loading: () => const FirstLoadPlaceholder(cardCount: 5),
          error: (error, _) {
            if (error is AuthRepoException) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                AppSession.instance.handleAuthRequiredFailure();
              });
              return _errorList(
                title: 'الرجاء تسجيل الدخول مرة أخرى',
                description: 'انتهت صلاحية الجلسة، سجّل دخولك للمتابعة.',
                retryLabel: 'تسجيل الدخول',
                onRetry: () => AppSession.instance.handleAuthRequiredFailure(),
              );
            }
            return _errorList(
              title: 'تعذر تحميل لوحة التحكم الآن',
              description: 'تحقق من البيانات أو حاول التحديث مرة أخرى.',
              retryLabel: 'إعادة المحاولة',
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
              if (data.isEmpty)
                _empty(context)
              else ...[
                _afterHero(context, ref),
                _RecentSection(data: data, privacyMode: privacyMode),
                if (data.budgetProgress.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s4),
                  _BudgetSection(data: data),
                ],
                const SizedBox(height: AppSpacing.s4),
                _SubscriptionSection(privacyMode: privacyMode),
                if (data.activeGoal != null) ...[
                  const SizedBox(height: AppSpacing.s4),
                  _GoalSection(
                      goal: data.activeGoal!, privacyMode: privacyMode),
                ],
                const SizedBox(height: AppSpacing.s4),
                const _PlansSection(),
                const SizedBox(height: AppSpacing.s4),
                const _DashboardCouponsRail(),
              ],
              const SizedBox(height: AppSpacing.s6),
            ],
          ),
        ),
      ],
    );
  }

  // ── Filters (range + account) ──────────────────────────────────────────────

  Widget _filters(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).valueOrNull;
    final selectedId = ref.watch(dashboardAccountProvider);
    final String accountLabel;
    if (accounts == null || accounts.isEmpty) {
      accountLabel = 'كل الحسابات';
    } else {
      final selected = accounts.firstWhere(
        (a) => a.id == selectedId,
        orElse: () => accounts.firstWhere((a) => a.isDefault,
            orElse: () => accounts.first),
      );
      accountLabel = 'حساب ${_currencyLabel(selected.currency)}';
    }
    return Row(
      children: [
        Expanded(
          child: GlassSelector(
            icon: Icons.calendar_month_outlined,
            label: data.range.label,
            onTap: () => _showRangeSheet(context, ref, data.range),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: GlassSelector(
            icon: Icons.account_balance_wallet_outlined,
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

  // ── Below-hero context cards (attention + safe-to-spend + insight) ─────────
  // The balance + today's pulse now live in the blue zone ([_BlueZone]); these
  // supporting cards sit at the top of the content sheet.

  Widget _afterHero(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final ratio = data.weekChangeRatio;
    final spentMore = ratio > 0.001;
    final trendText = (ratio.abs() > 0.001)
        ? '${(ratio.abs() * 100).round()}% عن الأسبوع الماضي'
        : null;

    final hasBudget = data.monthlyBudgetLimit > 0;
    final remaining =
        hasBudget ? (1 - data.monthlyBudgetRatio).clamp(0.0, 1.0) : null;
    final over = hasBudget && data.monthlyBudgetRatio >= 1.0;
    final tight = hasBudget && data.monthlyBudgetRatio >= 0.8;
    final verdict = !hasBudget
        ? 'حدّد ميزانية شهرية لتتابع المتاح'
        : over
            ? 'تجاوزت ميزانية الشهر'
            : tight
                ? 'مصروفك أعلى من المعتاد'
                : 'وضعك مستقر';
    final ringColor = over ? c.danger : (tight ? c.warning : c.income);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.pendingReviewCount > 0) ...[
          AttentionCard(
            icon: AppLucideIcons.inbox,
            title:
                '${data.pendingReviewCount} ${data.pendingReviewCount == 1 ? 'عملية' : 'عمليات'} في انتظار مراجعتك',
            subtitle: 'راجعها عشان أرصدتك تفضل مظبوطة',
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(shellIndexProvider.notifier).state = 1;
              ref.read(transactionsPendingFilterProvider.notifier).state = true;
            },
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        // Compact "safe to spend" — a thin raised bar (not a floating card).
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3, vertical: AppSpacing.s3),
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              RingProgress(
                value: remaining,
                size: 40,
                strokeWidth: 5,
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
                    Text('متاح من ميزانية الشهر',
                        style: AppTypography.caption(t.textOnCanvasSecondary)),
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
            label: 'ملخص الأسبوع',
            message: spentMore
                ? 'انتبه — مصروفك أعلى بـ${(ratio.abs() * 100).round()}% عن الأسبوع اللي فات. راجع أكتر فئة بتصرف فيها.'
                : 'أحسنت — مصروفك أقل بـ${(ratio.abs() * 100).round()}% عن الأسبوع اللي فات. كمّل كده وهتوفّر أكتر.',
          ),
        ],
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }

  Widget _empty(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: AppSpacing.s5),
        child: AppEmptyState(
          icon: AppLucideIcons.receipt,
          title: 'لا توجد عمليات مضافة',
          subtitle:
              'ألصق رسالة الخصم أو الإيداع من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائياً على جهازك.',
        ),
      );

  String _currencyLabel(String currency) =>
      Currency.arabicLabel(currency.toUpperCase());

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
                        to: DateTime(to.year, to.month, to.day, 23, 59, 59),
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

  String _name() {
    final n = displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final email = AppSession.instance.email;
    if (email == null || email.trim().isEmpty) return 'صديق مالي';
    final local = email.split('@').first.trim();
    if (local.isEmpty || local.toLowerCase() == 'user') return 'صديق مالي';
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
    final name = _name();
    final path = avatarPath?.trim();
    final file = (path == null || path.isEmpty) ? null : File(path);
    final hasImage = file != null && file.existsSync();

    final heroValue = data.rangeExpense;
    final ratio = data.weekChangeRatio;
    final trendText = (ratio.abs() > 0.001)
        ? '${(ratio.abs() * 100).round()}% عن الأسبوع الماضي'
        : null;
    final todayNet = data.todayIncome - data.todaySpend;
    String signed(double v) =>
        '${v >= 0 ? '+' : '−'}${Formatters.amount(v.abs())}';
    final currencyLabel = Currency.arabicLabel(data.currency.toUpperCase());

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          stops: const [0.0, 0.55, 1.0],
          colors: isDark
              ? const [Color(0xFF071634), Color(0xFF0E3A86), Color(0xFF1E74F0)]
              : const [Color(0xFF1E74F0), Color(0xFF3E8CF7), Color(0xFF7FB2FF)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(20, topPad + 12, 20, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: hasImage
                    ? Image.file(file, fit: BoxFit.cover)
                    : Text(_initials(name),
                        style: AppTypography.subhead(Colors.white)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('مرحباً 👋',
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
              const _AddButton(),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text('إجمالي المصروفات',
                  style: AppTypography.caption(
                      Colors.white.withValues(alpha: 0.78))),
              const SizedBox(width: 6),
              _eye(context, ref),
              const Spacer(),
              if (trendText != null)
                Text(trendText,
                    style: AppTypography.caption(
                        Colors.white.withValues(alpha: 0.70))),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  privacyMode ? '••••••' : Formatters.amount(heroValue),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.amountHero(Colors.white)
                      .copyWith(fontSize: 38, height: 1.0),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(currencyLabel,
                    style: AppTypography.subhead(
                        Colors.white.withValues(alpha: 0.82))),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                _pulseCell(
                    'دخل اليوم',
                    privacyMode
                        ? '••••'
                        : '+${Formatters.amount(data.todayIncome)}',
                    _income),
                _pulseDivider(),
                _pulseCell(
                    'مصروف اليوم',
                    privacyMode
                        ? '••••'
                        : '−${Formatters.amount(data.todaySpend)}',
                    Colors.white),
                _pulseDivider(),
                _pulseCell('الصافي', privacyMode ? '••••' : signed(todayNet),
                    todayNet >= 0 ? _income : _expenseNet),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pulseCell(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.subhead(color)),
            const SizedBox(height: 2),
            Text(label,
                style:
                    AppTypography.micro(Colors.white.withValues(alpha: 0.70))),
          ],
        ),
      );

  Widget _pulseDivider() => Container(
        width: 1,
        height: 26,
        color: Colors.white.withValues(alpha: 0.18),
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
            privacyMode
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded,
            size: 16,
            color: Colors.white.withValues(alpha: 0.8),
          ),
        ),
      );
}

/// White add button in the blue zone — opens the add-transaction flow.
class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        showCaptureEntrySheet(context);
      },
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
      ),
    );
  }
}

/// The content sheet: rounded top, mode-aware surface, sliding up over the
/// blue zone's bottom edge. Holds all the scrollable Home sections.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Dark sheet = the app's true-black canvas (matches every other page),
    // not the near-black #08090C from the mockup.
    final sheetBg = isDark ? context.colors.bg : const Color(0xFFF5F7FB);
    return Transform.translate(
      offset: const Offset(0, -18),
      child: Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, 20, AppSpacing.gutter, 120),
        child: child,
      ),
    );
  }
}

// ─── Recent transactions timeline ─────────────────────────────────────────────

class _RecentSection extends ConsumerWidget {
  const _RecentSection({required this.data, required this.privacyMode});
  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = data.recent.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: 'آخر العمليات',
            trailing: 'الكل',
            onTrailingTap: () =>
                ref.read(shellIndexProvider.notifier).state = 1,
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        MaliCard(
          style: MaliSurfaceStyle.floating,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: recent.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.cardPadding),
                  child: Text('لا توجد عمليات بعد',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(
                          MaliTokens.of(context).textOnCanvasMuted)),
                )
              : Column(
                  children: [
                    for (final tx in recent)
                      _TxRow(
                        tx: tx,
                        category: data.catalog.byId(tx.categoryId),
                        privacyMode: privacyMode,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TxRow extends StatelessWidget {
  const _TxRow({
    required this.tx,
    required this.category,
    required this.privacyMode,
  });

  final TransactionEntity tx;
  final CategoryView? category;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final merchant = tx.rawMerchant?.trim();
    final title = (merchant != null && merchant.isNotEmpty)
        ? merchant
        : category?.nameAr ?? 'عملية';
    final isDebit = transactionIsDebit(tx);
    final amountColor = isDebit ? t.textOnCanvasPrimary : c.income;
    final amount = privacyMode
        ? '••••'
        : '${isDebit ? '−' : '+'}${Formatters.amount(tx.amount)}';
    final catColor = category?.tileColor ?? c.cta;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              (merchant != null && BrandMark.hasBrand(merchant))
                  ? BrandMark(name: merchant, size: 42)
                  : Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        color: catColor,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      child: CategoryGlyph(
                        name: category?.iconName ?? 'receipt-text',
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    const SizedBox(height: 3),
                    Text(
                      '${category?.nameAr ?? 'غير مصنّفة'} · ${Formatters.time(tx.occurredAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(t.textOnCanvasMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(amount, style: AppTypography.amountSmall(amountColor)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Budgets ──────────────────────────────────────────────────────────────────

class _BudgetSection extends ConsumerWidget {
  const _BudgetSection({required this.data});
  final DashboardData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final entries = data.budgetProgress.take(3).toList();
    Color toneOf(double ratio) =>
        ratio >= 1.0 ? c.danger : (ratio >= 0.8 ? c.warning : c.income);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: 'الميزانية',
            trailing: 'إدارة',
            onTrailingTap: () => context.push('/budgets'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/budgets'),
          child: entries.length == 1
              ? _BudgetWideCard(
                  entry: entries.first, tone: toneOf(entries.first.ratio))
              : BudgetRingRail(
                  rings: [
                    for (final b in entries)
                      BudgetRing(
                        value: b.limit > 0 ? (b.ratio).clamp(0.0, 1.0) : null,
                        name: b.label,
                        sub:
                            '${Formatters.amount(b.spent)} / ${Formatters.amount(b.limit)}',
                        color: toneOf(b.ratio),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Full-width budget card used when there's only one budget — a ring + label +
/// spent/limit, instead of a single ring floating in an empty rings row.
class _BudgetWideCard extends StatelessWidget {
  const _BudgetWideCard({required this.entry, required this.tone});
  final DashboardBudgetEntry entry;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final ratio = entry.limit > 0 ? entry.ratio.clamp(0.0, 1.0) : null;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Row(
        children: [
          RingProgress(
            value: ratio,
            size: 84,
            strokeWidth: 8,
            color: tone,
            child: Text(ratio == null ? '—' : '${(ratio * 100).round()}%',
                style: AppTypography.subhead(t.textOnCanvasPrimary)),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                const SizedBox(height: 6),
                Text(
                  '${Formatters.amount(entry.spent)} / ${Formatters.amount(entry.limit)}',
                  style: AppTypography.caption(t.textOnCanvasSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Subscriptions ────────────────────────────────────────────────────────────

class _SubscriptionSection extends ConsumerWidget {
  const _SubscriptionSection({required this.privacyMode});
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeSubscriptionsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (subs) {
        if (subs.isEmpty) return const SizedBox.shrink();
        final items = subs.take(6).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SectionHeader(
                title: 'الاشتراكات',
                trailing: 'الكل',
                onTrailingTap: () => context.push('/subscriptions'),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            if (items.length == 1)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.push('/subscriptions'),
                child:
                    _SubWideCard(bill: items.first, privacyMode: privacyMode),
              )
            else
              SizedBox(
                height: 156,
                child: ListView.separated(
                  clipBehavior: Clip.none,
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => context.push('/subscriptions'),
                    child: _SubCard(bill: items[i], privacyMode: privacyMode),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SubCard extends StatelessWidget {
  const _SubCard({required this.bill, required this.privacyMode});
  final BillEntity bill;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final today = DateTime.now();
    final days = bill.nextDueDate
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    final due = days < 0
        ? 'متأخر ${days.abs()} يوم'
        : days == 0
            ? 'مستحق اليوم'
            : 'بعد $days يوم';
    final initial = bill.name.trim().isEmpty ? '?' : bill.name.characters.first;
    return SizedBox(
      width: 160,
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            (bill.name.isNotEmpty && BrandMark.hasBrand(bill.name))
                ? BrandMark(name: bill.name, size: 40)
                : Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: MaliTokens.accentStart.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(initial,
                        style: AppTypography.subhead(MaliTokens.accentStart)),
                  ),
            const Spacer(),
            Text(bill.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.subhead(t.textOnCanvasPrimary)),
            const SizedBox(height: 4),
            Text(due,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(t.textOnCanvasMuted)),
            const SizedBox(height: 6),
            Text(
              privacyMode
                  ? '••••'
                  : '${Formatters.amount(bill.amount)} ${Currency.arabicLabel(bill.currency.toUpperCase())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyStrong(t.textOnCanvasPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-width subscription card used when there's only one — avoids the empty
/// gap a single narrow rail card leaves.
class _SubWideCard extends StatelessWidget {
  const _SubWideCard({required this.bill, required this.privacyMode});
  final BillEntity bill;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final today = DateTime.now();
    final days = bill.nextDueDate
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    final due = days < 0
        ? 'متأخر ${days.abs()} يوم'
        : days == 0
            ? 'مستحق اليوم'
            : 'بعد $days يوم';
    final initial = bill.name.trim().isEmpty ? '?' : bill.name.characters.first;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Row(
        children: [
          (bill.name.isNotEmpty && BrandMark.hasBrand(bill.name))
              ? BrandMark(name: bill.name, size: 44)
              : Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MaliTokens.accentStart.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(initial,
                      style: AppTypography.subhead(MaliTokens.accentStart)),
                ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bill.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                const SizedBox(height: 3),
                Text(due, style: AppTypography.caption(t.textOnCanvasMuted)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            privacyMode
                ? '••••'
                : '${Formatters.amount(bill.amount)} ${Currency.arabicLabel(bill.currency.toUpperCase())}',
            style: AppTypography.bodyStrong(t.textOnCanvasPrimary),
          ),
        ],
      ),
    );
  }
}

// ─── Goal ─────────────────────────────────────────────────────────────────────

class _GoalSection extends StatelessWidget {
  const _GoalSection({required this.goal, required this.privacyMode});
  final GoalEntity goal;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final ratio = goal.targetAmount > 0
        ? (goal.savedAmount / goal.targetAmount).clamp(0.0, 1.0)
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: 'الأهداف',
            trailing: 'الكل',
            onTrailingTap: () => context.push('/goals'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/goals'),
          child: MaliCard(
            style: MaliSurfaceStyle.floating,
            child: Row(
              children: [
                RingProgress(
                  value: ratio,
                  size: 72,
                  strokeWidth: 8,
                  color: c.income,
                  child: Text('${(ratio * 100).round()}%',
                      style: AppTypography.subhead(t.textOnCanvasPrimary)),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(goal.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                      const SizedBox(height: 6),
                      Text(
                        privacyMode
                            ? '•••• / ••••'
                            : 'تم توفير ${Formatters.amount(goal.savedAmount)} من ${Formatters.amount(goal.targetAmount)}',
                        style: AppTypography.caption(t.textOnCanvasSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
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
                  child: Text('كمّل إعداد قرش ✨',
                      style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                ),
                InkWell(
                  onTap: () => _snoozeSetupNudge(ref),
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(Icons.close_rounded,
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
                title: 'الخطط',
                trailing: 'الكل',
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
                          Text('لا توجد خطط نشطة',
                              style: AppTypography.bodyStrong(
                                  t.textOnCanvasPrimary)),
                          const SizedBox(height: 2),
                          Text('أنشئ خطة ميزانية للسفر أو المناسبات',
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
                      child: const Text('خطة جديدة'),
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
              Text('المصروف: ${Formatters.amount(progress.spent)}',
                  style: AppTypography.caption(t.textOnCanvasSecondary)),
              Text('تنتهي: ${Formatters.dateGroupLabel(plan.endDate, context)}',
                  style: AppTypography.caption(t.textOnCanvasMuted)),
            ],
          ),
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
    final async = ref.watch(dashboardCouponsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (offers) {
        if (offers.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SectionHeader(
                title: 'كوبونات توفر عليك',
                trailing: 'الكل',
                onTrailingTap: () => context.push('/coupons'),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            if (offers.length == 1)
              _HomeCouponCard(offer: offers.first, width: null)
            else
              SizedBox(
                height: 132,
                child: ListView.separated(
                  clipBehavior: Clip.none,
                  scrollDirection: Axis.horizontal,
                  itemCount: offers.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) =>
                      _HomeCouponCard(offer: offers[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _HomeCouponCard extends StatelessWidget {
  const _HomeCouponCard({required this.offer, this.width = 230});
  final CouponOffer offer;

  /// null → fill the parent width (used when there's a single coupon).
  final double? width;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final card = MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              BrandMark(name: offer.partnerName, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(offer.partnerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(t.textOnCanvasMuted)),
                    Text(offer.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: c.cta.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(offer.code, style: AppTypography.caption(c.cta)),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                    Formatters.dateGroupLabel(offer.validUntil, context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(t.textOnCanvasMuted)),
              ),
            ],
          ),
        ],
      ),
    );
    final sized = width == null ? card : SizedBox(width: width, child: card);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showCouponDetailsSheet(context, offer),
      child: sized,
    );
  }
}
