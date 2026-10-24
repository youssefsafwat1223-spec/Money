// ignore_for_file: unused_import
import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:money_companion/features/capture/capture_runtime.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/main.dart';
import 'package:money_companion/core/backend/auth_client_provider.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async => barrier;
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {}
  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async => true;
  @override
  Future<void> publishCaptureOwner(
      {required String uid,
      required bool cloud,
      required bool ai,
      required int version,
      required int expectedEpoch,
      int? transitionGeneration}) async {}
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 2400 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}


const _channel = 'money_companion/native_capture';

/// Whether a native callback handler is installed on the capture channel.
Future<bool> _channelHandled(String method) async {
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method));
  final done = Completer<ByteData?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channel, data, done.complete);
  return (await done.future.timeout(const Duration(seconds: 5))) != null;
}

Future<String> _status(AppDatabase db, String id) async => (await db
        .customSelect('SELECT status FROM transactions WHERE id = ?;',
            variables: [Variable.withString(id)])
        .getSingle())
    .read<String>('status');

Future<void> _pending(AppDatabase db, String id) => db.customStatement(
    "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
    "source, occurred_at, raw_message, parse_confidence, status, created_at, "
    "updated_at, raw_merchant, direction) VALUES ('$id', 10, 1000, 'SAR', "
    "'payment', 'bank', '2026-10-01T00:00:00Z', '', 1, 'pending', "
    "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 'Shop', 'debit');");

/// One asynchronous error that reached the harness zone, with the phase of the
/// scenario it surfaced in.
class SeenError {
  SeenError(this.phase, this.error, this.stack);
  final String phase;
  final Object error;
  final StackTrace stack;
  String get text => '${error.runtimeType}: $error';
  @override
  String toString() => '[$phase] $text';
}

/// Strict error recording for the widget scenarios. NOTHING is suppressed: every
/// asynchronous error is recorded with its phase while collection is open.
/// After collection closes, the enclosing test zone owns every later error.
class StrictErrors {
  String phase = 'setup';
  final List<SeenError> seen = [];
  bool closed = false;

  /// The guarded zone errors are delivered to (set by [runStrict]).
  Zone? zone;
  late Zone owner;

  void add(Object error, StackTrace stack) {
    if (closed) {
      owner.handleUncaughtError(error, stack);
      return;
    }
    seen.add(SeenError(phase, error, stack));
  }

  /// Errors not matched, one-for-one, by [expected] (phase, text pattern).
  List<SeenError> unexpected(List<(String, Pattern)> expected) {
    final remaining = List<(String, Pattern)>.of(expected);
    final out = <SeenError>[];
    for (final e in seen) {
      final i = remaining.indexWhere(
          (r) => r.$1 == e.phase && e.text.contains(r.$2));
      if (i >= 0) {
        remaining.removeAt(i);
      } else {
        out.add(e);
      }
    }
    return out;
  }

  /// Expected failures that never happened (an exact count is asserted).
  List<(String, Pattern)> missing(List<(String, Pattern)> expected) {
    final remaining = List<(String, Pattern)>.of(expected);
    for (final e in seen) {
      final i = remaining.indexWhere(
          (r) => r.$1 == e.phase && e.text.contains(r.$2));
      if (i >= 0) remaining.removeAt(i);
    }
    return remaining;
  }
}

/// Runs [body] in a guarded zone that records, never suppresses. A thrown body
/// error propagates. After the body, real time is allowed to pass so late
/// asynchronous errors surface inside the recording window.
Future<StrictErrors> runStrict(
  WidgetTester tester,
  Future<void> Function(StrictErrors errors) body, {
  Duration drain = const Duration(milliseconds: 300),
}) async {
  final errors = StrictErrors()..owner = Zone.current;
  final finished = Completer<void>();
  runZonedGuarded(() async {
    errors.zone = Zone.current;
    try {
      await body(errors);
      errors.phase = 'drain';
      await tester.runAsync(() => Future<void>.delayed(drain));
      finished.complete();
    } catch (e, st) {
      if (!finished.isCompleted) finished.completeError(e, st);
    }
  }, errors.add);
  await finished.future;
  errors.closed = true;
  return errors;
}

