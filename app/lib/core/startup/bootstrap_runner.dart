import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/catalog/seed_loader.dart';
import '../../data/db/app_database.dart';
import '../../data/db/planning_canonical_invariants.dart';
import '../../data/db/planning_cutover.dart';
import '../exporting/managed_export_store.dart';
import '../../data/repositories/account_currency_repair_service.dart';
import '../../data/repositories/drift_account_repository.dart';
import '../../data/repositories/drift_card_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../privacy/consent_authority.dart';
import '../privacy/diagnostics_consent_gate.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/usecases/run_goal_auto_saves_usecase.dart';
import '../../domain/usecases/user_settings_usecases.dart';
import '../../features/capture/capture_runtime.dart';
import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/native_capture_bridge.dart';
import '../../features/capture/services/pending_notification_actions.dart';
import '../../features/capture/services/local_notification_service.dart';
import '../../features/app/app_boot_loader.dart';
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
  bool _accountCurrencyRepairRan = false;
  bool _cardIdentityBackfillRan = false;
  bool _dbKeyRefCleanupRan = false;
  String? _lastStep;

  /// Whether any transaction existed when bootstrap finished — read by
  /// `startupHasLocalDataProvider` so Home only shows the first-launch
  /// skeleton when there is truly nothing to render yet. Defaults to `true`
  /// (no skeleton) so a failed check can never cause a data-having user to
  /// see skeletons.
  bool hasLocalData = true;

  /// MALI-026 (B8-3) — the planning cutover state resolved from the opened DB.
  PlanningCutoverState planningCutoverState = PlanningCutoverState.canonical;

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
        // SDK init restores the persisted session from LOCAL storage and
        // refreshes the token in the background — it does not block the first
        // frame on a network round-trip. Required before session binding (owner
        // identity), so it stays on the critical path.
        await Supabase.initialize(
          url: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
        _supabaseInitialized = true;
      });
      // B2-C — the `app_open` metric is a REMOTE, best-effort telemetry RPC. Fire
      // it off the critical path so the first financial frame never waits on it
      // (nor on its offline timeout). logEvent already no-ops when there is no
      // authenticated session and swallows its own errors.
      unawaited(MetricsClient().logEvent('app_open'));
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

    // MALI-069n §Batch-4-closure-4 (Contract B) — take the process-lifetime OS
    // advisory lock and, if this is the sole opener, clear leftover lease/intent
    // records from ENDED process instances BEFORE opening. This startup pass is the
    // only reaping authority; runtime maintenance never reaps.
    await _step('database_process_liveness', AppDatabase.initProcessLiveness);
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

    // MALI-026 (B8-3 §1/§12) — resolve the REAL planning cutover state from the
    // opened DB (marker + canonical invariants). A fresh v30 install is canonical;
    // an upgraded-with-data DB is unresolved (P1). main() provides this as the
    // coordinator's initial state so guard/nav/reads react correctly from launch.
    await _step('planning_cutover_state', () async {
      planningCutoverState = await computePlanningCutoverState(
        () async => (await database
                .customSelect('PRAGMA user_version;')
                .getSingle())
            .read<int>('user_version'),
        () async => (await database
                .customSelect(
                    'SELECT planning_cutover_state AS s FROM user_settings;')
                .getSingle())
            .read<int>('s'),
        () async => (await planningCanonicalViolations(database)).length,
      );
    });

    await _step('seed_catalog', () async {
      await const SeedLoader().seedIfEmpty(database);
      _bindNotificationHistory(database);
      LocalNotificationService.instance.logService =
          NotificationLogService(database);
      await _registerBrandLogos();
    });

    // B2-C — LOCAL feature-flag init only (cached flags; makes `featureFlags`
    // usable and thus critical). The NETWORK override refresh is deferred: the
    // post-frame `syncCatalog` re-runs this with overrides, so the first frame
    // never blocks on a remote flag fetch (§12: no remote config on the critical
    // path).
    await _step(
      'feature_flags_init',
      () => initFeatureFlagService(database, applyRemoteOverrides: false),
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

    // MALI-058n — clear any legacy raw-key value from the deprecated
    // db_encryption_key_ref column. Runs AFTER admission (the identity above is
    // established), is idempotent (no-op once empty), touches only that column,
    // and never reads the value into logs/errors. Best-effort: a failure leaves
    // the value in place but backup generation already refuses to serialize it.
    if (!_dbKeyRefCleanupRan) {
      await _step('db_key_ref_cleanup', () async {
        try {
          await database.clearDeprecatedDbKeyRef();
        } catch (_) {
          // Never block startup; the value never leaves the device regardless.
        } finally {
          _dbKeyRefCleanupRan = true;
        }
      });
    }

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

    // OD-05 (C-3) — settings are readable now, so resolve the diagnostics gate.
    // Sentry was armed in main() before the DB existed and defaults to DENY, so
    // this is the first moment crash reporting can legitimately open. Failure
    // leaves it shut: an unsent crash report costs a diagnostic, an unconsented
    // one costs a privacy promise.
    await _step('diagnostics_consent_gate', () async {
      try {
        final settings =
            await LoadUserSettingsUseCase(DriftUserSettingsRepository(database))
                .call();
        DiagnosticsConsentGate.set(
          ConsentAuthority.decide(EgressClass.diagnostics, settings),
        );
      } catch (_) {
        DiagnosticsConsentGate.revoke();
      }
    });

    if (!_accountCurrencyRepairRan) {
      await _step('account_currency_repair', () async {
        try {
          // C-9 — the legacy per-currency account repair. This used to run
          // inside `dashboardDataProvider`, so opening Home created accounts,
          // reassigned transactions and (because both repositories enqueue)
          // produced cloud sync intent from a READ. It belongs here: an
          // explicit, owner-scoped startup command, before the financial UI is
          // marked usable.
          //
          // Idempotent by construction — it only creates a currency that has no
          // account and only touches `account_id IS NULL` rows — so a repaired
          // install writes nothing on later boots and therefore queues no
          // duplicate outbox rows.
          final settings =
              await LoadUserSettingsUseCase(DriftUserSettingsRepository(database))
                  .call();
          await AccountCurrencyRepairService(
            accounts: DriftAccountRepository(
              database,
              outboxQueue: buildPlanningOutboxQueue(database),
            ),
            // Both outboxes are wired deliberately: the repair changes real
            // financial state, so it must still reach other devices exactly as
            // it did from the dashboard. Idempotence — not the absence of a
            // queue — is what stops repeat boots from re-enqueueing.
            transactions: DriftTransactionRepository(
              database,
              outboxQueue: buildLedgerOutboxQueue(database),
            ),
          ).run(fallbackCurrency: settings.currency);
        } catch (_) {
          // Opportunistic, exactly like the card backfill: a failure leaves the
          // legacy rows for the next boot, it never blocks startup.
        } finally {
          _accountCurrencyRepairRan = true;
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

    if (!_cardIdentityBackfillRan) {
      await _step('card_identity_backfill', () async {
        try {
          // F-032 / OD-02 — attribute historical transactions to a canonical
          // card_id. Runs AFTER card_backfill so auto-discovered cards exist to
          // match against. Unambiguous matches only; anything else stays NULL
          // rather than being guessed.
          await database.backfillCardIdentity();
        } catch (_) {
          // Opportunistic: a failure leaves rows unattributed for the next boot,
          // which is the same truthful state as "not attributable".
        } finally {
          _cardIdentityBackfillRan = true;
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

    // B2-C — the safety-critical phase (config, DB open, liveness, admission/
    // owner-conflict, seed, local flags, owner-safe backfills) is complete: the
    // local financial UI is usable. Flip the milestone, then run the deferred,
    // non-critical, off-the-first-frame work (housekeeping only) WITHOUT gating
    // the return.
    localFinancialUiUsable.value = true;
    unawaited(_runDeferredStartupWork());

    if (kDebugMode) {
      debugPrint(
        '[Bootstrap] done — session=${AppSession.instance.status.name}',
      );
    }
    return database;
  }

  /// B2-C — deferred, non-critical startup housekeeping that must NOT gate the
  /// first financial frame. Owner-independent (temp files only, so no admission
  /// guard is needed), idempotent, and best-effort: a failure here can never
  /// turn a usable local DB into a fatal startup error. Runs outside the 30s
  /// bootstrap timeout.
  Future<void> _runDeferredStartupWork() async {
    // MALI-065n: on a fresh process no export share can be in flight, so any
    // file left in the managed export dir is a crash orphan — reclaim them all.
    try {
      await ManagedExportStore().sweep();
    } catch (_) {
      // Housekeeping only; never surface as a startup failure.
    }
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
    // C-3 — same gate as the provider construction site. Startup is exactly
    // where an ungated sync would run before any UI could reflect consent.
    mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(database).getSettings(),
        ).allows(EgressClass.senderBankMappings),
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
