import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import 'capture_backend_client.dart';
import 'native_capture_bridge.dart';

typedef NativeBackendConfigWriter = Future<void> Function({
  required bool cloudProcessingEnabled,
  required String installId,
  String? deviceSecret,
  required String backendUrl,
  required String anonKey,
  required bool aiConsentGranted,
});

typedef ApnsTokenLoader = Future<ApnsTokenInfo?> Function();

class CaptureDeviceRegistrationService {
  CaptureDeviceRegistrationService({
    required DriftUserSettingsRepository settingsRepository,
    CaptureBackendClient? client,
    FlutterSecureStorage? storage,
    bool Function()? isIos,
    bool Function()? isBackendConfigured,
    Future<String> Function()? loadInstallId,
    NativeBackendConfigWriter? writeNativeBackendConfig,
    ApnsTokenLoader? loadApnsToken,
  })  : _settingsRepository = settingsRepository,
        _client = client,
        _storage = storage ?? const FlutterSecureStorage(),
        _isIos = isIos ?? (() => Platform.isIOS),
        _isBackendConfigured =
            isBackendConfigured ?? (() => SupabaseConfig.isConfigured),
        _loadInstallId = loadInstallId ?? InstallId.get,
        _writeNativeBackendConfig =
            writeNativeBackendConfig ?? NativeCaptureBridge.setBackendConfig,
        _loadApnsToken = loadApnsToken ?? _defaultLoadApnsToken;

  static const _secretKey = 'qirsh_capture_device_secret';

  final DriftUserSettingsRepository _settingsRepository;
  final CaptureBackendClient? _client;
  final FlutterSecureStorage _storage;
  final bool Function() _isIos;
  final bool Function() _isBackendConfigured;
  final Future<String> Function() _loadInstallId;
  final NativeBackendConfigWriter _writeNativeBackendConfig;
  final ApnsTokenLoader _loadApnsToken;
  Future<String>? _credentialRecovery;
  Future<void>? _apnsSyncInFlight;
  String? _lastSyncedApnsTokenKey;
  DateTime? _apnsRetryBlockedUntil;

  static Future<ApnsTokenInfo?> _defaultLoadApnsToken() async {
    return await NativeCaptureBridge.registerForRemoteNotifications() ??
        await NativeCaptureBridge.getApnsToken();
  }

  CaptureBackendClient get _backendClient =>
      _client ??
      CaptureBackendClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  Future<void> syncNativeState() async {
    if (!_isIos()) return;
    final settings = await _settingsRepository.getSettings();
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);

    if (!settings.cloudProcessingEnabled || !_isBackendConfigured()) {
      await _writeNativeBackendConfig(
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
      await _writeNativeBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
      );
    }

    if (secret == null || secret.isEmpty) {
      secret = await _backendClient.registerDevice(installId: installId);
      await _storage.write(key: _secretKey, value: secret);
    }

