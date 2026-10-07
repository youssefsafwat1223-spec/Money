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

/// A-12-min R4: publishes the owner together with its consent mirror in one
/// native flock, compare-and-swap on [expectedEpoch].
typedef OwnerPublisher = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
  required int expectedEpoch,
});

/// A-12.4 — the single best-effort revoke projection call sent as the closing
/// act of the user's own Cloud ON->OFF action (constraints on
/// [CaptureDeviceRegistrationService._revokeOnSwitchOff]). It is a PRODUCT
/// decision awaiting user ratification: set this to false to drop it. Dropping
/// it leaves already-stored server content to CAP-3 retention (7 days) and means
/// the §4.6 revoke fan-out never runs for users who switch Cloud OFF.
const bool kRevokeAtCloudSwitchOff = true;

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
    OwnerPublisher? publishOwner,
    Future<int> Function()? readOwnerEpoch,
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
        _publishOwner = publishOwner ?? NativeCaptureBridge.publishCaptureOwner,
        _readOwnerEpoch = readOwnerEpoch ?? NativeCaptureBridge.captureOwnerEpoch;

  static const _secretKey = 'qirsh_capture_device_secret';

  /// WP-6: the last consent the server ACKNOWLEDGED for this install, as
  /// `uid|cloud|ai|version` (single slot). It proves the projection is linked to
  /// that uid at that version, which lets a repeat admission skip the network
  /// call, and it is the floor for a restrictive-first mirror write. Cleared on
  /// unlink and whenever the device credential is replaced.
  static const _ackKey = 'qirsh_capture_consent_ack';

  /// A-12.4: `uid|version` of the switch-off revoke, written BEFORE it is sent,
  /// so a crash or a restart can never send it (a second time).
  static const _revokeMarkerKey = 'qirsh_capture_revoke_marker';

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
  final OwnerPublisher _publishOwner;
  final Future<int> Function() _readOwnerEpoch;
  Future<bool>? _linkInFlight;
  final Map<String, int> _mirrorVersions = {};

  /// The uid whose Cloud-ON state this process observed. It is what makes the
  /// switch-off revoke a reaction to the user's own toggle in a RUNNING app: a
  /// relaunch starts empty, so startup and resume can never send it.
  String? _cloudOnSeenUid;

  /// Android: this process saw a Cloud/AI-ON consent push succeed.
  bool _androidOnAcked = false;
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
  ///
  /// Cloud OFF = ZERO EGRESS here too (A-12-min R6, no platform carve-out): with
  /// no opt-in nothing is sent, ever, even when a secret exists. The only
  /// exception is [_revokeAndroidOnSwitchOff].
  Future<void> _syncAndroidConsentState(_SyncOutcome outcome) async {
    if (!_isBackendConfigured()) return;
    final settings = await _settingsRepository.getSettings();
    final wantsCloudOrAi =
        settings.cloudProcessingEnabled || settings.aiConsentGranted;
    if (!wantsCloudOrAi) {
      await _revokeAndroidOnSwitchOff(settings.consentVersion);
      return;
    }
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);

    if (secret == null || secret.isEmpty) {
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

    final pushed = await _pushDeviceConsent(
      outcome,
      installId: installId,
      deviceSecret: secret,
      aiConsentGranted: settings.aiConsentGranted,
      cloudProcessingEnabled: settings.cloudProcessingEnabled,
    );
    if (pushed) _androidOnAcked = true;
  }

  /// A-12.4 on Android: the one-shot revoke at the user's own ON->OFF toggle.
  /// Android has no uid-bound ack, so the proof that the server holds an ON
  /// state is [_androidOnAcked] (a push this process saw succeed); like iOS it
  /// is in-memory only (a relaunch never sends it), the durable marker is
  /// written BEFORE sending, there is no 401 recovery and it is never retried.
  Future<void> _revokeAndroidOnSwitchOff(int version) async {
    final acked = _androidOnAcked;
    _androidOnAcked = false;
    if (!kRevokeAtCloudSwitchOff || !acked) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final marker = 'android|$version';
    try {
      if (await _storage.read(key: _revokeMarkerKey) == marker) return;
      await _storage.write(key: _revokeMarkerKey, value: marker);
    } catch (_) {
      return;
    }
    try {
      await _backendClient.setDeviceConsent(
        installId: await _loadInstallId(),
        deviceSecret: secret,
        aiConsentGranted: false,
        cloudProcessingEnabled: false,
      );
    } catch (_) {
      // Best-effort and final.
    }
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
      // Cloud OFF = ZERO EGRESS (A-12-min R6): no link, no registerDevice, no
      // setConsent, no APNs registration and no 401 recovery. The owner and its
      // restrictive mirror are published LOCALLY, first; then (only for the
      // user's own ON->OFF toggle in this running app) at most one revoke.
      if (!settings.cloudProcessingEnabled) {
        await _linkOnce();
        await _revokeOnSwitchOff();
      }
      return;
    }
    _cloudOnSeenUid = _readSession()?.uid;

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

  /// WP-6 / A-12-min — the capture-owner gate (manifest §4.2/§4.6).
  ///
  /// Cloud OFF or unset: the owner and its restrictive mirror are published
  /// LOCALLY with no network call at all (the session uid must equal the
  /// admitted replica's owner). Cloud ON: the install is linked to the
  /// authenticated user with the replica's consent first, and ONLY IF the server
  /// accepted it is the owner published (mirror and owner in one native call).
  /// Any failure (offline, 4xx/5xx, no secret, the session and the admitted
  /// replica disagree, a clear since the epoch was read) leaves the owner
  /// unpublished, so captures stay unbound (fail closed). Safe to call
  /// repeatedly; concurrent calls share one run. [_linkOnce] reports whether the
  /// owner is published.
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
    if (!_isIos()) return false;
    final session = _readSession();
    if (session == null) return false;
    if (await _readReplicaOwnerUid() != session.uid) return false;
    // Read BEFORE any await that can take long: a sign-out / transition / removal
    // clear after this point bumps the epoch and the native publish refuses.
    final epoch = await _readOwnerEpoch();
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    var linked = (cloud: false, ai: false, version: snapshot.version);
    if (snapshot.cloud) {
      if (!_isBackendConfigured()) return false;
      final ack = await _readAck(session.uid);
      if (ack != snapshot) {
        if (!await _linkWithConsent(session, snapshot)) return false;
      }
      linked = snapshot;
      _cloudOnSeenUid = session.uid;
    }
    // Re-checked after the round trip: an account switch in between must not
    // publish the previous user as the owner.
    final current = _readSession();
    if (current == null ||
        current.uid != session.uid ||
        await _readReplicaOwnerUid() != session.uid) {
      return false;
    }
    // The mirror is never wider than what is proven (OFF, or what the server
    // acknowledged), even if consent changed while the link was in flight.
    final now = _snapshotOf(await _settingsRepository.getSettings());
    final mirror = (
      cloud: now.cloud && linked.cloud,
      ai: now.ai && linked.ai,
      version: now.version,
    );
    await _publishOwner(
      uid: session.uid,
      cloud: mirror.cloud,
      ai: mirror.ai,
      version: mirror.version,
      expectedEpoch: epoch,
    );
    _mirrorVersions[session.uid] = mirror.version;
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
  /// full gate instead. Cloud ON only: Cloud OFF never reaches this (R6).
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
    final ack = await _readAckAny();
    return ack != null && ack.uid == uid ? ack.snapshot : null;
  }

  Future<({String uid, _ConsentSnapshot snapshot})?> _readAckAny() async {
    final raw = await _storage.read(key: _ackKey);
    final parts = raw?.split('|');
    if (parts == null || parts.length != 4) return null;
    final version = int.tryParse(parts[3]);
    if (version == null) return null;
    return (
      uid: parts[0],
      snapshot: (cloud: parts[1] == '1', ai: parts[2] == '1', version: version),
    );
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

  /// WP-8 (diagnostics, read-only): what the server last acknowledged for the
  /// current session user and the newest mirror version written this process.
  /// Flags and a version only; null when nothing was acknowledged / mirrored.
  Future<({bool cloud, bool ai, int version})?> consentAckSnapshot() async {
    final uid = _readSession()?.uid;
    if (uid == null) return null;
    return _readAck(uid);
  }

  int? get mirroredConsentVersion {
    final uid = _readSession()?.uid;
    return uid == null ? null : _mirrorVersions[uid];
  }

  /// A-12.4 — the one-shot revoke projection call at the user's own Cloud
  /// ON->OFF toggle. The mirror already restricted (see [_syncNativeState]); this
  /// only tells the server so it can null content it already holds. Constraints:
  /// content-free, not a link; only for a toggle observed in THIS running
  /// process; only while the uid-bound ack shows Cloud ON for this uid; the
  /// `(uid, version)` marker is durable BEFORE sending and the ack is cleared
  /// before sending, so a crash, a restart or a later OFF sync never sends it
  /// again; no 401 recovery; never retried.
  Future<void> _revokeOnSwitchOff() async {
    final session = _readSession();
    final seen = _cloudOnSeenUid;
    _cloudOnSeenUid = null;
    if (!kRevokeAtCloudSwitchOff ||
        session == null ||
        seen != session.uid ||
        !_isBackendConfigured()) {
      return;
    }
    final ack = await _readAck(session.uid);
    if (ack == null || !ack.cloud) return;
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    if (snapshot.cloud) return;
    final marker = '${session.uid}|${snapshot.version}';
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    try {
      if (await _storage.read(key: _revokeMarkerKey) == marker) return;
      await _storage.write(key: _revokeMarkerKey, value: marker);
    } catch (_) {
      return; // no durable marker, no send
    }
    await _clearAck();
    try {
      await _consent.setConsent(
        installId: installId,
        deviceSecret: secret,
        jwt: session.jwt,
        cloud: false,
        ai: false,
        version: snapshot.version,
      );
    } catch (_) {
      // Best-effort and final: retention (CAP-3) covers a call that never lands.
    }
  }

  /// Revokes the mutable user/APNs association without deleting the relay
  /// secret needed by the App Intent while the host app is signed out. Sent only
  /// when the uid-bound ack shows a Cloud-ON link (A-12-min R6): an install that
  /// never linked, or whose Cloud is OFF, sends nothing. The ack is cleared
  /// before sending. Always resets the in-process mirror versions (R4), because a
  /// sign-out or Remove data ends this replica's consent history.
  Future<void> unlinkCurrentDevice() async {
    _mirrorVersions.clear();
    _cloudOnSeenUid = null;
    if (!_isIos() || !_isBackendConfigured()) return;
    final ack = await _readAckAny();
    if (ack == null || !ack.snapshot.cloud) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    await _clearAck();
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

  /// A-12-min R5: whether the legacy device-credential calls (`sync-captures`,
  /// the ACK through it, `process-ios-sms`) may run. On iOS only when the
  /// uid-bound ack is for the CURRENT session user with Cloud ON, so a failed or
  /// missing link never falls through to a projection that may still belong to
  /// someone else. Android has no link and is unchanged.
  Future<bool> isLinkedForCloud() async {
    if (!_isIos()) return true;
    final uid = _readSession()?.uid;
    if (uid == null) return false;
    final ack = await _readAck(uid);
    return ack != null && ack.cloud;
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
    // Cloud OFF = zero egress (R6): a 401 never re-registers the device while
    // the user's Cloud consent is OFF (e.g. switched off mid-flight).
    if (!(await _settingsRepository.getSettings()).cloudProcessingEnabled) {
      throw const CaptureBackendException('recovery_skipped_cloud_off');
    }
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
