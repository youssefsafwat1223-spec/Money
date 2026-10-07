import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_server_port.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

// A-12-min — CLOUD OFF = ZERO EGRESS. A network spy: every transport the
// capture path owns is a fake that records the call, and the tests assert the
// call list is EMPTY across admission, capture, sign-out, sign-in, resume, a
// 401 and Remove data. The only exception is the single, one-shot revoke INSIDE
// the user's own ON->OFF transition (CaptureDeviceRegistrationService.
// disableCloud, kRevokeAtCloudSwitchOff): the freeze comes first, the revoke is
// the last control-plane action of the ON state, OFF is committed whatever it
// does, and it is never sent again (sync, resume, relaunch, timers).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

typedef _Consent = ({bool cloud, bool ai, int version});

/// Every egress call lands in the ONE shared [calls] log.
class _SpyBackend extends CaptureBackendClient {
  _SpyBackend(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  Object? error;
  final deviceConsents = <({bool cloud, bool ai})>[];
  Future<void> Function()? onSetDevice;

  @override
  Future<String> registerDevice(
      {required String installId, String platform = 'ios'}) async {
    calls.add('registerDevice');
    if (error != null) throw error!;
    return 'device-secret';
  }

  @override
  Future<void> unlinkDevice(
      {required String installId, required String deviceSecret}) async {
    calls.add('unlinkDevice');
  }

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    calls.add('setDeviceConsent');
    deviceConsents.add((cloud: cloudProcessingEnabled, ai: aiConsentGranted));
    await onSetDevice?.call();
  }

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    calls.add('registerPushToken');
  }

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    calls.add('syncCaptures');
    return const [];
  }

  @override
  Future<void> processIosSms({
    required String installId,
    required String deviceSecret,
    required String payloadId,
    required String smsText,
    required DateTime receivedAt,
    required bool allowAi,
    String? sender,
    String? locale,
    String? ownerUid,
  }) async {
    calls.add('processIosSms');
  }
}

class _SpyConsent extends CaptureConsentClient {
  _SpyConsent(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  final links = <_Consent>[];
  final sets = <_Consent>[];
  Object? linkError;
  Object? setError;
  Future<void> Function()? onLink;
  Future<void> Function()? onSet;

  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    calls.add('link');
    await onLink?.call();
    if (linkError != null) throw linkError!;
    links.add((cloud: cloud, ai: ai, version: version));
  }

  @override
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    calls.add('set');
    await onSet?.call();
    if (setError != null) throw setError!;
    sets.add((cloud: cloud, ai: ai, version: version));
  }
}

