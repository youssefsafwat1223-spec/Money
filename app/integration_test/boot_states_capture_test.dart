import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/app/startup_loading_screen.dart';
import 'package:money_companion/main.dart' as app;

import 'demo_seed_test.dart' as demo_seed;

/// BOOT STATES — the three conditional roots that render BEFORE the app exists.
///
/// `StartupLoadingScreen`, its error/timeout variant and `_DatabaseRecoveryView`
/// are not reachable from a running app: they are what `StartupApp` shows while
/// — or because — bootstrap has not produced a database. §6 of the visual
/// matrix listed them as covered by widget tests, and said plainly that a
/// widget test is not visual acceptance.
///
/// They are rendered here on the device, at device size, through the real
/// `StartupApp` with its documented injectable runner ("Injectable for
/// lifecycle tests"). Nothing about the widgets is stubbed — only the async
/// work whose OUTCOME selects between them. That is the honest boundary: the
/// bootstrap failure cannot be provoked on a healthy Simulator without
/// corrupting the encrypted database, and a corrupt database is not something
/// to manufacture on a machine holding the QA ledger.
///
/// The bootstrap app has no saved language to read — the database is exactly
/// what has not opened — so it resolves against the DEVICE locale. That is the
/// input varied here, because it is the only signal these three screens have.

/// Never completes: holds `StartupApp` on the loading state for as long as the
/// capture needs.
class _HangingRunner extends BootstrapRunner {
  @override
  String? get lastStep => 'database_open';

  @override
  Future<AppDatabase> run() => Completer<AppDatabase>().future;
}

class _FailingRunner extends BootstrapRunner {
  _FailingRunner(this._step, this._error);

  final String _step;
  final Object _error;

  @override
  String? get lastStep => _step;

  @override
  Future<AppDatabase> run() async => throw _error;

  /// The recovery view's only control calls this. Overridden to a no-op so a
  /// stray tap during capture cannot delete the encrypted database.
  @override
  Future<void> resetDatabaseAndRetry() async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // DISARM THE APP LOCK BEFORE ANY TEST RUNS.
  //
  // `AppLockGate` locks on the first frame when this flag is set, and asks iOS
  // to authenticate. On a Simulator that prompt is the device-passcode sheet,
  // which is a NATIVE view sitting above Flutter and cannot be satisfied — the
  // shell never mounts and every test in the file dies on "shell never
  // mounted", including ones that have nothing to do with the lock.
  //
  // The flag is sticky: `visual_closure_capture_test` turns it on to capture
  // the locked screen, and a run killed between the capture and its restore
  // leaves the device unlaunchable. Two runs were lost to exactly that before
  // the cause was found, so clearing it is a precondition of every capture
  // file rather than a courtesy of the one that sets it.
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  // Runs first. Not for the ledger — nothing here reads it — but because a
  // file whose own `app.main()` is the FIRST in the process does not mount a
  // shell, and a run was lost to exactly that. It also means the live capture
  // below is of a genuine second bootstrap, which the log shows running every
  // step end to end, not of a half-initialised process.
  demo_seed.main();

  var surfaceConverted = false;
  Future<void> captureReady() async {
    if (surfaceConverted || !Platform.isAndroid) return;
    await binding.convertFlutterSurfaceToImage();
    surfaceConverted = true;
  }

