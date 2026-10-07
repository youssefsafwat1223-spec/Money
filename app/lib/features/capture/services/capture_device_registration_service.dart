import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/privacy/cloud_egress_gate.dart';
import '../../../core/privacy/consent_authority.dart';
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
  String? ownerUid,
  int? transitionGeneration,
});

typedef ApnsTokenLoader = Future<ApnsTokenInfo?> Function();

/// WP-6: the signed-in user as the capture backend sees it.
typedef CaptureSession = ({String uid, String jwt});

typedef ConsentMirrorWriter = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
  int? transitionGeneration,
});

/// A-12-min R4: publishes the owner together with its consent mirror in one
/// native flock, compare-and-swap on [expectedEpoch].
typedef OwnerPublisher = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
  required int expectedEpoch,
  int? transitionGeneration,
});

/// A-12.4 / E1 / Astra G C.3 — the single one-shot revoke
/// (`revoke_capture_consent`, JWT) sent as the ONLY control-plane exception while
/// DISABLING, inside [CaptureDeviceRegistrationService.disableCloud]. Set this to
/// false to drop it: the transition then only freezes and commits OFF with zero
/// requests, and already-stored server content is left to CAP-3 retention.
const bool kRevokeAtCloudSwitchOff = true;

/// Upper bound on the one revoke request. The user is waiting on the toggle and
/// OFF is committed only after the request settles, so the bound must be short;
/// 5 s covers a normal mobile round trip of this tiny content-free call, and a
/// slower server is covered by CAP-3 retention. Timing out never blocks OFF.
const Duration kCloudOffRevokeTimeout = Duration(seconds: 5);

/// WP-6: the consent the replica holds, as projected to the server and to the
/// native mirror. Derived ONLY from the replica's own explicit, versioned choice
/// (cloud is the master gate, so AI is on only when cloud is on); never from a
/// server value.
typedef _ConsentSnapshot = ({bool cloud, bool ai, int version});

/// P4: what an async mutation captured when it started. Every write after an
/// await re-checks it ([CaptureDeviceRegistrationService._holds]): the
/// in-process epoch (advanced by disable / enable / account transitions /
/// sign-out), the session uid and the replica owner must all be unchanged.
typedef _Tx = ({int epoch, String? sessionUid, String? owner});

/// The persistent gate as the registration service needs it.
enum _Gate { open, off, blocked }

/// C.3 / C.4: the outcome of the one-shot revoke. NOT_ATTEMPTED = nothing was
/// sent (no frozen-owner JWT, ack or secret, or no durable attempt record);
/// UNCONFIRMED = it was sent (or may have been) and no `applied` answer came
/// back; CONFIRMED = the server answered `{ok, applied}`. Never a claim that
/// content was nulled or that work stopped.
enum ServerRevocation { confirmed, unconfirmed, notAttempted }

/// Thrown by [CaptureDeviceRegistrationService.disableCloud] when the UI must
/// NOT be told that OFF succeeded (DISABLING could not be made durable, or the
/// owner changed under the transition).
class CloudDisableException implements Exception {
  const CloudDisableException(this.reason);
  final String reason;
  @override
  String toString() => 'CloudDisableException($reason)';
}

class _RevokeInputs {
  const _RevokeInputs(this.installId, this.secret, this.jwt);
  final String installId;
  final String secret;
  final String jwt;
}

/// Two independent durable copies of one small record (secure storage + file).
class _DualSlot {
  _DualSlot(this._a, this._b);
  final DurableSlot _a;
  final DurableSlot _b;

  Future<bool> write(String value) async {
    var ok = false;
    try {
      await _a.write(value);
      ok = true;
    } catch (_) {}
    try {
      await _b.write(value);
      ok = true;
    } catch (_) {}
    return ok;
  }