typedef _Published = ({
  String uid,
  bool cloud,
  bool ai,
  int version,
  int epoch,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late List<String> calls;
  late _SpyBackend backend;
  late _SpyConsent consent;
  late List<_Published> published;
  late int epoch;
  late int apnsLoads;
  late List<bool> nativeConfigs;
  late List<({String uid, bool cloud, bool ai, int version})> mirrors;
  Object? nativeConfigError;
  CaptureSession? session;
  String? replicaOwner;
  late Directory markerDir;

  CaptureDeviceRegistrationService service({
    bool backendConfigured = true,
    bool revoke = kRevokeAtCloudSwitchOff,
    Duration timeout = kCloudOffRevokeTimeout,
    FlutterSecureStorage? storage,
    Future<Directory> Function()? markerDirectory,
  }) =>
      CaptureDeviceRegistrationService(
        revokeAtSwitchOff: revoke,
        revokeTimeout: timeout,
        markerDirectory: markerDirectory ?? () async => markerDir,
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: storage ?? const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => backendConfigured,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
        }) async {
          nativeConfigs.add(cloudProcessingEnabled);
          if (nativeConfigError != null) throw nativeConfigError!;
        },
        loadApnsToken: () async {
          apnsLoads++;
          return null;
        },
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        }) async {
          mirrors.add((uid: uid, cloud: cloud, ai: ai, version: version));
        },
        readOwnerEpoch: () async => epoch,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        }) async {
          published.add((
            uid: uid,
            cloud: cloud,
            ai: ai,
            version: version,
            epoch: expectedEpoch,
          ));
        },
      );

  Future<void> save({ConsentState? cloud, ConsentState? ai}) async {
    final s = await repo.getSettings();
    await repo
        .saveSettings(s.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    calls = [];
    backend = _SpyBackend(calls);
    consent = _SpyConsent(calls);
    published = [];
    epoch = 0;
    apnsLoads = 0;
    nativeConfigs = [];
    mirrors = [];
    nativeConfigError = null;
    ConsentAuthority.egressFrozen = false;
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
    markerDir = Directory.systemTemp.createTempSync('cloud_off_marker');
  });
  tearDown(() async {
    ConsentAuthority.egressFrozen = false;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
    await db.close();
  });

  group('Cloud OFF sends nothing', () {
    test('admission publishes the owner LOCALLY with a Cloud-OFF mirror',
        () async {
      await save(cloud: ConsentState.declined);

      await service().linkToCurrentUser();

      expect(calls, isEmpty);
      expect(published, hasLength(1));
      expect(published.single.uid, 'uid-a');
      expect(published.single.cloud, isFalse);
      expect(published.single.ai, isFalse);
    });

    test('an unset consent (a brand-new user) is OFF too', () async {
      await service().linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published.single.cloud, isFalse);
    });

    test('local publication needs neither a configured backend nor a secret',
        () async {
      await service(backendConfigured: false).linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published, hasLength(1));
    });

    test('capture / resume / startup syncs repeat with zero calls', () async {
      final s = service();
      for (var i = 0; i < 4; i++) {
        await s.syncBackendState();
      }
      await s.syncNativeState();
      await s.retry();
      expect(calls, isEmpty);
      expect(apnsLoads, 0, reason: 'no APNs registration while OFF');
    });

    test('an existing secret does not make OFF talk to the server', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = service();
      await s.syncBackendState();
      await s.linkToCurrentUser();
      expect(calls, isEmpty);
    });

    test('sign-in of another user: still zero calls, owner published locally',
        () async {
      final s = service();
      await s.linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      await s.linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published.map((p) => p.uid), ['uid-a', 'uid-b']);
    });

    test('sign-out and Remove data (the unlink hook) send nothing', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = service();
      await s.syncBackendState();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test('a 401-shaped backend is never even called, so nothing recovers',
        () async {
      backend.error = const CaptureBackendException('register_failed_401');
      consent.linkError = const CaptureBackendException('link_device_failed_401');
      consent.setError = const CaptureBackendException('set_consent_failed_401');
      final s = service();
      await s.linkToCurrentUser();
      await s.syncBackendState();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test(
        'a 401 recovery never re-registers when Cloud is switched OFF while '
        'the link is in flight', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'stale-secret'});
      await save(cloud: ConsentState.accepted);
      consent.onLink = () async {
        await save(cloud: ConsentState.declined); // the user flips OFF mid-link
        throw const CaptureBackendException('link_device_failed_401');
      };
      await service().linkToCurrentUser();
      expect(calls, ['link'], reason: 'no registerDevice after the OFF toggle');
    });

    test('Cloud OFF with no admitted replica / session publishes nothing',
        () async {
      session = null;
      await service().linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'j');
      await service().linkToCurrentUser(); // replica belongs to uid-a
      expect(published, isEmpty);
      expect(calls, isEmpty);
    });

    test('the legacy server port treats OFF as "not configured": zero calls',
        () async {
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: service(),
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );
      expect((await port.fetchResults()).status,
          CaptureFetchStatus.notConfigured);
      await port.acknowledge(const ['x']);
      expect(calls, isEmpty);
    });
  });

  group('publication is a compare-and-swap on the owner epoch', () {
    test('the epoch read BEFORE the publish is the one passed to native',
        () async {
      epoch = 7;
      await service().linkToCurrentUser();
      expect(published.single.epoch, 7);
    });

    test('a failed native publish (cleared since) leaves no owner, no throw',
        () async {
      final s = CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        readOwnerEpoch: () async => 1,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        }) async =>
            throw const CaptureQueueException('owner_changed'),
      );
      await s.linkToCurrentUser(); // _linkOnce swallows: fail closed
      expect(calls, isEmpty);
    });
  });

  // E1 — the user-ratified Cloud ON->OFF transition (disableCloud).
  group('E1: the ON->OFF transition (disableCloud)', () {
    var commits = 0;
    Future<void> commit() async {
      commits++;
      await save(cloud: ConsentState.declined);
    }

    Future<void> pump() async {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<CaptureDeviceRegistrationService> linkedOn(
        {bool revoke = kRevokeAtCloudSwitchOff,
        Duration timeout = kCloudOffRevokeTimeout}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service(revoke: revoke, timeout: timeout);
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      commits = 0;
      return s;
    }

    CaptureSyncService syncSvc(
            CaptureDeviceRegistrationService reg, List<String> authCalls) =>
        CaptureSyncService(
          settingsRepository: repo,
          transactionRepository: DriftTransactionRepository(db),
          dedupStore: DriftDedupStore(db),
          smartInboxRepository: DriftSmartInboxRepository(db),
          suspectedDuplicateRepository:
              DriftSuspectedDuplicateRepository(db),
          registrationService: reg,
          ownershipGuard: _Guard(),
          currentUserId: () => 'uid-a',
          client: backend,
          backendConfigured: true,
          loadInstallId: () async => 'install-id',
          authorizeUpload: (id) async {
            authCalls.add(id);
            return const CaptureUploadAuthorization(
                CaptureUploadDecision.allowed,
                ownerUid: 'uid-a',
                allowAi: true);
          },
        );

    const pending = SharedCapturedMessage(
        id: 'p1',
        text: 'x',
        source: CapturedMessageSource.iosShare,
        status: 'pendingSend');

    /// Every egress path the app has, run once; callers assert [calls].
    Future<void> everyPath(CaptureDeviceRegistrationService s,
        List<String> authCalls) async {
      final sync = syncSvc(s, authCalls);
      await s.syncBackendState();
      await s.syncNativeState();
      await s.retry();
      await s.linkToCurrentUser();
      await s.isLinkedForCloud();
      await s.syncApnsToken(
          const ApnsTokenInfo(token: 'tok', environment: 'sandbox'));
      await service().syncBackendState(); // the other (startup) instance
      await sync.sync();
      await sync.retryPendingSend(pending);
    }

    test('POINT 1: during a hanging revoke every other egress path is silent '
        'and native is already restrictive; OFF commits after it settles',
        () async {
      final s = await linkedOn();
      final gate = Completer<void>();
      consent.onSet = () => gate.future;
      final authCalls = <String>[];
      final nativeStart = nativeConfigs.length;

      final done = s.disableCloud(commitLocalOff: commit);
      await _waitFor(() => calls.contains('set'));
      expect(calls, ['set'], reason: 'the revoke is in flight');
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue,
          reason: 'OFF is committed only after the revoke settles');
      // Native: restricted BEFORE the revoke left, mirror restrictive.
      expect(nativeConfigs.skip(nativeStart), [false]);
      expect(mirrors.last.cloud, isFalse);
      expect(mirrors.last.ai, isFalse);
      final nativeBefore = nativeConfigs.length;
      final mirrorsBefore = mirrors.length;

      await everyPath(s, authCalls);

      expect(calls, ['set'], reason: 'zero new requests while frozen');
      expect(authCalls, isEmpty, reason: 'native authorize is never asked');
      expect(nativeConfigs.length, nativeBefore);
      expect(mirrors.length, mirrorsBefore, reason: 'no widening, no republish');
      expect(await s.isLinkedForCloud(), isFalse);
      final authority = ConsentAuthority(repo.getSettings);
      for (final c in EgressClass.values) {
        expect(await authority.allows(c),
            c == EgressClass.catalog || c == EgressClass.auth,
            reason: '$c');
      }
      expect(commits, 0);

      gate.complete();
      await done;
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(consent.sets.single.cloud, isFalse);
      expect(consent.sets.single.ai, isFalse);
      expect(consent.sets.single.version,
          (await repo.getSettings()).consentVersion,
          reason: 'the revoke carries the next consent version');
    });

    test('POINT 1: a link that was already in flight cannot widen the mirror '
        'after the freeze', () async {
      await save(cloud: ConsentState.accepted);
      final linkGate = Completer<void>();
      consent.onLink = () => linkGate.future;
      final s = service();
      final link = s.linkToCurrentUser();
      await _waitFor(() => calls.contains('link'));
      // Hold the transition open (the local commit hangs) while the link ends.
      final commitGate = Completer<void>();
      final disable = s.disableCloud(commitLocalOff: () async {
        await commitGate.future;
        await commit();
      });
      await pump();
      linkGate.complete();
      await link;
      commitGate.complete();
      await disable;
      expect(published, isEmpty, reason: 'a frozen publish is refused');
      expect(mirrors.every((m) => !m.cloud), isTrue);
    });

    test('POINT 2: concurrent double toggle, repeated sync, relaunch: one '
        'revoke', () async {
      final s = await linkedOn();
      final other = service();
      final a = s.disableCloud(commitLocalOff: commit);
      final b = s.disableCloud(commitLocalOff: commit);
      final c = other.disableCloud(commitLocalOff: commit);
      await Future.wait([a, b, c]);
      expect(calls, ['set']);
      expect(commits, 1, reason: 'one transition, one commit');

      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await service().syncBackendState(); // relaunch
      await service().resolvePendingDisable();
      expect(calls, ['set']);

      // A later, separate toggle of an already-OFF state sends nothing either.
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, ['set']);
    });

    for (final failure in <String, Object>{
      'exception': const CaptureBackendException('offline'),
      '401': const CaptureBackendException('set_consent_failed_401'),
    }.entries) {
      test('POINT 3: a revoke failing with ${failure.key} still commits '
          'OFF and never throws', () async {
        final s = await linkedOn();
        consent.setError = failure.value;
        await s.disableCloud(commitLocalOff: commit);
        expect(commits, 1);
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(calls, ['set'], reason: 'no 401 recovery, no link, no register');
      });
    }

    test('POINT 3: a timed-out revoke still commits OFF', () async {
      final s = await linkedOn(timeout: const Duration(milliseconds: 50));
      consent.onSet = () => Completer<void>().future; // never answers
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, ['set']);
    });

    test('POINT 3: a native-restriction failure does not block OFF either',
        () async {
      final s = await linkedOn();
      nativeConfigError = StateError('native down');
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
    });

    test('POINT 4: after a failure nothing ever retries the revoke', () async {
      final s = await linkedOn();
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commit);
      consent.setError = null;
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState(); // sync / resume
      }
      await s.unlinkCurrentDevice();
      await s.linkToCurrentUser();
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      await relaunched.syncBackendState();
      await Future<void>.delayed(const Duration(milliseconds: 200)); // timers
      expect(calls, ['set'], reason: 'one attempt, success or not');
    });

    test('POINT 4: the durable (uid, version) marker blocks a second send',
        () async {
      final s = await linkedOn();
      final version = (await repo.getSettings()).consentVersion + 1;
      await const FlutterSecureStorage()
          .write(key: 'qirsh_capture_revoke_marker', value: 'uid-a|$version');
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('POINT 5: once OFF is committed the spy sees zero egress until an '
        'explicit enable', () async {
      final s = await linkedOn();
      await s.disableCloud(commitLocalOff: commit);
      calls.clear();
      apnsLoads = 0;
      final nativeAfterOff = nativeConfigs.length;
      final authCalls = <String>[];

      await everyPath(s, authCalls); // sync, resume, capture, replay
      // sign-out, sign-in of another user, relaunch
      await s.unlinkCurrentDevice();
      session = null;
      await s.syncBackendState();
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      await s.linkToCurrentUser();
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      await relaunched.syncBackendState();
      await relaunched.linkToCurrentUser();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(calls, isEmpty);
      expect(authCalls, isEmpty);
      expect(apnsLoads, 0);
      expect(nativeConfigs.skip(nativeAfterOff).every((c) => !c), isTrue);
      expect(await s.isLinkedForCloud(), isFalse);

      // Explicit enable: egress resumes (link) only now.
      session = (uid: 'uid-a', jwt: 'jwt-a');
      replicaOwner = 'uid-a';
      await save(cloud: ConsentState.accepted);
      await relaunched.syncBackendState();
      expect(calls, contains('link'));
    });

    test('a crash with disable_pending: relaunch commits OFF, sends no revoke, '
        'clears the marker', () async {
      await linkedOn(); // ON, acked; then the process "dies" mid-transition
      const storage = FlutterSecureStorage();
      await storage.write(
          key: 'qirsh.capture_disable_pending.v1', value: 'uid-a');

      final relaunched = service();
      await relaunched.resolvePendingDisable();

      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
      expect(await storage.read(key: 'qirsh.capture_disable_pending.v1'),
          isNull);
      expect(await storage.read(key: 'qirsh_capture_consent_ack'), isNull);
      expect(await relaunched.isLinkedForCloud(), isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      await relaunched.syncBackendState();
      await relaunched.syncBackendState();
      expect(calls, isEmpty, reason: 'never retried');
    });

    test('a crash marker is completed by the first sync as well, before any '
        'egress', () async {
      await linkedOn();
      await const FlutterSecureStorage()
          .write(key: 'qirsh.capture_disable_pending.v1', value: 'uid-a');
      await service().syncBackendState();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
    });

    test('a marker left by ANOTHER replica owner is not applied here', () async {
      await linkedOn();
      const storage = FlutterSecureStorage();
      await storage.write(
          key: 'qirsh.capture_disable_pending.v1', value: 'uid-other');
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
      expect(await storage.read(key: 'qirsh.capture_disable_pending.v1'),
          'uid-other');
    });

    test('kRevokeAtCloudSwitchOff = false: freeze + commit, zero requests',
        () async {
      final s = await linkedOn(revoke: false);
      final done = s.disableCloud(commitLocalOff: commit);
      await done;
      expect(calls, isEmpty);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(nativeConfigs.last, isFalse);
      expect(mirrors.last.cloud, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
    });

    test('the OFF branch of syncBackendState never sends a revoke, even right '
        'after the save', () async {
      final s = await linkedOn();
      await save(cloud: ConsentState.declined); // a bare save, no transition
      await s.syncBackendState();
      await s.syncBackendState();
      expect(calls, isEmpty);
    });

    test('no revoke without a Cloud-ON ack for this uid; OFF still commits',
        () async {
      await save(cloud: ConsentState.accepted);
      consent.linkError = const CaptureBackendException('offline');
      final s = service();
      await s.syncBackendState();
      calls.clear();
      commits = 0;
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('sign-out while ON still unlinks once; the ack is cleared first',
        () async {
      final s = await linkedOn();
      await s.unlinkCurrentDevice();
      expect(calls, ['unlinkDevice']);
      calls.clear();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test('ON->ON changes (AI only) are not a transition; OFF->ON is not',
        () async {
      final s = service();
      final base = await repo.getSettings();
      final on = base.copyWith(
          cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted);
      final aiOff = on.copyWith(aiConsentState: ConsentState.declined);
      final off = on.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState: ConsentState.declined);
      expect(s.isDisablingCloud(on, aiOff), isFalse);
      expect(s.isDisablingCloud(off, on), isFalse);
      expect(s.isDisablingCloud(on, off), isTrue);
    });

    test('the revoke is one named constant, bounded by a short timeout', () {
      expect(kRevokeAtCloudSwitchOff, isTrue);
      expect(kCloudOffRevokeTimeout, lessThanOrEqualTo(const Duration(seconds: 5)));
    });
  });

  group('E1 Android: the same transition, no platform carve-out', () {
    CaptureDeviceRegistrationService android({
      bool revoke = kRevokeAtCloudSwitchOff,
      Duration timeout = kCloudOffRevokeTimeout,
    }) =>
        CaptureDeviceRegistrationService(
          revokeAtSwitchOff: revoke,
          revokeTimeout: timeout,
          settingsRepository: repo,
          client: backend,
          consentClient: consent,
          storage: const FlutterSecureStorage(),
          isIos: () => false,
          isAndroid: () => true,
          isBackendConfigured: () => true,
          loadInstallId: () async => 'install-id',
          readSession: () => session,
          readReplicaOwnerUid: () async => replicaOwner,
        );

    var commits = 0;
    Future<void> commit() async {
      commits++;
      await save(cloud: ConsentState.declined, ai: ConsentState.declined);
    }

    Future<CaptureDeviceRegistrationService> androidOn(
        {bool revoke = kRevokeAtCloudSwitchOff,
        Duration timeout = kCloudOffRevokeTimeout}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = android(revoke: revoke, timeout: timeout);
      await s.syncBackendState();
      expect(calls, ['registerDevice', 'setDeviceConsent']);
      calls.clear();
      commits = 0;
      return s;
    }

    test('OFF: zero calls across startup, resume, retry and sign-out',
        () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = android();
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await s.retry();
      await s.unlinkCurrentDevice(); // iOS-only link; nothing on Android
      expect(calls, isEmpty);
    });

    test('OFF with no secret: no registerDevice either', () async {
      await android().syncBackendState();
      expect(calls, isEmpty);
    });

    test('POINTS 1+2: freeze during a hanging revoke, exactly one revoke, '
        'then OFF and silence (also after relaunch)', () async {
      final s = await androidOn();
      final gate = Completer<void>();
      backend.onSetDevice = () => gate.future;

      final done = s.disableCloud(commitLocalOff: commit);
      await _waitFor(() => calls.contains('setDeviceConsent'));
      expect(calls, ['setDeviceConsent']);
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await android().syncBackendState();
      expect(calls, ['setDeviceConsent'], reason: 'frozen: nothing else');
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);

      gate.complete();
      await done;
      expect(commits, 1);
      expect(backend.deviceConsents.last, (cloud: false, ai: false));
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);

      await s.syncBackendState();
      await android().syncBackendState(); // relaunch
      expect(calls, ['setDeviceConsent'], reason: 'POINT 5: silence');
    });

    test('POINTS 3+4: a failing or timed-out revoke still commits OFF and is '
        'never retried', () async {
      final s = await androidOn(timeout: const Duration(milliseconds: 50));
      backend.onSetDevice = () => Completer<void>().future;
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      backend.onSetDevice = null;
      await s.syncBackendState();
      await android().syncBackendState();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, ['setDeviceConsent']);
    });

    test('a relaunch before the toggle still sends the one revoke (ON is '
        'proven by the stored secret, not by in-memory state)', () async {
      await androidOn();
      final relaunched = android();
      await relaunched.disableCloud(commitLocalOff: commit);
      expect(calls, ['setDeviceConsent']);
      expect(commits, 1);
    });

    test('POINT 5 / no secret: nothing to revoke, OFF still commits',
        () async {
      commits = 0;
      await save(cloud: ConsentState.accepted);
      await android().disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('revoke seam false: freeze and commit with zero requests', () async {
      final s = await androidOn(revoke: false);
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('a crash with disable_pending commits OFF on relaunch, no revoke',
        () async {
      await androidOn();
      await const FlutterSecureStorage()
          .write(key: 'qirsh.capture_disable_pending.v1', value: 'uid-a');
      await android().syncBackendState();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect((await repo.getSettings()).aiConsentGranted, isFalse);
      expect(calls, isEmpty);
    });

    test('an AI-only OFF on Android is a transition; ON->ON is not', () async {
      final s = android();
      final base = await repo.getSettings();
      final both = base.copyWith(
          cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted);
      expect(
          s.isDisablingCloud(
              both, both.copyWith(aiConsentState: ConsentState.declined)),
          isFalse);
      expect(
          s.isDisablingCloud(
              both.copyWith(cloudConsentState: ConsentState.declined),
              both.copyWith(
                  cloudConsentState: ConsentState.declined,
                  aiConsentState: ConsentState.declined)),
          isTrue);
    });
  });

  group('E1 fail-closed: the local OFF write fails', () {
    const markerKey = 'qirsh.capture_disable_pending.v1';
    var failCommit = true;
    Future<void> commit() async {
      if (failCommit) throw StateError('local OFF write failed');
      await save(cloud: ConsentState.declined);
    }

    Future<CaptureDeviceRegistrationService> linkedOn(
        {FlutterSecureStorage? storage}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service(storage: storage);
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      failCommit = true;
      return s;
    }

    File markerFile() => File('${markerDir.path}/capture_disable_pending.v1');

    test('freeze stays, Cloud is NOT restored, both markers persist, and '
        'nothing more is sent', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      expect(consent.sets, hasLength(1), reason: 'the one revoke, nothing more');
      calls.clear();
      expect(ConsentAuthority.egressFrozen, isTrue);
      // The DB write failed, so the stored value is still ON; nothing reverts
      // it to "allowed" and no egress follows.
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
      expect(await const FlutterSecureStorage().read(key: markerKey), 'uid-a');
      expect(markerFile().readAsStringSync(), 'uid-a');
      for (final reg in [s, service()]) {
        await reg.syncBackendState();
        expect(await reg.isLinkedForCloud(), isFalse);
      }
      for (final c in EgressClass.values) {
        if (c == EgressClass.catalog || c == EgressClass.auth) continue;
        expect(
            ConsentAuthority.decide(c, await repo.getSettings()), isFalse,
            reason: '$c must stay denied while frozen');
      }
      expect(calls, isEmpty);
    });

    test('next launch completes OFF from the marker, sends no revoke, and '
        'clears both markers', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(await const FlutterSecureStorage().read(key: markerKey), isNull);
      expect(markerFile().existsSync(), isFalse);
      await relaunched.syncBackendState();
      expect(calls, isEmpty, reason: 'no revoke, no egress after OFF');
    });

    test('Keychain marker write fails too: the file marker still lets the next '
        'launch complete OFF', () async {
      final flaky = _FlakyStorage()..failMarkerWrite = true;
      final s = await linkedOn(storage: flaky);
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      expect(await const FlutterSecureStorage().read(key: markerKey), isNull);
      expect(markerFile().readAsStringSync(), 'uid-a');
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
    });

    test('a relaunch whose OFF write fails again stays frozen with zero '
        'egress', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      final failingRepo = _FailingSaveRepo(db);
      final relaunched = CaptureDeviceRegistrationService(
        settingsRepository: failingRepo,
        client: backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        markerDirectory: () async => markerDir,
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
        }) async {},
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
      );
      await relaunched.resolvePendingDisable();
      expect(ConsentAuthority.egressFrozen, isTrue);
      await relaunched.syncBackendState();
      expect(await relaunched.isLinkedForCloud(), isFalse);
      expect(calls, isEmpty);
      expect(markerFile().existsSync(), isTrue, reason: 'kept for the next try');
    });

    test('marker state unreadable in BOTH stores: fail closed, no egress',
        () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final flaky = _FlakyStorage()..failMarkerRead = true;
      final s = service(
          storage: flaky,
          markerDirectory: () async => throw const FileSystemException('fs'));
      await s.syncBackendState();
      expect(calls, isEmpty);
      expect(await s.isLinkedForCloud(), isFalse);
    });

    test('UI: a failed local OFF write is swallowed by the privacy screen path '
        '(fail closed, no crash)', () async {
      // Source pin: privacy_screen catches the disableCloud failure and returns
      // without any further sync.
      final src =
          File('lib/features/settings/privacy_screen.dart').readAsStringSync();
      final i = src.indexOf('await registration.disableCloud(');
      expect(i, greaterThan(0));
      final tail = src.substring(i, i + 400);
      expect(tail, contains('} catch (_) {'));
      expect(tail, contains('return;'));
    });
  });

  group('R5: the legacy device-credential calls need a uid-bound ack', () {
    test('B\'s failed link never falls through to the legacy contract',
        () async {
      // A is linked (ack A, Cloud ON); the projection still belongs to A.
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.syncBackendState();
      expect(await s.isLinkedForCloud(), isTrue);

      // A -> B: B's link fails.
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      consent.linkError = const CaptureBackendException('offline');
      calls.clear();
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: s,
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );

      expect(await s.isLinkedForCloud(), isFalse);
      expect((await port.fetchResults()).status,
          CaptureFetchStatus.notConfigured);
      await port.acknowledge(const ['x']);
      expect(calls.where((c) => c == 'syncCaptures'), isEmpty,
          reason: 'no legacy sync-captures while the projection is still A\'s');
    });

    test('A -> B -> A: nothing legacy before A re-links', () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.syncBackendState(); // A linked
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      await s.syncBackendState(); // B links: the single ack slot is now B's
      session = (uid: 'uid-a', jwt: 'jwt-a');
      replicaOwner = 'uid-a';
      calls.clear();

      expect(await s.isLinkedForCloud(), isFalse,
          reason: 'the projection is B\'s; A has no ack until it re-links');
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: _NoRelink(s),
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );
      await port.fetchResults();
      expect(calls.where((c) => c == 'syncCaptures'), isEmpty);

      await s.linkToCurrentUser(); // A re-links
      expect(await s.isLinkedForCloud(), isTrue);
    });
  });
}

