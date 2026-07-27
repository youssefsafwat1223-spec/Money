import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/backend/sentry_config.dart';
import 'core/di/app_providers.dart';
import 'core/startup/bootstrap_runner.dart';
import 'core/theme/app_theme.dart';
import 'data/db/app_database.dart';
import 'features/app/startup_loading_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (SentryConfig.isConfigured) {
    await SentryFlutter.init(
      (options) {
        options.dsn = SentryConfig.dsn;
        options.sendDefaultPii = false;
        options.tracesSampleRate = 0.0;
        options.attachScreenshot = false;
        // Defence-in-depth: redact anything that looks like a monetary amount
        // or a long digit run (account/card) from crash payloads, so financial
        // data can never reach Sentry via an exception message.
        options.beforeSend = (event, hint) => _scrubSentryEvent(event);
      },
      appRunner: () async => runApp(const StartupApp()),
    );
    return;
  }
  runApp(const StartupApp());
}

/// Redacts monetary amounts and long digit runs from a Sentry event's exception
/// values before it is sent. Conservative on purpose so stack traces stay
/// useful while financial data cannot leak.
SentryEvent _scrubSentryEvent(SentryEvent event) {
  String scrub(String input) => input
      .replaceAll(RegExp(r'\d[\d,]*\.\d{2,3}'), '[amount]')
      .replaceAll(RegExp(r'\d{5,}'), '[redacted]');
  final exceptions = event.exceptions;
  if (exceptions == null || exceptions.isEmpty) return event;
  return event.copyWith(
    exceptions: <SentryException>[
      for (final e in exceptions)
        if (e.value == null) e else e.copyWith(value: scrub(e.value!)),
    ],
  );
}

/// Root widget for the first frame. Renders [StartupLoadingScreen] while
/// [BootstrapRunner] performs real async initialization (Supabase, session
/// restore, local DB, seed data, feature flags, capture registration), then
/// swaps itself out for the real [MoneyApp] in the same widget tree. Bootstrap
/// starts after the loading screen's first frame so fast/synchronously
/// completing startup work cannot replace it before the spinner is painted.
/// Nothing here is a fixed/minimum-duration splash; the loading screen is
/// removed the instant bootstrap actually finishes.
class StartupApp extends StatefulWidget {
  const StartupApp({super.key, this.runner});

  /// Injectable for lifecycle tests. Production always uses a fresh runner.
  final BootstrapRunner? runner;

  @override
  State<StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<StartupApp> {
  late final BootstrapRunner _runner;
  AppDatabase? _database;
  Object? _error;
  bool _bootstrapping = false;

  @override
  void initState() {
    super.initState();
    _runner = widget.runner ?? BootstrapRunner();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attempt();
    });
  }

  void _attempt() {
    if (_bootstrapping) return;
    setState(() => _error = null);
    unawaited(_runBootstrap());
  }

  Future<void> _resetDatabaseAndRetry() async {
    await _runner.resetDatabaseAndRetry();
    _attempt();
  }

  Future<void> _runBootstrap() async {
    _bootstrapping = true;
    try {
      final database = await _runner.run();
      if (!mounted) return;
      setState(() => _database = database);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      _bootstrapping = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final database = _database;
    if (database != null) {
      return ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          startupHasLocalDataProvider.overrideWithValue(_runner.hasLocalData),
        ],
        child: const MoneyApp(),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // A timeout can land while `database_open` is the step in flight (it's
      // simply the slowest step, e.g. first-run key generation) without the
      // database itself being corrupt — only route to the destructive
      // reset flow for a real database_open failure, never for a timeout.
      home: _error != null &&
              _error is! BootstrapTimeoutException &&
              _runner.lastStep == 'database_open'
          ? _DatabaseRecoveryView(onReset: _resetDatabaseAndRetry)
          : StartupLoadingScreen(
              error: _error,
              lastStep: _runner.lastStep,
              onRetry: _attempt,
            ),
    );
  }
}

/// Shown when the local encrypted DB can't be opened (corrupt file, or a
/// key/file mismatch after the keychain was cleared) — lets the user
/// explicitly reset their data rather than being stuck on a generic retry
/// that would just fail identically.
class _DatabaseRecoveryView extends StatefulWidget {
  const _DatabaseRecoveryView({required this.onReset});

  final Future<void> Function() onReset;

  @override
  State<_DatabaseRecoveryView> createState() => _DatabaseRecoveryViewState();
}

class _DatabaseRecoveryViewState extends State<_DatabaseRecoveryView> {
  bool _resetting = false;

  Future<void> _reset() async {
    setState(() => _resetting = true);
    try {
      await widget.onReset();
    } catch (_) {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
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
    );
  }
}
