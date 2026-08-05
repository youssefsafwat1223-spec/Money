import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/catalog/seed_loader.dart';
import '../../data/db/app_database.dart';
import '../exporting/managed_export_store.dart';
import '../../data/repositories/drift_card_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/usecases/run_goal_auto_saves_usecase.dart';
import '../../domain/usecases/user_settings_usecases.dart';
import '../../features/capture/capture_runtime.dart';
import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/native_capture_bridge.dart';
import '../../features/capture/services/pending_notification_actions.dart';
import '../../features/capture/services/local_notification_service.dart';
import '../../features/capture/services/notification_log_service.dart';
import '../../features/cards/brand_mark.dart';
import '../../features/planning_sync/services/outbox_queue_factory.dart';
import '../backend/metrics_client.dart';
import '../backend/supabase_config.dart';
import '../di/app_providers.dart';
import '../privacy/data_wipe_service.dart';
import '../session/app_session.dart';

/// Thrown when [BootstrapRunner.run] exceeds [BootstrapRunner.timeout].
class BootstrapTimeoutException implements Exception {
  const BootstrapTimeoutException(this.lastStep);
  final String? lastStep;
  @override
  String toString() => 'BootstrapTimeoutException(lastStep: $lastStep)';
}

/// Runs every startup initialization step (Supabase, session restore, local
/// database, seed data, feature flags, capture registration) that used to run
/// unconditionally before `runApp()` in `main.dart`. Moved into a retained
/// object with its own state so [run] can be called again on retry without
/// re-opening the database or re-registering listeners a second time —
/// each side-effecting step below is memoized against a field on this class.
class BootstrapRunner {
  // A brand-new install pays a one-time cost here: SQLCipher key generation,
  // creating the encrypted DB file, and seeding the bundled catalog. Measured
  // ~20s on a debug build / cold simulator for that exact path (session
  // restore + database_open dominate). 30s leaves real margin above that
  // without letting a genuinely hung bootstrap spin indefinitely.
  static const Duration timeout = Duration(seconds: 30);

  AppDatabase? _database;
  bool _supabaseInitialized = false;
  bool _senderBankSyncStarted = false;
  bool _goalAutoSavesRan = false;
  bool _cardBackfillRan = false;
  String? _lastStep;

  /// Whether any transaction existed when bootstrap finished — read by
  /// `startupHasLocalDataProvider` so Home only shows the first-launch
  /// skeleton when there is truly nothing to render yet. Defaults to `true`
  /// (no skeleton) so a failed check can never cause a data-having user to
  /// see skeletons.
  bool hasLocalData = true;

  /// Name of the step that was running when the most recent [run] call
  /// failed (or is currently running). `'database_open'` specifically means
  /// the local encrypted DB could not be opened (corrupt file/key mismatch)
  /// — callers should offer a reset action rather than a plain retry.
  String? get lastStep => _lastStep;

  /// Deletes the unopenable encrypted DB file so the next [run] can create a
  /// fresh one. Only relevant when [lastStep] is `'database_open'`.
  Future<void> resetDatabaseAndRetry() async {
    await AppDatabase.deleteDatabaseFile();
    _database = null;
  }

  /// Runs the full startup sequence, or resumes/retries a previous attempt
  /// without repeating steps that already completed. Returns the ready
  /// [AppDatabase] to be handed to `appDatabaseProvider`.
  Future<AppDatabase> run() {
    return _runSteps().timeout(
      timeout,
      onTimeout: () => throw BootstrapTimeoutException(_lastStep),
    );
  }

