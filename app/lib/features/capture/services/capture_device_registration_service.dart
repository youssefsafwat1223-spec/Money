import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import 'capture_backend_client.dart';
import 'native_capture_bridge.dart';

class CaptureDeviceRegistrationService {
  CaptureDeviceRegistrationService({
    required DriftUserSettingsRepository settingsRepository,
    CaptureBackendClient? client,
    FlutterSecureStorage? storage,
  })  : _settingsRepository = settingsRepository,
        _client = client,
        _storage = storage ?? const FlutterSecureStorage();

  static const _secretKey = 'qirsh_capture_device_secret';

  final DriftUserSettingsRepository _settingsRepository;
  final CaptureBackendClient? _client;
  final FlutterSecureStorage _storage;

  Future<void> syncNativeState() async {
    if (!Platform.isIOS) return;
    final settings = await _settingsRepository.getSettings();
    final installId = await InstallId.get();
    var secret = await _storage.read(key: _secretKey);

    if (!settings.cloudProcessingEnabled || !SupabaseConfig.isConfigured) {
      await NativeCaptureBridge.setBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
      );
      return;
    }

    if (!settings.aiConsentGranted || secret == null || secret.isEmpty) {
      // Clear stale native consent before any later step that can fail. If the
      // final write does not happen, the App Intent stays local/no-AI.
      await NativeCaptureBridge.setBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
      );
    }

    if (secret == null || secret.isEmpty) {
      final client = _client ??
          CaptureBackendClient(
            supabaseUrl: SupabaseConfig.url,
            anonKey: SupabaseConfig.anonKey,
          );
      secret = await client.registerDevice(installId: installId);
      await _storage.write(key: _secretKey, value: secret);
    }

    await NativeCaptureBridge.setBackendConfig(
      cloudProcessingEnabled: SupabaseConfig.isConfigured,
      installId: installId,
      deviceSecret: secret,
      backendUrl: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      aiConsentGranted: settings.aiConsentGranted,
    );
    final token = await NativeCaptureBridge.registerForRemoteNotifications() ??
        await NativeCaptureBridge.getApnsToken();
    if (token != null) {
      await syncApnsToken(token);
    }
  }

  // Links this device's capture_devices row to the authenticated Supabase user.
  // Best-effort — safe to call even when offline or before device registration.
  // Guests (no currentUser) are silently skipped so they always stay relay-only.
  Future<void> linkToCurrentUser() async {
    if (!Platform.isIOS || !SupabaseConfig.isConfigured) return;
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    final session = client.auth.currentSession;
    if (user == null || session == null) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await InstallId.get();
    final backendClient = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    await backendClient.linkDevice(
      installId: installId,
      deviceSecret: secret,
      jwt: session.accessToken,
    );
  }

  Future<String?> readDeviceSecret() => _storage.read(key: _secretKey);

  Future<void> syncApnsToken(ApnsTokenInfo token) async {
    if (!Platform.isIOS || !SupabaseConfig.isConfigured) return;
    final settings = await _settingsRepository.getSettings();
    if (!settings.cloudProcessingEnabled) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    await client.registerPushToken(
      installId: await InstallId.get(),
      deviceSecret: secret,
      apnsToken: token.token,
      apnsEnvironment: token.environment,
    );
  }
}
