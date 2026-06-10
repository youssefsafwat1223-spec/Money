import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../achievements/achievements_providers.dart';
import '../achievements/achievements_screen.dart';
import '../budgets/budgets_providers.dart';
import '../budgets/budgets_screen.dart';
import '../capture/capture_entry_sheet.dart';
import '../capture/capture_runtime.dart';
import '../capture/services/android_sms_capture_service.dart';
import '../capture/services/captured_message_processor.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/native_capture_bridge.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../goals/goals_providers.dart';
import '../goals/goals_screen.dart';
import '../settings/settings_providers.dart';
import '../settings/settings_screen.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/transactions_screen.dart';
import '../transactions/widgets/confirm_transaction_sheet.dart';
import 'celebration_runtime.dart';

final shellIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final AppLifecycleListener _lifecycleListener;
  StreamSubscription<String>? _confirmSubscription;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    _confirmSubscription = CaptureRuntime.instance.confirmRequests.listen(
      _openConfirmSheet,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AndroidSmsCaptureService.instance.startListeningIfPermitted();
      await _consumeSharedInput();
      await _syncEngagement();
      _drainCelebrations();
      final initialTransactionId =
          CaptureRuntime.instance.takeInitialConfirmation();
      if (initialTransactionId != null && mounted) {
        await _openConfirmSheet(initialTransactionId);
      }
    });
  }

  @override
  void dispose() {
    _celebrationTimer?.cancel();
    _confirmSubscription?.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    await _consumeSharedInput();
    await _syncEngagement();
    _drainCelebrations();
  }

  Future<void> _consumeSharedInput() async {
    final sharedInput = await NativeCaptureBridge.consumePendingSharedInput();
    if (sharedInput == null || sharedInput.isEmpty) {
      return;
    }

    final result = await CapturedMessageProcessor.process(
      rawMessage: sharedInput,
      showNotifications: false,
    );
    if (!mounted) {
      return;
    }

    _refreshAll();
    if (result.transactionId != null &&
        result.addTransactionResult.requiresConfirmation) {
      await _openConfirmSheet(result.transactionId!);
    }
  }

  Future<void> _syncEngagement() async {
    final preferences =
        await ref.read(loadNotificationPreferencesUseCaseProvider).call();
    final snapshot = await ref.read(budgetProgressUseCaseProvider).call();
    final catalog = await ref.read(categoryCatalogProvider.future);
    for (final alert in snapshot.alerts) {
      final category = catalog.byId(alert.budget.categoryId);
      final label = alert.budget.categoryId == BudgetEntity.allExpensesCategoryId
          ? 'كل المصروفات'
          : category?.nameAr ?? 'ميزانية';
      if (alert.kind == BudgetAlertKind.warning80) {
        await LocalNotificationService.instance.showBudgetAlert(
          title: 'اقتربت من ميزانية $label',
          body:
              'وصلت إلى ${(alert.progress.ratio * 100).round()}% من ميزانية ${alert.progress.budget.amount.toStringAsFixed(0)} ريال.',
          type: NotificationType.budgetWarning,
          preferences: preferences,
        );
      } else {
        await LocalNotificationService.instance.showBudgetAlert(
          title: 'تم تجاوز ميزانية $label',
          body:
              'تجاوزت الميزانية بمقدار ${alert.progress.remaining.abs().toStringAsFixed(0)} ريال.',
          type: NotificationType.budgetOver,
          preferences: preferences,
        );
      }
    }

    final passive = await ref.read(recordEngagementUseCaseProvider).evaluatePassiveBadges();
    for (final achievement in passive) {
      await LocalNotificationService.instance.showAchievementNotification(
        title: 'شارة جديدة',
        body: achievement.nameAr,
        preferences: preferences,
      );
      CelebrationRuntime.instance.pushAll([
        CelebrationEvent(
          kind: CelebrationKind.badgeUnlocked,
          title: 'شارة جديدة',
          message: achievement.nameAr,
        ),
      ]);
    }

    final streak = await ref.read(gamificationRepositoryProvider).getStreak();
    final hasActivityToday = RiyadhTime.dayGap(
          streak.lastActiveDate,
          DateTime.now().toUtc(),
        ) ==
        0;
    await LocalNotificationService.instance.scheduleStreakReminder(
      hasActivityToday: hasActivityToday,
      preferences: preferences,
    );
    _refreshAll();
  }

  void _refreshAll() {
    refreshTransactions(ref);
    refreshBudgets(ref);
    refreshGoals(ref);
    refreshAchievements(ref);
    refreshNotificationPreferences(ref);
    ref.invalidate(dashboardDataProvider);
  }

  void _drainCelebrations() {
    if (!mounted || _activeCelebration != null) {
      return;
    }
    final next = CelebrationRuntime.instance.takeNext();
    if (next == null) {
      return;
    }
    setState(() => _activeCelebration = next);
    final disableAnimations = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _celebrationTimer = Timer(
      disableAnimations ? const Duration(milliseconds: 10) : const Duration(seconds: 2),
      () {
        if (!mounted) {
          return;
        }
        setState(() => _activeCelebration = null);
        _drainCelebrations();
      },
    );
  }

  Future<void> _openConfirmSheet(String transactionId) async {
    if (!mounted) {
      return;
    }
    _refreshAll();
    await showConfirmTransactionSheet(context, transactionId);
    await _syncEngagement();
    _drainCelebrations();
  }

  IconData _getIconForIndex(int index) {
    switch (index) {
      case 0:
        return AppLucideIcons.home;
      case 1:
        return AppLucideIcons.receipt;
      case 2:
        return AppLucideIcons.wallet;
      case 3:
        return AppLucideIcons.target;
      case 4:
        return AppLucideIcons.medal;
      case 5:
        return AppLucideIcons.wrench;
      default:
        return AppLucideIcons.home;
    }
  }

  String _getLabelForIndex(int index) {
    switch (index) {
      case 0:
        return 'الرئيسية';
      case 1:
        return 'العمليات';
      case 2:
        return 'الميزانيات';
      case 3:
        return 'الأهداف';
      case 4:
        return 'الإنجازات';
      case 5:
        return 'الإعدادات';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final index = ref.watch(shellIndexProvider);
    const pages = [
      DashboardScreen(),
      TransactionsScreen(),
      BudgetsScreen(),
      GoalsScreen(),
      AchievementsScreen(),
      SettingsScreen(),
    ];

    final isFabVisible = index <= 1;

    return Scaffold(
      extendBody: true,
      appBar: null,
      body: Stack(
        children: [
          // الخلفية الأساسية مع التوهج الملون (Ambient Glows) لتعميق الإحساس البصري
          Positioned.fill(
            child: Container(
              color: c.bg,
            ),
          ),
          // توهج بنفسجي علوي يمين
          Positioned(
            top: -150,
            right: -150,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.primary.withValues(alpha: 0.12),
                    c.primary.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // توهج بنفسجي غامق سفلي يسار
          Positioned(
            bottom: 100,
            left: -150,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.gradA.withValues(alpha: 0.08),
                    c.gradA.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // محتوى الصفحة الرئيسي
          SafeArea(
            bottom: false,
            child: IndexedStack(index: index, children: pages),
          ),
          if (_activeCelebration != null)
            Positioned(
              top: AppSpacing.s5,
              left: AppSpacing.gutter,
              right: AppSpacing.gutter,
              child: _CelebrationBanner(event: _activeCelebration!),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            textDirection: TextDirection.ltr,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Liquid Glass Navigation Bar
              Expanded(
                child: Container(
                  height: 64,
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: c.surface.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: c.primary.withValues(alpha: 0.25),
                            width: 1.5,
                          ),
                        ),
                        child: Directionality(
                          textDirection: TextDirection.rtl,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: List.generate(6, (i) {
                              final isSelected = index == i;
                              return GestureDetector(
                                onTap: () => ref.read(shellIndexProvider.notifier).state = i,
                                behavior: HitTestBehavior.opaque,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeInOut,
                                  padding: isSelected
                                      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
                                      : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? c.primary.withValues(alpha: 0.16)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isSelected
                                          ? c.primary.withValues(alpha: 0.25)
                                          : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        _getIconForIndex(i),
                                        color: isSelected ? c.primary : c.textLight,
                                        size: 20,
                                      ),
                                      if (isSelected) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          _getLabelForIndex(i),
                                          style: AppTypography.bodyStrong(c.primary).copyWith(
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              
              // Animated Floating Action Button
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                width: isFabVisible ? 68 : 0,
                child: AnimatedScale(
                  scale: isFabVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutBack,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: GestureDetector(
                      onTap: () => showCaptureEntrySheet(context),
                      child: Container(
                        height: 58,
                        width: 58,
                        decoration: BoxDecoration(
                          gradient: c.primaryGradient,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.primary.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(
                          AppLucideIcons.plus,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CelebrationBanner extends StatelessWidget {
  const _CelebrationBanner({required this.event});

  final CelebrationEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          gradient: c.primaryGradient,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: AppTypography.bodyStrong(Colors.white)),
            const SizedBox(height: AppSpacing.s1),
            Text(event.message, style: AppTypography.callout(Colors.white)),
          ],
        ),
      ),
    );
  }
}
