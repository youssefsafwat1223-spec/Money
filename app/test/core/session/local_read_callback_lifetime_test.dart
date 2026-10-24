// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/features/capture/capture_runtime.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';

// O-LC-2 (Astra R6) — a foreground notification callback is bound to the
// account lifecycle it STARTED in. Opened-event handling is paused INSIDE the
// log write (the await after the entry guard), the lifecycle is replaced in
// each way a lifecycle can be replaced, and the handler is then released:
// nothing it would have dispatched (quick action, confirmation, navigation) may
// reach a listener, which stands for whatever shell is mounted for the
// successor, and nothing may be written for the successor.

const _uid = 'uid-lifetime-a';
const _other = 'uid-lifetime-b';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;
  late _GatedLog gatedLog;
  late AppDatabase memory;
  final confirms = <String>[];
  final quick = <CaptureQuickAction>[];
  final routes = <String>[];
  final subs = <StreamSubscription<Object?>>[];
  final svc = LocalNotificationService.instance;
  NotificationLogService? previous;

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: (
          {location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted()}) {
        return AppDatabase.open(
            location: location,
            runMigrations: runMigrations,
            creation: creation);
      },
    );
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
    memory = await AppDatabase.open(executor: NativeDatabase.memory());
    gatedLog = _GatedLog(memory);
    previous = svc.logService;
    svc.logService = gatedLog;
    confirms.clear();
    quick.clear();
    routes.clear();
    subs
      ..add(CaptureRuntime.instance.confirmRequests.listen(confirms.add))
      ..add(CaptureRuntime.instance.quickActionRequests.listen(quick.add))
      ..add(CaptureRuntime.instance.navigationRequests.listen(routes.add));
  });

  tearDown(() async {
    gatedLog.gate.isCompleted ? null : gatedLog.gate.complete();
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    svc.logService = previous;
    await memory.close();
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
  });

  Future<void> signIn([String uid = _uid]) async {
    final sdk = await f.clientFor(uid);
    clients.add(sdk);
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$uid@example.com', userId: uid);
    await f.session.finishOnboarding(client: sdk);
  }

  final tap = const CaptureNotificationPayload(
          kind: 'confirm',
          transactionId: 'tx-1',
          notificationLogId: 'log-1',
          notificationType: 'captureReview')
      .encode();
  final route = const CaptureNotificationPayload(
          kind: 'route', route: '/reports', notificationLogId: 'log-2')
      .encode();

  /// Four handlers enter the guard, then all wait inside the opened-event write.
  Future<List<Future<void>>> enterAndPause() async {
    final started = [
      svc.debugHandleNotificationTap(tap),
      svc.debugHandleNotificationTap(tap, actionId: 'confirm_tx'),
      svc.debugHandleNotificationTap(tap, actionId: 'dismiss_tx'),
      svc.debugHandleNotificationTap(route),
    ];
    await gatedLog.entered(4);
    expect(confirms, isEmpty);
    expect(quick, isEmpty);
    expect(routes, isEmpty);
    return started;
  }

  Future<void> releaseAndSettle(List<Future<void>> started) async {
    gatedLog.gate.complete();
    await Future.wait(started);
    await Future<void>.delayed(Duration.zero);
  }

  test('control: with no transition the released handlers dispatch', () async {
    await signIn();
    final started = await enterAndPause();
    await releaseAndSettle(started);
    expect(confirms, ['tx-1']);
    expect(quick.map((a) => (a.transactionId, a.confirm)),
        [('tx-1', true), ('tx-1', false)]);
    expect(routes, ['/reports']);
  });

  test(
      'O-LC-2: a signed-out (no admitted origin) tap makes ZERO account log '
      'writes and dispatches nothing', () async {
    gatedLog.gate.complete();
    expect(f.session.captureCallbackOrigin(), isNull);
    final from = f.storage.attempts.length;
    for (final action in [null, 'confirm_tx', 'dismiss_tx']) {
      await svc.debugHandleNotificationTap(tap, actionId: action);
    }
    await svc.debugHandleNotificationTap(route);
    await Future<void>.delayed(Duration.zero);
    expect(gatedLog.enteredCount, 0, reason: 'no opened-event write attempted');
    expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:')),
        isEmpty);
    expect(confirms, isEmpty);
    expect(quick, isEmpty);
    expect(routes, isEmpty);
  });

  final transitions = <String, Future<void> Function()>{
    'writable -> local-read': () async {
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(f.session.localReadActive, isTrue);
    },
    'logout': () async {
      await f.session.signOut();
      expect(f.session.status, isNot(SessionStatus.authenticated));
    },
    'same-UID readmission': () async {
      await f.session.signOut();
      await signIn(_uid);
      expect(f.host.current!.uid, _uid);
    },
    'different-UID replacement': () async {
      await f.session.signOut();
      await signIn(_other);
      expect(f.host.current!.uid, _other);
    },
  };

  for (final entry in transitions.entries) {
    test(
        '${entry.key}: a handler paused inside the opened-event write '
        'dispatches nothing and writes nothing for the successor', () async {
      await signIn();
      final started = await enterAndPause();
      await entry.value();
      final from = f.storage.attempts.length;
      await releaseAndSettle(started);
      expect(confirms, isEmpty, reason: 'no stale confirmation sheet');
      expect(quick, isEmpty, reason: 'no stale confirm / dismiss');
      expect(routes, isEmpty, reason: 'no stale navigation');
      expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:')),
          isEmpty,
          reason: 'no successor write');
    });
  }

  test(
      'an event delivered AFTER the replacement is still refused (retained '
      'callback), and a fresh callback of the new lifecycle works', () async {
    gatedLog.gate.complete();
    await signIn();
    await f.session.signOut();
    await svc.debugHandleNotificationTap(tap, actionId: 'confirm_tx');
    await Future<void>.delayed(Duration.zero);
    expect(quick, isEmpty, reason: 'signed out: nothing is authorised');
    await signIn(_other);
    await svc.debugHandleNotificationTap(tap, actionId: 'confirm_tx');
    await Future<void>.delayed(Duration.zero);
    expect(quick.map((a) => (a.transactionId, a.confirm)), [('tx-1', true)],
        reason: 'the new lifecycle\'s own callback is honoured');
  });
}

/// Holds every opened-event write on [gate] and counts the entries.
class _GatedLog extends NotificationLogService {
  _GatedLog(super.db);
  final Completer<void> gate = Completer<void>();
  int _entered = 0;
  Completer<void>? _waiting;
  int _target = 0;

  int get enteredCount => _entered;

  Future<void> entered(int count) {
    if (_entered >= count) return Future.value();
    _target = count;
    return (_waiting = Completer<void>()).future;
  }

  @override
  Future<void> recordOpened({
    required String logId,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
  }) async {
    _entered++;
    if (_entered >= _target) {
      final waiting = _waiting;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    }
    await gate.future;
  }
}
