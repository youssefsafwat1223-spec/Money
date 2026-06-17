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
import '../../domain/entities/captured_message.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../domain/services/notification_planner.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../achievements/achievements_providers.dart';
import '../bank_discovery/bank_discovery_confirmation_sheet.dart';
import '../budgets/budgets_providers.dart';
import '../budgets/budgets_screen.dart';
import '../capture/capture_entry_sheet.dart';
import '../capture/capture_runtime.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/native_capture_bridge.dart';
import '../../core/tracking/user_activity_service.dart';
import '../common/category_catalog.dart';
import '../common/widgets/announcement_banner.dart';
import '../onboarding/force_update_screen.dart';
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
  StreamSubscription<SenderBankMappingEntity>? _bankDiscoverySubscription;
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
    _bankDiscoverySubscription =
        CaptureRuntime.instance.bankDiscoveryRequests.listen(
      _openBankDiscoverySheet,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      unawaited(syncCatalog(ref, force: true));
      unawaited(UserActivityService.ping()); // cold start — always writes
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
    _bankDiscoverySubscription?.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    unawaited(syncCatalog(ref));
    unawaited(UserActivityService.ping()); // resume — writes only if > 30 min
    await _consumeSharedInput();
    await _syncEngagement();
    _drainCelebrations();
  }

  Future<void> _consumeSharedInput() async {
    final messages = await NativeCaptureBridge.consumePendingSharedMessages();
    if (messages.isEmpty) return;

    // Prune old dedup hashes opportunistically on each drain cycle.
    unawaited(ref.read(appDatabaseProvider).pruneOldDedupHashes());

    final ingestUseCase = ref.read(ingestCapturedMessageUseCaseProvider);

    String? pendingConfirmationId;
    SenderBankMappingEntity? pendingBankDiscovery;
    final unprocessableSenders = <String>[];

    for (final message in messages) {
      final captured = CapturedMessage(
        text: message.text,
        senderId: message.sender,
        source: message.source,
        receivedAt: DateTime.now().toUtc(),
      );
      final result = await ingestUseCase.fromCapturedMessage(captured);
      if (result.transactionId != null &&
          result.addTransactionResult.requiresConfirmation) {
        pendingConfirmationId = result.transactionId;
      }
      if (result.disposition == CapturedMessageDisposition.unprocessable) {
        unprocessableSenders.add(message.sender ?? 'مرسل غير معروف');
      }
      pendingBankDiscovery ??= await _pendingBankDiscoveryForSender(
        message.sender,
      );
    }
    if (!mounted) return;

    _refreshAll();

    // Notify user about messages that couldn't be parsed so they can add manually.
    for (final sender in unprocessableSenders) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('لم نتمكن من تحليل رسالة $sender. اضغط للإضافة يدوياً.'),
        action: SnackBarAction(
          label: 'إضافة',
          onPressed: () => showCaptureEntrySheet(context),
        ),
        duration: const Duration(seconds: 6),
      ));
    }

    if (pendingConfirmationId != null) {
      await _openConfirmSheet(pendingConfirmationId);
    }
    if (pendingBankDiscovery != null) {
      await _openBankDiscoverySheet(pendingBankDiscovery);
    }
  }

  Future<SenderBankMappingEntity?> _pendingBankDiscoveryForSender(
    String? senderId,
  ) async {
    final cleanSender = senderId?.trim();
    if (cleanSender == null || cleanSender.isEmpty) return null;
    final mapping = await ref
        .read(senderBankMappingRepositoryProvider)
        .getActiveSuggestionBySender(cleanSender);
    if (mapping?.status == SenderBankMappingStatus.pending) {
      return mapping;
    }
    return null;
  }

  Future<void> _syncEngagement() async {
    final preferences =
        await ref.read(loadNotificationPreferencesUseCaseProvider).call();
    final snapshot = await ref.read(budgetProgressUseCaseProvider).call();
    final catalog = await ref.read(categoryCatalogProvider.future);
    // Use settings currency for budget notifications; budgets don't have own currency.
    final budgetCurrency =
        ref.read(userSettingsProvider).valueOrNull?.currency ?? 'SAR';
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
              'وصلت إلى ${(alert.progress.ratio * 100).round()}% من ميزانية ${alert.progress.budget.amount.toStringAsFixed(0)} $budgetCurrency.',
          type: NotificationType.budgetWarning,
          preferences: preferences,
        );
      } else {
        await LocalNotificationService.instance.showBudgetAlert(
          title: 'تم تجاوز ميزانية $label',
          body:
              'تجاوزت الميزانية بمقدار ${alert.progress.remaining.abs().toStringAsFixed(0)} $budgetCurrency.',
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

  Future<void> _openBankDiscoverySheet(SenderBankMappingEntity mapping) async {
    if (!mounted) {
      return;
    }
    await showBankDiscoveryConfirmationSheet(context, mapping);
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
    // Force update blocks the entire app — check before rendering anything else.
    final forceUpdateAsync = ref.watch(hasForceUpdateProvider);
    if (forceUpdateAsync.valueOrNull == true) {
      return const ForceUpdateScreen();
    }

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
        backgroundColor: c.bg,
        appBar: null,
        body: Stack(
          children: [
            // محتوى الصفحة الرئيسي — بدون SafeArea علوي حتى يمتد الهيدر
            // المتدرّج خلف شريط الحالة (كل شاشة تتكفّل بالمساحة الآمنة داخليًا).
            IndexedStack(index: index, children: pages),
            // Announcement banner — shown above content, below celebrations.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(bottom: false, child: AnnouncementBanner()),
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
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
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
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: AppTypography.bodyStrong(c.textMain)),
            const SizedBox(height: AppSpacing.s1),
            Text(event.message, style: AppTypography.callout(c.textLight)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1C1C1E).withValues(alpha: 0.8)
                    : Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.05),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
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

    final activeColor = c.accent;
    final inactiveColor = c.textLight;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(item.index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: 50,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              item.icon,
              color: selected ? activeColor : inactiveColor,
              size: 22,
            ),
            if (selected) ...[
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: AppTypography.caption(activeColor).copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 10.0,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: isDark ? c.accent : c.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: (isDark ? c.accent : c.primary).withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(AppLucideIcons.plus,
            color: isDark ? c.primary : Colors.white, size: 24),
      ),
    );
  }
}
