import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/supporting_entities.dart';
import '../../planning_sync/services/outbox_queue_factory.dart'
    show localDataOwnerUid;
import 'capture_backend_client.dart';
import 'capture_consent_client.dart';
import 'native_capture_bridge.dart';
import '../../../core/security/secure_storage_options.dart';

typedef NativeBackendConfigWriter = Future<void> Function({
  required bool cloudProcessingEnabled,
  required String installId,
  String? deviceSecret,
  required String backendUrl,
  required String anonKey,
  required bool aiConsentGranted,
});

typedef ApnsTokenLoader = Future<ApnsTokenInfo?> Function();

/// WP-6: the signed-in user as the capture backend sees it.
typedef CaptureSession = ({String uid, String jwt});

typedef ConsentMirrorWriter = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
});

/// WP-6: the consent the replica holds, as projected to the server and to the
/// native mirror. Derived ONLY from the replica's own explicit, versioned choice
/// (cloud is the master gate, so AI is on only when cloud is on); never from a
/// server value.
typedef _ConsentSnapshot = ({bool cloud, bool ai, int version});

/// Per-run outcome, so overlapping syncs can never pollute each other.
class _SyncOutcome {
  bool registerFailed = false;
  bool consentPushFailed = false;
}

enum CaptureRegistrationPhase { notRequested, connecting, connected, failed }

/// User-visible device-registration state. [failureCode] is a coarse code only
/// ('register_failed', 'consent_sync_failed', 'unknown') — never an exception
/// message, secret, install id or URL.
@immutable
class CaptureRegistrationStatus {
  const CaptureRegistrationStatus(this.phase, [this.failureCode]);

  final CaptureRegistrationPhase phase;
  final String? failureCode;

  @override
  bool operator ==(Object other) =>
      other is CaptureRegistrationStatus &&
      other.phase == phase &&
      other.failureCode == failureCode;

  @override
  int get hashCode => Object.hash(phase, failureCode);
}

class CaptureDeviceRegistrationService {
  CaptureDeviceRegistrationService({
    required DriftUserSettingsRepository settingsRepository,
    CaptureBackendClient? client,
    FlutterSecureStorage? storage,
    bool Function()? isIos,
    bool Function()? isAndroid,
    bool Function()? isBackendConfigured,
    Future<String> Function()? loadInstallId,
    NativeBackendConfigWriter? writeNativeBackendConfig,
    ApnsTokenLoader? loadApnsToken,
    CaptureConsentClient? consentClient,
    CaptureSession? Function()? readSession,
    Future<String?> Function()? readReplicaOwnerUid,
    ConsentMirrorWriter? writeConsentMirror,
    Future<void> Function(String uid)? publishOwner,
  })  : _settingsRepository = settingsRepository,
        _client = client,
        _storage = storage ?? SecureStorageOptions.storage,
        _isIos = isIos ?? (() => Platform.isIOS),
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _isBackendConfigured =
            isBackendConfigured ?? (() => SupabaseConfig.isConfigured),
        _loadInstallId = loadInstallId ?? InstallId.get,
        _writeNativeBackendConfig =
            writeNativeBackendConfig ?? NativeCaptureBridge.setBackendConfig,
        _loadApnsToken = loadApnsToken ?? _defaultLoadApnsToken,
        _consentClient = consentClient,
        _readSession = readSession ?? _defaultReadSession,
        _readReplicaOwnerUid = readReplicaOwnerUid ?? localDataOwnerUid,
        _writeConsentMirror =
            writeConsentMirror ?? NativeCaptureBridge.setCaptureConsentMirror,
        _publishOwner = publishOwner ?? NativeCaptureBridge.publishCaptureOwner;

  static const _secretKey = 'qirsh_capture_device_secret';

  /// WP-6: the last consent the server ACKNOWLEDGED for this install, as
  /// `uid|cloud|ai|version` (single slot). It proves the projection is linked to
  /// that uid at that version, which lets a repeat admission skip the network
  /// call, and it is the floor for a restrictive-first mirror write. Cleared on
  /// unlink and whenever the device credential is replaced.
  static const _ackKey = 'qirsh_capture_consent_ack';

