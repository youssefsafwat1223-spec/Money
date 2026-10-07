import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/entities/captured_message.dart';
import '../../../domain/services/captured_timestamp.dart';

/// A single bank message drained from the native share queue.
class SharedCapturedMessage {
  const SharedCapturedMessage({
    required this.text,
    required this.source,
    this.id,
    this.receivedAt,
    this.sender,
    this.senderName,
    this.senderId,
    this.locale,
    this.status,
    this.failureReason,
    this.receivedAtInferred,
    this.ownerUid,
    this.localOnly,
  });

  final String? id;
  final String text;
  final String? sender;
  final String? senderName;
  final String? senderId;
  final String? locale;
  final String? status;
  final String? failureReason;
  final CapturedMessageSource source;
  final DateTime? receivedAt;

  /// R9: true when the iOS Shortcut did not pass Date Received and the native
  /// layer inferred the receive time; null when the native layer did not report
  /// it (share extension, builds before R9).
  final bool? receivedAtInferred;

  /// CAP-6: the uid this item is stamped to (queue v3). The native peek returns
  /// only the active owner's items; CAP-5 still checks equality before import.
  final String? ownerUid;

  /// CAP-6 §4.3: bound by an explicit claim. Import it with the local
  /// deterministic parser only: no upload, no AI.
  final bool? localOnly;
}

/// The active capture owner `{uid, uidHash, generation}` held natively (§4.2).
class CaptureOwnerRecord {
  const CaptureOwnerRecord({
    required this.uid,
    required this.uidHash,
    required this.generation,
  });

  final String uid;
  final String uidHash;
  final int generation;

  static CaptureOwnerRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final uid = raw['uid'];
    final hash = raw['uidHash'];
    final generation = raw['generation'];
    if (uid is! String || hash is! String || generation is! int) return null;
    return CaptureOwnerRecord(uid: uid, uidHash: hash, generation: generation);
  }
}

/// What the "N bank messages were received while you were signed out" prompt
/// may show: a count and the senders (§4.3). [ids] is the snapshot the claim /
/// discard CAS is checked against; it is never displayed.
class UnboundCaptureSummary {
  const UnboundCaptureSummary({required this.ids, required this.senders});

  final List<String> ids;
  final List<String> senders;

  int get count => ids.length;
}

enum CaptureClaimStatus {
  /// The CAS held; [CaptureClaimResult.count] items were bound / discarded.
  applied,

  /// The items changed since the prompt snapshot. Nothing was mutated.
  stale,

  /// uid, owner record, generation, replica owner and session uid did not all
  /// agree. Nothing was mutated.
  ownerMismatch,
}

class CaptureClaimResult {
  const CaptureClaimResult(this.status, this.count);

  final CaptureClaimStatus status;
  final int count;

  bool get applied => status == CaptureClaimStatus.applied;
}

/// §4.4 destructive barrier for a Remove-data run.
class CaptureRemovalBarrier {
  const CaptureRemovalBarrier({
    required this.nonce,
    required this.uidHash,
    required this.startedAt,
  });

  final String nonce;
  final String uidHash;
  final String startedAt;

  static CaptureRemovalBarrier? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final nonce = raw['nonce'];
    final hash = raw['uidHash'];
    final startedAt = raw['startedAt'];
    if (nonce is! String || hash is! String || startedAt is! String) {
      return null;
    }
    return CaptureRemovalBarrier(
      nonce: nonce,
      uidHash: hash,
      startedAt: startedAt,
    );
  }
}

/// Why the native queue refused a write (v3). Nothing was written in any case.
enum CaptureQueueFailure {
  /// §4.5 count or byte quota exhausted. Nothing is evicted.
  quotaExceeded,

  /// A Remove-data barrier is in force (§4.4).
  removalInProgress,

  /// The active owner is not the owner the caller required.
  ownerChanged,

  /// Any other refusal (key, lock, unreadable queue, channel).
  unavailable,
}

/// Thrown by the owner / claim / barrier calls when the native layer refuses.
/// Callers MUST treat it as "the operation did not happen" and fail closed.
class CaptureQueueException implements Exception {
  const CaptureQueueException(this.code, [this.message]);

  /// `queue_unavailable`, `quota_exceeded`, `removal_in_progress`,
  /// `owner_changed`, `bad_args` or `channel_unavailable`.
  final String code;
  final String? message;

  CaptureQueueFailure get failure => _failureForCode(code);

  @override
  String toString() => 'CaptureQueueException($code)';
}