/// The server port only touches its sync service on a replay; these tests never
/// reach it.
CaptureSyncService _unusedSync() => _Unused();


/// Fails only the `disable_pending` marker reads/writes; everything else uses
/// the mock store.
class _FlakyStorage extends FlutterSecureStorage {
  _FlakyStorage();
  bool failMarkerWrite = false;
  bool failMarkerRead = false;
  static const _marker = 'qirsh.capture_disable_pending.v1';

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failMarkerWrite && key == _marker) throw StateError('keychain');
    return super.write(key: key, value: value);
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failMarkerRead && key == _marker) throw StateError('keychain');
    return super.read(key: key);
  }
}

/// A settings repository whose save always fails (the local OFF write).
class _FailingSaveRepo extends DriftUserSettingsRepository {
  _FailingSaveRepo(super.db);
  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async =>
      throw StateError('local OFF write failed');
}

/// Waits (wall clock, bounded) until [cond] holds. Real file I/O now precedes
/// the revoke (the second disable_pending store), so counting microtask turns
/// is not a valid wait under parallel load.
Future<void> _waitFor(bool Function() cond,
    {Duration limit = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _Unused implements CaptureSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

/// The server port normally re-runs `syncBackendState` (which would re-link A
/// at once); this view lets the test observe the state BEFORE the re-link.
class _NoRelink implements CaptureDeviceRegistrationService {
  _NoRelink(this._inner);
  final CaptureDeviceRegistrationService _inner;
  @override
  Future<void> syncBackendState() async {}
  @override
  Future<bool> isLinkedForCloud() => _inner.isLinkedForCloud();
  @override
  Future<String?> readDeviceSecret() => _inner.readDeviceSecret();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

class _Guard extends OwnershipGuard {
  final AdmissionToken current =
      const AdmissionToken(ownerUid: 'uid-a', generation: 'gen-a');

  @override
  Future<AdmissionToken> capture() async => current;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == current;
}
