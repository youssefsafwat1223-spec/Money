import 'dart:async';

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
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _RotatingCaptureClient implements CaptureBackendClient {
  int registerDeviceCalls = 0;
  final pushSecrets = <String>[];

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async {
    registerDeviceCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return 'fresh-device-secret';
  }

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    pushSecrets.add(deviceSecret);
    if (deviceSecret == 'stale-device-secret') {
      throw const CaptureBackendException('register_push_failed_401');
    }
  }

  @override
  Future<void> linkDevice({
    required String installId,
    required String deviceSecret,
    required String jwt,
  }) async {}

  @override
  Future<void> unlinkDevice({
    required String installId,
    required String deviceSecret,
  }) async {}

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {}

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
  }) async {}

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async =>
      const [];
}

class _RateLimitedCaptureClient extends _RotatingCaptureClient {
  int pushCalls = 0;

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    pushCalls++;
    throw const CaptureBackendException('register_push_failed_429');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository settingsRepository;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'stale-device-secret',
    });
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    settingsRepository = DriftUserSettingsRepository(db);
    final settings = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(
      settings.copyWith(cloudConsentState: ConsentState.accepted),
    );
  });

  tearDown(() async => db.close());

  test('401 rotates a stale device secret once across concurrent APNs syncs',
      () async {
    final client = _RotatingCaptureClient();
    var nativeConfigWrites = 0;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
      }) async {
        expect(cloudProcessingEnabled, isTrue);
        expect(deviceSecret, 'fresh-device-secret');
        nativeConfigWrites++;
      },
    );
    const token = ApnsTokenInfo(
      token: 'apns-token',
      environment: 'sandbox',
    );

    await Future.wait([
      service.syncApnsToken(token),
      service.syncApnsToken(token),
    ]);

    expect(client.registerDeviceCalls, 1);
    expect(nativeConfigWrites, 1);
    expect(
      client.pushSecrets.where((secret) => secret == 'fresh-device-secret'),
      hasLength(1),
    );
    expect(await service.readDeviceSecret(), 'fresh-device-secret');
  });

  test('APNs 429 never blocks native capture state and is backed off',
      () async {
    final client = _RateLimitedCaptureClient();
    var enabledNativeWrites = 0;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      loadApnsToken: () async => const ApnsTokenInfo(
        token: 'same-apns-token',
        environment: 'sandbox',
      ),
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
      }) async {
        if (cloudProcessingEnabled) enabledNativeWrites++;
      },
    );

    await service.syncNativeState();
    await service.syncNativeState();

    expect(enabledNativeWrites, 2);
    expect(client.pushCalls, 1);
    expect(await service.readDeviceSecret(), 'stale-device-secret');
  });

  // ── MALI-060n Android consent-propagation tail ────────────────────────────

  CaptureDeviceRegistrationService androidService(_ConsentRecordingClient c) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settingsRepository,
        client: c,
        storage: const FlutterSecureStorage(),
        isIos: () => false,
        isAndroid: () => true,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
      );

  Future<void> setConsent({required bool ai, required bool cloud}) async {
    final s = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(s.copyWith(
      aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
      cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
    ));
  }

  test('Android default OFF: no registration, no consent push', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    await androidService(client).syncBackendState();
    expect(client.registeredPlatforms, isEmpty);
    expect(client.consentCalls, isEmpty);
    expect(await androidService(client).readDeviceSecret(), isNull);
  });

  test('Android enable: registers android device and pushes consent true',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient();
    final service = androidService(client);
    await service.syncBackendState();
    expect(client.registeredPlatforms, ['android']);
    expect(client.consentCalls.last, (ai: true, cloud: true));
    expect(await service.readDeviceSecret(), 'android-secret');
  });

  // A-12-min R6 (updated truthfully): this test used to pin a consent push on
  // every OFF sync of a relaunched app. Cloud OFF = ZERO EGRESS on Android too:
  // an existing secret does not make an OFF sync talk to the server.
  test('Android OFF (relaunched): zero egress even with an existing secret',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
    });
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    await androidService(client).syncBackendState();
    expect(client.registeredPlatforms, isEmpty);
    expect(client.consentCalls, isEmpty);
  });

  test('Android: the user\'s own ON->OFF toggle sends ONE revoke, never again',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient();
    final service = androidService(client);
    await service.syncBackendState();
    expect(client.consentCalls.last, (ai: true, cloud: true));
    client.consentCalls.clear();

    await setConsent(ai: false, cloud: false);
    await service.syncBackendState();
    expect(client.consentCalls, [(ai: false, cloud: false)]);
    await service.syncBackendState();
    await service.syncBackendState();
    expect(client.consentCalls, hasLength(1), reason: 'never retried');

    // A relaunch (new instance, no in-memory ON proof) sends nothing.
    await androidService(client).syncBackendState();
    expect(client.consentCalls, hasLength(1));
    expect(client.registeredPlatforms, ['android'], reason: 'no re-register');
  });

  // A-12-min R6 (updated truthfully): this test used to pin a server revoke on a
  // RELAUNCHED app. The revoke is the one-shot closing act of the user's own
  // ON->OFF toggle in a running process (proven in cloud_off_zero_egress_test);
  // a relaunch with OFF settings and an old Cloud-ON ack sends nothing.
  test('iOS OFF after a relaunch: native config OFF, zero server calls',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
      // The server last acknowledged (cloud, ai) = (on, on) for this user.
      'qirsh_capture_consent_ack': 'uid-a|1|1|1',
    });
    // Cloud is the master gate. Keep the local AI preference accepted to prove
    // the iOS cloud-OFF branch does not preserve that stale grant server-side.
    await setConsent(ai: true, cloud: false);
    final client = _ConsentRecordingClient();
    final consent = _V2ConsentServer();
    final nativeWrites = <({bool ai, bool cloud})>[];
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      consentClient: consent,
      readSession: () => (uid: 'uid-a', jwt: 'jwt-a'),
      readReplicaOwnerUid: () async => 'uid-a',
      writeConsentMirror: ({
        required uid,
        required cloud,
        required ai,
        required version,
      }) async {},
      storage: const FlutterSecureStorage(),
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
      }) async {
        nativeWrites.add((
          ai: aiConsentGranted,
          cloud: cloudProcessingEnabled,
        ));
      },
    );

    await service.syncBackendState();

    expect(nativeWrites, [(ai: false, cloud: false)]);
    expect(client.registeredPlatforms, isEmpty);
    // WP-6: iOS no longer uses the build-50 device-secret consent call; the v2
    // (JWT, versioned) call carries the revocation, AI forced off by cloud.
    expect(client.consentCalls, isEmpty);
    expect(consent.sets, isEmpty, reason: 'no revoke at startup/resume');
    expect(consent.links, isEmpty);
  });

  test('Android offline registration fails closed without throwing', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..registerThrows = true;
    await androidService(client).syncBackendState(); // must not throw
    expect(client.consentCalls, isEmpty);
    expect(await androidService(client).readDeviceSecret(), isNull);
  });

  test('Android consent-push failure is swallowed (retried next sync)',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
    });
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..consentThrows = true;
    await androidService(client).syncBackendState(); // must not throw
  });

  // ── WP1 registration status ───────────────────────────────────────────────

  const sentinel = 'SENTINEL-secret-message-do-not-leak';

  CaptureDeviceRegistrationService iosService(
    _ConsentRecordingClient c, {
    ApnsTokenLoader? loadApnsToken,
  }) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settingsRepository,
        client: c,
        storage: const FlutterSecureStorage(),
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
        loadApnsToken: loadApnsToken ?? () async => null,
      );

  const connected =
      CaptureRegistrationStatus(CaptureRegistrationPhase.connected);
  CaptureRegistrationStatus failed(String code) =>
      CaptureRegistrationStatus(CaptureRegistrationPhase.failed, code);

  test('status starts notRequested', () {
    expect(iosService(_ConsentRecordingClient()).status.value.phase,
        CaptureRegistrationPhase.notRequested);
  });

  test('iOS registerDevice throw: failed(register_failed), still propagates; '
      'retry never throws and reaches connected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final client = _ConsentRecordingClient()..registerThrowsMessage = sentinel;
    final service = iosService(client);
    await expectLater(service.syncBackendState(), throwsA(anything));
    expect(service.status.value, failed('register_failed'));
    expect(service.status.value.failureCode, isNot(contains(sentinel)));

    await service.retry(); // still failing: must not throw
    expect(service.status.value, failed('register_failed'));

    client.registerThrowsMessage = null;
    await service.retry();
    expect(service.status.value, connected);
  });

  test('iOS consent off: notRequested and no registerDevice call', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    final service = iosService(client);
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
    expect(client.registeredPlatforms, isEmpty);
  });

  test('iOS consent link failure while granting: consent_sync_failed',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final consent = _V2ConsentServer()..linkThrows = true;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: _ConsentRecordingClient(),
      consentClient: consent,
      readSession: () => (uid: 'uid-a', jwt: 'jwt-a'),
      readReplicaOwnerUid: () async => 'uid-a',
      writeConsentMirror: ({
        required uid,
        required cloud,
        required ai,
        required version,
      }) async {},
      readOwnerEpoch: () async => 0,
      publishOwner: ({
        required uid,
        required cloud,
        required ai,
        required version,
        required expectedEpoch,
      }) async {},
      storage: const FlutterSecureStorage(),
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
      loadApnsToken: () async => null,
    );
    await service.syncBackendState(); // swallow behaviour unchanged
    expect(service.status.value, failed('consent_sync_failed'));
  });

  test('iOS failed consent push during revocation stays notRequested',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        {'qirsh_capture_device_secret': 'existing'});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient()..consentThrows = true;
    final service = iosService(client);
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
  });

  test('iOS APNs failure is best-effort: still connected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = iosService(
      _ConsentRecordingClient(),
      loadApnsToken: () async => throw StateError(sentinel),
    );
    await service.syncBackendState();
    expect(service.status.value, connected);
  });

  test('Android registerDevice throw: failed(register_failed), no throw',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..registerThrowsMessage = sentinel;
    final service = androidService(client);
    await service.syncBackendState();
    expect(service.status.value, failed('register_failed'));
    expect(service.status.value.failureCode, isNot(contains(sentinel)));

    client.registerThrowsMessage = null;
    await service.retry();
    expect(service.status.value, connected);
  });

  test('overlapping syncs: an older failing run cannot taint the newer run',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _GatedRegisterClient();
    final service = androidService(client);
    final older = service.syncBackendState();
    await client.firstRegisterStarted.future;
    final newer = service.syncBackendState();
    await newer;
    expect(service.status.value, connected);
    client.firstRegister.completeError(const CaptureBackendException('x'));
    await older;
    expect(service.status.value, connected);
  });

  test('Android consent off: notRequested', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final service = androidService(_ConsentRecordingClient());
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
  });

  test('Android setDeviceConsent failure: consent_sync_failed', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final service =
        androidService(_ConsentRecordingClient()..consentThrows = true);
    await service.syncBackendState();
    expect(service.status.value, failed('consent_sync_failed'));
  });
}