void main() {
  setUp(() => rootBundle.clear());
  // No asynchronous failure is tolerated anywhere in the scenario. The real
  // dashboard request has a completion barrier before this fixture locks the
  // scope; a separate gated-query test covers a real transition while pending.
  const expected = <(String, Pattern)>[];

  testWidgets(
      'O-LC-2: the REAL shell cleans up on its transition and a stale '
      'originating lifecycle cannot act for the successor shell',
      (tester) async {
    final errors = await runStrict(tester, (e) => _body(tester, e));
    // Errors arriving after the harness closed fail through teardown too.
    addTearDown(() {
      expect(errors.unexpected(expected), isEmpty,
          reason: 'unexpected asynchronous error(s)');
    });
    expect(errors.unexpected(expected), isEmpty,
        reason: 'unexpected asynchronous error(s)');
    expect(errors.seen, isEmpty);
  });

  testWidgets(
      'control: the strict harness reports an unexpected LATE asynchronous '
      'error (after the body finished) instead of dropping it',
      (tester) async {
    final errors = await runStrict(tester, (e) async {
      e.phase = 'body';
      // Delivered through the guarded zone after the body returned, inside the
      // drain window, from real time (as an isolate response would be).
      final zone = e.zone!;
      await tester.runAsync(() async {
        Timer(const Duration(milliseconds: 30), () {
          zone.handleUncaughtError(StateError('late-injected'), StackTrace.current);
        });
      });
    }, drain: const Duration(milliseconds: 200));
    final bad = errors.unexpected(const []);
    expect(bad, hasLength(1));
    expect(bad.single.phase, 'drain');
    expect(bad.single.text, contains('late-injected'));
    // A narrowly expected error is matched once; a second one is unexpected.
    expect(errors.unexpected([('drain', 'late-injected')]), isEmpty);
    expect(errors.missing([('drain', 'never-happens')]), hasLength(1));
  });

  for (final duringTeardown in [false, true]) {
    testWidgets(
        'control: a closed strict harness forwards errors '
        '${duringTeardown ? 'during teardown' : 'after runStrict returns'} '
        'to its enclosing error zone', (tester) async {
      final forwarded = <Object>[];
      final done = Completer<StrictErrors>();
      runZonedGuarded(() async {
        try {
          done.complete(await runStrict(tester, (_) async {},
              drain: Duration.zero));
        } catch (error, stack) {
          done.completeError(error, stack);
        }
      }, (error, stack) => forwarded.add(error));
      final errors = await done.future;
      expect(errors.closed, isTrue);
      void injectAndVerify() {
        errors.phase = duringTeardown ? 'teardown' : 'post-return';
        final error = StateError('closed-sink-injected');
        errors.zone!.handleUncaughtError(error, StackTrace.current);
        expect(forwarded, [same(error)],
            reason: 'the enclosing test error zone owns closed-sink errors');
        expect(errors.seen, isEmpty,
            reason: 'closed collection cannot consume a late failure');
      }

      if (duringTeardown) {
        addTearDown(injectAndVerify);
      } else {
        injectAndVerify();
      }
    });
  }
}

