import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/pending_notification_actions.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';

/// إجراءات الإشعار (تأكيد/تجاهل) والتطبيق مغلق: يجب أن تُسجَّل دائمًا في
/// الملف الاحتياطي كي يعيد التطبيق تطبيقها عبر الـ routed repository عند أول
/// فتح — في وضع transactions_supabase_primary التعديل المحلي وحده يعني ضياع
/// الإجراء على الخادم (الـ isolate الخلفي لا يعرف قيمة العلامة الفعلية).
class _FakePathProvider extends PlatformInterface
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.root) : super(token: _token);

  static final Object _token = Object();
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;

  @override
  Future<List<String>?> getExternalCachePaths() async => [root];

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async =>
      [root];

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bg_actions_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ------------------------------------------------------------------------
  // PRODUCTION PATH (the gate). The plugin callback supplies action / payload
  // strings and NO host-issued job, so it runs through `_backgroundEntry`,
  // which defers BEFORE record, open or acknowledgement. These cases drive that
  // very gate (`debugRunBackgroundEntry`), never the ungated action.
  // ------------------------------------------------------------------------
  group('production path: the default-deny gate', () {
    Future<void> expectNothingHappened() async {
      expect(await PendingNotificationActions.drain(), isEmpty,
          reason: 'nothing was recorded for replay');
      expect(tempDir.listSync(), isEmpty,
          reason: 'no record file, replica, key or lease was created');
    }

    test('background confirm without a job records, opens and acks nothing',
        () async {
      final ran = await LocalNotificationService.debugRunBackgroundEntry(
        'tx-confirm-1',
        confirm: true,
      );
      expect(ran, isFalse);
      await expectNothingHappened();
    });

    test('background dismiss without a job records, opens and acks nothing',
        () async {
      final ran = await LocalNotificationService.debugRunBackgroundEntry(
        'tx-dismiss-1',
        confirm: false,
      );
      expect(ran, isFalse);
      await expectNothingHappened();
    });

    test('a flip of the same transaction without a job still does nothing',
        () async {
      for (final confirm in [true, false]) {
        expect(
            await LocalNotificationService.debugRunBackgroundEntry('tx-flip',
                confirm: confirm),
            isFalse);
      }
      await expectNothingHappened();
    });

    test('clear() is safe and idempotent when the gate recorded nothing',
        () async {
      await LocalNotificationService.debugRunBackgroundEntry('tx-user-a',
          confirm: true);
      expect(await PendingNotificationActions.clear(), isTrue);
      expect(await PendingNotificationActions.drain(), isEmpty);
      expect(await PendingNotificationActions.clear(), isTrue);
    });

    test('an unissued (hand-built) job is not a host-issued job', () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final ran = await LocalNotificationService.debugRunBackgroundEntry(
        'tx-forged',
        confirm: true,
        job: DatabaseBrokerClient(port.sendPort),
      );
      expect(ran, isFalse);
      await expectNothingHappened();
    });
  });

  // ------------------------------------------------------------------------
  // POST-GATE action logic. The action only runs for a job the broker really
  // issued to a genuine, current host (committed publication + writable mode),
  // obtained through the broker's own issuance — never a forged client.
  // ------------------------------------------------------------------------
  group('post-gate action logic with a host-issued test job', () {
    late F2Fixture fixture;
    late SupabaseClient sdk;
    late DatabaseAccessBroker broker;

    Future<void> publishGenuineHost() async {
      final settled = Completer<void>();
      fixture.session.debugAuthEventCompleted = (event) {
        if (event == AuthChangeEvent.tokenRefreshed && !settled.isCompleted) {
          settled.complete();
        }
      };
      final actual = sdk.auth.currentSession!;
      await fixture.session.setIdentity(
        method: 'apple',
        email: actual.user.email,
        userId: actual.user.id,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken &&
            sdk.auth.currentSession?.isExpired == false,
      );
      await fixture.session.finishOnboarding(client: sdk);
      try {
        await fixture.session.bindSupabaseAuth(sdk);
        await settled.future;
      } finally {
        fixture.session.debugAuthEventCompleted = null;
      }
    }

    setUp(() async {
      // The host publishes its replica without a coordinator ledger (as the
      // broker suite does): the coordinator only exists to issue the job.
      broker = DatabaseAccessBroker.debugUnregistered();
      fixture = await F2Fixture.create();
      await fixture.session.debugResetAuthBinding();
      fixture.session.configureAccountScope(fixture.host);
      sdk = await fixture.clientFor('bg-action-owner');
      await publishGenuineHost();
      final receipt = fixture.session.captureDatabaseHostAdmission();
      expect(receipt, isNotNull,
          reason: 'a genuine committed publication issued the host receipt');
      await broker.transition(DatabaseAccessMode.writable, admission: receipt);
      // The notification isolate's own app-support directory (path provider).
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    });

    tearDown(() async {
      await fixture.session.debugResetAuthBinding();
      await fixture.dispose();
      await sdk.dispose();
      broker.debugDispose();
    });

    /// The broker's own issuance: a client only a current writable host can mint.
    DatabaseBrokerClient issuedJob() {
      final job = broker.client;
      expect(job.isHostIssued, isTrue);
      return job;
    }

    Future<void> runGated(String id, {required bool confirm}) async {
      final ran = await LocalNotificationService.debugRunBackgroundEntry(id,
          confirm: confirm, job: issuedJob());
      expect(ran, isTrue, reason: 'a host-issued job passes the gate');
    }

    test('background confirm while app is closed is recorded for replay',
        () async {
      await runGated('tx-confirm-1', confirm: true);

      final drained = await PendingNotificationActions.drain();
      expect(drained, hasLength(1));
      expect(drained.single.transactionId, 'tx-confirm-1');
      expect(drained.single.confirm, isTrue);

      // السحب يمسح الملف — لا إعادة تطبيق مكررة في الفتحات اللاحقة.
      expect(await PendingNotificationActions.drain(), isEmpty);
    });

    test(
        'MALI-070n: clear() deletes queued actions so they never replay under '
        'the next identity, and is safe when the file is absent', () async {
      await runGated('tx-user-a', confirm: true);

      // Destructive sign-out purges the file outright (no draining/applying).
      expect(await PendingNotificationActions.clear(), isTrue);

      // The next user drains nothing — user A's action cannot execute under B.
      expect(await PendingNotificationActions.drain(), isEmpty);
      // Idempotent: clearing an already-absent file still reports success.
      expect(await PendingNotificationActions.clear(), isTrue);
    });

    test('background dismiss while app is closed is recorded for replay',
        () async {
      await runGated('tx-dismiss-1', confirm: false);

      final drained = await PendingNotificationActions.drain();
      expect(drained, hasLength(1));
      expect(drained.single.transactionId, 'tx-dismiss-1');
      expect(drained.single.confirm, isFalse);
    });

    test('latest action for the same transaction wins', () async {
      await runGated('tx-flip', confirm: true);
      await runGated('tx-flip', confirm: false);

      final drained = await PendingNotificationActions.drain();
      expect(drained, hasLength(1));
      expect(drained.single.confirm, isFalse);
    });

    test(
        'sequential drains (app startup, then a later resume) never return '
        'the same action twice', () async {
      await runGated('tx-race-1', confirm: true);

      // Simulates AppShell's initial-mount drain followed by a later
      // AppLifecycleState.resumed drain for the same pending action. AppShell
      // never issues these two calls concurrently — _reconcileDataAfterResume
      // guards re-entry with _isReconcilingAfterResume, so a resume firing
      // while startup reconciliation is still running is a no-op rather than
      // a second overlapping drain(). Note: PendingNotificationActions.drain()
      // itself is a read-then-delete and is NOT safe against true concurrent
      // callers — the AppShell guard is what keeps calls to it sequential.
      final first = await PendingNotificationActions.drain();
      final second = await PendingNotificationActions.drain();

      final totalDrained = [...first, ...second];
      expect(totalDrained, hasLength(1));
      expect(totalDrained.single.transactionId, 'tx-race-1');
    });

    test('once the host loses its issuer, the broker issues no job at all',
        () async {
      expect(broker.client.isHostIssued, isTrue);
      fixture.session.markSessionInvalid();
      await broker.transition(DatabaseAccessMode.closed);
      // The same gate now sees an unissued client and refuses everything.
      final ran = await LocalNotificationService.debugRunBackgroundEntry(
          'tx-after-loss',
          confirm: true,
          job: broker.client);
      expect(ran, isFalse);
      expect(broker.client.isHostIssued, isFalse);
      expect(await PendingNotificationActions.drain(), isEmpty);
    });
  });
}
