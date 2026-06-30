import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/backend/metrics_client.dart';
import 'core/backend/sentry_config.dart';
import 'core/backend/supabase_config.dart';
import 'core/di/app_providers.dart';
import 'core/session/app_session.dart';
import 'data/catalog/seed_loader.dart';
import 'data/repositories/drift_goal_repository.dart';
import 'domain/usecases/run_goal_auto_saves_usecase.dart';
import 'data/db/app_database.dart';
import 'features/cards/brand_mark.dart';
import 'data/repositories/drift_sender_bank_mapping_repository.dart';
import 'data/sync/sender_bank_mapping_sync_service.dart';
import 'features/capture/capture_runtime.dart';
import 'features/capture/services/local_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (SentryConfig.isConfigured) {
    await SentryFlutter.init(
      (options) {
        options.dsn = SentryConfig.dsn;
        options.sendDefaultPii = false;
        options.tracesSampleRate = 0.0;
        options.attachScreenshot = false;
      },
      appRunner: _bootstrap,
    );
    return;
  }
  await _bootstrap();
}

Future<void> _bootstrap() async {
  if (SupabaseConfig.isConfigured) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    await MetricsClient().logEvent('app_open');
  }
  await AppSession.instance.load();
  if (SupabaseConfig.isConfigured) {
    await AppSession.instance.bindSupabaseAuth(Supabase.instance.client);
  }
  final initialCaptureTransactionId =
      await LocalNotificationService.instance.initialize();
  await LocalNotificationService.instance.requestPermissionsIfNeeded();
  final AppDatabase database;
  try {
    database = await AppDatabase.open();
  } catch (error) {
    // The encrypted DB can't be opened (corrupt file, or a key/file mismatch
    // after the keychain was cleared). Show a recovery screen instead of a hard
    // crash; the user decides whether to reset.
    runApp(_DatabaseRecoveryApp(error: error));
    return;
  }
  // Seed catalog tables from bundled assets and load feature flags before the
  // first frame so flags have real values (not just defaults) immediately.
  await const SeedLoader().seedIfEmpty(database);
  await _registerBrandLogos();
  await initFeatureFlagService(database);
  // Apply any due recurring auto-saves toward goals (catch-up on launch).
  try {
    await RunGoalAutoSavesUseCase(DriftGoalRepository(database)).call();
  } catch (_) {
    // Auto-save is best-effort; never block startup on it.
  }
  if (SupabaseConfig.isConfigured) {
    _startSenderBankMappingSync(database, Supabase.instance.client);
  }
  if (initialCaptureTransactionId != null) {
    CaptureRuntime.instance
        .seedInitialConfirmation(initialCaptureTransactionId);
  }

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
      ],
      child: const MoneyApp(),
    ),
  );
}

/// Shown when the local database can't be opened (corrupt/undecryptable). Lets
/// the user explicitly reset their data rather than crashing on launch.
class _DatabaseRecoveryApp extends StatefulWidget {
  const _DatabaseRecoveryApp({required this.error});

  final Object error;

  @override
  State<_DatabaseRecoveryApp> createState() => _DatabaseRecoveryAppState();
}

class _DatabaseRecoveryAppState extends State<_DatabaseRecoveryApp> {
  bool _resetting = false;

  Future<void> _reset() async {
    setState(() => _resetting = true);
    try {
      await AppDatabase.deleteDatabaseFile();
      await _bootstrap();
    } catch (_) {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Colors.white70, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'تعذّر فتح بياناتك',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'ملف البيانات تالف أو مشفّر بمفتاح غير متطابق ولا يمكن فتحه. '
                    'تقدر تعيد تعيين بيانات التطبيق للبدء من جديد (هيتم حذف '
                    'العمليات المحفوظة محلياً فقط).',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _resetting ? null : _reset,
                      child: _resetting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('إعادة تعيين البيانات'),
                    ),
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
    repository: DriftSenderBankMappingRepository(database),
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