class _ConsentRecordingClient extends _RotatingCaptureClient {
  final registeredPlatforms = <String>[];
  final consentCalls = <({bool ai, bool cloud})>[];
  bool registerThrows = false;
  String? registerThrowsMessage;
  bool consentThrows = false;

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async {
    if (registerThrows) throw const CaptureBackendException('offline');
    final message = registerThrowsMessage;
    if (message != null) throw CaptureBackendException(message);
    registeredPlatforms.add(platform);
    return 'android-secret';
  }

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    if (consentThrows) throw const CaptureBackendException('offline');
    consentCalls.add((ai: aiConsentGranted, cloud: cloudProcessingEnabled));
  }
}

class _V2ConsentServer extends CaptureConsentClient {
  _V2ConsentServer()
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final sets = <({bool cloud, bool ai, int version})>[];
  final links = <({bool cloud, bool ai, int version})>[];
  bool linkThrows = false;

  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    links.add((cloud: cloud, ai: ai, version: version));
    if (linkThrows) throw const CaptureBackendException('offline');
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
    sets.add((cloud: cloud, ai: ai, version: version));
  }
}

class _GatedRegisterClient extends _ConsentRecordingClient {
  final firstRegisterStarted = Completer<void>();
  final firstRegister = Completer<String>();
  var _calls = 0;

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) {
    if (_calls++ == 0) {
      firstRegisterStarted.complete();
      return firstRegister.future;
    }
    return super.registerDevice(installId: installId, platform: platform);
  }
}