  Future<AppDatabase> _runSteps() async {
    // Runs in EVERY build mode. In release a missing/non-production Supabase
    // configuration throws (fail closed → startup error screen) instead of
    // silently proceeding into stub auth / no cloud (MALI-003).
    _assertRuntimeConfig();

    if (SupabaseConfig.isConfigured && !_supabaseInitialized) {
      await _step('supabase_init', () async {
        await Supabase.initialize(
          url: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
        await MetricsClient().logEvent('app_open');
        _supabaseInitialized = true;
      });
    }

    await _step('session_restore', () async {
      await AppSession.instance.load();
      if (SupabaseConfig.isConfigured) {
        await AppSession.instance.bindSupabaseAuth(Supabase.instance.client);
      }
    });

    final initialCaptureTransactionId = await _step(
      'notifications_init',
      () => LocalNotificationService.instance.initialize(),
    );

    _database ??= await _step('database_open', () => AppDatabase.open());
    final database = _database!;

    await _step('has_local_data', () async {
      try {
        final row = await database
            .customSelect('SELECT EXISTS(SELECT 1 FROM transactions) AS d')
            .getSingle();
        hasLocalData = row.read<int>('d') != 0;
      } catch (_) {
        hasLocalData = true;
      }
    });

    await _step('seed_catalog', () async {
      await const SeedLoader().seedIfEmpty(database);
      _bindNotificationHistory(database);
      LocalNotificationService.instance.logService =
          NotificationLogService(database);
      await _registerBrandLogos();
    });

    await _step(
      'feature_flags_init',
      () => initFeatureFlagService(database),
    );

    // MALI-065n: on a fresh process no export share can be in flight, so any
    // file left in the managed export dir is a crash orphan — reclaim them all.
    await _step(
      'export_temp_sweep',
      () => ManagedExportStore().sweep(),
    );

    await _step('capture_registration', () async {
      final captureRegistration = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(database),
      );
      AppSession.instance.configureCaptureDeviceUnlink(
        captureRegistration.unlinkCurrentDevice,
      );
      AppSession.instance.configureLocalDataWipe(
        DataWipeService(database).wipeAll,
      );
      // MALI-054n/070n: residue purge = native App Group / SharedPreferences
      // capture queue + the pending-notification-actions file. Both run; the
      // hook reports success only when BOTH are confirmed, so the owner gate can
      // fail closed. Registered before the deferred owner-conflict resolves so
      // the conflict path can purge before admitting the new identity.
      AppSession.instance.configureLocalResiduePurge(() async {
        final nativePurged = await NativeCaptureBridge.purgeAllCaptureState();
        final filesCleared = await PendingNotificationActions.clear();
        // MALI-019 §10 — clear the previous user's pending OS reminders too, so a
        // stale bill/weekly/streak reminder can never surface after sign-out /
        // ownership change. Best-effort; does not gate the fail-closed result.
        await LocalNotificationService.instance.cancelScheduledReminders();
        return nativePurged && filesCleared;
      });
      // Owner gate (MALI-002): the first session reconcile ran before the DB
      // (and therefore the wipe hook) existed. If it deferred an owner
      // conflict — the DB still holds a DIFFERENT account's data — resolve it
      // now: wipe, claim, and re-admit against a clean DB, before any later
      // step (goal autosaves, card backfill, sync) touches the stale rows.
      if (SupabaseConfig.isConfigured) {
        await AppSession.instance
            .resolvePendingLocalDataOwnerConflict(Supabase.instance.client);
      }
      unawaited(
        captureRegistration.syncBackendState().catchError((_) {
          // Capture backend registration is optional; local fallback remains active.
        }),
      );
    });

    if (!_goalAutoSavesRan) {
      await _step('goal_autosaves', () async {
        try {
          await RunGoalAutoSavesUseCase(
            DriftGoalRepository(
              database,
              outboxQueue: buildPlanningOutboxQueue(database),
            ),
          ).call();
        } catch (_) {
          // Auto-save is best-effort; never block startup on it.
        } finally {
          _goalAutoSavesRan = true;
        }
      });
    }

    if (!_cardBackfillRan) {
      await _step('card_backfill', () async {
        try {
          // Seed the real cards table from existing transactions (auto cards
          // per confident account). Idempotent — skips existing, never touches
          // manual cards. Best-effort; never block startup.
          await DriftCardRepository(
            database,
            outboxQueue: buildPlanningOutboxQueue(database),
          ).backfillFromTransactions();
        } catch (_) {
          // Backfill is opportunistic; a failure leaves cards empty, not broken.
        } finally {
          _cardBackfillRan = true;
        }
      });
    }

    if (SupabaseConfig.isConfigured && !_senderBankSyncStarted) {
      await _step('sender_bank_sync_start', () async {
        _startSenderBankMappingSync(database, Supabase.instance.client);
        _senderBankSyncStarted = true;
      });
    }

    if (initialCaptureTransactionId != null) {
      CaptureRuntime.instance
          .seedInitialConfirmation(initialCaptureTransactionId);
    }

    if (kDebugMode) {
      debugPrint(
        '[Bootstrap] done — session=${AppSession.instance.status.name}',
      );
    }
    return database;
  }

