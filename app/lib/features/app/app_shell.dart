import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_glass_navbar/native_glass_navbar.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/captured_message.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
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
import '../capture/services/notification_log_service.dart';
import '../capture/services/pending_notification_actions.dart';
import '../capture/services/native_capture_bridge.dart';
import '../../core/tracking/user_activity_service.dart';
import '../cards/cards_providers.dart';
import '../common/category_catalog.dart';
import '../onboarding/force_update_screen.dart';
import '../dashboard/dashboard_providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_providers.dart';
import '../reports/reports_providers.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_providers.dart';
import '../settings/settings_screen.dart';
import '../subscriptions/subscriptions_providers.dart';
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
  SessionStatus? _lastSessionStatus;
  bool? _lastAccountsSupabasePrimary;
  bool? _lastTransactionsSupabasePrimary;
  bool? _lastBudgetsSupabasePrimary;
  bool? _lastGoalsSupabasePrimary;
  bool? _lastSubscriptionsSupabasePrimary;
  bool? _lastPlansSupabasePrimary;
  bool? _lastSmartInboxSupabasePrimary;
  bool _remoteOnboardingCompletionSynced = false;
  bool _isReconcilingAfterResume = false;

  /// Transaction ids already auto-opened (confirm sheet or a `/transaction/`
  /// route push) by a notification-driven path this session. A single
  /// notification tap can be observed by more than one of this app's
  /// overlapping routing mechanisms at once — the native pending-route queue
  /// drained in [_drainPendingNotificationRoutes], flutter_local_notifications'
  /// own cold-launch details (`CaptureRuntime.takeInitialConfirmation`/
  /// `takeInitialNavigation`), and the live [CaptureRuntime] streams — and
  /// without this guard two of them can both fire for the same tap, stacking
  /// a confirm sheet and a full transaction-details route push on top of each
  /// other (visible as the screen "loading twice"/flickering right after
  /// opening a transaction notification). Each transaction id is claimed at
  /// most once per app session; a later, genuinely separate notification for
  /// a different transaction is unaffected since ids are unique per capture.
  final Set<String> _autoNavigatedTransactionIds = {};

  bool _claimAutoNavigation(String transactionId) =>
      _autoNavigatedTransactionIds.add(transactionId);

  @override
  void initState() {
    super.initState();
    _lastSessionStatus = AppSession.instance.status;
    AppSession.instance.addListener(_handleSessionStatusChange);
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

    // Providers mounted with the currently resolved repository flags. Keep
    // that state as the baseline so the first catalog check only refreshes
    // financial data when sync actually changes a flag.
    _captureSupabasePrimaryFlagSnapshot();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Defensive: the router should already have redirected away from this
      // shell for a non-authenticated status before it ever mounted, but
      // never run Supabase-primary startup work without re-confirming.
      if (!await _revalidateAuthSession()) return;
      unawaited(_syncRemoteOnboardingCompletion());
      await syncCatalog(ref, force: true);
      // Same coordinated path as app resume — drains any Confirm/Dismiss
      // notification action applied while the app was closed, repairs any
      // dirty Supabase-mirror cache, and refreshes financial providers.
      await _reconcileDataAfterResume();
      _handleSupabasePrimaryFlagTransition();
      unawaited(UserActivityService.ping()); // cold start — always writes
      await _syncNativeCaptureState();
      unawaited(_linkCaptureDeviceToUser());
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
    AppSession.instance.removeListener(_handleSessionStatusChange);
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

  /// Centralized reaction to any session-status change while this shell is
  /// mounted — covers both an explicit sign-out (Settings) and the
  /// auth-required recovery path (`_handleAuthRequiredFailure`) in one place,
  /// satisfying "financial providers invalidated" for either trigger without
  /// duplicating the provider list at each call site. The router redirects
  /// away from this shell on the same notification; invalidating here just
  /// ensures no stale cached data from the previous session is still held by
  /// the (app-lifetime) ProviderScope for whoever signs in next.
  void _handleSessionStatusChange() {
    final now = AppSession.instance.status;
    final wasAuthenticated = _lastSessionStatus == SessionStatus.authenticated;
    _lastSessionStatus = now;
    if (wasAuthenticated && now != SessionStatus.authenticated) {
      if (!mounted) return;
      _invalidateFinancialProviders();
      ref.read(activeAccountIdProvider.notifier).state = null;
      if (kDebugMode) {
        debugPrint(
          '[AppShell] session status → $now: financial providers invalidated',
        );
      }
    }
  }

  Future<void> _onResume() async {
    // A refresh token can be revoked/expire while backgrounded with no
    // auth-state event ever delivered until something touches the client
    // again — re-check before running any Supabase-primary-dependent work.
    if (!await _revalidateAuthSession()) return;
    unawaited(_syncRemoteOnboardingCompletion());
    await syncCatalog(ref);
    // Reconciles writes that landed through a connection other than this
    // shell's live `appDatabaseProvider` instance while the app was
    // backgrounded — background notification Confirm/Dismiss actions open
    // their own `AppDatabase` connection (local_notification_service.dart),
    // so `dbRevisionProvider` never ticks for them on its own. See
    // docs/STALE_UI_ROOT_CAUSE_REPORT.md.
    await _reconcileDataAfterResume();
    _handleSupabasePrimaryFlagTransition();
    unawaited(UserActivityService.ping()); // resume — writes only if > 30 min
    await _syncNativeCaptureState();
    await _consumeSharedInput();
    unawaited(_runLedgerSync());
    await _drainPendingNotificationRoutes();
    await _syncEngagement();
    unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
    _drainCelebrations();
  }

  /// Returns false (recovery already triggered, router about to redirect
  /// away from this shell) when the live Supabase session turned out to be
  /// invalid — callers must stop running further Supabase-primary work.
  Future<bool> _revalidateAuthSession() async {
    if (!SupabaseConfig.isConfigured) return true;
    await AppSession.instance
        .revalidateSupabaseSessionOnResume(supabase.Supabase.instance.client);
    return AppSession.instance.status != SessionStatus.sessionExpired;
  }

  Future<void> _syncRemoteOnboardingCompletion() async {
    if (_remoteOnboardingCompletionSynced) return;
    final synced = await AppSession.instance.syncRemoteOnboardingCompletion();
    if (synced) _remoteOnboardingCompletionSynced = true;
  }

  /// The one centralized entry point for a Supabase-primary repository call
  /// failing with `auth_required`. Never catch this and show a generic
  /// dashboard/error message instead — always route through here so the user
  /// ends up back at sign-in, not stuck on a screen that can never load.
  Future<void> _handleAuthRequiredFailure() async {
    if (kDebugMode) {
      debugPrint('[AppShell] auth_required — triggering session recovery');
    }
    await AppSession.instance.handleAuthRequiredFailure();
  }

  Future<void> _repairDirtyFinancialCaches() async {
    try {
      await ref.read(financialCacheRepairServiceProvider).repairDirty();
    } catch (error) {
      // Keep the dirty marker intact. Routed repositories will fail closed
      // instead of trusting Drift until a later online repair succeeds.
      if (kDebugMode) {
        debugPrint('[FinancialCache] repair pending: ${error.runtimeType}');
      }
    }
  }

  /// Financial-data providers that may hold stale results after a write that
  /// bypassed this shell's live `dbRevisionProvider` connection (background
  /// notification actions, a repaired dirty mirror, or a session change).
  /// Shared by [_handleSessionStatusChange] and [_reconcileDataAfterResume]
  /// so both stay in sync with one list instead of two.
  void _invalidateFinancialProviders() {
    ref.invalidate(accountsProvider);
    ref.invalidate(transactionsListProvider);
    ref.invalidate(billsViewProvider);
    ref.invalidate(budgetsViewProvider);
    ref.invalidate(goalsListProvider);
    ref.invalidate(savedBillsProvider);
    ref.invalidate(plansWithSpentProvider);
    ref.invalidate(smartInboxItemsProvider);
    ref.invalidate(cardSummariesProvider);
    ref.invalidate(subscriptionsProvider);
    ref.invalidate(reportsProvider);
    ref.invalidate(dashboardDataProvider);
  }

  /// Coordinated reconciliation for writes that `dbRevisionProvider` cannot
  /// see on its own — background notification Confirm/Dismiss actions write
  /// through a separate `AppDatabase` connection
  /// (local_notification_service.dart's `_backgroundTapHandler`), and a
  /// Supabase-primary mirror-write failure only marks the cache dirty
  /// without ticking the revision counter. Runs on both initial startup and
  /// every app resume (see `initState` and [_onResume]) so the two paths
  /// can't drift apart. See docs/STALE_UI_ROOT_CAUSE_REPORT.md.
  ///
  /// Guarded against re-entry: a second resume firing while the first is
  /// still running is a no-op rather than a duplicate reconciliation pass.
  Future<void> _reconcileDataAfterResume() async {
    if (_isReconcilingAfterResume) {
      if (kDebugMode) {
        debugPrint('[Reconcile] already running — skipping duplicate trigger');
      }
      return;
    }
    _isReconcilingAfterResume = true;
    if (kDebugMode) debugPrint('[Reconcile] start');
    try {
      // A. Pending notification actions — idempotent (PendingNotificationActions
      // .drain() empties the queue first; _applyQuickAction tolerates a
      // confirm/delete that already landed via the background path).
      await _drainPendingNotificationActions();
      if (!mounted) return;
      // B. Repair any Supabase-mirror cache marked dirty by a failed local
      // write — this itself writes through the live AppDatabase connection,
      // so it also ticks dbRevisionProvider for anything that watches it.
      await _repairDirtyFinancialCaches();
      if (!mounted) return;
      // C. Explicit invalidation as a safety net — do not rely solely on
      // dbRevisionProvider having ticked for A/B above.
      _invalidateFinancialProviders();
      if (kDebugMode) debugPrint('[Reconcile] success');
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[Reconcile] failed: $error\n$stackTrace');
      }
    } finally {
      _isReconcilingAfterResume = false;
    }
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

  /// Compares direct-repository flags after catalog refresh and invalidates
  /// every cached FutureProvider that may still contain results from the old
  /// repository. Routed repositories read the flag per operation; this handles
  /// providers that otherwise would not execute another operation on resume.
  /// Account transition also resets the selected account because local/server
  /// identifiers differ during rollout.
  ///
  /// عند تغيّر علامة الحسابات يُعاد
  /// ضبط الحساب النشط المختار — حتى لا يبقى AccountEntity بمعرّف محلي قديم
  /// معروضًا في نموذج أو مزوّد مفتوح بعد التحوّل. لا يُشغَّل خارج نقطتَي
  /// بدء التشغيل/الاستئناف — أي تغيير للعلامة أثناء الجلسة الأمامية نفسها
  /// لا يُلتقَط إلا عند الاستئناف/بدء التشغيل التالي (موثَّق في خطة المرحلة 2).
  void _captureSupabasePrimaryFlagSnapshot() {
    final flags = featureFlags;
    _lastAccountsSupabasePrimary = flags.getBool('accounts_supabase_primary');
    _lastTransactionsSupabasePrimary =
        flags.getBool('transactions_supabase_primary');
    _lastBudgetsSupabasePrimary = flags.getBool('budgets_supabase_primary');
    _lastGoalsSupabasePrimary = flags.getBool('goals_supabase_primary');
    _lastSubscriptionsSupabasePrimary =
        flags.getBool('subscriptions_supabase_primary');
    _lastPlansSupabasePrimary = flags.getBool('plans_supabase_primary');
    _lastSmartInboxSupabasePrimary =
        flags.getBool('smart_inbox_supabase_primary');
  }

  void _handleSupabasePrimaryFlagTransition() {
    if (!mounted) return;
    final flags = featureFlags;
    final accountsNow = flags.getBool('accounts_supabase_primary');
    final transactionsNow = flags.getBool('transactions_supabase_primary');
    final budgetsNow = flags.getBool('budgets_supabase_primary');
    final goalsNow = flags.getBool('goals_supabase_primary');
    final subscriptionsNow = flags.getBool('subscriptions_supabase_primary');
    final plansNow = flags.getBool('plans_supabase_primary');
    final smartInboxNow = flags.getBool('smart_inbox_supabase_primary');

    final accountsChanged = _lastAccountsSupabasePrimary != null &&
        _lastAccountsSupabasePrimary != accountsNow;
    final transactionsChanged = _lastTransactionsSupabasePrimary != null &&
        _lastTransactionsSupabasePrimary != transactionsNow;
    final budgetsChanged = _lastBudgetsSupabasePrimary != null &&
        _lastBudgetsSupabasePrimary != budgetsNow;
    final goalsChanged = _lastGoalsSupabasePrimary != null &&
        _lastGoalsSupabasePrimary != goalsNow;
    final subscriptionsChanged = _lastSubscriptionsSupabasePrimary != null &&
        _lastSubscriptionsSupabasePrimary != subscriptionsNow;
    final plansChanged = _lastPlansSupabasePrimary != null &&
        _lastPlansSupabasePrimary != plansNow;
    final smartInboxChanged = _lastSmartInboxSupabasePrimary != null &&
        _lastSmartInboxSupabasePrimary != smartInboxNow;

    if (accountsChanged) {
      ref.invalidate(accountsProvider);
      ref.read(activeAccountIdProvider.notifier).state = null;
      if (kDebugMode) {
        debugPrint(
            '[Phase2] accounts_supabase_primary changed → providers invalidated');
      }
    }
    if (transactionsChanged) {
      ref.invalidate(transactionsListProvider);
      ref.invalidate(billsViewProvider);
      if (kDebugMode) {
        debugPrint(
            '[Phase2] transactions_supabase_primary changed → providers invalidated');
      }
    }
    if (budgetsChanged || goalsChanged) {
      ref.invalidate(budgetsViewProvider);
    }
    if (goalsChanged) {
      ref.invalidate(goalsListProvider);
    }
    if (subscriptionsChanged) {
      ref.invalidate(savedBillsProvider);
      ref.invalidate(billsViewProvider);
    }
    if (plansChanged) {
      ref.invalidate(plansWithSpentProvider);
    }
    if (smartInboxChanged) {
      ref.invalidate(smartInboxItemsProvider);
    }
    if (accountsChanged ||
        transactionsChanged ||
        budgetsChanged ||
        goalsChanged ||
        subscriptionsChanged) {
      ref.invalidate(dashboardDataProvider);
    }

    _lastAccountsSupabasePrimary = accountsNow;
    _lastTransactionsSupabasePrimary = transactionsNow;
    _lastBudgetsSupabasePrimary = budgetsNow;
    _lastGoalsSupabasePrimary = goalsNow;
    _lastSubscriptionsSupabasePrimary = subscriptionsNow;
    _lastPlansSupabasePrimary = plansNow;
    _lastSmartInboxSupabasePrimary = smartInboxNow;
  }

  Future<void> _runLedgerSync() async {
    final flags = featureFlags;
    if (!flags.getBool('transactions_supabase_primary')) {
      try {
        await ref.read(ledgerSyncEngineProvider).sync();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[LedgerEngine] sync skipped: ${error.runtimeType}');
        }
      }
    }
    if (!flags.getBool('smart_inbox_supabase_primary')) {
      try {
        await ref.read(smartInboxSyncServiceProvider).pull();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[SmartInboxSync] pull skipped: ${error.runtimeType}');
        }
      }
    }
    final allPlanningPrimary = flags.getBool('accounts_supabase_primary') &&
        flags.getBool('budgets_supabase_primary') &&
        flags.getBool('subscriptions_supabase_primary') &&
        flags.getBool('goals_supabase_primary') &&
        flags.getBool('plans_supabase_primary');
    if (!allPlanningPrimary) {
      try {
        await ref.read(planningSyncEngineProvider).sync();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[PlanningSync] sync skipped: ${error.runtimeType}');
        }
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
      } on AuthRepoException {
        await _handleAuthRequiredFailure();
        return;
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Capture] backend sync skipped: $error');
        }
      }
      final messages = await NativeCaptureBridge.consumePendingSharedMessages();
      if (kDebugMode) {
        debugPrint('[Capture] consumeSharedInput: ${messages.length} messages');
      }

      if (messages.isNotEmpty) {
        // Prune old dedup hashes opportunistically on each drain cycle.
        unawaited(ref.read(appDatabaseProvider).pruneOldDedupHashes());
      }

      final ingestUseCase = ref.read(ingestCapturedMessageUseCaseProvider);
      final notificationPreferences =
          await ref.read(loadNotificationPreferencesUseCaseProvider).call();

      String? pendingConfirmationId;
      String? pendingSecondaryNotice;
      SenderBankMappingEntity? pendingBankDiscovery;

      for (final message in messages) {
        // كل رسالة في try مستقلة: السحب من الطابور الأصلي مدمِّر، وفشل رسالة
        // واحدة كان يُسقط بقية الرسائل المسحوبة بلا رجعة. الفاشلة تُعاد
        // للطابور الأصلي (بدون إيقاظ فوري) وتُعاد محاولتها في السحب التالي.
        try {
          if (message.status == 'pendingSend') {
            final captureSync = ref.read(captureSyncServiceProvider);
            final sent = await captureSync.retryPendingSend(message);
            if (sent) {
              backendSync = await captureSync.sync();
              if (message.id != null &&
                  (backendSync.importedPayloadIds.contains(message.id) ||
                      await captureSync.isPayloadImported(message.id!))) {
                continue;
              }
              throw StateError('backend_capture_not_observable');
            }
          }
          if (message.id != null) {
            final alreadySynced =
                backendSync?.importedPayloadIds.contains(message.id) ?? false;
            final alreadyImported = alreadySynced ||
                await ref
                    .read(captureSyncServiceProvider)
                    .isPayloadImported(message.id!);
            if (alreadyImported) {
              if (kDebugMode) {
                debugPrint('[Capture] skip already imported backend payload');
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
          // Flag the payload as imported so a later backend sync skips the same
          // capture instead of importing it a second time (list showed it twice).
          if (message.id != null && result.transactionId != null) {
            await ref.read(captureSyncServiceProvider).markPayloadImported(
                  payloadId: message.id!,
                  transactionId: result.transactionId!,
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
        } on AuthRepoException {
          // Every remaining message would fail identically until re-auth —
          // stop draining, requeue this one, and let the centralized
          // recovery redirect to sign-in instead of looping through failures.
          await NativeCaptureBridge.reEnqueueSharedMessage(message);
          await _handleAuthRequiredFailure();
          break;
        } catch (error) {
          final requeued =
              await NativeCaptureBridge.reEnqueueSharedMessage(message);
          if (kDebugMode) {
            debugPrint(
              '[Capture] message processing failed '
              '($error); requeued=$requeued',
            );
          }
        }
      }
      if (pendingConfirmationId == null &&
          backendSync?.needsReviewTransactionIds.isNotEmpty == true) {
        pendingConfirmationId = backendSync!.needsReviewTransactionIds.last;
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

  bool _syncEngagementInFlight = false;

  /// Wraps the actual engagement sync so an `auth_required` failure from any
  /// Supabase-primary repository call inside it (budgets/goals/bills — all
  /// now require a live session) triggers the one centralized session-invalid
  /// recovery instead of surfacing as an unhandled exception. Any other error
  /// type is intentionally left to propagate — this must not become a
  /// blanket catch-all that hides unrelated bugs.
  Future<void> _syncEngagement() async {
    if (_syncEngagementInFlight) return;
    _syncEngagementInFlight = true;
    try {
      await _syncEngagementBody();
    } on AuthRepoException {
      await _handleAuthRequiredFailure();
    } finally {
      _syncEngagementInFlight = false;
    }
  }

  Future<void> _syncEngagementBody() async {
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
              'وصلت إلى ${(alert.progress.ratio * 100).round()}% من ميزانية ${Currency.moneyInt(alert.progress.budget.amount, budgetCurrency)}.',
          type: NotificationType.budgetWarning,
          preferences: preferences,
        );
      } else {
        await LocalNotificationService.instance.showBudgetAlert(
          title: 'تم تجاوز ميزانية $label',
          body:
              'تجاوزت الميزانية بمقدار ${Currency.moneyInt(alert.progress.remaining.abs(), budgetCurrency)}.',
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
    if (passive.isNotEmpty && mounted) {
      refreshAchievements(ref);
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
    // Opportunistic — drains native (iOS Shortcut) notification events and
    // syncs the local outbox to notification_logs. Never blocks engagement
    // evaluation on network availability.
    unawaited(ref.read(notificationLogSyncServiceProvider).sync());
  }

  void _refreshAll() {
    refreshTransactions(ref);
    refreshBudgets(ref);
    refreshAchievements(ref);
    refreshNotificationPreferences(ref);
    ref.invalidate(accountsProvider);
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
    if (!_claimAutoNavigation(transactionId)) {
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
    _recordOpenedForRoutes(routes);
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

  /// Records the 'opened' lifecycle event for every drained route that
  /// carries a notificationLogId (remote APNs pushes and the iOS Shortcut's
  /// local fallback both attach one — see local_notification_service.dart
  /// and BankMessageShortcuts.swift). Idempotent and never awaited by the
  /// caller — routing must not wait on this. See
  /// docs/NOTIFICATION_PIPELINE_AUDIT.md.
  void _recordOpenedForRoutes(List<CaptureNotificationRoute> routes) {
    final service = ref.read(notificationLogServiceProvider);
    for (final route in routes) {
      final logId = route.notificationLogId;
      if (logId == null) continue;
      unawaited(service.recordOpened(
        logId: logId,
        channel: NotificationLogChannel.apns,
        notificationType: route.notificationType ?? 'unknown',
        relatedEntityType: route.transactionId != null ? 'transaction' : null,
        relatedEntityId: route.transactionId,
      ));
    }
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
      final transactionId = route.substring('/transaction/'.length);
      if (!_claimAutoNavigation(transactionId)) return;
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