  Future<String?> read() async {
    final a = await _a.read();
    if (a.status == SlotStatus.value) return a.raw;
    final b = await _b.read();
    return b.status == SlotStatus.value ? b.raw : null;
  }
}

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
    bool revokeAtSwitchOff = kRevokeAtCloudSwitchOff,
    Duration revokeTimeout = kCloudOffRevokeTimeout,
    Future<Directory> Function()? markerDirectory,
    CloudEgressGate? gate,
  })  : _gateOverride = gate,
        _revokeAtSwitchOff = revokeAtSwitchOff,
        _revokeTimeout = revokeTimeout,
        _markerDirectory = markerDirectory ?? getApplicationSupportDirectory,
        _settingsRepository = settingsRepository,
        _client = client,
        _storage = storage ?? SecureStorageOptions.storage,
        _isIos = isIos ?? (() => Platform.isIOS),
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _isBackendConfigured =
            isBackendConfigured ?? (() => SupabaseConfig.isConfigured),
        _loadInstallId = loadInstallId ?? InstallId.get,
        _writeNativeBackendConfig =
            writeNativeBackendConfig ?? NativeCaptureBridge.setBackendConfig,
        _loadApnsTokenOverride = loadApnsToken,
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

  /// C.4: the durable, consumed `revoke_attempt = {owner, transition_generation,
  /// consumed: true}`, written BEFORE the single send and SEPARATE from the
  /// DISABLING record (`disable_pending` is the `cloud_egress_state` DISABLING
  /// record of [CloudEgressGate]). Nothing ever replays it: a crash after this
  /// write means the revoke is never sent (the status is then UNCONFIRMED).
  static const _revokeAttemptKey = 'qirsh.capture_revoke_attempt.v1';
  static const _revokeAttemptFile = 'capture_revoke_attempt.v1';

  /// `{owner, transition_generation, status}` of the last revoke outcome,
  /// exposed read-only through [serverRevocation].
  static const _serverRevocationKey = 'qirsh.capture_server_revocation.v1';
  static const _serverRevocationFile = 'capture_server_revocation.v1';

  /// One transition at a time, process-wide (the UI and startup own different
  /// service instances).
  static Future<void>? _disableInFlight;
  static Future<void>? _enableInFlight;

  final DriftUserSettingsRepository _settingsRepository;
  final CaptureBackendClient? _client;
  final FlutterSecureStorage _storage;
  final bool Function() _isIos;
  final bool Function() _isAndroid;
  final bool Function() _isBackendConfigured;
  final Future<String> Function() _loadInstallId;
  final NativeBackendConfigWriter _writeNativeBackendConfig;
  final ApnsTokenLoader? _loadApnsTokenOverride;
  final CaptureConsentClient? _consentClient;
  final CaptureSession? Function() _readSession;
  final Future<String?> Function() _readReplicaOwnerUid;
  final ConsentMirrorWriter _writeConsentMirror;
  final OwnerPublisher _publishOwner;
  final Future<int> Function() _readOwnerEpoch;
  final bool _revokeAtSwitchOff;
  final Duration _revokeTimeout;
  final CloudEgressGate? _gateOverride;

  /// App-support directory for the file copies of the revoke records.
  final Future<Directory> Function() _markerDirectory;
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

  CloudEgressGate get _gate => _gateOverride ?? CloudEgressGate.instance;

  _DualSlot get _revokeAttemptSlots => _DualSlot(
      SecureStorageSlot(_storage, _revokeAttemptKey),
      FileSlot(_markerDirectory, _revokeAttemptFile));

  _DualSlot get _serverRevocationSlots => _DualSlot(
      SecureStorageSlot(_storage, _serverRevocationKey),
      FileSlot(_markerDirectory, _serverRevocationFile));

  bool _cloudOn(UserSettingsEntity s) => _isAndroid()
      ? s.cloudProcessingEnabled || s.aiConsentGranted
      : s.cloudProcessingEnabled;

  Future<_Tx> _beginTx() async =>
      (epoch: _gate.epoch, sessionUid: _readSession()?.uid, owner: await _readReplicaOwnerUid());

  /// P4: whether the async mutation that captured [tx] may still write. False
  /// after a disable / enable / account transition / sign-out advanced the
  /// epoch, after an account or session switch, or while frozen.
  Future<bool> _holds(_Tx tx) async {
    if (_gate.epoch != tx.epoch || ConsentAuthority.egressFrozen) return false;
    if (_readSession()?.uid != tx.sessionUid) return false;
    try {
      return await _readReplicaOwnerUid() == tx.owner;
    } catch (_) {
      return false;
    }
  }

  /// The APNs registration. Astra H3 cross-unit: the native call carries the
  /// CURRENT transition generation of the active owner so the native side can
  /// refuse a stale call, and it is made only while the gate permits.
  Future<ApnsTokenInfo?> _loadApnsToken(String owner) async {
    final override = _loadApnsTokenOverride;
    if (override != null) return override();
    if (!await _gate.permits()) return null;
    final generation = await _clientGeneration(owner);
    return await NativeCaptureBridge.registerForRemoteNotifications(
            transitionGeneration: generation) ??
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
    if (await _gateState() == _Gate.blocked) return;
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
  /// exception is the revoke inside [disableCloud].
  Future<void> _syncAndroidConsentState(_SyncOutcome outcome) async {
    if (!_isBackendConfigured()) return;
    // OFF (persistent gate) or unset: nothing is sent, ever, even with a secret.
    if (await _gateState() != _Gate.open) return;
    final tx = await _beginTx();
    final settings = await _settingsRepository.getSettings();
    final wantsCloudOrAi =
        settings.cloudProcessingEnabled || settings.aiConsentGranted;
    if (!wantsCloudOrAi) return;
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);

    if (secret == null || secret.isEmpty) {
      try {
        secret = await _backendClient.registerDevice(
          installId: installId,
          platform: 'android',
        );
        await _storage.write(key: _secretKey, value: secret);
        await _clearAck();
      } catch (_) {
        outcome.registerFailed = true;
        return; // retried on the next sync; nothing leaks, nothing breaks
      }
    }

    // C.3 / P7: the Android device row is linked to its owner with the JWT link
    // (`link_capture_device(consent)`), exactly like iOS, so the revoke can be
    // authorised by the same contract. Only a session whose uid IS the admitted
    // replica owner may link; otherwise (signed out) the legacy device-secret
    // consent push below is all that exists, and it creates no owner proof.
    final session = _readSession();
    if (session != null && tx.owner == session.uid && tx.sessionUid == session.uid) {
      final snapshot = (
        cloud: settings.cloudProcessingEnabled,
        ai: settings.aiConsentGranted,
        version: settings.consentVersion,
      );
      if (await _readAck(session.uid) == snapshot) return;
      if (!await _linkWithConsent(session, snapshot, tx)) {
        outcome.consentPushFailed = true;
      }
      return;
    }

    if (!await _holds(tx)) return;
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
    final gateState = await _gateState();
    if (gateState == _Gate.blocked) return;
    final tx = await _beginTx();
    final settings = await _settingsRepository.getSettings();
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);

    if (!settings.cloudProcessingEnabled ||
        !_isBackendConfigured() ||
        gateState == _Gate.off) {
      await _writeNativeBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
        ownerUid: tx.owner ?? '',
        transitionGeneration: await _clientGeneration(tx.owner ?? ''),
      );
      // Cloud OFF = ZERO EGRESS (A-12-min R6): no link, no registerDevice, no
      // setConsent, no APNs registration and no 401 recovery. The owner and its
      // restrictive mirror are published LOCALLY. This branch NEVER sends a
      // revoke: the only one lives inside [disableCloud].
      if (!settings.cloudProcessingEnabled) await _linkOnce();
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
        ownerUid: tx.owner ?? '',
        transitionGeneration: await _clientGeneration(tx.owner ?? ''),
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

    // P4: the registration round trip may have outlived an account switch or a
    // transition; the (widening) native config is written only if nothing moved.
    if (!await _holds(tx)) return;
    await _writeNativeBackendConfig(
      cloudProcessingEnabled: _isBackendConfigured(),
      installId: installId,
      deviceSecret: secret,
      backendUrl: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      aiConsentGranted: settings.aiConsentGranted,
      ownerUid: tx.owner ?? '',
      transitionGeneration: await _clientGeneration(tx.owner ?? ''),
    );
    // MALI-060n — mirror consent onto the verified server device row so the
    // AI/paid endpoints enforce it authoritatively (revocation propagates the
    // moment the user toggles it, since syncNativeState re-runs). Best-effort:
    // a failure here must never block native config or local capture.
    await _projectConsent(outcome, tx);
    try {
      final token = await _loadApnsToken(tx.owner ?? '');
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
    // P6: OFF (a committed persistent gate) still publishes LOCALLY with a
    // restrictive mirror; DISABLING / frozen / uncertain authority fails closed.
    if (!_isIos()) return false;
    final gateState = await _gateState();
    if (gateState == _Gate.blocked) return false;
    final session = _readSession();
    if (session == null) return false;
    if (await _readReplicaOwnerUid() != session.uid) return false;
    final tx = await _beginTx();
    // Read BEFORE any await that can take long: a sign-out / transition / removal
    // clear after this point bumps the epoch and the native publish refuses.
    final epoch = await _readOwnerEpoch();
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    var linked = (cloud: false, ai: false, version: snapshot.version);
    if (snapshot.cloud && gateState == _Gate.open) {
      if (!_isBackendConfigured()) return false;
      final ack = await _readAck(session.uid);
      if (ack != snapshot) {
        if (!await _linkWithConsent(session, snapshot, tx)) return false;
      }
      linked = snapshot;
    }
    // Re-checked after the round trip: an account switch in between must not
    // publish the previous user as the owner, and a Cloud-OFF transition that
    // began meanwhile must not have its restricted mirror widened.
    if (!await _holds(tx)) return false;
    // The mirror is never wider than what is proven (OFF, or what the server
    // acknowledged), even if consent changed while the link was in flight.
    final now = _snapshotOf(await _settingsRepository.getSettings());
    final mirror = (
      cloud: now.cloud && linked.cloud,
      ai: now.ai && linked.ai,
      version: now.version,
    );
    if (!await _holds(tx)) return false;
    await _publishOwner(
      uid: session.uid,
      cloud: mirror.cloud,
      ai: mirror.ai,
      version: mirror.version,
      expectedEpoch: epoch,
      transitionGeneration: await _clientGeneration(session.uid),
    );
    _mirrorVersions[session.uid] = mirror.version;
    return true;
  }

  Future<bool> _linkWithConsent(
      CaptureSession session, _ConsentSnapshot snapshot, _Tx tx) async {
    final installId = await _loadInstallId();
    var secret = await _storage.read(key: _secretKey);
    final generation = await _clientGeneration(session.uid);
    try {
      if (secret == null || secret.isEmpty) {
        secret = await _backendClient.registerDevice(
            installId: installId, platform: _isAndroid() ? 'android' : 'ios');
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
          clientGeneration: generation,
        );
      });
    } catch (_) {
      return false;
    }
    // P4: an ack for a link that completed after an account switch or a
    // transition is never written; the next admission links again.
    if (!await _holds(tx)) return false;
    await _writeAck(session.uid, snapshot);
    return true;
  }

  /// The client transition generation sent as `p_client_generation` (C.2): the
  /// owner's durable `cloud_egress_state` generation (0 before any record).
  Future<int> _clientGeneration(String uid) async {
    try {
      return (await _gate.view(owner: uid)).record?.transitionGeneration ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// WP-6 — projects a consent CHANGE after the install is linked. A revocation
  /// reaches the device first (restrictive mirror: never wider than what the
  /// server last acknowledged); the widened/final mirror is written only after
  /// the server accepted `set_capture_consent` with the newer version. A failure
  /// leaves the restrictive mirror and the old acknowledgement, so the next sync
  /// retries the same absolute state. A never-linked install goes through the
  /// full gate instead. Cloud ON only: Cloud OFF never reaches this (R6).
  Future<void> _projectConsent(_SyncOutcome outcome, _Tx tx) async {
    if (ConsentAuthority.egressFrozen) return;
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
    if (!await _holds(tx)) return;
    await _writeMirror(session.uid, (
      cloud: snapshot.cloud && ack.cloud,
      ai: snapshot.ai && ack.ai,
      version: snapshot.version,
    ));
    final generation = await _clientGeneration(session.uid);
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
          clientGeneration: generation,
        );
      });
    } catch (_) {
      if (snapshot.cloud) outcome.consentPushFailed = true;
      return;
    }
    // P4: the answer of a set that outlived an account switch / transition has
    // no state effect (no widened mirror, no ack).
    if (!await _holds(tx)) return;
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
    if (ConsentAuthority.egressFrozen) return;
    final last = _mirrorVersions[uid];
    if (last != null && snapshot.version < last) return;
    await _writeConsentMirror(
      uid: uid,
      cloud: snapshot.cloud,
      ai: snapshot.ai,
      version: snapshot.version,
      transitionGeneration: await _clientGeneration(uid),
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

  /// Whether saving [after] over [before] switches the capture cloud from ON to
  /// OFF on this platform (Android treats AI like cloud, see
  /// [_syncAndroidConsentState]). Such a change MUST go through [disableCloud].
  bool isDisablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      _cloudOn(before) && !_cloudOn(after);

  /// The opposite change: OFF/unset -> ON. Such a change MUST go through
  /// [enableCloud] (an explicit user action; the only way out of the persistent
  /// OFF gate).
  bool isEnablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      !_cloudOn(before) && _cloudOn(after);

  /// Astra G C.4 — the Cloud ON->OFF transition. In order:
  ///  (a) FREEZE, synchronously: the in-process flag and the epoch advance
  ///      first; then, under the admission lock, `cloud_egress_state = DISABLING`
  ///      (owner, a NEW transition generation, reserved version = current + 1)
  ///      is written durably to every store. No request newly passes admission
  ///      after that, concurrent attempts included. If not one store takes the
  ///      record NOTHING is sent (no revoke), local OFF is still attempted, and
  ///      the UI is told ([CloudDisableException]);
  ///  (b) the native side is restricted (no network), the revoke inputs are
  ///      FROZEN (owner, generation, version, install, JWT of THAT owner, secret,
  ///      uid-bound ack), the in-flight requests are drained (bounded, then
  ///      cancelled) and at most ONE revoke is sent: its `revoke_attempt` is
  ///      durably written (consumed) BEFORE the send, there is no retry, no
  ///      relink, no 401 recovery and no startup replay; the outcome is
  ///      [serverRevocation];
  ///  (c) [commitLocalOff] persists Cloud OFF, then durable OFF replaces
  ///      DISABLING and only then is the freeze lifted. If the local write fails
  ///      the freeze stays on, DISABLING is re-written and the error is rethrown.
  /// A crash leaves DISABLING: [resolvePendingDisable] commits OFF locally at
  /// the next start (never a revoke). The callback is skipped when the account
  /// changed under the transition (the marker stays for its owner). Bytes
  /// already transmitted before DISABLING cannot be recalled.
  Future<void> disableCloud({
    required Future<void> Function() commitLocalOff,
  }) =>
      _disableInFlight ??= _disableCloud(commitLocalOff)
          .whenComplete(() => _disableInFlight = null);

  Future<void> _disableCloud(Future<void> Function() commitLocalOff) async {
    ConsentAuthority.egressFrozen = true;
    _gate.advanceEpoch(); // P4: advance BEFORE any transition work
    final sessionUid = _readSession()?.uid;
    String? owner;
    DisableFreeze? freeze;
    try {
      try {
        owner = await _readReplicaOwnerUid() ?? '';
        final settings = await _settingsRepository.getSettings();
        freeze = await _gate.beginDisabling(
            owner: owner, reservedVersion: settings.consentVersion + 1);
        await _restrictNativeSide(freeze);
        final inputs = await _captureRevokeInputs(freeze, settings);
        await _gate.drain();
        await _gate.drainNative(freeze.owner);
        await _revokeOnce(freeze, inputs);
      } catch (_) {
        // Nothing above may block the local OFF below. Without a durable
        // DISABLING record no revoke can have been sent (see beginDisabling).
      }
    } finally {
      await _finishDisable(commitLocalOff, owner, sessionUid, freeze);
    }
  }

  Future<void> _finishDisable(
    Future<void> Function() commitLocalOff,
    String? owner,
    String? sessionUid,
    DisableFreeze? freeze,
  ) async {
    // P4: the callback writes the CURRENT replica. If the account changed under
    // the transition it must not touch the new owner; the DISABLING marker stays
    // for the old owner's next admission and the new owner is evaluated alone.
    var sameOwner = false;
    try {
      sameOwner = owner != null &&
          (await _readReplicaOwnerUid() ?? '') == owner &&
          _readSession()?.uid == sessionUid;
    } catch (_) {}
    if (!sameOwner) {
      ConsentAuthority.egressFrozen = false;
      throw const CloudDisableException('owner_changed');
    }
    // FAIL CLOSED: if the local OFF write fails, the process-wide freeze stays
    // on, Cloud is never restored to ON, nothing more is sent, and DISABLING is
    // re-written so the next launch completes OFF.
    try {
      await commitLocalOff();
    } catch (_) {
      if (freeze != null) await _gate.rewriteDisabling(freeze);
      rethrow;
    }
    if (freeze == null) {
      // DISABLING never became durable: egress stays denied in this process and
      // the UI is NOT told that OFF succeeded.
      throw const CloudDisableException('disabling_not_durable');
    }
    if (await _gate.commitOff(freeze)) {
      ConsentAuthority.egressFrozen = false;
      await _gate.refresh();
    }
    // else: durable OFF could not be written; DISABLING (denied) is still
    // there and the freeze stays, so nothing reopens.
  }

  /// Astra G: an explicit enable (the only way out of the persistent OFF gate).
  /// Advances to a NEW transition generation and version (strictly greater),
  /// writes ON to every store, lifts the freeze, then runs [commitLocalOn] (the
  /// UI's settings save) and the existing ON path ([syncBackendState]).
  Future<void> enableCloud({
    required Future<void> Function() commitLocalOn,
  }) async {
    final pending = _disableInFlight;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    return _enableInFlight ??=
        _enableCloud(commitLocalOn).whenComplete(() => _enableInFlight = null);
  }

  Future<void> _enableCloud(Future<void> Function() commitLocalOn) async {
    _gate.advanceEpoch();
    final owner = await _readReplicaOwnerUid() ?? '';
    final settings = await _settingsRepository.getSettings();
    await _gate.enable(owner: owner, reservedVersion: settings.consentVersion + 1);
    ConsentAuthority.egressFrozen = false;
    await commitLocalOn();
    await _gate.refresh();
  }

  /// Restricts the native side (no network): backend config cloud=false and a
  /// restrictive mirror for the frozen owner at the reserved version.
  Future<void> _restrictNativeSide(DisableFreeze freeze) async {
    if (!_isIos()) return;
    try {
      await _writeNativeBackendConfig(
        cloudProcessingEnabled: false,
        installId: await _loadInstallId(),
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
        ownerUid: freeze.owner,
        transitionGeneration: freeze.transitionGeneration,
      );
    } catch (_) {}
    try {
      if (freeze.owner.isNotEmpty) {
        await _writeConsentMirror(
            uid: freeze.owner,
            cloud: false,
            ai: false,
            version: freeze.reservedVersion,
            transitionGeneration: freeze.transitionGeneration);
        _mirrorVersions[freeze.owner] = freeze.reservedVersion;
      }
    } catch (_) {}
  }

  /// The revoke inputs, FROZEN at DISABLING: the frozen owner's JWT (the live
  /// session must be that owner), its uid-bound ack showing Cloud ON, the device
  /// secret and the install id. "Stored secret + was ON" is NEVER enough: with
  /// no JWT or no ack there is nothing to send (NOT_ATTEMPTED).
  Future<_RevokeInputs?> _captureRevokeInputs(
      DisableFreeze freeze, UserSettingsEntity settings) async {
    if (!_revokeAtSwitchOff ||
        !_cloudOn(settings) ||
        !_isBackendConfigured() ||
        freeze.owner.isEmpty ||
        (!_isIos() && !_isAndroid())) {
      return null;
    }
    final session = _readSession();
    if (session == null || session.uid != freeze.owner) return null;
    final ack = await _readAck(freeze.owner);
    if (ack == null || !(_isAndroid() ? ack.cloud || ack.ai : ack.cloud)) {
      return null;
    }
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return null;
    return _RevokeInputs(await _loadInstallId(), secret, session.jwt);
  }

  /// The single send opportunity. The consumed `revoke_attempt` is durably
  /// written FIRST (no durable record, no send), the ack is cleared, then ONE
  /// request is made with a hard timeout. No retry, no relink, no 401 recovery.
  Future<void> _revokeOnce(DisableFreeze freeze, _RevokeInputs? inputs) async {
    if (inputs == null) {
      await _recordRevocation(freeze, ServerRevocation.notAttempted);
      return;
    }
    if (await _attemptRecorded(freeze)) {
      // A consumed attempt for this (owner, generation) already exists: the one
      // send opportunity is gone. Never a second send.
      await _recordRevocation(freeze, ServerRevocation.unconfirmed);
      return;
    }
    final attempt = jsonEncode({
      'owner': freeze.owner,
      'transition_generation': freeze.transitionGeneration,
      'consumed': true,
    });
    if (!await _revokeAttemptSlots.write(attempt)) {
      await _recordRevocation(freeze, ServerRevocation.notAttempted);
      return;
    }
    await _clearAck();
    var status = ServerRevocation.unconfirmed;
    try {
      final result = await _gate.runRevoke(freeze, _revokeTimeout, () {
        return _consent.revoke(
          installId: inputs.installId,
          deviceSecret: inputs.secret,
          jwt: inputs.jwt,
          ownerUid: freeze.owner,
          transitionGeneration: freeze.transitionGeneration,
          version: freeze.reservedVersion,
        );
      });
      if (result.applied || result.reason == 'already_revoked') {
        status = ServerRevocation.confirmed;
      }
    } catch (_) {
      // Best-effort and final: CAP-3 retention covers a call that never lands.
    }
    await _recordRevocation(freeze, status);
  }

  Future<void> _recordRevocation(
      DisableFreeze freeze, ServerRevocation status) async {
    await _serverRevocationSlots.write(jsonEncode({
      'owner': freeze.owner,
      'transition_generation': freeze.transitionGeneration,
      'status': status.name,
    }));
  }

  /// WP-8 diagnostics (read-only): how the last revoke ended. Status and
  /// generation only; never a uid, secret or content. CONFIRMED means the server
  /// answered `{ok, applied}` for that call, nothing more.
  Future<({ServerRevocation status, int generation})?> serverRevocation() async {
    try {
      final raw = await _serverRevocationSlots.read();
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final status = ServerRevocation.values
          .where((v) => v.name == m['status'])
          .firstOrNull;
      final gen = m['transition_generation'];
      if (status == null || gen is! int) return null;
      return (status: status, generation: gen);
    } catch (_) {
      return null;
    }
  }

  /// Startup hook: finishes a Cloud-OFF transition a dead process left behind
  /// and reconciles the durable state with the replica, before any other egress
  /// can start (C.5). No revoke, ever. Uncertain state keeps egress frozen.
  Future<void> resolvePendingDisable() async {
    if (_disableInFlight != null) return;
    if (ConsentAuthority.egressFrozen) ConsentAuthority.egressFrozen = false;
    await _reconcile();
    // Astra H2.3: reconciliation (DISABLING crash recovery, the store/native
    // read) has COMPLETED, so admission may start judging the durable record.
    // Until this line the process-level latch denied everything, grants too. A
    // throw above leaves it unresolved (deny). An uncertain or restrictive
    // outcome is still denied by the record/freeze itself.
    _gate.markResolved();
    await _gate.refresh();
  }

  /// The persistent gate for this replica's owner. A DISABLING record with no
  /// transition running in this process means the process died mid-transition:
  /// local OFF is retried (never the revoke). Another owner's marker is left
  /// alone: it is neither applied to this owner nor discarded.
  Future<_Gate> _gateState() async {
    // An explicit enable writes the ON record and THEN the settings: judging
    // the pair in between would read "ON record, settings OFF" (or, with no
    // record yet, "settings ON") as a divergence and align it back down.
    if (ConsentAuthority.egressFrozen ||
        _disableInFlight != null ||
        _enableInFlight != null) {
      return _Gate.blocked;
    }
    return _reconcile();
  }

  Future<_Gate> _reconcile() async {
    final String owner;
    final EgressView view;
    try {
      owner = await _readReplicaOwnerUid() ?? '';
      view = await _gate.view(owner: owner);
    } catch (e) {
      ConsentAuthority.egressFrozen = true; // owner/state unknown: fail closed
      return _Gate.blocked;
    }
    if (view.uncertain) {
      ConsentAuthority.egressFrozen = true;
      return _Gate.blocked;
    }
    final rec = view.record;
    if (rec != null && rec.state == EgressState.disabling) {
      return await _completePendingDisable(rec) ? _Gate.off : _Gate.blocked;
    }
    try {
      final settings = await _settingsRepository.getSettings();
      final on = _cloudOn(settings);
      if (rec == null) {
        // Astra H2.2: an ABSENT record is NOT adopted as ON. Cloud only becomes
        // ON through an explicit enable ([enableCloud]), which writes ON to
        // every store. The effective cloud consent is the persisted consent AND
        // a durable ON record, so an upgraded user whose settings say ON but who
        // has no record sees Cloud as OFF until they re-enable it: the persisted
        // value is aligned DOWN (never up), exactly like the OFF-record case.
        if (on) {
          await _settingsRepository.saveSettings(settings.copyWith(
            cloudConsentState: ConsentState.declined,
            aiConsentState:
                _isAndroid() ? ConsentState.declined : settings.aiConsentState,
          ));
        }
        return _Gate.off;
      }
      if (rec.state == EgressState.on && !on) {
        // Settings are more restrictive than the record (a disable that never
        // became durable): align the record to OFF, never the other way.
        await _gate.writeRecord(rec.copyWith(
            state: EgressState.off,
            transitionGeneration: rec.transitionGeneration + 1));
        return _Gate.off;
      }
      if (rec.state == EgressState.off && on) {
        // The persistent OFF gate wins over a settings value that widened
        // without an explicit enable.
        await _settingsRepository.saveSettings(settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState:
              _isAndroid() ? ConsentState.declined : settings.aiConsentState,
        ));
      }
    } catch (_) {
      ConsentAuthority.egressFrozen = true;
      return _Gate.blocked;
    }
    return rec.state == EgressState.off ? _Gate.off : _Gate.open;
  }

  Future<bool> _completePendingDisable(CloudEgressRecord rec) async {
    ConsentAuthority.egressFrozen = true;
    _gate.advanceEpoch();
    try {
      final settings = await _settingsRepository.getSettings();
      if (_cloudOn(settings)) {
        await _settingsRepository.saveSettings(settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState:
              _isAndroid() ? ConsentState.declined : settings.aiConsentState,
        ));
      }
      await _clearAck();
      final freeze = DisableFreeze(
          owner: rec.ownerUid,
          transitionGeneration: rec.transitionGeneration,
          reservedVersion: rec.reservedVersion);
      // Never a revoke here. A consumed attempt without an outcome is UNCONFIRMED.
      if (await serverRevocation() == null ||
          (await serverRevocation())!.generation != freeze.transitionGeneration) {
        final attempted = await _attemptRecorded(freeze);
        await _recordRevocation(
            freeze,
            attempted
                ? ServerRevocation.unconfirmed
                : ServerRevocation.notAttempted);
      }
      if (!await _gate.commitOff(freeze)) return false;
      ConsentAuthority.egressFrozen = false;
      await _gate.refresh();
      return true;
    } catch (_) {
      return false; // not committed: stay frozen, fail closed
    }
  }

  Future<bool> _attemptRecorded(DisableFreeze freeze) async {
    try {
      final raw = await _revokeAttemptSlots.read();
      if (raw == null) return false;
      final m = jsonDecode(raw);
      return m is Map &&
          m['owner'] == freeze.owner &&
          m['transition_generation'] == freeze.transitionGeneration &&
          m['consumed'] == true;
    } catch (_) {
      return false;
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
    if (!_isIos() || !_isBackendConfigured()) return;
    if (await _gateState() != _Gate.open) return;
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
    if (await _gateState() != _Gate.open) return false;
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
    if (await _gateState() != _Gate.open) return;
    final tx = await _beginTx();
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
    // P4: a registration that completed after an account switch / transition is
    // not recorded as synced for the new state.
    if (!await _holds(tx)) return;
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
    if (await _gateState() != _Gate.open ||
        !(await _settingsRepository.getSettings()).cloudProcessingEnabled) {
      throw const CaptureBackendException('recovery_skipped_cloud_off');
    }
    final stored = await _storage.read(key: _secretKey);
    if (stored != null && stored.isNotEmpty && stored != rejectedSecret) {
      return stored;
    }
    final inFlight = _credentialRecovery;
    if (inFlight != null) return inFlight;

    final recovery = () async {
      final tx = await _beginTx();
      final fresh = await _backendClient.registerDevice(installId: installId);
      await _storage.write(key: _secretKey, value: fresh);
      // A new credential is a new server row: nothing was acknowledged for it.
      await _clearAck();
      // P4: no widening native config after an account switch / transition.
      if (!await _holds(tx)) return fresh;
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
        ownerUid: tx.owner ?? '',
        transitionGeneration: await _clientGeneration(tx.owner ?? ''),
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
