import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
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
}