Future<void> _body(WidgetTester tester, StrictErrors errors) async {
  {
    final support = Directory.systemTemp.createTempSync('o_lc2_');
    RecordingSecureStorage().install().data['welcome_manifesto_seen'] = '1';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    FlutterLocalNotificationsPlatform.instance = _Notifications();
    final session = AppSession.instance;
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final client = await tester.runAsync(() => F2Fixture.liveClient('uid-x'));
    var runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = _Queue();
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(MoneyApp).evaluate().isNotEmpty);

    Future<void> signIn() async {
      var done = false;
      await tester.runAsync(() async {
        unawaited(session
            .completeOnboarding(
                method: 'google', email: 'x@example.com', userId: 'uid-x')
            .then((_) => done = true));
      });
      await _until(tester, () => done);
      await _until(tester, () => find.byType(AppShell).evaluate().isNotEmpty);
    }

    /// Runs real async work without blocking the frame pump (the shell's own
    /// startup work may be waiting for a frame while it holds the database).
    Future<T> bg<T>(Future<T> Function() work) async {
      T? result;
      Object? failure;
      StackTrace? failureStack;
      var finished = false;
      await tester.runAsync(() async {
        unawaited(work().then((v) {
          result = v;
          finished = true;
        }, onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          finished = true;
        }));
      });
      await _until(tester, () => finished);
      if (failure != null) {
        Error.throwWithStackTrace(failure!, failureStack!);
      }
      return result as T;
    }

    Future<void> statusBecomes(AppDatabase db, String id, String want) async {
      var seen = '';
      for (var i = 0; i < 200 && seen != want; i++) {
        seen = await bg(() => _status(db, id));
        if (seen != want) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }
      expect(seen, want);
    }

    Future<void> dashboardFinished() async {
      final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)));
      await bg(() => container.read(dashboardDataProvider.future));
    }

    Future<bool> handled(String method) async =>
        await bg(() => _channelHandled(method));

    expect(await handled('pendingSharedMessagesAvailable'), isFalse,
        reason: 'no shell yet: no native callback is registered');

    // ---- first lifecycle: the shell registers, honours its own origin ----
    errors.phase = 'first-lifecycle';
    await signIn();
    expect(await handled('pendingNotificationRouteAvailable'), isTrue,
        reason: 'the mounted shell registered its native callbacks');
    final first = runner.accountScope.current!.database;
    await bg(() => _pending(first, 'tx-control'));
    final firstOrigin = session.captureCallbackOrigin()!;
    CaptureRuntime.instance
        .requestQuickAction('tx-control', confirm: true, origin: firstOrigin);
    await statusBecomes(first, 'tx-control', 'confirmed');
    // Let the first shell's own cold-start work finish before its transition.
    await bg(() => session.drainAdmissions());
    await dashboardFinished();
    await bg(() => session.drainAdmissions());

    // ---- the transition: Remove data unmounts the shell and its cleanup runs ----
    errors.phase = 'transition';
    await bg(() => session.removeDataFromDevice());
    await _until(tester, () => find.byType(AppShell).evaluate().isEmpty);
    expect(await handled('pendingSharedMessagesAvailable'), isFalse,
        reason: 'the disposed shell left no pending-messages callback');
    expect(await handled('pendingNotificationRouteAvailable'), isFalse,
        reason: 'the disposed shell left no route callback');
    expect(await handled('apnsTokenUpdated'), isFalse,
        reason: 'the disposed shell left no APNs callback');
    expect(firstOrigin.isCurrent, isFalse);

    // ---- same-UID readmission in a fresh process: a NEW shell listens -----
    errors.phase = 'second-lifecycle';
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await bg(() => runner.accountScope.lock());
    runner.accountScope.dispose();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    runner = BootstrapRunner(debugAuthClient: client)..captureQueue = _Queue();
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(MoneyApp).evaluate().isNotEmpty);
    await signIn();
    final second = runner.accountScope.current!.database;
    expect(identical(second, first), isFalse);
    await bg(() => _pending(second, 'tx-stale'));
    await bg(() => _pending(second, 'tx-fresh'));
    CaptureRuntime.instance
        .requestQuickAction('tx-stale', confirm: true, origin: firstOrigin);
    CaptureRuntime.instance
        .requestQuickAction('tx-stale', confirm: false, origin: firstOrigin);
    final secondOrigin = session.captureCallbackOrigin()!;
    CaptureRuntime.instance
        .requestQuickAction('tx-fresh', confirm: true, origin: secondOrigin);
    await statusBecomes(second, 'tx-fresh', 'confirmed');
    // The current action is delivered after both stale actions on the same
    // ordered stream; its completed write is the delivery barrier.
    expect(await bg(() => _status(second, 'tx-stale')), 'pending',
        reason: 'the stale lifecycle\'s quick action wrote nothing for the '
            'successor, though its shell is listening');
    // The successor shell's own cold-start work must finish before teardown.
    await bg(() => session.drainAdmissions());
    await dashboardFinished();
    await bg(() => session.drainAdmissions());

    errors.phase = 'teardown';
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The unmounted shell's providers are disposed; let any query it already
    // sent finish BEFORE the scope (and its connection) is locked.
    var locked = false;
    await tester.runAsync(() async {
      unawaited(runner.accountScope.lock().then((_) => locked = true));
    });
    await _until(tester, () => locked);
    runner.accountScope.dispose();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async => support.deleteSync(recursive: true));
  }
}
