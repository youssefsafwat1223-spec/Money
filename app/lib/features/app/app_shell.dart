import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/services/notification_planner.dart';
import '../achievements/achievements_providers.dart';
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
  StreamSubscription<String>? _navigationSubscription;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;
  bool _isBottomBarVisible = true;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    _confirmSubscription = CaptureRuntime.instance.confirmRequests.listen(
      _openConfirmSheet,
    );
    _navigationSubscription = CaptureRuntime.instance.navigationRequests.listen(
      _handleNotificationRoute,
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
      final initialRoute = CaptureRuntime.instance.takeInitialNavigation();
      if (initialRoute != null && mounted) {
        _handleNotificationRoute(initialRoute);
      }
    });
  }

  @override
  void dispose() {
    _celebrationTimer?.cancel();
    _confirmSubscription?.cancel();
    _navigationSubscription?.cancel();
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
      final label =
          alert.budget.categoryId == BudgetEntity.allExpensesCategoryId
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

    final passive =
        await ref.read(recordEngagementUseCaseProvider).evaluatePassiveBadges();
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
    final bills = await ref.read(billRepositoryProvider).getAll();
    final planned = const NotificationPlanner().planScheduled(
      preferences: preferences,
      bills: bills,
      nowRiyadh: RiyadhTime.toRiyadh(DateTime.now().toUtc()),
    );
    await LocalNotificationService.instance.schedulePlannedNotifications(
      planned,
    );
    _refreshAll();
  }

  void _refreshAll() {
    refreshTransactions(ref);
    refreshBudgets(ref);
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
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _celebrationTimer = Timer(
      disableAnimations
          ? const Duration(milliseconds: 10)
          : const Duration(seconds: 2),
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

  void _handleNotificationRoute(String route) {
    if (!mounted) return;
    if (route == '/reports') {
      context.push('/reports');
      return;
    }
    if (route == '/') {
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPageTabProvider.notifier).state = 1;
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
      SettingsScreen(),
    ];

    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction == ScrollDirection.reverse) {
          if (_isBottomBarVisible) {
            setState(() => _isBottomBarVisible = false);
          }
        } else if (notification.direction == ScrollDirection.forward) {
          if (!_isBottomBarVisible) {
            setState(() => _isBottomBarVisible = true);
          }
        }
        return true;
      },
      child: Scaffold(
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
        bottomNavigationBar: AnimatedSlide(
          offset: _isBottomBarVisible ? Offset.zero : const Offset(0, 1.5),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          child: _FloatingBottomBar(
            currentIndex: index,
            onSelect: (next) =>
                ref.read(shellIndexProvider.notifier).state = next,
            onAdd: () => showCaptureEntrySheet(context),
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

class _FloatingBottomBar extends StatelessWidget {
  const _FloatingBottomBar({
    required this.currentIndex,
    required this.onSelect,
    required this.onAdd,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  static const _items = [
    _BottomBarItem(index: 0, icon: AppLucideIcons.home, label: 'الرئيسية'),
    _BottomBarItem(index: 1, icon: AppLucideIcons.receipt, label: 'العمليات'),
    _BottomBarItem(index: 2, icon: AppLucideIcons.wallet, label: 'الميزانيات'),
    _BottomBarItem(index: 3, icon: AppLucideIcons.wrench, label: 'الإعدادات'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              height: 72,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: c.surface.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.42),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Row(
                textDirection: TextDirection.rtl,
                children: [
                  _NavSlot(
                      item: _items[0],
                      currentIndex: currentIndex,
                      onTap: onSelect),
                  _NavSlot(
                      item: _items[1],
                      currentIndex: currentIndex,
                      onTap: onSelect),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _CenterAddButton(onTap: onAdd),
                  ),
                  _NavSlot(
                      item: _items[2],
                      currentIndex: currentIndex,
                      onTap: onSelect),
                  _NavSlot(
                      item: _items[3],
                      currentIndex: currentIndex,
                      onTap: onSelect),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  const _NavSlot({
    required this.item,
    required this.currentIndex,
    required this.onTap,
  });

  final _BottomBarItem item;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final selected = item.index == currentIndex;
    return Expanded(
      flex: selected ? 16 : 10,
      child: _NavTab(item: item, selected: selected, onTap: onTap),
    );
  }
}

class _BottomBarItem {
  const _BottomBarItem({
    required this.index,
    required this.icon,
    required this.label,
  });

  final int index;
  final IconData icon;
  final String label;
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _BottomBarItem item;
  final bool selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // High contrast color selections for active and inactive states
    final activeColor = isDark ? Colors.white : c.primary;
    final activeBgColor = isDark
        ? c.primary.withValues(alpha: 0.24)
        : c.primary.withValues(alpha: 0.12);
    final activeBorderColor = isDark
        ? c.primary.withValues(alpha: 0.35)
        : c.primary.withValues(alpha: 0.18);
    final inactiveColor =
        isDark ? c.textLight.withValues(alpha: 0.7) : c.textLight;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(item.index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        height: 50,
        padding: EdgeInsets.symmetric(horizontal: selected ? 8 : 4),
        decoration: BoxDecoration(
          color: selected ? activeBgColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? activeBorderColor : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              item.icon,
              color: selected ? activeColor : inactiveColor,
              size: 21,
            ),
            if (selected) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: AppTypography.caption(activeColor).copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CenterAddButton extends StatelessWidget {
  const _CenterAddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [c.accent, c.accent.withValues(alpha: 0.86)],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: c.accent.withValues(alpha: 0.36),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(AppLucideIcons.plus, color: c.primary, size: 27),
      ),
    );
  }
}
