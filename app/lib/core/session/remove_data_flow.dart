import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/db/replica_store.dart';
import '../security/secure_storage_options.dart';
import 'account_scope.dart';

/// WP-3b — the Dart side of the manifest §4.4 "Remove data from this device"
/// barrier.
///
/// The native queue (App Group, flock) is CAP-6a's; this file reaches it only
/// through [RemoveDataBarrier], backed by the narrow `CaptureQueueBridge`
/// (capture_queue.dart) whose methods are the `NativeCaptureBridge` statics
/// `beginCaptureRemoval(uid)`, `getCaptureRemovalBarrier()` and
/// `finishCaptureRemoval(uid)`.
abstract class RemoveDataBarrier {
  /// Step 1 (native, under flock): write the destructive transition and clear the
  /// owner record when it is [uid]. Idempotent.
  Future<void> begin(String uid);

  /// The uid of a native barrier that is still set (a crash mid-removal), or null.
  Future<String?> pendingUid();

  /// Step 5 (native, under flock): final sweep of everything owned by or hinted
  /// to [uid] or created at/after the barrier, then clear the barrier. MUST throw
  /// when the sweep cannot be confirmed.
  Future<void> finish(String uid);
}

/// "The consent question was shown" marker, per uid on this device (secure
/// storage, `qirsh.`-prefixed). Remove data deletes it so the next admission into
/// a fresh replica asks again (§4.6: a new device re-asks).
const String kConsentAskedKeyPrefix = 'qirsh.consent_asked.v1.';

/// The removal could not be completed. The barrier record is KEPT, so the next
/// launch (or the next admission) resumes it; nothing has been reported as done.
class RemoveDataIncompleteException implements Exception {
  const RemoveDataIncompleteException();
  @override
  String toString() => 'RemoveDataIncompleteException: removal not completed.';
}

/// Fixed order of the removal steps; a test hook may stop the process after any
/// of them.
const List<String> kRemovalSteps = [
  'afterBarrierRecord',
  'afterNativeBegin',
  'afterOwnerCleared',
  'afterScopeStopped',
  'afterReplicaRemoved',
  'afterServerCleanup',
  'afterFinalSweep',
];

class RemoveDataFlow {
  RemoveDataFlow({
    required ReplicaStore store,
    required AccountScopeControl scope,
    required RemoveDataBarrier barrier,
    required Future<void> Function() clearOwnerMarker,
    Future<void> Function()? serverCleanupBestEffort,
    FlutterSecureStorage? storage,
    Future<void> Function(String step)? debugAfterStep,
  })  : _store = store,
        _scope = scope,
        _barrier = barrier,
        _clearOwnerMarker = clearOwnerMarker,
        _serverCleanup = serverCleanupBestEffort,
        _storage = storage ?? SecureStorageOptions.storage,
        _debugStep = debugAfterStep;

  /// The persisted barrier. `qirsh.`-prefixed so the session secure-storage wipe
  /// preserves it (a removal in progress must survive a crash AND a wipe).
  static const String barrierKey = 'qirsh.removal_barrier.v1';

  final ReplicaStore _store;
  final AccountScopeControl _scope;
  final RemoveDataBarrier _barrier;
  final Future<void> Function() _clearOwnerMarker;
  final Future<void> Function()? _serverCleanup;
  final FlutterSecureStorage _storage;
  final Future<void> Function(String step)? _debugStep;

  Future<void> _step(String name) async => _debugStep?.call(name);

  /// True while a removal has started and not finished.
  Future<bool> hasPending() async => (await _readRecord()) != null;

  /// Removes [uid]'s replica and everything native that belongs to it (§4.4).
  /// Throws [RemoveDataIncompleteException] (barrier kept) when a step could not
  /// be confirmed; returns normally only after step 6's precondition holds.
  Future<void> remove(String uid) async {
    final hash = await _store.uidHash(uid);
    final record = _Record(uid: uid, uidHash: hash);
    // Step 1. The durable record goes first: from here a crash is resumed, and
    // the native barrier is (re)written idempotently on resume.
    await _storage.write(key: barrierKey, value: jsonEncode(record.toJson()));
    try {
      await _step('afterBarrierRecord');
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
    await _run(record);
  }

  /// Launch / admission: finishes a removal a crash left behind. Returns true
  /// when none is pending or it has now completed; false when it could not be
  /// completed (the caller must not admit anyone yet).
  Future<bool> resumePending() async {
    var record = await _readRecord();
    if (record == null) {
      // A native barrier with no Dart record (crash between the two writes).
      final uid = await _barrier.pendingUid();
      if (uid == null) return true;
      record = _Record(uid: uid, uidHash: await _store.uidHash(uid));
    }
    try {
      await _run(record);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run(_Record r) async {
    try {
      await _barrier.begin(r.uid);
      await _step('afterNativeBegin');
      await _clearOwnerMarker();
      await _step('afterOwnerCleared');
      // Step 2.
      await _scope.detach();
      await _step('afterScopeStopped');
      // Step 3.
      await _store.remove(r.uid);
      await _storage.delete(key: '$kConsentAskedKeyPrefix${r.uid}');
      await _step('afterReplicaRemoved');
      // Step 4, best effort.
      final cleanup = _serverCleanup;
      if (cleanup != null) {
        try {
          await cleanup().timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      await _step('afterServerCleanup');
      // Step 5.
      await _barrier.finish(r.uid);
      await _step('afterFinalSweep');
      await _storage.delete(key: barrierKey);
    } on RemoveDataIncompleteException {
      rethrow;
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
  }

  Future<_Record?> _readRecord() async {
    final raw = await _storage.read(key: barrierKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return _Record.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}

class _Record {
  const _Record({required this.uid, required this.uidHash});
  final String uid;
  final String uidHash;

  Map<String, Object?> toJson() => {'uid': uid, 'uidHash': uidHash};

  static _Record fromJson(Map<String, Object?> j) =>
      _Record(uid: j['uid']! as String, uidHash: j['uidHash']! as String);
}