CaptureQueueFailure _failureForCode(String code) {
  switch (code) {
    case 'quota_exceeded':
      return CaptureQueueFailure.quotaExceeded;
    case 'removal_in_progress':
      return CaptureQueueFailure.removalInProgress;
    case 'owner_changed':
      return CaptureQueueFailure.ownerChanged;
    default:
      return CaptureQueueFailure.unavailable;
  }
}

class ApnsTokenInfo {
  const ApnsTokenInfo({
    required this.token,
    required this.environment,
  });

  final String token;
  final String environment;
}

class ApnsRegistrationFailure {
  const ApnsRegistrationFailure({
    required this.message,
    required this.occurredAt,
    this.domain,
    this.code,
  });

  final String message;
  final DateTime occurredAt;
  final String? domain;
  final int? code;
}

class CaptureNotificationRoute {
  const CaptureNotificationRoute({
    this.payloadId,
    this.transactionId,
    this.smartInboxItemId,
    this.notificationType,
    this.source,
    this.receivedAt,
    this.notificationLogId,
    this.action,
  });

  final String? payloadId;
  final String? transactionId;
  final String? smartInboxItemId;
  final String? notificationType;
  final String? source;
  final DateTime? receivedAt;
  final String? notificationLogId;

  /// Notification action button identifier; null for a plain banner tap.
  final String? action;
}

/// One notification lifecycle event recorded natively (iOS Shortcut local
/// fallback notifications) and drained here for Flutter to fold into the
/// local `notification_log_events` outbox — see
/// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
class NativeNotificationLogEvent {
  const NativeNotificationLogEvent({
    required this.notificationLogId,
    required this.eventType,
    required this.channel,
    required this.notificationType,
    this.relatedEntityType,
    this.relatedEntityId,
    this.errorCode,
    this.errorReason,
    this.occurredAt,
  });

  final String notificationLogId;
  final String eventType;
  final String channel;
  final String notificationType;
  final String? relatedEntityType;
  final String? relatedEntityId;
  final String? errorCode;
  final String? errorReason;
  final DateTime? occurredAt;
}

/// MALI-013 — honest capture capabilities for Android (share always; SMS is
/// opt-in and two-key: declared in the build AND granted AND enabled). The old
/// `hasSmsPermission()` conflated notification and SMS permission; these fields
/// keep them strictly separate.
class CaptureCapabilities {
  const CaptureCapabilities({
    this.supportsShareCapture = true,
    this.receiveSmsDeclared = false,
    this.hasReceiveSmsPermission = false,
    this.canUseAutomaticSmsCapture = false,
    this.isAutomaticSmsCaptureEnabled = false,
    this.hasNotificationPermission = false,
  });

  /// "Share to Mali" — always available, needs no permission.
  final bool supportsShareCapture;

  /// Whether RECEIVE_SMS is declared in this build's manifest at all
  /// (false in a Play-safe, share-only build → automatic capture "not
  /// included in this build").
  final bool receiveSmsDeclared;
  final bool hasReceiveSmsPermission;

  /// The build declares + the OS grants RECEIVE_SMS (auto capture is possible).
  final bool canUseAutomaticSmsCapture;

  /// The user has turned automatic capture on AND it is permitted.
  final bool isAutomaticSmsCaptureEnabled;

  /// Notification permission — NEVER conflated with SMS.
  final bool hasNotificationPermission;

  factory CaptureCapabilities.fromJson(Map<String, dynamic> json) {
    return CaptureCapabilities(
      supportsShareCapture: json['supportsShareCapture'] as bool? ?? true,
      receiveSmsDeclared: json['receiveSmsDeclared'] as bool? ?? false,
      hasReceiveSmsPermission:
          json['hasReceiveSmsPermission'] as bool? ?? false,
      canUseAutomaticSmsCapture:
          json['canUseAutomaticSmsCapture'] as bool? ?? false,
      isAutomaticSmsCaptureEnabled:
          json['isAutomaticSmsCaptureEnabled'] as bool? ?? false,
      hasNotificationPermission:
          json['hasNotificationPermission'] as bool? ?? false,
    );
  }
}

/// Outcome of the Android runtime RECEIVE_SMS request.
///
/// `denied` and `permanentlyDenied` are separated deliberately: only the first
/// can be retried with a dialog. The second needs the Settings route, and
/// showing a button that silently does nothing is worse than showing none.
enum SmsPermissionStatus {
  /// Build does not declare RECEIVE_SMS — the automatic path is not in this build.
  unavailable,
  granted,

