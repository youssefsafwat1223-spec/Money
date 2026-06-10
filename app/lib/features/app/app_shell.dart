import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/riyadh_time.dart';
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

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;
  late final AppLifecycleListener _lifecycleListener;
  StreamSubscription<String>? _confirmSubscription;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;

  static const _titles = [
    '',
    'العمليات',
    'الميزانيات',
    'الأهداف',
    'الإنجازات',
    'الإعدادات',
  ];

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
      final label = category?.nameAr ?? 'ميزانية';
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const pages = [
      DashboardScreen(),
      TransactionsScreen(),
      BudgetsScreen(),
      GoalsScreen(),
      AchievementsScreen(),
      SettingsScreen(),
    ];

    return Scaffold(
      appBar: _index == 0 ? null : AppBar(title: Text(_titles[_index])),
      body: Stack(
        children: [
          SafeArea(child: IndexedStack(index: _index, children: pages)),
          if (_activeCelebration != null)
            Positioned(
              top: AppSpacing.s5,
              left: AppSpacing.gutter,
              right: AppSpacing.gutter,
              child: _CelebrationBanner(event: _activeCelebration!),
            ),
        ],
      ),
      floatingActionButton: _index <= 1
          ? FloatingActionButton(
              onPressed: () => showCaptureEntrySheet(context),
              backgroundColor: c.primary,
              child: const Icon(AppLucideIcons.plus, color: Colors.white),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: c.surface,
        indicatorColor: c.primary.withValues(alpha: 0.14),
        destinations: const [
          NavigationDestination(
            icon: Icon(AppLucideIcons.home),
            label: 'الرئيسية',
          ),
          NavigationDestination(
            icon: Icon(AppLucideIcons.receipt),
            label: 'العمليات',
          ),
          NavigationDestination(
            icon: Icon(AppLucideIcons.wallet),
            label: 'الميزانيات',
          ),
          NavigationDestination(
            icon: Icon(AppLucideIcons.target),
            label: 'الأهداف',
          ),
          NavigationDestination(
            icon: Icon(AppLucideIcons.medal),
            label: 'الإنجازات',
          ),
          NavigationDestination(
            icon: Icon(AppLucideIcons.wrench),
            label: 'الإعدادات',
          ),
        ],
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
