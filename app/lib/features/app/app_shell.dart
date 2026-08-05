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
import '../../core/diagnostics/duplicate_trace_service.dart';
import '../../core/exporting/export_providers.dart';
import '../../core/exporting/managed_export_store.dart';
import '../../core/router/modal_route_observer.dart';
import 'app_boot_loader.dart';
import '../planning_sync/services/startup_sync_reconcile_service.dart';
import '../../core/session/app_session.dart';
import '../../core/sync/sync_wakeup.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/captured_message.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/services/notification_planner.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../bank_discovery/bank_discovery_confirmation_sheet.dart';
import '../budgets/budgets_providers.dart';
import '../budgets/budgets_screen.dart';
import '../capture/capture_runtime.dart';
import '../capture/services/capture_notification_content.dart';
import '../capture/services/capture_sync_service.dart';
import '../capture/services/captured_message_processor.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/notification_log_service.dart';
import '../capture/services/pending_notification_actions.dart';
import '../capture/services/native_capture_bridge.dart';
import '../../core/tracking/user_activity_service.dart';
import '../cards/cards_providers.dart';
import '../onboarding/force_update_screen.dart';
import '../dashboard/dashboard_providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../gamification/services/engagement_event_service.dart';
import '../gamification/services/gamification_sync_service.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_providers.dart';
import '../reports/reports_providers.dart';
import '../reports/reports_screen.dart';
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
  StreamSubscription<void>? _syncWakeupSubscription;
  Timer? _syncDebounceTimer;
  Timer? _syncPollTimer;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;
  bool _isBottomBarVisible = true;
  bool _isConsumingSharedInput = false;
  SessionStatus? _lastSessionStatus;
  bool _remoteOnboardingCompletionSynced = false;
  bool _isReconcilingAfterResume = false;

  /// Post-sign-in restore gate: after a sign-out wipe the local DB holds only
  /// reseeded defaults, and offline-first screens would render those "wrong"
  /// values until the first pull replaces them under the user's eyes. While
  /// open, the root-level [appDataRestoring] loader covers the app; it drops
  /// the moment the first full sync round completes (or the DB turns out to
  /// already have data / a 20s safety timeout fires). Normal daily opens with
  /// existing data never show it — offline-first stays instant. This flag
  /// tracks whether THIS shell opened the gate, so it only ever closes its own.
  bool _openedRestoreGate = false;
  Timer? _restoreGateTimeout;

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
    // Final push before the sign-out wipe destroys the outboxes — otherwise a
    // change made seconds before signing out is deleted un-uploaded and lost.
    AppSession.instance.configureSignOutFlush(_flushPendingForSignOut);
    if (SupabaseConfig.isConfigured &&
        AppSession.instance.status == SessionStatus.authenticated) {
      _openedRestoreGate = true;
      appDataRestoring.value = true;
      unawaited(_resolveRestoreGate());
      _restoreGateTimeout = Timer(const Duration(seconds: 20), () {
        // Safety: never trap the user behind the loader (e.g. offline).
        _closeRestoreGate();
      });
    }
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
    _syncWakeupSubscription = SyncWakeup.events.listen((_) {
      _syncDebounceTimer?.cancel();
      _syncDebounceTimer = Timer(
        const Duration(milliseconds: 750),
        _runLedgerSync,
      );
    });
    // Pull remote changes made on another device and retry offline outbox
    // items after connectivity returns without requiring a lifecycle event.
    _syncPollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_runLedgerSync()),
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
    AppSession.instance.configureSignOutFlush(null);
    _restoreGateTimeout?.cancel();
    if (_openedRestoreGate) {
      _openedRestoreGate = false;
      appDataRestoring.value = false; // never leave the root loader stuck up
    }
    _celebrationTimer?.cancel();
    _confirmSubscription?.cancel();
    _quickActionSubscription?.cancel();
    _navigationSubscription?.cancel();
    _bankDiscoverySubscription?.cancel();
    _syncWakeupSubscription?.cancel();
    _syncDebounceTimer?.cancel();
    _syncPollTimer?.cancel();
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
    // Any session change (sign-in or sign-out) re-arms the one-shot reconcile
    // so a freshly signed-in identity backfills its own local data once.
    _didReconcile = false;
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
    unawaited(UserActivityService.ping()); // resume — writes only if > 30 min
    await _syncNativeCaptureState();
    await _consumeSharedInput();
    unawaited(_runLedgerSync());
    await _drainPendingNotificationRoutes();
    await _syncEngagement();
    unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
    // MALI-065n: bounded-lease sweep of any export temp file a crash orphaned
    // while backgrounded — never touches one still inside its lease (an
    // in-flight share).
    unawaited(ref
        .read(managedExportStoreProvider)
        .sweep(olderThan: ManagedExportStore.defaultLease));
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

  Future<bool> _repairDirtyFinancialCaches() async {
    try {
      return await ref.read(financialCacheRepairServiceProvider).repairDirty();
    } catch (error) {
      // Keep the dirty marker intact. Routed repositories will fail closed
      // instead of trusting Drift until a later online repair succeeds.
      if (kDebugMode) {
        debugPrint('[FinancialCache] repair pending: ${error.runtimeType}');
      }
      return false;
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
  /// The broad safety-net invalidation only fires when step A or B actually
  /// found something to reconcile — an idle resume with no pending
  /// background actions and no dirty cache does not force every screen back
  /// into a loading state; `dbRevisionProvider` already covers any write
  /// that landed through this shell's own live connection.
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
    final start = DateTime.now();
    if (kDebugMode) debugPrint('[Reconcile] start');
    try {
      // A. Pending notification actions — idempotent (PendingNotificationActions
      // .drain() empties the queue first; _applyQuickAction tolerates a
      // confirm/delete that already landed via the background path).
      final drainedActions = await _drainPendingNotificationActions();
      if (!mounted) return;
      // B. Repair any Supabase-mirror cache marked dirty by a failed local
      // write — this itself writes through the live AppDatabase connection,
      // so it also ticks dbRevisionProvider for anything that watches it.
      final repairedCache = await _repairDirtyFinancialCaches();
      if (!mounted) return;
      // C. Explicit invalidation as a safety net for writes that landed
      // through a connection dbRevisionProvider can't observe — only when
      // A or B actually found something (see doc comment above).
      final needsInvalidation = drainedActions || repairedCache;
      if (needsInvalidation) {
        _invalidateFinancialProviders();
      }
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Reconcile] success (${ms}ms) drainedActions='
            '$drainedActions repairedCache=$repairedCache '
            'invalidated=$needsInvalidation');
      }
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

  bool _isRunningLedgerSync = false;

  /// Whether the one-shot local→server reconcile has run for the current
  /// session. Re-armed on any session change (see [_handleSessionStatusChange]).
  bool _didReconcile = false;

  /// Whether the read-only duplicate trace has printed this session (debug).
  bool _didDupTrace = false;

  /// Called unawaited on every resume — guarded so a resume firing again
  /// before the previous sync round finished doesn't run the ledger/smart
  /// inbox/planning/gamification sync engines concurrently with themselves.
  /// Drops the restore gate immediately when the local DB already holds real
  /// data (normal daily open) — the overlay then never gets a visible frame.
  /// After a sign-out wipe the transactions table is empty, so the gate stays
  /// up until the first sync round completes.
  Future<void> _resolveRestoreGate() async {
    try {
      final row = await ref
          .read(appDatabaseProvider)
          .customSelect('SELECT EXISTS(SELECT 1 FROM transactions) AS d')
          .getSingle();
      if (row.read<int>('d') != 0) _closeRestoreGate();
    } catch (_) {
      _closeRestoreGate();
    }
  }

  void _closeRestoreGate() {
    _restoreGateTimeout?.cancel();
    _restoreGateTimeout = null;
    if (!_openedRestoreGate) return;
    _openedRestoreGate = false;
    appDataRestoring.value = false;
    // Everything the pull imported must render fresh in one shot.
    if (mounted) _invalidateFinancialProviders();
  }

  /// Push-only flush run by [AppSession.signOut] right before the wipe (no
  /// pulls — we are leaving this identity, we only need pending local changes
  /// to reach the server so they aren't destroyed with the outboxes).
  Future<void> _flushPendingForSignOut() async {
    // MALI-053n: flush EVERY outbox — including the child entities (goal
    // contributions / bill payments / plan links via PlanningChildSyncService),
    // smart-inbox status, notification log, and sender mappings — so pending
    // local changes reach the server before the wipe deletes the queues. Each
    // attempt is best-effort and independent: one offline/failed queue must not
    // skip the rest. A failure/timeout here is NEVER treated as a successful
    // sync — the sign-out flow re-checks the unsynced inventory afterward.
    Future<void> attempt(Future<void> Function() push) async {
      try {
        await push();
      } catch (_) {
        // Re-checked by the unsynced inventory; do not block the other queues.
      }
    }

    await attempt(() async {
      await ref.read(accountsPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(planningPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(ledgerPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(planningChildSyncServiceProvider).sync();
    });
    await attempt(() async {
      await ref.read(smartInboxSyncServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(notificationLogSyncServiceProvider).sync();
    });
    await attempt(() async {
      await ref.read(senderBankMappingSyncServiceProvider)?.sync();
    });
  }

  Future<void> _runLedgerSync() async {
    if (_isRunningLedgerSync) return;
    _isRunningLedgerSync = true;
    try {
      await _runLedgerSyncBody();
    } finally {
      _isRunningLedgerSync = false;
      // First completed round after sign-in: the pull has landed — reveal the
      // real data in one shot instead of defaults morphing under the user.
      _closeRestoreGate();
    }
  }

  Future<void> _runLedgerSyncBody() async {
    // Reconcile local accounts/transactions that never reached Supabase BEFORE
    // the normal push/pull, so back-filled rows are marked synced and the
    // outbox path takes over cleanly. One-shot per session; the service guards
    // itself to be cheap when nothing is pending. On transient failure we leave
    // the flag unset so the next cycle retries.
    if (!_didReconcile) {
      final outcome = await ref.read(startupSyncReconcileServiceProvider).run();
      if (outcome != ReconcileOutcome.failed) _didReconcile = true;
    }
    final planning = ref.read(planningSyncEngineProvider);
    try {
      await planning.syncParents();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PlanningSync] parent sync skipped: ${error.runtimeType}');
      }
    }
    // S5 reads are Drift-only. Background workers are a signed-in capability
    // and never depend on obsolete *_supabase_primary routing flags.
    try {
      await ref.read(ledgerSyncEngineProvider).sync();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[LedgerEngine] sync skipped: ${error.runtimeType}');
      }
    }
    // S3: ادفع تغييرات الحالة المحلية (رفض/معالجة) أولاً ثم اسحب. الخدمة تتحقق
    // داخليًا من التفعيل، فنستدعيها دائمًا (offline-safe).
    try {
      final smartInbox = ref.read(smartInboxSyncServiceProvider);
      await smartInbox.push();
      await smartInbox.pull();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SmartInboxSync] sync skipped: ${error.runtimeType}');
      }
    }
    try {
      await planning.syncChildren();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PlanningSync] child sync skipped: ${error.runtimeType}');
      }
    }

    // Gamification: submit durable engagement events (server awards exactly
    // once), then pull the acknowledged server aggregate (MALI-024 — the client
    // never uploads a total).
    try {
      await ref.read(engagementEventServiceProvider).push();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Engagement] push skipped: ${error.runtimeType}');
      }
    }
    try {
      await ref.read(gamificationSyncServiceProvider).performSync();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[GamificationSync] sync skipped: ${error.runtimeType}');
      }
    }

    // Read-only duplicate trace — runs once per session after a full
    // push/pull/reconcile cycle so any duplicate is visible in its final state.
    // Debug builds only; writes nothing.
    if (kDebugMode && !_didDupTrace) {
      _didDupTrace = true;
      try {
        final report =
            await DuplicateTraceService(ref.read(appDatabaseProvider)).run();
        for (final line in report.split('\n')) {
          debugPrint(line);
        }
      } catch (error) {
        debugPrint('[DupTrace] failed: $error');
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
      // Per-item lease (MALI-012): peek does NOT delete the native queue.
      // Each message is acknowledged (removed) individually only after its
      // local import committed — a kill anywhere in this loop re-delivers
      // exactly the unprocessed remainder on the next drain.
      final messages = await NativeCaptureBridge.peekPendingSharedMessages();
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

      // Positive per-item acknowledgement: removes the leased message from
      // the native queue only after it was fully handled locally.
      Future<void> ackMessage(SharedCapturedMessage message) async {
        final id = message.id;
        if (id == null || id.isEmpty) return;
        await NativeCaptureBridge.acknowledgeSharedMessage(id);
      }

      for (final message in messages) {
        // كل رسالة في try مستقلة، والطابور الأصلي لا يُمسح دفعة واحدة بعد
        // الآن (MALI-012): الرسالة تُحذف من الطابور فقط بعد اكتمال معالجتها
        // (ack)، والفاشلة تبقى في الطابور كما هي وتُعاد محاولتها في السحب
        // التالي — لا فقدان للدفعة عند انهيار/انتهاء جلسة في المنتصف.
        try {
          if (message.status == 'pendingSend') {
            final captureSync = ref.read(captureSyncServiceProvider);
            final sent = await captureSync.retryPendingSend(message);
            if (sent) {
              backendSync = await captureSync.sync();
              if (message.id != null &&
                  (backendSync.importedPayloadIds.contains(message.id) ||
                      await captureSync.isPayloadImported(message.id!))) {
                await ackMessage(message);
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
              await ackMessage(message);
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
          // Fully handled — release the lease.
          await ackMessage(message);
        } on AuthRepoException {
          // Every remaining message would fail identically until re-auth —
          // stop draining. Nothing was deleted from the native queue (peek,
          // not consume), so this message AND the whole remainder stay leased
          // and are retried after the centralized recovery re-auths.
          await _handleAuthRequiredFailure();
          break;
        } catch (error) {
          // Not acked — the message stays in the native queue and is retried
          // on the next drain.
          if (kDebugMode) {
            debugPrint('[Capture] message processing failed ($error)');
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
      // Budget alerts for spend that arrived through THIS path: the relay
      // import and the foreground shared-message ingest both add transactions
      // without going through CapturedMessageProcessor, so its budget check
      // never ran for them — budgets crossed 75%/90%/100% silently on iOS.
      if (backendSync?.importedPayloadIds.isNotEmpty == true ||
          messages.isNotEmpty) {
        try {
          await CapturedMessageProcessor.checkBudgetAlert(
            ref.read(appDatabaseProvider),
            notificationPreferences,
          );
        } catch (error) {
          if (kDebugMode) {
            debugPrint('[BudgetAlert] check skipped: ${error.runtimeType}');
          }
        }
      }
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
          stableId: result.addTransactionResult.transaction?.id,
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
          stableId: result.addTransactionResult.transaction?.id,
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

    // Streak reminder, weekly report, and bill/subscription reminders are
    // scheduled locally (no server-side equivalent exists) — this was
    // dropped when gamification/budgets moved to Supabase edge functions
    // (commit 8bf8259b) and never restored, so these three notification
    // types stopped firing entirely.
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
      // Device-local wall-clock time — the notification service now schedules
      // in the device timezone (tz.local), so plan in the same frame. (The
      // `Riyadh` names are legacy; the values are device-local.)
      nowRiyadh: DateTime.now(),
    );
    await LocalNotificationService.instance.schedulePlannedNotifications(
      planned,
    );

    // Opportunistic — drains native (iOS Shortcut) notification events and
    // syncs the local outbox to notification_logs. Never blocks engagement
    // evaluation on network availability.
    unawaited(ref.read(notificationLogSyncServiceProvider).sync());
  }

  /// Invalidates only the providers a transaction mutation (confirm/dismiss/
  /// capture) can actually affect — the transaction list, budget spend,
  /// account balance, and dashboard aggregates. Achievements and
  /// notification preferences have no correctness relationship to a
  /// transaction change and are refreshed by their own triggers instead
  /// ([_syncEngagement], the settings screens).
  void _refreshAll() {
    refreshTransactions(ref);
    refreshBudgets(ref);
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
    // No pre-emptive _refreshAll() here — the sheet reads its own
    // transactionByIdProvider fresh, and refreshing the list/dashboard
    // providers before the sheet is even visible only caused a visible
    // flash right as a notification was tapped, with no data it needed.
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
  /// تُطبَّق هنا عند أول فتح. Returns true iff at least one action was
  /// actually drained — callers use this to skip a broad refresh when the
  /// queue was already empty.
  Future<bool> _drainPendingNotificationActions() async {
    final actions = await PendingNotificationActions.drain();
    for (final action in actions) {
      await _applyQuickAction(
        CaptureQuickAction(
          transactionId: action.transactionId,
          confirm: action.confirm,
        ),
      );
    }
    return actions.isNotEmpty;
  }

  bool _isDrainingNotificationRoutes = false;

  /// Guarded against re-entry: [_onResume] and the cold-start post-frame
  /// callback can both reach this in quick succession (e.g. a resume firing
  /// while the initial drain from cold start is still awaiting
  /// `captureSyncServiceProvider.sync()`) — a second call while one is
  /// in-flight is a no-op rather than a duplicate sync + duplicate refresh.
  Future<void> _drainPendingNotificationRoutes() async {
    if (_isDrainingNotificationRoutes) return;
    _isDrainingNotificationRoutes = true;
    try {
      final routes =
          await NativeCaptureBridge.consumePendingNotificationRoutes();
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
    } finally {
      _isDrainingNotificationRoutes = false;
    }
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

    final shell = NotificationListener<UserScrollNotification>(
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
            // شريط زجاجي (frosted) بارتفاع شريط الحالة — يضبّب ما يمرّ تحت النوتش
            // (الهيدر الأزرق وقت الراحة، المحتوى الغامق وقت السكرول) فيتأقلم
            // تلقائيًا زي iOS بدل ظهور مساحة غامقة حادّة حول النوتش.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top,
              child: IgnorePointer(
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
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
        bottomNavigationBar: ValueListenableBuilder<bool>(
          valueListenable: modalRouteOpen,
          builder: (context, modalOpen, child) {
            // The native glass tab bar is a platform view a sheet can't cover;
            // drop it from the tree while a sheet/dialog is open so it doesn't
            // bleed a glass band over the sheet's bottom.
            if (modalOpen) return const SizedBox.shrink();
            return child!;
          },
          child: AnimatedSlide(
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
      ),
    );

    // The post-sign-in restore loader lives at the app root (see MoneyApp /
    // [appDataRestoring]), so it is one continuous screen with the cold-start
    // loader instead of a second loader flashing over the shell here.
    return shell;
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
    const barRadius = 26.0;

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
              height: AppSpacing.navBarHeight,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
            height: 44,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.icon,
                  color: selected ? activeColor : inactiveColor,
                  size: selected ? 20 : 19,
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 13,
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