  /// Denied, but the system will still show the dialog if asked again.
  denied,

  /// "Don't ask again", or the OS blocks the prompt. Only Settings can change it.
  permanentlyDenied,

  /// A request is already in flight; never queue a second dialog.
  inProgress,
}

/// The full answer to a permission request: the outcome plus the resulting
/// capability state, so callers never infer consent from the outcome alone.
///
/// `granted` and `enabled` are separate on purpose — a granted permission is
/// NOT consent to read. The user opt-in is its own stored key.
class SmsPermissionResult {
  const SmsPermissionResult({
    required this.status,
    required this.declared,
    required this.granted,
    required this.enabled,
  });

  final SmsPermissionStatus status;
  final bool declared;
  final bool granted;
  final bool enabled;

  static const SmsPermissionResult unsupported = SmsPermissionResult(
    status: SmsPermissionStatus.unavailable,
    declared: false,
    granted: false,
    enabled: false,
  );

  factory SmsPermissionResult.fromJson(Map<String, dynamic> json) {
    return SmsPermissionResult(
      status: switch (json['status'] as String?) {
        'granted' => SmsPermissionStatus.granted,
        'denied' => SmsPermissionStatus.denied,
        'permanently_denied' => SmsPermissionStatus.permanentlyDenied,
        'in_progress' => SmsPermissionStatus.inProgress,
        _ => SmsPermissionStatus.unavailable,
      },
      declared: json['declared'] as bool? ?? false,
      granted: json['granted'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? false,
    );
  }
}

class NativeCaptureBridge {
  NativeCaptureBridge._();

  static const MethodChannel _channel =
      MethodChannel('money_companion/native_capture');
  static Future<void> Function()? _pendingMessagesHandler;
  static Future<void> Function(ApnsTokenInfo token)? _apnsTokenHandler;
  static Future<void> Function(ApnsRegistrationFailure failure)?
      _apnsFailureHandler;
  static Future<void> Function()? _notificationRouteHandler;

  static void setPendingMessagesHandler(
    Future<void> Function()? handler,
  ) {
    _pendingMessagesHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsTokenUpdatedHandler(
    Future<void> Function(ApnsTokenInfo token)? handler,
  ) {
    _apnsTokenHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsRegistrationFailedHandler(
    Future<void> Function(ApnsRegistrationFailure failure)? handler,
  ) {
    _apnsFailureHandler = handler;
    _configureMethodHandler();
  }

  static void setNotificationRouteHandler(
    Future<void> Function()? handler,
  ) {
    _notificationRouteHandler = handler;
    _configureMethodHandler();
  }

  static void _configureMethodHandler() {
    if (_pendingMessagesHandler == null &&
        _apnsTokenHandler == null &&
        _apnsFailureHandler == null &&
        _notificationRouteHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingSharedMessagesAvailable') {
        await _pendingMessagesHandler?.call();
        return null;
      }
      if (call.method == 'apnsTokenUpdated') {
        final token = _tokenInfoFrom(call.arguments);
        if (token != null) {
          await _apnsTokenHandler?.call(token);
        }
        return null;
      }
      if (call.method == 'apnsRegistrationFailed') {
        final failure = _apnsFailureFrom(call.arguments);
        if (failure != null) {
          await _apnsFailureHandler?.call(failure);
        }
        return null;
      }
      if (call.method == 'pendingNotificationRouteAvailable') {
        await _notificationRouteHandler?.call();
        return null;
      }
      throw MissingPluginException('Unknown native capture callback');
    });
  }

  /// MALI-013 — honest Android capture capabilities. Replaces the old
  /// `hasSmsPermission()` which mislabelled the NOTIFICATION permission as SMS.
  /// On non-Android platforms only share capture applies.
  static Future<CaptureCapabilities> captureCapabilities() async {
    if (!Platform.isAndroid) {
      return const CaptureCapabilities(supportsShareCapture: true);
    }
    try {
      final raw = await _channel.invokeMethod<String>('captureCapabilities');
      if (raw == null) {
        return const CaptureCapabilities(supportsShareCapture: true);
      }
      return CaptureCapabilities.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const CaptureCapabilities(supportsShareCapture: true);
    }
  }

  /// Turn automatic SMS capture on/off (persisted natively). Returns the
  /// effective state — false unless RECEIVE_SMS is granted, whatever was asked.
  static Future<bool> setAutomaticSmsCaptureEnabled(bool enabled) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>(
          'setAutomaticSmsCaptureEnabled',
          {'enabled': enabled},
        ) ??
        false;
  }

