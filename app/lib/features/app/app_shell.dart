import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_glass_navbar/native_glass_navbar.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
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
import '../capture/capture_runtime.dart';
import '../capture/services/capture_notification_content.dart';
import '../capture/services/capture_sync_service.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/pending_notification_actions.dart';
import '../capture/services/native_capture_bridge.dart';
import '../../core/tracking/user_activity_service.dart';
import '../common/category_catalog.dart';
import '../onboarding/force_update_screen.dart';
import '../dashboard/dashboard_providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../reports/reports_screen.dart';
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
  StreamSubscription<CaptureQuickAction>? _quickActionSubscription;
  StreamSubscription<String>? _navigationSubscription;
  StreamSubscription<SenderBankMappingEntity>? _bankDiscoverySubscription;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;
  bool _isBottomBarVisible = true;
  bool _isConsumingSharedInput = false;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    _confirmSubscription = CaptureRuntime.instance.confirmRequests.listen(
      _openConfirmSheet,
    );
    _quickActionSubscription =
        CaptureRuntime.instance.quickActionRequests.listen(
      _applyQuickAction,
    );
    _navigationSubscription = CaptureRuntime.instance.navigationRequests.listen(
      _handleNotificationRoute,
    );
    _bankDiscoverySubscription =
        CaptureRuntime.instance.bankDiscoveryRequests.listen(
      _openBankDiscoverySheet,
    );
    NativeCaptureBridge.setPendingMessagesHandler(() async {
      if (!mounted) return;
      await _consumeSharedInput();
    });
    NativeCaptureBridge.setApnsTokenUpdatedHandler((token) async {
      try {
        await ref
            .read(captureDeviceRegistrationServiceProvider)
            .syncApnsToken(token);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Capture] APNs token sync skipped: $error');
        }
      }
    });
    NativeCaptureBridge.setNotificationRouteHandler(() async {
      if (!mounted) return;
      await _drainPendingNotificationRoutes();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      unawaited(syncCatalog(ref, force: true));
      unawaited(UserActivityService.ping()); // cold start — always writes
      await _syncNativeCaptureState();
      unawaited(_linkCaptureDeviceToUser());
      await _drainPendingNotificationActions();
      await _consumeSharedInput();
      unawaited(_runLedgerSync());
      await _drainPendingNotificationRoutes();
      await _syncEngagement();
      unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
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
    _quickActionSubscription?.cancel();
    _navigationSubscription?.cancel();
    _bankDiscoverySubscription?.cancel();
    NativeCaptureBridge.setPendingMessagesHandler(null);
    NativeCaptureBridge.setApnsTokenUpdatedHandler(null);
    NativeCaptureBridge.setNotificationRouteHandler(null);
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    unawaited(syncCatalog(ref));
    unawaited(UserActivityService.ping()); // resume — writes only if > 30 min
    await _syncNativeCaptureState();
    await _consumeSharedInput();
    unawaited(_runLedgerSync());
    await _drainPendingNotificationRoutes();
    await _syncEngagement();
    unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
    _drainCelebrations();
  }

  Future<void> _syncNativeCaptureState() async {
    try {
      await ref
          .read(captureDeviceRegistrationServiceProvider)
          .syncNativeState();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] native state sync skipped: $error');
      }
    }
  }

  Future<void> _linkCaptureDeviceToUser() async {
    try {
      await ref
          .read(captureDeviceRegistrationServiceProvider)
          .linkToCurrentUser();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] device link skipped: $error');
      }
    }
  }

  Future<void> _runLedgerSync() async {
    try {
      await ref.read(ledgerSyncEngineProvider).sync();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[LedgerEngine] sync skipped: $error');
      }
    }
    try {
      await ref.read(smartInboxSyncServiceProvider).pull();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SmartInboxSync] pull skipped: $error');
      }
    }
    try {
      await ref.read(planningSyncEngineProvider).sync();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PlanningSync] sync skipped: $error');
      }
    }
  }

  Future<void> _consumeSharedInput() async {
    if (_isConsumingSharedInput) return;
    _isConsumingSharedInput = true;
    try {
      CaptureSyncResult? backendSync;
      try {
        backendSync = await ref.read(captureSyncServiceProvider).sync();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Capture] backend sync skipped: $error');
        }
      }
      final messages = await NativeCaptureBridge.consumePendingSharedMessages();
      if (kDebugMode) {
        debugPrint('[Capture] consumeSharedInput: ${messages.length} messages');
      }
      if (messages.isEmpty) return;

      // Prune old dedup hashes opportunistically on each drain cycle.
      unawaited(ref.read(appDatabaseProvider).pruneOldDedupHashes());

      final ingestUseCase = ref.read(ingestCapturedMessageUseCaseProvider);
      final notificationPreferences =
          await ref.read(loadNotificationPreferencesUseCaseProvider).call();

      String? pendingConfirmationId;
      String? pendingSecondaryNotice;
      SenderBankMappingEntity? pendingBankDiscovery;

      for (final message in messages) {
        if (message.id != null) {
          final alreadySynced =
              backendSync?.importedPayloadIds.contains(message.id) ?? false;
          final alreadyImported = alreadySynced ||
              await ref
                  .read(captureSyncServiceProvider)
                  .isPayloadImported(message.id!);
          if (alreadyImported) {
            if (kDebugMode) {
              debugPrint(
                  '[Capture] skip imported backend payload ${message.id}');
            }
            continue;
          }
        }
        if (kDebugMode) {
          debugPrint(
            '[Capture] processing: source=${message.source} '
            'senderSet=${message.sender != null} '
            'receivedAt=${message.receivedAt?.toIso8601String()} '
            'textLength=${message.text.length}',
          );
        }
        final captured = CapturedMessage(
          text: message.text,
          senderId: message.sender,
          source: message.source,
          receivedAt: message.receivedAt ?? DateTime.now().toUtc(),
        );
        final result = await ingestUseCase.fromCapturedMessage(captured);
        if (kDebugMode) {
          debugPrint(
            '[Capture] disposition=${result.disposition} '
            'hasTransaction=${result.transactionId != null}',
          );
        }
        // AppIntent already showed a notification (status == 'sent'); skip duplicate.
        if (message.status != 'sent') {
          await _showCapturedMessageNotification(
            result,
            notificationPreferences,
          );
        }
        if (result.transactionId != null &&
            result.addTransactionResult.requiresConfirmation) {
          pendingConfirmationId = result.transactionId;
          pendingSecondaryNotice =
              feeNoticeFor(result.addTransactionResult.secondary);
        }
        pendingBankDiscovery ??= await _pendingBankDiscoveryForSender(
          message.sender,
        );
      }
      unawaited(
        ref.read(notificationJourneyServiceProvider).evaluateAfterCapture(),
      );
      if (!mounted) return;

      _refreshAll();

      if (pendingConfirmationId != null) {
        await _openConfirmSheet(
          pendingConfirmationId,
          secondaryNotice: pendingSecondaryNotice,
        );
      }
      if (pendingBankDiscovery != null) {
        await _openBankDiscoverySheet(pendingBankDiscovery);
      }
    } finally {
      _isConsumingSharedInput = false;
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

  Future<void> _showCapturedMessageNotification(
    CapturedMessageResult result,
    NotificationPreferences preferences,
  ) async {
    switch (result.disposition) {
      case CapturedMessageDisposition.ignored:
        return;
      case CapturedMessageDisposition.notifyOnly:
        final content = buildConfirmedCaptureContent(
            result.addTransactionResult.transaction);
        await LocalNotificationService.instance.showLightCaptureNotification(
          title: content.title,
          body: content.body,
          preferences: preferences,
        );
      case CapturedMessageDisposition.requestConfirmation:
        final transaction = result.addTransactionResult.transaction;
        if (transaction == null) return;
        final content =
            buildReviewCaptureContent(result.addTransactionResult.transaction);
        await LocalNotificationService.instance.showReviewNotification(
          transactionId: transaction.id,
          title: content.title,
          body: content.body,
          preferences: preferences,
        );
      case CapturedMessageDisposition.suspiciousDuplicate:
        final content = buildDuplicateCaptureContent(
            result.addTransactionResult.transaction);
        await LocalNotificationService.instance.showLightCaptureNotification(
          title: content.title,
          body: content.body,
          preferences: preferences,
        );
      case CapturedMessageDisposition.unprocessable:
        await LocalNotificationService.instance.showLightCaptureNotification(
          title: 'رسالة غير مدعومة',
          body: 'افتح قرش والصق الرسالة يدوياً للإضافة.',
          preferences: preferences,
        );
    }
  }

  Future<void> _syncEngagement() async {
    final preferences =
        await ref.read(loadNotificationPreferencesUseCaseProvider).call();
    final snapshot = await ref.read(budgetProgressUseCaseProvider).call();
    final catalog = await ref.read(categoryCatalogProvider.future);
    // Budget notifications follow the active/default account currency.
    final budgetCurrency = await ref.read(baseCurrencyProvider.future);
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

  Future<void> _openConfirmSheet(
    String transactionId, {
    String? secondaryNotice,
  }) async {
    if (!mounted) {
      return;
    }
    _refreshAll();
    await showConfirmTransactionSheet(
      context,
      transactionId,
      secondaryNotice: secondaryNotice,
    );
    await _syncEngagement();
    _drainCelebrations();
  }

  /// زر "تأكيد ✓" أو "تجاهل" من الإشعار والتطبيق شغال — ينفَّذ مباشرة
  /// عبر نفس مسار الشاشات (usecase/repository) ثم تحديث الواجهة.
  Future<void> _applyQuickAction(CaptureQuickAction action) async {
    try {
      if (action.confirm) {
        await ref.read(confirmTransactionUseCaseProvider)(action.transactionId);
      } else {
        await ref
            .read(transactionRepositoryProvider)
            .deleteTransaction(action.transactionId);
      }
    } catch (_) {
      // العملية قد تكون أُكّدت/حُذفت من مكان آخر بالفعل.
    }
    if (!mounted) return;
    _refreshAll();
    await _syncEngagement();
    _drainCelebrations();
  }

  /// إجراءات فشلت في الـ background (جهاز مقفول → Keychain غير متاح) —
  /// تُطبَّق هنا عند أول فتح.
  Future<void> _drainPendingNotificationActions() async {
    final actions = await PendingNotificationActions.drain();
    for (final action in actions) {
      await _applyQuickAction(
        CaptureQuickAction(
          transactionId: action.transactionId,
          confirm: action.confirm,
        ),
      );
    }
  }

  Future<void> _drainPendingNotificationRoutes() async {
    final routes = await NativeCaptureBridge.consumePendingNotificationRoutes();
    if (routes.isEmpty) return;
    CaptureSyncResult? syncResult;
    try {
      syncResult = await ref.read(captureSyncServiceProvider).sync();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] notification route sync skipped: $error');
      }
    }
    _refreshAll();
    if (!mounted) return;
    final route = routes.last;
    final target = await _routeForCaptureNotification(route, syncResult);
    _handleNotificationRoute(target);
  }

  Future<String> _routeForCaptureNotification(
    CaptureNotificationRoute route,
    CaptureSyncResult? syncResult,
  ) async {
    final type = route.notificationType;
    if (type == 'needs_review' || type == 'suspicious_duplicate') {
      return '/smart-inbox';
    }
    final direct = route.transactionId;
    if (direct != null &&
        direct.isNotEmpty &&
        !direct.startsWith('rejected:')) {
      return '/transaction/$direct';
    }
    final payloadId = route.payloadId ?? route.smartInboxItemId;
    if (payloadId != null && payloadId.isNotEmpty) {
      if (syncResult?.importedPayloadIds.contains(payloadId) ?? false) {
        final txId = await ref
            .read(captureSyncServiceProvider)
            .transactionIdForPayload(payloadId);
        if (txId != null && !txId.startsWith('rejected:')) {
          return '/transaction/$txId';
        }
      }
      final txId = await ref
          .read(captureSyncServiceProvider)
          .transactionIdForPayload(payloadId);
      if (txId != null && !txId.startsWith('rejected:')) {
        return '/transaction/$txId';
      }
    }
    return '/smart-inbox';
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
    if (route.startsWith('/transaction/')) {
      context.push(route);
      return;
    }
    if (route == '/smart-inbox') {
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPageTabProvider.notifier).state = 0;
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
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
    // Reports embeds a TabBarView (needs bounded height). IndexedStack lays out
    // every child even when offstage, so build it only when its tab is active.
    final pages = [
      const DashboardScreen(),
      const TransactionsScreen(),
      const BudgetsScreen(),
      const SettingsScreen(),
      index == 4 ? const ReportsScreen() : const SizedBox.shrink(),
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
          boxShadow: AppShadows.float,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: AppTypography.bodyStrong(c.textPrimary)),
            const SizedBox(height: AppSpacing.s1),
            Text(event.message, style: AppTypography.callout(c.textSecondary)),
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
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;

  static const _items = [
    _BottomBarItem(
      page: 3,
      icon: AppLucideIcons.settings,
      symbol: 'ellipsis.circle.fill',
      label: 'المزيد',
    ),
    _BottomBarItem(
      page: 4,
      icon: AppLucideIcons.shapes,
      symbol: 'chart.bar.fill',
      label: 'التحليلات',
    ),
    _BottomBarItem(
      page: 0,
      icon: AppLucideIcons.home,
      symbol: 'house.fill',
      label: 'الرئيسية',
    ),
    _BottomBarItem(
      page: 2,
      icon: AppLucideIcons.walletCards,
      symbol: 'creditcard.fill',
      label: 'الميزانيات',
    ),
    _BottomBarItem(
      page: 1,
      icon: AppLucideIcons.receipt,
      symbol: 'doc.text.fill',
      label: 'العمليات',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selectedVisualIndex = _items.indexWhere(
      (item) => item.page == currentIndex,
    );
    final nativeIndex = selectedVisualIndex == -1 ? 0 : selectedVisualIndex;

    return NativeGlassNavBar(
      currentIndex: nativeIndex,
      tintColor: c.cta,
      tabs: [
        for (final item in _items)
          NativeGlassNavBarItem(label: item.label, symbol: item.symbol),
      ],
      onTap: (visualIndex) {
        if (visualIndex < 0 || visualIndex >= _items.length) return;
        HapticFeedback.selectionClick();
        onSelect(_items[visualIndex].page);
      },
      fallback: _FlutterGlassBottomBar(
        currentIndex: currentIndex,
        onSelect: onSelect,
        items: _items,
      ),
    );
  }
}

class _FlutterGlassBottomBar extends StatelessWidget {
  const _FlutterGlassBottomBar({
    required this.currentIndex,
    required this.onSelect,
    required this.items,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final List<_BottomBarItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final selectedVisualIndex = items.indexWhere(
      (item) => item.page == currentIndex,
    );
    const barRadius = 32.0;

    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s5,
          AppSpacing.s2,
          AppSpacing.s5,
          safeBottom > 0 ? safeBottom + AppSpacing.s2 : AppSpacing.s5,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(barRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              height: 62,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                color: c.surface.withValues(alpha: isDark ? 0.66 : 0.72),
                borderRadius: BorderRadius.circular(barRadius),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: isDark ? 0.08 : 0.52),
                    c.surface.withValues(alpha: isDark ? 0.50 : 0.62),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.66),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.13),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  _GlassTabIndicator(
                    selectedIndex:
                        selectedVisualIndex == -1 ? 0 : selectedVisualIndex,
                    tabCount: items.length,
                    isDark: isDark,
                    accent: c.cta,
                  ),
                  Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      for (final item in items)
                        Expanded(
                          child: _NavTab(
                            item: item,
                            selected: item.page == currentIndex,
                            onTap: onSelect,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassTabIndicator extends StatelessWidget {
  const _GlassTabIndicator({
    required this.selectedIndex,
    required this.tabCount,
    required this.isDark,
    required this.accent,
  });

  final int selectedIndex;
  final int tabCount;
  final bool isDark;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final relative = tabCount <= 1 ? 0.5 : selectedIndex / (tabCount - 1);
    final alignment = Alignment((relative * 2) - 1, 0);

    return Positioned.fill(
      child: AnimatedAlign(
        alignment: alignment,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        child: FractionallySizedBox(
          widthFactor: 1 / tabCount,
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.44),
                borderRadius: BorderRadius.circular(25),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.72),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: isDark ? 0.16 : 0.62),
                    accent.withValues(alpha: isDark ? 0.12 : 0.10),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.07),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: accent.withValues(alpha: isDark ? 0.10 : 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBarItem {
  const _BottomBarItem({
    required this.page,
    required this.icon,
    required this.symbol,
    required this.label,
  });

  final int page;
  final IconData icon;
  final String symbol;
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
    final activeColor = c.cta;
    final inactiveColor =
        isDark ? c.textSecondary.withValues(alpha: 0.72) : c.textMuted;

    return Semantics(
      label: item.label,
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap(item.page);
        },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          scale: selected ? 1.03 : 1,
          child: SizedBox(
            height: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.icon,
                  color: selected ? activeColor : inactiveColor,
                  size: selected ? 22 : 21,
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 14,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      style: AppTypography.caption(
                        selected ? activeColor : inactiveColor,
                      ).copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
