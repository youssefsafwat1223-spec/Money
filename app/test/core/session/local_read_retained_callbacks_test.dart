// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/capture_runtime.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';

// Astra R45 R14 + R15 — retained callbacks and the logout residue clear, driven
// DIRECTLY (not through the providers that happen not to be built):
//  * the retained last-seen activity consent callback,
//  * the foreground notification tap / confirm / dismiss / route handler,
//  * previously registered native method-channel callbacks,
//  * the local-read logout's permitted local residue clear.
// "Scope replacement" here is the in-process writable -> read-only transition.

const _uid = 'uid-retained';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;

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
  });

  tearDown(() async {
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
  });

  Future<void> signIn() async {
    final sdk = await f.clientFor(_uid);
    clients.add(sdk);
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    await f.session.finishOnboarding(client: sdk);
  }

  /// The in-process writable -> local-read replacement of the same uid's scope.
  Future<AppDatabase> replaceWritableWithLocalRead() async {
    await signIn();
    final writable = f.host.current!.database;
    expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
    expect(f.session.localReadActive, isTrue);
    expect(writable.lifecycleState, DatabaseLifecycleState.closed);
    return writable;
  }

  UserSettingsEntity cloudOn() => const UserSettingsEntity(
        id: 'settings',
        country: 'SA',
        currency: 'SAR',
        language: 'ar',
        theme: 'dark',
        inputMethod: 'manual',
        notificationsJson: '{}',
        privacyModeEnabled: false,
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted,
      );

  // ---------------------------------------------------------- activity callback

  test(
      'R15: the retained last-seen activity callback sends nothing after the '
      'writable scope was replaced, even with Cloud ON saved', () async {
    final egress = TestEgress(seedOn: true)
      ..owner = _uid
      ..install();
    addTearDown(() => CloudEgressGate.instance = CloudEgressGate());
    final body = jsonEncode({
      'v': 1,
      'records': {
        _uid: const CloudEgressRecord(
                state: EgressState.on,
                ownerUid: _uid,
                transitionGeneration: 1,
                reservedVersion: 1)
            .toJson()
      }
    });
    egress.secure.value = body;
    egress.file.value = body;
    egress.gate.localReadActive = () => f.session.localReadEgressDenied;

    var settingsReads = 0;
    // The very factory bootstrap retains in the static ping service.
    final retained = BootstrapRunner.activityConsentGate(
      uid: _uid,
      settings: () async {
        settingsReads++;
        return cloudOn(); // the obsolete scope's saved consent: ON
      },
    );
    expect(await retained(), isTrue, reason: 'control: the writable scope');

    await replaceWritableWithLocalRead();
    final from = f.storage.attempts.length;
    final readsBefore = settingsReads;
    bool? allowed;
    try {
      allowed = await retained();
    } catch (_) {
      allowed = false; // a closed old database throws: the ping swallows it
    }
    expect(allowed, isFalse,
        reason: 'the saved ON consent of the obsolete scope must not transmit');
    expect(settingsReads, greaterThanOrEqualTo(readsBefore));
    expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:')),
        isEmpty,
        reason: 'no write of any kind');
    // Signed-out factory is always closed.
    expect(
        await BootstrapRunner.activityConsentGate(
            uid: null, settings: () async => cloudOn())(),
        isFalse);
  });

  // ------------------------------------------------ foreground notification tap

  group('R15 foreground notification handler after scope replacement', () {
    late _SpyLog spy;
    late AppDatabase memory;
    final confirms = <String>[];
    final quick = <CaptureQuickAction>[];
    final routes = <String>[];
    final subs = <StreamSubscription<Object?>>[];
    final svc = LocalNotificationService.instance;
    NotificationLogService? previous;

    setUp(() async {
      memory = await AppDatabase.open(executor: NativeDatabase.memory());
      spy = _SpyLog(memory);
      previous = svc.logService;
      svc.logService = spy;
      confirms.clear();
      quick.clear();
      routes.clear();
      subs
        ..add(CaptureRuntime.instance.confirmRequests.listen(confirms.add))
        ..add(CaptureRuntime.instance.quickActionRequests.listen(quick.add))
        ..add(CaptureRuntime.instance.navigationRequests.listen(routes.add));
    });

    tearDown(() async {
      for (final s in subs) {
        await s.cancel();
      }
      subs.clear();
      svc.logService = previous;
      await memory.close();
    });

    final tap = const CaptureNotificationPayload(
            kind: 'confirm',
            transactionId: 'tx-1',
            notificationLogId: 'log-1',
            notificationType: 'captureReview')
        .encode();
    final route = const CaptureNotificationPayload(
            kind: 'route', route: '/reports', notificationLogId: 'log-2')
        .encode();

    Future<void> deliverAll() async {
      await svc.debugHandleNotificationTap(tap); // plain tap
      await svc.debugHandleNotificationTap(tap, actionId: 'confirm_tx');
      await svc.debugHandleNotificationTap(tap, actionId: 'dismiss_tx');
      await svc.debugHandleNotificationTap(route);
      await Future<void>.delayed(Duration.zero);
    }

    test('control: in the writable scope the handler logs and routes',
        () async {
      await signIn();
      await deliverAll();
      expect(spy.opened, 4);
      expect(confirms, ['tx-1']);
      expect(quick.map((a) => (a.transactionId, a.confirm)),
          [('tx-1', true), ('tx-1', false)]);
      expect(routes, ['/reports']);
    });

    test(
        'after the replacement by a local-read scope: zero log, zero write, '
        'zero quick action, zero route', () async {
      await replaceWritableWithLocalRead();
      final from = f.storage.attempts.length;
      await deliverAll();
      expect(spy.opened, 0, reason: 'no stale opened-event log');
      expect(confirms, isEmpty);
      expect(quick, isEmpty, reason: 'no stale confirm / dismiss');
      expect(routes, isEmpty);
      expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:')),
          isEmpty);
    });
  });

  // -------------------------------------------------------- native callbacks

  group('R15 native method-channel callbacks', () {
    const channel = 'money_companion/native_capture';
    final calls = <String>[];

    Future<void> deliver(String method, [Object? args]) async {
      final data = const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, args));
      final completer = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channel, data, (_) => completer.complete());
      await completer.future.timeout(const Duration(seconds: 2));
    }

    tearDown(() {
      NativeCaptureBridge.setPendingMessagesHandler(null);
      NativeCaptureBridge.setNotificationRouteHandler(null);
      NativeCaptureBridge.setApnsTokenUpdatedHandler(null);
      calls.clear();
    });

    test(
        'registered callbacks run while mounted and NOTHING runs after the '
        'shell cleared them (what its dispose does)', () async {
      NativeCaptureBridge.setPendingMessagesHandler(
          () async => calls.add('pending'));
      NativeCaptureBridge.setNotificationRouteHandler(
          () async => calls.add('route'));
      NativeCaptureBridge.setApnsTokenUpdatedHandler(
          (token) async => calls.add('apns'));
      await deliver('pendingSharedMessagesAvailable');
      await deliver('pendingNotificationRouteAvailable');
      expect(calls, ['pending', 'route'], reason: 'control');

      // AppShell.dispose (the scope replacement unmounts it) clears all three.
      NativeCaptureBridge.setPendingMessagesHandler(null);
      NativeCaptureBridge.setApnsTokenUpdatedHandler(null);
      NativeCaptureBridge.setNotificationRouteHandler(null);
      calls.clear();
      await deliver('pendingSharedMessagesAvailable');
      await deliver('pendingNotificationRouteAvailable');
      await deliver(
          'apnsTokenUpdated', {'token': 'abc', 'environment': 'sandbox'});
      expect(calls, isEmpty, reason: 'no callback survives the shell');
    });
  });

  // ------------------------------------------------------- R14 logout residue

  group('R14 local-read logout: the permitted local residue clear only', () {
    var clears = 0;
    var flushes = 0;
    var unlinks = 0;
    var publishes = 0;

    setUp(() {
      clears = 0;
      flushes = 0;
      unlinks = 0;
      publishes = 0;
      f.session.configureSignOutFlush(() async => flushes++);
      f.session.configureCaptureDeviceUnlink(() async => unlinks++);
      f.session.configureCaptureOwnerPublish((uid, authority) async {
        publishes++;
      });
    });

    tearDown(() {
      f.session.configureSignOutFlush(null);
      f.session.configureCaptureDeviceUnlink(null);
      f.session.configureCaptureOwnerPublish(null);
    });

    Future<void> inLocalRead() async {
      await replaceWritableWithLocalRead();
      // Counters describe only what happens FROM HERE (sign-in did its own).
      clears = 0;
      flushes = 0;
      unlinks = 0;
      publishes = 0;
    }

    test('runs the local clear once; no flush, no unlink, no owner publication',
        () async {
      f.session.configureCaptureOwnerClear(() async {
        clears++;
        return true;
      });
      await inLocalRead();
      await f.session.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clears, 1, reason: 'the permitted local clear');
      expect(flushes, 0);
      expect(unlinks, 0);
      expect(publishes, 0);
      expect(f.session.localReadActive, isFalse);
      expect(await f.session.readLocalDataOwnerUid(), isNull,
          reason: 'a confirmed clear releases the owner marker');
    });

    test(
        'a failed clear keeps the owner marker (so a different user is '
        're-purged / refused) and the logout still locks', () async {
      f.session.configureCaptureOwnerClear(() async {
        clears++;
        return false;
      });
      await inLocalRead();
      final outcome = await f.session.signOut();
      expect(clears, 1);
      expect(await f.session.readLocalDataOwnerUid(), _uid,
          reason: 'unconfirmed residue purge: the owner stays named');
      expect(f.session.localReadActive, isFalse);
      expect(outcome, SignOutOutcome.complete,
          reason: 'the durable denial itself landed; the residue is reported '
              'by the retained owner marker, not as a clean slate');
      expect(flushes + unlinks + publishes, 0);
    });

    test('a throwing clear is treated as a failed clear', () async {
      f.session.configureCaptureOwnerClear(() async {
        clears++;
        throw StateError('native clear failed');
      });
      await inLocalRead();
      await f.session.signOut();
      expect(clears, 1);
      expect(await f.session.readLocalDataOwnerUid(), _uid);
      expect(f.session.localReadActive, isFalse);
    });

    test(
        'a successor owner is never released by the logout of the outgoing '
        'account (removal path keeps its owner guard)', () async {
      f.session.configureCaptureOwnerClear(() async {
        clears++;
        return true;
      });
      await inLocalRead();
      // The marker moved to another account meanwhile.
      f.storage.data['local_data_owner_uid'] = 'uid-successor';
      await f.session.removeDataFromDevice();
      expect(await f.session.readLocalDataOwnerUid(), 'uid-successor',
          reason: 'a Remove data for the outgoing uid must not release it');
    });
  });
}

class _SpyLog extends NotificationLogService {
  _SpyLog(super.db);
  int opened = 0;
  @override
  Future<void> recordOpened({
    required String logId,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
  }) async {
    opened++;
  }
}
