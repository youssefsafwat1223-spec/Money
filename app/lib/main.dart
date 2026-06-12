import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/backend/metrics_client.dart';
import 'core/backend/supabase_config.dart';
import 'core/di/app_providers.dart';
import 'core/session/app_session.dart';
import 'data/db/app_database.dart';
import 'features/capture/capture_runtime.dart';
import 'features/capture/services/local_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (SupabaseConfig.isConfigured) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    await MetricsClient().logEvent('app_open');
  }
  await AppSession.instance.load();
  final initialCaptureTransactionId =
      await LocalNotificationService.instance.initialize();
  final database = await AppDatabase.open();
  if (initialCaptureTransactionId != null) {
    CaptureRuntime.instance.seedInitialConfirmation(initialCaptureTransactionId);
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
