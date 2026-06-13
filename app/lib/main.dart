import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/backend/metrics_client.dart';
import 'core/backend/rules_client.dart';
import 'core/backend/sentry_config.dart';
import 'core/backend/supabase_config.dart';
import 'core/di/app_providers.dart';
import 'core/session/app_session.dart';
import 'data/db/app_database.dart';
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
  final database = await AppDatabase.open();
  unawaited(
    RulesClient(database: database).syncBankRules().catchError((Object error) {
      debugPrint('Remote parsing rules sync failed: $error');
    }),
  );
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