  /// Ask Android for RECEIVE_SMS.
  ///
  /// The caller MUST have shown the prominent disclosure immediately before
  /// this — Play requires it, and the native side deliberately shows no UI of
  /// its own so the disclosure cannot be skipped by calling straight through.
  ///
  /// Never throws: a platform error resolves to `unsupported` so a failure here
  /// can only ever leave automatic capture off, never on.
  static Future<SmsPermissionResult> requestReceiveSmsPermission() async {
    if (!Platform.isAndroid) return SmsPermissionResult.unsupported;
    try {
      final raw =
          await _channel.invokeMethod<String>('requestReceiveSmsPermission');
      if (raw == null) return SmsPermissionResult.unsupported;
      return SmsPermissionResult.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on PlatformException {
      return SmsPermissionResult.unsupported;
    } on MissingPluginException {
      return SmsPermissionResult.unsupported;
    }
  }

  static Future<void> openAppSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('openAppSettings');
  }

  static Future<bool> hasPendingSharedMessages() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasPendingSharedMessages') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> setBackendConfig({
    required bool cloudProcessingEnabled,
    required String installId,
    required String backendUrl,
    required String anonKey,
    bool aiConsentGranted = false,
    String? deviceSecret,

    /// Mirror of the server capability `capture_contract_v2`. Default false:
    /// the App Intent keeps uploading on the legacy contract.
    bool captureContractV2 = false,
  }) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setCaptureBackendConfig', {
        'cloudProcessingEnabled': cloudProcessingEnabled,
        'installId': installId,
        'deviceSecret': deviceSecret,
        'backendUrl': backendUrl,
        'anonKey': anonKey,
        'aiConsentGranted': aiConsentGranted,
        'captureContractV2': captureContractV2,
      });
    } on MissingPluginException {
      return;
    }
  }

  // ── CAP-6 queue v3: owner record, unbound claim, Remove-data barrier ───────
  //
  // Every call below runs natively under the queue flock. They throw
  // [CaptureQueueException] when the native layer refuses and do nothing on
  // platforms without the iOS queue. The account-scoped drain/import that uses
  // them (WP-3 / CAP-5) is NOT implemented here.

  static bool get _hasNativeQueue => debugTreatHostAsNative || Platform.isIOS;

  static Future<T?> _queueCall<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw CaptureQueueException(e.code, e.message);
    } on MissingPluginException {
      throw const CaptureQueueException('channel_unavailable');
    }
  }

  /// Publishes [uid] as the active capture owner. Call ONLY after the replica is
  /// admitted AND `link_capture_device(consent)` succeeded (§4.2). Idempotent for
  /// the current owner; refused (`removal_in_progress`) during a barrier.
  static Future<CaptureOwnerRecord?> publishCaptureOwner(String uid) async {
    if (!_hasNativeQueue) return null;
    return CaptureOwnerRecord.tryParse(
      await _queueCall<Object?>('publishCaptureOwner', {'uid': uid}),
    );
  }

  /// Clears the active owner (sign-out, or the start of an account transition).
  /// [clearHint] true at a transition: captures made during it are unbound with
  /// no hint. At a plain sign-out the hint stays so the same uid can recover.
  static Future<void> clearCaptureOwner({required bool clearHint}) async {
    if (!_hasNativeQueue) return;
    await _queueCall<Object?>('clearCaptureOwner', {'clearHint': clearHint});
  }

  static Future<CaptureOwnerRecord?> getCaptureOwner() async {
    if (!_hasNativeQueue) return null;
    return CaptureOwnerRecord.tryParse(
      await _queueCall<Object?>('getCaptureOwner'),
    );
  }

  /// Advisory per-owner consent mirror, read by the App Intent for the stamped
  /// owner only (§4.6). Written by the consent flow (WP-6).
  static Future<void> setCaptureConsentMirror({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    if (!_hasNativeQueue) return;
    await _queueCall<Object?>('setCaptureConsentMirror', {
      'uid': uid,
      'cloud': cloud,
      'ai': ai,
      'version': version,
    });
  }

  /// The unbound items hinted to [uid]; empty when there are none, or when the
  /// hint is another uid's or absent.
  static Future<UnboundCaptureSummary> unboundCaptureSummary(String uid) async {
    if (!_hasNativeQueue) {
      return const UnboundCaptureSummary(ids: [], senders: []);
    }
    final raw =
        await _queueCall<Object?>('unboundCaptureSummary', {'uid': uid});
    if (raw is! Map) return const UnboundCaptureSummary(ids: [], senders: []);
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : const <String>[];
    return UnboundCaptureSummary(
      ids: strings(raw['ids']),
      senders: strings(raw['senders']),
    );
  }

  /// "Add them to my account" (§4.3): the native CAS. [uid], [replicaOwnerUid]
  /// and [sessionUid] must all be equal and [generation] the current owner
  /// generation, else nothing is mutated.
  static Future<CaptureClaimResult> claimUnboundCaptures({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      _claimCall('claimUnboundCaptures', uid, generation, replicaOwnerUid,
          sessionUid, ids);

  /// "Discard them": the same CAS, then deletes the items.
  static Future<CaptureClaimResult> discardUnboundCaptures({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      _claimCall('discardUnboundCaptures', uid, generation, replicaOwnerUid,
          sessionUid, ids);

  static Future<CaptureClaimResult> _claimCall(
    String method,
    String uid,
    int generation,
    String replicaOwnerUid,
    String sessionUid,
    List<String> ids,
  ) async {
    if (!_hasNativeQueue) {
      return const CaptureClaimResult(CaptureClaimStatus.stale, 0);
    }
    final raw = await _queueCall<Object?>(method, {
      'uid': uid,
      'generation': generation,
      'replicaOwnerUid': replicaOwnerUid,
      'sessionUid': sessionUid,
      'ids': ids,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final count = map['count'] is int ? map['count'] as int : 0;
    switch (map['status']) {
      case 'applied':
        return CaptureClaimResult(CaptureClaimStatus.applied, count);
      case 'owner_mismatch':
        return const CaptureClaimResult(CaptureClaimStatus.ownerMismatch, 0);
      default:
        // Unknown or missing status: treat as "did not happen".
        return const CaptureClaimResult(CaptureClaimStatus.stale, 0);
    }
  }

  /// §4.7: the adopted replica's verdict on items migrated from the v2 queue.
  /// [consumedIds] (receipt `capture_payload:<id>` or tx.id == capture_id) are
  /// removed; [suspectedIds] (fingerprint match) are annotated for review only.
  /// Returns how many items were removed.
  static Future<int> resolveLegacyCaptureItems({
    List<String> consumedIds = const [],
    List<String> suspectedIds = const [],
  }) async {
    if (!_hasNativeQueue) return 0;
    final removed = await _queueCall<int>('resolveLegacyCaptureItems', {
      'consumedIds': consumedIds,
      'suspectedIds': suspectedIds,
    });
    return removed ?? 0;
  }

  /// Remove-data step 1 (§4.4): persists the barrier and clears the owner record
  /// if it is [uid]'s. Idempotent for the same uid (a resumed removal).
  static Future<CaptureRemovalBarrier?> beginCaptureRemoval(String uid) async {
    if (!_hasNativeQueue) return null;
    return CaptureRemovalBarrier.tryParse(
      await _queueCall<Object?>('beginCaptureRemoval', {'uid': uid}),
    );
  }

  /// A barrier left by a removal that crashed; a launch that finds one resumes
  /// the removal from the replica teardown step.
  static Future<CaptureRemovalBarrier?> getCaptureRemovalBarrier() async {
    if (!_hasNativeQueue) return null;
    return CaptureRemovalBarrier.tryParse(
      await _queueCall<Object?>('getCaptureRemovalBarrier'),
    );
  }

  /// Remove-data step 5 (§4.4): the final sweep; clears the barrier. Returns how
  /// many queue items were deleted.
  static Future<int> finishCaptureRemoval(String uid) async {
    if (!_hasNativeQueue) return 0;
    return await _queueCall<int>('finishCaptureRemoval', {'uid': uid}) ?? 0;
  }

  static Future<ApnsTokenInfo?> registerForRemoteNotifications() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel
          .invokeMethod<Object?>('registerForRemoteNotifications');
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsTokenInfo?> getApnsToken() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod<Object?>('getApnsToken');
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsRegistrationFailure?> getApnsRegistrationFailure() async {
    if (!Platform.isIOS) return null;
    try {
      final result =
          await _channel.invokeMethod<Object?>('getApnsRegistrationFailure');
      return _apnsFailureFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> consumePendingSharedInput() async {
    if (!Platform.isIOS) {
      return null;
    }
    final text =
        await _channel.invokeMethod<String>('consumePendingSharedInput');
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  /// Returns the native capture queue WITHOUT deleting it (per-item lease,
  /// MALI-012). Call [acknowledgeSharedMessage] for each message only after
  /// its local import committed — a kill mid-drain re-delivers exactly the
  /// unacknowledged remainder instead of losing the whole batch.
  static Future<List<SharedCapturedMessage>> peekPendingSharedMessages() async {
    return _fetchSharedMessages('peekPendingSharedMessages');
  }

  /// Positively acknowledges (removes) one leased message from the native
  /// queue after its import committed. Returns false when the native layer
  /// doesn't support acks or the id was already gone.
  static Future<bool> acknowledgeSharedMessage(String payloadId) async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;
    try {
      final removed = await _channel.invokeMethod<bool>(
        'acknowledgeSharedMessage',
        {'payloadId': payloadId},
      );
      return removed ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// MALI-054n: purges ALL user-owned native capture residue (the App Group
  /// pending-message queue + its metadata, notification routes, and notification
  /// log events on iOS; the durable SharedPreferences queue on Android) so one
  /// identity's captured bank messages can never be imported under another.
  /// Install-level config (device secret, backend URL/keys, install id, APNs
  /// token) is deliberately preserved.
  ///
  /// Returns true when the purge is confirmed (or there is nothing native to
  /// purge on this platform). Returns false when it could NOT be confirmed
  /// (channel/plugin error) — callers MUST treat false as "residue may remain"
  /// and fail closed at user-admission boundaries.
  /// How long to keep waiting for the native channel during startup.
  ///
  /// Under the UIScene lifecycle the capture channel cannot be registered in
  /// `didFinishLaunchingWithOptions` — there is no FlutterViewController yet, so
  /// `rootFlutterViewController()` returns nil and registration is deferred to
  /// `applicationDidBecomeActive`. Dart bootstrap runs inside that window, so
  /// the first call here can legitimately find no handler. That is "not ready",
  /// NOT "failed", and the two must not be confused: the ownership transition
  /// treats a failed purge as a reason to withhold admission, and treating a
  /// startup race as a permanent failure is what stranded the owner marker.
  ///
  /// Bounded on purpose. Six attempts at 150ms is ~0.9s of patience, which
  /// comfortably covers scene attachment without turning a genuinely absent
  /// handler (a build with the channel removed) into an indefinite hang.
  @visibleForTesting
  static const int purgeChannelRetries = 6;
  @visibleForTesting
  static const Duration purgeChannelRetryDelay = Duration(milliseconds: 150);

  /// Test seam: lets a test drive the retry loop without real delays.
  @visibleForTesting
  static Future<void> Function(Duration)? debugDelayOverride;

  /// Test seam: the retry only exists on the platforms that have the channel,
  /// and a host test runs on neither. Without this the loop is unreachable.
  @visibleForTesting
  static bool debugTreatHostAsNative = false;

  static Future<bool> purgeAllCaptureState() async {
    if (!debugTreatHostAsNative && !Platform.isIOS && !Platform.isAndroid) {
      return true;
    }
    for (var attempt = 0; ; attempt++) {
      try {
        final ok = await _channel.invokeMethod<bool>('purgeAllCaptureState');
        return ok ?? false;
      } on MissingPluginException {
        // Channel not registered YET. Retry — but never forever.
        if (attempt >= purgeChannelRetries - 1) return false;
        final delay = debugDelayOverride;
        if (delay != null) {
          await delay(purgeChannelRetryDelay);
        } else {
          await Future<void>.delayed(purgeChannelRetryDelay);
        }
      } on PlatformException {
        // A real native failure. The handler ran and refused; retrying would
        // just repeat it, and pretending it is a startup race would hide it.
        return false;
      }
    }
  }

  static Future<List<SharedCapturedMessage>> _fetchSharedMessages(
    String method,
  ) async {
    if (!debugTreatHostAsNative && !Platform.isIOS && !Platform.isAndroid) {
      return const [];
    }
    final String? json;
    try {
      json = await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      // An older native layer without the peek/ack handlers reports
      // notImplemented as a PlatformException — treat as empty; the caller
      // falls back to the destructive consume path.
      return const [];
    }
    if (json == null || json.trim().isEmpty) {
      return const [];
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    final messages = <SharedCapturedMessage>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      final text = (item['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        continue;
      }
      final rawId = (item['id'] as String?)?.trim();
      final rawSender = (item['sender'] as String?)?.trim();
      final rawSenderName = (item['senderName'] as String?)?.trim();
      final rawSenderId = (item['senderId'] as String?)?.trim();
      final rawSource = (item['source'] as String?)?.trim();
      final rawReceivedAt = (item['receivedAt'] as String?)?.trim();
      final rawLocale = (item['locale'] as String?)?.trim();
      final rawStatus = (item['status'] as String?)?.trim();
      final rawFailureReason = (item['failureReason'] as String?)?.trim();
      final rawInferred = item['receivedAtInferred'];
      final rawOwnerUid = (item['ownerUid'] as String?)?.trim();
      final rawLocalOnly = item['localOnly'];
      final sender = _firstNonEmpty([rawSenderId, rawSender, rawSenderName]);
      messages.add(
        SharedCapturedMessage(
          id: _emptyToNull(rawId),
          text: text,
          source: Platform.isIOS
              ? _iosCapturedSource(rawSource)
              : CapturedMessageSource.androidShare,
          sender: sender,
          senderName: _emptyToNull(rawSenderName),
          senderId: _emptyToNull(rawSenderId),
          locale: _emptyToNull(rawLocale),
          status: _emptyToNull(rawStatus),
          failureReason: _emptyToNull(rawFailureReason),
          receivedAtInferred: rawInferred is bool ? rawInferred : null,
          ownerUid: _emptyToNull(rawOwnerUid),
          localOnly: rawLocalOnly is bool ? rawLocalOnly : null,
          // MALI-068n §11 — native epoch is authoritative; the ISO string is a
          // legacy fallback; unknown → null (never `now`).
          receivedAt: resolveCapturedReceivedAt(
            epochMs: item['receivedAtEpochMs'] as int?,
            isoString: rawReceivedAt,
          ),
        ),
      );
    }
    return messages;
  }

  /// Returns a drained message to the native queue after processing failed —
  /// the drain is destructive, so this is what keeps a failing message from
  /// being lost. The native side skips its host wake-up notification to avoid
  /// an immediate drain → fail → re-enqueue loop; the message is retried on
  /// the next resume/launch drain instead. Best-effort: on Android (no handler
  /// yet) or bridge failure the message is dropped exactly as before this fix.
  static Future<bool> reEnqueueSharedMessage(
    SharedCapturedMessage message,
  ) async =>
      await reEnqueueSharedMessageChecked(message) == null;

  /// [reEnqueueSharedMessage] that says WHY a refused write was refused (null =
  /// re-enqueued). The item goes back under its original [message.ownerUid] or
  /// not at all (`ownerChanged`); `quotaExceeded` and `removalInProgress` leave
  /// the queue untouched.
  static Future<CaptureQueueFailure?> reEnqueueSharedMessageChecked(
    SharedCapturedMessage message,
  ) async {
    if (!Platform.isIOS) return CaptureQueueFailure.unavailable;
    try {
      await _channel.invokeMethod<void>('reEnqueueSharedMessage', {
        'text': message.text,
        'sender': message.sender,
        'senderName': message.senderName,
        'senderId': message.senderId,
        'source': message.source == CapturedMessageSource.iosShortcut
            ? 'ios_shortcut'
            : message.source == CapturedMessageSource.iosShare
                ? 'ios_share'
                : null,
        'receivedAt': message.receivedAt?.toIso8601String(),
        'locale': message.locale,
        'status': message.status,
        'failureReason': message.failureReason,
        'payloadId': message.id,
        'receivedAtInferred': message.receivedAtInferred,
        'ownerUid': message.ownerUid,
        'localOnly': message.localOnly,
      });
      return null;
    } on PlatformException catch (e) {
      return _failureForCode(e.code);
    } on MissingPluginException {
      return CaptureQueueFailure.unavailable;
    }
  }

  static Future<List<CaptureNotificationRoute>>
      consumePendingNotificationRoutes() async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationRoutes');
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map)
          CaptureNotificationRoute(
            payloadId: _emptyToNull(_asString(item['payloadId'])),
            transactionId: _emptyToNull(_asString(item['transactionId'])),
            smartInboxItemId: _emptyToNull(_asString(item['smartInboxItemId'])),
            notificationType: _emptyToNull(_asString(item['notificationType'])),
            source: _emptyToNull(_asString(item['source'])),
            receivedAt: resolveCapturedReceivedAt(
              epochMs: item['receivedAtEpochMs'] as int?,
              isoString: item['receivedAt'] is String
                  ? item['receivedAt'] as String
                  : null,
            ),
            notificationLogId:
                _emptyToNull(_asString(item['notificationLogId'])),
            action: _emptyToNull(_asString(item['action'])),
          ),
    ];
  }

  /// Drains the iOS Shortcut extension's local notification-scheduling
  /// events (created/sent/failed) recorded via SharedCaptureStore. Returns
  /// an empty list on Android or when nothing is pending.
  static Future<List<NativeNotificationLogEvent>>
      consumePendingNotificationLogEvents() async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationLogEvents');
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map &&
            item['notificationLogId'] is String &&
            item['eventType'] is String &&
            item['channel'] is String &&
            item['notificationType'] is String)
          NativeNotificationLogEvent(
            notificationLogId: item['notificationLogId'] as String,
            eventType: item['eventType'] as String,
            channel: item['channel'] as String,
            notificationType: item['notificationType'] as String,
            relatedEntityType:
                _emptyToNull(_asString(item['relatedEntityType'])),
            relatedEntityId: _emptyToNull(_asString(item['relatedEntityId'])),
            errorCode: _emptyToNull(_asString(item['errorCode'])),
            errorReason: _emptyToNull(_asString(item['errorReason'])),
            occurredAt: item['occurredAt'] is String
                ? DateTime.tryParse(item['occurredAt'] as String)?.toUtc()
                : null,
          ),
    ];
  }

  static CapturedMessageSource _iosCapturedSource(String? source) {
    return source == 'ios_shortcut' || source == 'shortcut'
        ? CapturedMessageSource.iosShortcut
        : CapturedMessageSource.iosShare;
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final clean = _emptyToNull(value);
      if (clean != null) return clean;
    }
    return null;
  }

  static String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Like a `value as String?` cast, but tolerant of an unexpected JSON type
  /// (e.g. a number) instead of throwing — one malformed field in a decoded
  /// native payload must not take down the whole list comprehension it's
  /// part of. See notification_log_service_test.dart / requirement 9 of the
  /// Phase 1 notification-tracking hardening pass.
  static String? _asString(Object? value) => value is String ? value : null;

  static ApnsTokenInfo? _tokenInfoFrom(Object? value) {
    if (value is! Map) return null;
    final token = _emptyToNull(value['token'] as String?);
    final environment = _emptyToNull(value['environment'] as String?);
    if (token == null || environment == null) return null;
    return ApnsTokenInfo(token: token, environment: environment);
  }

  static ApnsRegistrationFailure? _apnsFailureFrom(Object? value) {
    if (value is! Map) return null;
    final message = _emptyToNull(value['message'] as String?);
    final occurredAtRaw = _emptyToNull(value['occurredAt'] as String?);
    final occurredAt = occurredAtRaw == null
        ? null
        : DateTime.tryParse(occurredAtRaw)?.toUtc();
    if (message == null || occurredAt == null) return null;
    return ApnsRegistrationFailure(
      message: message,
      occurredAt: occurredAt,
      domain: _emptyToNull(value['domain'] as String?),
      code: value['code'] is int ? value['code'] as int : null,
    );
  }
}

/// COUPONS Phase 5 — a shared merchant link, staged natively.
///
/// Deliberately NOT a capture. It arrives through its own channel method from
/// its own store, so a shopping URL is never one missed switch case away from
/// the SMS parser.
class OfferIntent {
  const OfferIntent({
    required this.id,
    required this.url,
    required this.host,
    required this.receivedAt,
  });

  final String id;

  /// Already sanitized natively: scheme, host and path only. The query and
  /// fragment were destroyed before this was written to disk.
  final String url;
  final String host;
  final String receivedAt;

  static OfferIntent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final host = raw['host'];
    if (url is! String || host is! String || url.isEmpty || host.isEmpty) {
      return null;
    }
    // Refuse anything still carrying a query or fragment even though the native
    // side strips them. This is the last checkpoint before a URL enters the app,
    // and the cost of the check is nothing.
    if (url.contains('?') || url.contains('#') || !url.startsWith('https://')) {
      return null;
    }
    return OfferIntent(
      id: raw['id'] as String? ?? '',
      url: url,
      host: host,
      receivedAt: raw['receivedAt'] as String? ?? '',
    );
  }
}

/// Drains merchant links the user shared into Qirsh.
///
/// Returns empty on any failure, including a platform without the method — an
/// offer intent has no durability requirement. The worst case for losing one is
/// that the user taps the link again, whereas a lost bank message is a missing
/// transaction, which is why the two paths have different guarantees.
Future<List<OfferIntent>> drainOfferIntents() async {
  try {
    final raw = await const MethodChannel('money_companion/native_capture')
        .invokeMethod<String>('drainOfferIntents');
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .map(OfferIntent.tryParse)
        .whereType<OfferIntent>()
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}