  final DriftUserSettingsRepository _settingsRepository;
  final CaptureBackendClient? _client;
  final FlutterSecureStorage _storage;
  final bool Function() _isIos;
  final bool Function() _isAndroid;
  final bool Function() _isBackendConfigured;
  final Future<String> Function() _loadInstallId;
  final NativeBackendConfigWriter _writeNativeBackendConfig;
  final ApnsTokenLoader _loadApnsToken;
  final CaptureConsentClient? _consentClient;
  final CaptureSession? Function() _readSession;
  final Future<String?> Function() _readReplicaOwnerUid;
  final ConsentMirrorWriter _writeConsentMirror;
  final Future<void> Function(String uid) _publishOwner;
  Future<bool>? _linkInFlight;
  final Map<String, int> _mirrorVersions = {};
  Future<String>? _credentialRecovery;
  Future<void>? _apnsSyncInFlight;
  String? _lastSyncedApnsTokenKey;
  DateTime? _apnsRetryBlockedUntil;

  final ValueNotifier<CaptureRegistrationStatus> _status = ValueNotifier(
    const CaptureRegistrationStatus(CaptureRegistrationPhase.notRequested),
  );
  int _syncGeneration = 0;

  ValueListenable<CaptureRegistrationStatus> get status => _status;

  static Future<ApnsTokenInfo?> _defaultLoadApnsToken() async {
    return await NativeCaptureBridge.registerForRemoteNotifications() ??
        await NativeCaptureBridge.getApnsToken();
  }