    await _writeNativeBackendConfig(
      cloudProcessingEnabled: _isBackendConfigured(),
      installId: installId,
      deviceSecret: secret,
      backendUrl: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      aiConsentGranted: settings.aiConsentGranted,
    );
    // MALI-060n — mirror consent onto the verified server device row so the
    // AI/paid endpoints enforce it authoritatively (revocation propagates the
    // moment the user toggles it, since syncNativeState re-runs). Best-effort:
    // a failure here must never block native config or local capture.
    try {
      await _backendClient.setDeviceConsent(
        installId: installId,
        deviceSecret: secret,
        aiConsentGranted: settings.aiConsentGranted,
        cloudProcessingEnabled: settings.cloudProcessingEnabled,
      );
    } catch (_) {
      // Consent push is retried on the next sync; a stale server row still fails
      // closed (defaults FALSE), never open.
    }
    try {
      final token = await _loadApnsToken();
      if (token != null) {
        await syncApnsToken(token);
      }
    } catch (error) {
      // Push delivery is optional. A throttled/unavailable APNs registration
      // must never prevent relay sync or local capture processing.
      if (kDebugMode) {
        debugPrint('[Capture] APNs registration deferred: $error');
      }
    }
  }

  // Links this device's capture_devices row to the authenticated Supabase user.
  // Best-effort — safe to call even when offline or before device registration.
  // Guests (no currentUser) are silently skipped so they always stay relay-only.
  Future<void> linkToCurrentUser() async {
    if (!_isIos() || !_isBackendConfigured()) return;
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    final session = client.auth.currentSession;
    if (user == null || session == null) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    try {
      await _backendClient.linkDevice(
        installId: installId,
        deviceSecret: secret,
        jwt: session.accessToken,
      );
    } on CaptureBackendException catch (error) {
      if (!_isUnauthorized(error)) rethrow;
      final freshSecret = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
      );
      await _backendClient.linkDevice(
        installId: installId,
        deviceSecret: freshSecret,
        jwt: session.accessToken,
      );
    }
  }

  Future<String?> readDeviceSecret() => _storage.read(key: _secretKey);

  /// Revokes the mutable user/APNs association without deleting the relay
  /// secret needed by the App Intent while the host app is signed out.
  Future<void> unlinkCurrentDevice() async {
    if (!_isIos() || !_isBackendConfigured()) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    try {
      await _backendClient.unlinkDevice(
        installId: installId,
        deviceSecret: secret,
      );
    } on CaptureBackendException catch (error) {
      if (!_isUnauthorized(error)) rethrow;
      final freshSecret = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
      );
      await _backendClient.unlinkDevice(
        installId: installId,
        deviceSecret: freshSecret,
      );
    }
  }

  Future<void> syncApnsToken(ApnsTokenInfo token) {
    final tokenKey = '${token.environment}:${token.token}';
    if (_lastSyncedApnsTokenKey == tokenKey) return Future.value();
    final blockedUntil = _apnsRetryBlockedUntil;
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) {
      return Future.value();
    }
    final pending = _apnsSyncInFlight;
    if (pending != null) {
      return pending.then((_) => syncApnsToken(token));
    }
    final run = _syncApnsTokenOnce(token, tokenKey);
    _apnsSyncInFlight = run;
    return run.whenComplete(() {
      if (identical(_apnsSyncInFlight, run)) _apnsSyncInFlight = null;
    });
  }

  Future<void> _syncApnsTokenOnce(
    ApnsTokenInfo token,
    String tokenKey,
  ) async {
    if (!_isIos() || !_isBackendConfigured()) return;
    final settings = await _settingsRepository.getSettings();
    if (!settings.cloudProcessingEnabled) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    try {
      await _backendClient.registerPushToken(
        installId: installId,
        deviceSecret: secret,
        apnsToken: token.token,
        apnsEnvironment: token.environment,
      );
    } on CaptureBackendException catch (error) {
      if (_isRateLimited(error)) {
        _apnsRetryBlockedUntil = DateTime.now().add(const Duration(hours: 1));
        rethrow;
      }
      if (!_isUnauthorized(error)) rethrow;
      final freshSecret = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
      );
      await _backendClient.registerPushToken(
        installId: installId,
        deviceSecret: freshSecret,
        apnsToken: token.token,
        apnsEnvironment: token.environment,
      );
    }
    _lastSyncedApnsTokenKey = tokenKey;
    _apnsRetryBlockedUntil = null;
  }

  bool _isUnauthorized(CaptureBackendException error) =>
      error.reason.endsWith('_401');

  bool _isRateLimited(CaptureBackendException error) =>
      error.reason.endsWith('_429');

  /// Reissues a stale relay credential exactly once across concurrent APNs,
  /// link and startup callbacks. If another callback already replaced the
  /// rejected secret, reuse that replacement instead of rotating again.
  Future<String> _recoverRejectedSecret({
    required String rejectedSecret,
    required String installId,
  }) async {
    final stored = await _storage.read(key: _secretKey);
    if (stored != null && stored.isNotEmpty && stored != rejectedSecret) {
      return stored;
    }
    final inFlight = _credentialRecovery;
    if (inFlight != null) return inFlight;

    final recovery = () async {
      final fresh = await _backendClient.registerDevice(installId: installId);
      await _storage.write(key: _secretKey, value: fresh);
      final settings = await _settingsRepository.getSettings();
      await _writeNativeBackendConfig(
        cloudProcessingEnabled:
            settings.cloudProcessingEnabled && _isBackendConfigured(),
        installId: installId,
        deviceSecret: fresh,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted:
            settings.cloudProcessingEnabled && settings.aiConsentGranted,
      );
      return fresh;
    }();
    _credentialRecovery = recovery;
    try {
      return await recovery;
    } finally {
      if (identical(_credentialRecovery, recovery)) {
        _credentialRecovery = null;
      }
    }
  }
}