  Future<void> pumpFor(WidgetTester tester, Duration d) async {
    final deadline = DateTime.now().add(d);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final captured = <String>[];
  final notes = <String>[];

  testWidgets('live cold start shows the loading screen', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    app.main();
    // Polled, not a fixed window. The loading screen is removed the instant
    // bootstrap finishes, and a SECOND bootstrap in a warm process finishes
    // fast — the first version waited a flat 900ms and missed it.
    var present = false;
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(StartupLoadingScreen).evaluate().isNotEmpty) {
        present = true;
        break;
      }
    }
    notes.add('live cold start: StartupLoadingScreen '
        '${present ? "on screen" : "already replaced"}');
    if (present) {
      await captureReady();
      await binding.takeScreenshot('boot-live-startup-loading');
      captured.add('live/startup-loading');
    }
    // Recorded, not asserted. Missing this window means the app started fast,
    // which is not a defect — and the same surface is captured deterministically
    // by the pumped variant below. Failing here would have taken the whole file
    // down for a good outcome.
    if (!present) {
      debugPrint('[BOOT-NOTE] live cold start: bootstrap outran the capture '
          'window; SHELL-STARTUPLOADING is covered by the pumped variant');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  for (final lang in ['ar', 'en']) {
    testWidgets('boot states — $lang', (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = false;
      tester.platformDispatcher.localeTestValue = Locale(lang);
      tester.platformDispatcher.localesTestValue = [Locale(lang)];
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      // A UNIQUE KEY PER VARIANT. `StartupApp` assigns `_runner` in initState
      // as `late final`, so pumping a second `StartupApp` of the same type
      // REUSES the State and keeps the first runner. Without these keys every
      // variant below rendered the hanging runner's loading screen — four
      // captures of one surface, byte-distinct because the spinner had moved,
      // which is precisely the kind of evidence that looks like coverage and
      // is not.
      //
      // SHELL-STARTUPLOADING — the branded loading body, held open.
      await tester.pumpWidget(
          app.StartupApp(key: const ValueKey('loading'), runner: _HangingRunner()));
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(StartupLoadingScreen), findsOneWidget);
      await captureReady();
      await binding.takeScreenshot('boot-$lang-startup-loading');
      captured.add('$lang/startup-loading');

      // SHELL-STARTUPLOADING-ERROR — a generic bootstrap failure. `lastStep`
      // is deliberately NOT 'database_open': that combination is what routes
      // to the destructive recovery view instead.
      await tester.pumpWidget(app.StartupApp(
          key: const ValueKey('error'),
          runner: _FailingRunner(
              'session_restore', StateError('bootstrap failed'))));
      await pumpFor(tester, const Duration(seconds: 4));
      expect(find.byType(StartupLoadingScreen), findsOneWidget);
      await binding.takeScreenshot('boot-$lang-startup-error');
      captured.add('$lang/startup-error');

      // The timeout copy is a different string from the generic failure, and
      // the timeout must NOT reach the recovery view even though the step that
      // timed out is database_open — that distinction is load-bearing: a slow
      // first-run key generation would otherwise offer to erase the user's
      // data.
      await tester.pumpWidget(app.StartupApp(
          key: const ValueKey('timeout'),
          runner: _FailingRunner(
              'database_open', const BootstrapTimeoutException('database_open'))));
      await pumpFor(tester, const Duration(seconds: 4));
      expect(find.byType(StartupLoadingScreen), findsOneWidget,
          reason: 'a TIMEOUT on database_open must stay on the retry screen; '
              'routing it to the reset flow would offer to erase a healthy '
              'database because startup was merely slow');
      await binding.takeScreenshot('boot-$lang-startup-timeout');
      captured.add('$lang/startup-timeout');

      // SHELL-DATABASE-RECOVERY — a real database_open failure.
      await tester.pumpWidget(app.StartupApp(
          key: const ValueKey('recovery'),
          runner: _FailingRunner(
              'database_open', StateError('file is not a database'))));
      await pumpFor(tester, const Duration(seconds: 4));
      expect(find.byType(StartupLoadingScreen), findsNothing,
          reason: 'a database_open FAILURE must route to the recovery view');
      await binding.takeScreenshot('boot-$lang-database-recovery');
      captured.add('$lang/database-recovery');

      debugPrint('[BOOT] captured ${captured.join(", ")}');
      for (final n in notes) {
        debugPrint('[BOOT-NOTE] $n');
      }
    }, timeout: const Timeout(Duration(minutes: 8)));
  }
}