  void _assertRuntimeConfig() {
    if (kDebugMode) {
      debugPrint(
        '[SupabaseConfig] env=${SupabaseConfig.environment.name}'
        ' configured=${SupabaseConfig.isConfigured}',
      );
    }
    if (!kReleaseMode) return;
    // Release builds fail closed: a production binary must never run with
    // fake/local auth or a non-production backend.
    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Release build launched without SUPABASE_URL/SUPABASE_ANON_KEY — '
        'refusing to start with stub auth.',
      );
    }
    if (SupabaseConfig.environment != SupabaseEnvironment.production) {
      throw StateError(
        'Non-production SUPABASE_ENV '
        '"${SupabaseConfig.environment.name}" in release build.',
      );
    }
  }

  Future<T> _step<T>(String name, Future<T> Function() run) async {
    _lastStep = name;
    final start = DateTime.now();
    if (kDebugMode) debugPrint('[Bootstrap] $name start');
    try {
      final result = await run();
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Bootstrap] $name ok (${ms}ms)');
      }
      return result;
    } catch (error) {
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Bootstrap] $name failed after ${ms}ms: '
            '${error.runtimeType}');
      }
      rethrow;
    }
  }
}

/// يربط الإشعارات المعروضة بسجل الرسائل داخل التطبيق حتى تظهر في
/// شاشة الرسائل حتى لو فاتت المستخدم الـ banner.
void _bindNotificationHistory(AppDatabase database) {
  final settingsRepository = DriftUserSettingsRepository(database);
  final loadPreferences =
      LoadNotificationPreferencesUseCase(settingsRepository);
  final savePreferences =
      SaveNotificationPreferencesUseCase(settingsRepository);
  LocalNotificationService.instance.historyStore = (entry) async {
    final preferences = await loadPreferences();
    await savePreferences(
      preferences.copyWith(
        inboxState: preferences.inboxState.addHistory(entry),
      ),
    );
  };
}

/// Loads every bundled `assets/brands/*.svg` slug once so [BrandMark] can show
/// any of them automatically (drop a new SVG in the folder → it just works).
Future<void> _registerBrandLogos() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final slugs = manifest
        .listAssets()
        .where((a) => a.startsWith('assets/brands/') && a.endsWith('.svg'))
        .map((a) => a.split('/').last.replaceAll('.svg', ''))
        .toList();
    BrandMark.registerAssetSlugs(slugs);
  } catch (_) {
    // Logos are optional; ignore manifest read failures.
  }
}

void _startSenderBankMappingSync(
  AppDatabase database,
  SupabaseClient client,
) {
  final service = SenderBankMappingSyncService(
    db: database,
    remoteStore: SupabaseSenderBankMappingRemoteStore(client),
    currentUserId: () => client.auth.currentUser?.id,
  );
  unawaited(service.sync());
  client.auth.onAuthStateChange.listen((state) {
    switch (state.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.userUpdated:
        unawaited(service.sync());
        return;
      case AuthChangeEvent.signedOut:
      case AuthChangeEvent.userDeleted:
      case AuthChangeEvent.passwordRecovery:
      case AuthChangeEvent.mfaChallengeVerified:
        return;
    }
  });
}