  static CaptureSession? _defaultReadSession() {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final user = session?.user;
      if (session == null || user == null) return null;
      return (uid: user.id, jwt: session.accessToken);
    } catch (_) {
      return null;
    }
  }

  CaptureConsentClient get _consent =>
      _consentClient ??
      CaptureConsentClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  CaptureBackendClient get _backendClient =>
      _client ??
      CaptureBackendClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  /// Platform dispatcher for keeping the backend in sync (MALI-060n Android
  /// tail). iOS writes the native App-Intent config AND pushes consent; Android
  /// registers the device and pushes consent (no native App-Intent config).
  /// Both keep the verified server consent row current. Call this from every
  /// trigger point (registration, consent change, startup, resume) instead of
  /// [syncNativeState] directly.
  Future<void> syncBackendState() async {
    final ios = _isIos();
    if (!ios && !_isAndroid()) return;
    final generation = ++_syncGeneration;
    void record(CaptureRegistrationStatus next) {
      // A newer sync owns the status; never let a stale run overwrite it.
      if (generation == _syncGeneration) _status.value = next;
    }

    final outcome = _SyncOutcome();
    var tracked = false;
    try {
      final settings = await _settingsRepository.getSettings();
      final wantsCloud = ios
          ? settings.cloudProcessingEnabled
          : settings.cloudProcessingEnabled || settings.aiConsentGranted;
      tracked = _isBackendConfigured() && wantsCloud;
      record(CaptureRegistrationStatus(
        tracked
            ? CaptureRegistrationPhase.connecting
            : CaptureRegistrationPhase.notRequested,
      ));
      if (ios) {
        await _syncNativeState(outcome);
      } else {
        await _syncAndroidConsentState(outcome);
      }
      if (tracked) {
        record(outcome.consentPushFailed
            ? const CaptureRegistrationStatus(
                CaptureRegistrationPhase.failed, 'consent_sync_failed')
            : outcome.registerFailed
                ? const CaptureRegistrationStatus(
                    CaptureRegistrationPhase.failed, 'register_failed')
                : const CaptureRegistrationStatus(
                    CaptureRegistrationPhase.connected));
      }
    } catch (_) {
      if (tracked) {
        record(CaptureRegistrationStatus(
          CaptureRegistrationPhase.failed,
          outcome.registerFailed ? 'register_failed' : 'unknown',
        ));
      }
      if (ios) rethrow;
    }
  }

  /// UI-friendly re-run of [syncBackendState]; failures are reflected in
  /// [status] instead of thrown.
  Future<void> retry() async {
    try {
      await syncBackendState();
    } catch (_) {
      // Recorded in [status].
    }
  }

  /// Android consent propagation. Registers a device (to obtain the verified
  /// secret the hardened AI endpoints require) ONLY once the user has opted into
  /// cloud/AI — a purely-local user never gets a server device row — then
  /// mirrors consent onto that verified row. Fail-closed and best-effort: a
  /// failure never blocks local parsing, and a stale/absent server row defaults
  /// consent OFF (never open). No SMS/financial payload is ever sent here.
  Future<void> _syncAndroidConsentState(_SyncOutcome outcome) async {
    if (!_isBackendConfigured()) return;
    final settings = await _settingsRepository.getSettings();
    final wantsCloudOrAi =
        settings.cloudProcessingEnabled || settings.aiConsentGranted;
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);

    if (secret == null || secret.isEmpty) {
      // No opt-in yet → no server device, AI stays local (fail-closed).
      if (!wantsCloudOrAi) return;
      try {
        secret = await _backendClient.registerDevice(
          installId: installId,
          platform: 'android',
        );
        await _storage.write(key: _secretKey, value: secret);
      } catch (_) {
        outcome.registerFailed = true;
        return; // retried on the next sync; nothing leaks, nothing breaks
      }
    }

    await _pushDeviceConsent(
      outcome,
      installId: installId,
      deviceSecret: secret,
      aiConsentGranted: settings.aiConsentGranted,
      cloudProcessingEnabled: settings.cloudProcessingEnabled,
    );
  }

  Future<void> syncNativeState() => _syncNativeState(_SyncOutcome());

  Future<void> _syncNativeState(_SyncOutcome outcome) async {
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
      // The native bridge is OFF, but an existing verified server row must also
      // receive the revocation. With no backend or no secret there is no safe,
      // authenticated row to update, so preserve those guards.
      if (_isBackendConfigured() && secret != null && secret.isNotEmpty) {
        await _projectConsent(outcome);
      }
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
      try {
        secret = await _backendClient.registerDevice(installId: installId);
      } catch (_) {
        outcome.registerFailed = true;
        rethrow;
      }
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
    await _projectConsent(outcome);
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

  Future<bool> _pushDeviceConsent(
    _SyncOutcome outcome, {
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    try {
      await _backendClient.setDeviceConsent(
        installId: installId,
        deviceSecret: deviceSecret,
        aiConsentGranted: aiConsentGranted,
        cloudProcessingEnabled: cloudProcessingEnabled,
      );
      return true;
    } catch (_) {
      // Best-effort: startup/resume/next capture sync retries the same absolute
      // consent state. No SMS or financial payload is sent by this call.
      // While granting, the caller surfaces this as consent_sync_failed.
      if (cloudProcessingEnabled) outcome.consentPushFailed = true;
      return false;
    }
  }

  /// WP-6 — the capture-owner gate (manifest §4.2/§4.6). Links this install to
  /// the authenticated user with the replica's consent, and ONLY IF the server
  /// accepted it writes the per-owner consent mirror and publishes the capture
  /// owner. Any failure (offline, 4xx/5xx, no secret, the session and the
  /// admitted replica disagree) leaves the owner unpublished, so captures stay
  /// unbound (fail closed). Safe to call repeatedly; concurrent calls share one
  /// run. [_linkOnce] reports whether the owner is published.
  Future<bool> _linkOnce() {
    final inFlight = _linkInFlight;
    if (inFlight != null) return inFlight;
    final run = _linkAndPublish().catchError((_) => false);
    _linkInFlight = run;
    return run.whenComplete(() {
      if (identical(_linkInFlight, run)) _linkInFlight = null;
    });
  }

  /// The public entry (sign-in, resume, the admission hook).
  Future<void> linkToCurrentUser() async {
    await _linkOnce();
  }

  Future<bool> _linkAndPublish() async {
    if (!_isIos() || !_isBackendConfigured()) return false;
    final session = _readSession();
    if (session == null) return false;
    if (await _readReplicaOwnerUid() != session.uid) return false;
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    final ack = await _readAck(session.uid);
    if (ack != snapshot) {
      if (!await _linkWithConsent(session, snapshot)) return false;
    }
    // Re-checked after the network round trip: an account switch in between must
    // not publish the previous user as the owner.
    final current = _readSession();
    if (current == null ||
        current.uid != session.uid ||
        await _readReplicaOwnerUid() != session.uid) {
      return false;
    }
    await _writeMirror(session.uid, snapshot);
    await _publishOwner(session.uid);
    return true;
  }

  Future<bool> _linkWithConsent(
      CaptureSession session, _ConsentSnapshot snapshot) async {
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);
    try {
      if (secret == null || secret.isEmpty) {
        secret = await _backendClient.registerDevice(installId: installId);
        await _storage.write(key: _secretKey, value: secret);
        await _clearAck();
      }
      await _withSecretRecovery(installId, secret, (deviceSecret) {
        return _consent.link(
          installId: installId,
          deviceSecret: deviceSecret,
          jwt: session.jwt,
          cloud: snapshot.cloud,
          ai: snapshot.ai,
          version: snapshot.version,
        );
      });
    } catch (_) {
      return false;
    }
    await _writeAck(session.uid, snapshot);
    return true;
  }

  /// WP-6 — projects a consent CHANGE after the install is linked. A revocation
  /// reaches the device first (restrictive mirror: never wider than what the
  /// server last acknowledged); the widened/final mirror is written only after
  /// the server accepted `set_capture_consent` with the newer version. A failure
  /// leaves the restrictive mirror and the old acknowledgement, so the next sync
  /// retries the same absolute state. A never-linked install goes through the
  /// full gate instead.
  Future<void> _projectConsent(_SyncOutcome outcome) async {
    final session = _readSession();
    if (session == null || await _readReplicaOwnerUid() != session.uid) return;
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    final ack = await _readAck(session.uid);
    if (ack == null || ack.version > snapshot.version) {
      if (!await _linkOnce() && snapshot.cloud) {
        outcome.consentPushFailed = true;
      }
      return;
    }
    if (ack == snapshot) return;
    await _writeMirror(session.uid, (
      cloud: snapshot.cloud && ack.cloud,
      ai: snapshot.ai && ack.ai,
      version: snapshot.version,
    ));
    try {
      final installId = await _loadInstallId();
      final secret = await _storage.read(key: _secretKey);
      if (secret == null || secret.isEmpty) {
        throw const CaptureBackendException('no_secret');
      }
      await _withSecretRecovery(installId, secret, (deviceSecret) {
        return _consent.setConsent(
          installId: installId,
          deviceSecret: deviceSecret,
          jwt: session.jwt,
          cloud: snapshot.cloud,
          ai: snapshot.ai,
          version: snapshot.version,
        );
      });
    } catch (_) {
      if (snapshot.cloud) outcome.consentPushFailed = true;
      return;
    }
    await _writeMirror(session.uid, snapshot);
    await _writeAck(session.uid, snapshot);
  }

  _ConsentSnapshot _snapshotOf(UserSettingsEntity settings) => (
        cloud: settings.cloudProcessingEnabled,
        ai: settings.cloudProcessingEnabled && settings.aiConsentGranted,
        version: settings.consentVersion,
      );

  /// Runs [call] with [secret]; a 401 replaces the credential exactly once
  /// (shared with every other caller) and retries with the fresh one.
  Future<void> _withSecretRecovery(
    String installId,
    String secret,
    Future<void> Function(String deviceSecret) call,
  ) async {
    try {
      await call(secret);
    } on CaptureBackendException catch (error) {
      if (!_isUnauthorized(error)) rethrow;
      final fresh = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
      );
      await call(fresh);
    }
  }

  /// The mirror never moves to an older version within a process (a slow link
  /// finishing after a newer consent change must not overwrite it).
  Future<void> _writeMirror(String uid, _ConsentSnapshot snapshot) async {
    final last = _mirrorVersions[uid];
    if (last != null && snapshot.version < last) return;
    await _writeConsentMirror(
      uid: uid,
      cloud: snapshot.cloud,
      ai: snapshot.ai,
      version: snapshot.version,
    );
    _mirrorVersions[uid] = snapshot.version;
  }

  Future<_ConsentSnapshot?> _readAck(String uid) async {
    final raw = await _storage.read(key: _ackKey);
    final parts = raw?.split('|');
    if (parts == null || parts.length != 4 || parts[0] != uid) return null;
    final version = int.tryParse(parts[3]);
    if (version == null) return null;
    return (cloud: parts[1] == '1', ai: parts[2] == '1', version: version);
  }

  Future<void> _writeAck(String uid, _ConsentSnapshot snapshot) => _storage.write(
        key: _ackKey,
        value:
            '$uid|${snapshot.cloud ? 1 : 0}|${snapshot.ai ? 1 : 0}|${snapshot.version}',
      );

  Future<void> _clearAck() async {
    try {
      await _storage.delete(key: _ackKey);
    } catch (_) {}
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
    // The server projection is now unlinked (owner, flags and version reset).
    await _clearAck();
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
      // A new credential is a new server row: nothing was acknowledged for it.
      await _clearAck();
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
