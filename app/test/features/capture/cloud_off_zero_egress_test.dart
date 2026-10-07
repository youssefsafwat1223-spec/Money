import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
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
// 401 and Remove data. The only exception is the single, one-shot revoke at the
// user's own ON->OFF toggle (kRevokeAtCloudSwitchOff), proven to be sent exactly
// once and never again, including after a simulated kill and relaunch.

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
  CaptureSession? session;
  String? replicaOwner;

  CaptureDeviceRegistrationService service({bool backendConfigured = true}) =>
      CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
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
        }) async {},
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
        }) async {},
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
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
  });
  tearDown(() async => db.close());

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

  group('the one-shot revoke at the user\'s own ON->OFF toggle', () {
    Future<CaptureDeviceRegistrationService> linkedOn() async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      return s;
    }

    test('switching OFF restricts the mirror FIRST, then sends exactly one '
        'revoke, and never again', () async {
      final s = await linkedOn();
      await save(cloud: ConsentState.declined);

      await s.syncBackendState();

      expect(published.last.cloud, isFalse, reason: 'mirror restricted');
      expect(calls, ['set']);
      expect(consent.sets.single.cloud, isFalse);
      expect(consent.sets.single.ai, isFalse);

      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await s.unlinkCurrentDevice();
      expect(calls, ['set'], reason: 'never retried, never unlinked while OFF');
    });

    test('zero revokes after a simulated kill and relaunch', () async {
      final s = await linkedOn();
      await save(cloud: ConsentState.declined);
      await s.syncBackendState();
      calls.clear();

      final relaunched = service(); // new process: no in-memory state
      await relaunched.syncBackendState();
      await relaunched.linkToCurrentUser();
      await relaunched.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test('a kill BEFORE the toggle was observed never sends it later',
        () async {
      await linkedOn();
      await save(cloud: ConsentState.declined);
      final relaunched = service();
      await relaunched.syncBackendState();
      expect(calls, isEmpty, reason: 'startup/resume is not the user toggle');
    });

    test('a failed revoke is not retried', () async {
      final s = await linkedOn();
      consent.setError = const CaptureBackendException('offline');
      await save(cloud: ConsentState.declined);
      await s.syncBackendState();
      consent.setError = null;
      await s.syncBackendState();
      await s.syncBackendState();
      expect(calls, ['set'], reason: 'one attempt, success or not');
    });

    test('a 401 on the revoke never re-registers the device', () async {
      final s = await linkedOn();
      consent.setError = const CaptureBackendException('set_consent_failed_401');
      await save(cloud: ConsentState.declined);
      await s.syncBackendState();
      expect(calls, ['set']);
    });

    test('the durable (uid, version) marker blocks a second send', () async {
      final s = await linkedOn();
      await save(cloud: ConsentState.declined);
      final version = (await repo.getSettings()).consentVersion;
      const storage = FlutterSecureStorage();
      await storage.write(
          key: 'qirsh_capture_revoke_marker', value: 'uid-a|$version');
      await s.syncBackendState();
      expect(calls, isEmpty);
    });

    test('no revoke without a Cloud-ON ack for this uid', () async {
      // Cloud was ON in this process but the link never succeeded.
      await save(cloud: ConsentState.accepted);
      consent.linkError = const CaptureBackendException('offline');
      final s = service();
      await s.syncBackendState();
      calls.clear();
      await save(cloud: ConsentState.declined);
      await s.syncBackendState();
      expect(calls, isEmpty);
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

    test('the revoke is one named constant', () {
      expect(kRevokeAtCloudSwitchOff, isTrue);
    });
  });

  group('Android: no platform carve-out', () {
    CaptureDeviceRegistrationService android() =>
        CaptureDeviceRegistrationService(
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

    test('the user\'s own ON->OFF toggle: one revoke, then silence; none '
        'after a relaunch', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = android();
      await s.syncBackendState();
      expect(calls, ['registerDevice', 'setDeviceConsent']);
      calls.clear();

      await save(cloud: ConsentState.declined, ai: ConsentState.declined);
      await s.syncBackendState();
      expect(calls, ['setDeviceConsent']);
      await s.syncBackendState();
      await android().syncBackendState(); // relaunch
      expect(calls, ['setDeviceConsent']);
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
