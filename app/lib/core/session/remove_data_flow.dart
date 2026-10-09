import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/db/replica_store.dart';
import '../security/secure_storage_options.dart';
import 'account_scope.dart';
import 'admission_authority.dart';

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
  /// Null does NOT mean "no barrier": the native record may hold only an HMAC of
  /// the uid, so a set barrier can have an unknown uid. See [nativeBarrierPresent].
  Future<String?> pendingUid();

  /// F2: true when a native barrier is set, whether or not its uid is known.
  /// "Barrier exists, uid unknown" blocks admission; it is never "nothing
  /// pending", and no uid is invented from the hash.
  Future<bool> nativeBarrierPresent();

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
  'afterRevocationRecorded',
];

class RemoveDataFlow {
  RemoveDataFlow({
    required ReplicaStore store,
    required AccountScopeControl scope,
    required RemoveDataBarrier barrier,
    required Future<void> Function(String uid) clearOwnerMarker,
    Future<void> Function()? serverCleanupBestEffort,
    FlutterSecureStorage? storage,
    Future<void> Function(String step)? debugAfterStep,
    Future<void> Function()? quiesce,
    Future<void> Function(String uid)? invalidateAdmissionGeneration,
  })  : _store = store,
        _scope = scope,
        _barrier = barrier,
        _clearOwnerMarker = clearOwnerMarker,
        _serverCleanup = serverCleanupBestEffort,
        _storage = storage ?? SecureStorageOptions.storage,
        _debugStep = debugAfterStep,
        _quiesce = quiesce,
        _invalidateAdmissionGeneration = invalidateAdmissionGeneration;

  /// The persisted barrier. `qirsh.`-prefixed so the session secure-storage wipe
  /// preserves it (a removal in progress must survive a crash AND a wipe).
  static const String barrierKey = 'qirsh.removal_barrier.v1';

  /// F2 — the durable `removed_requires_explicit_auth` state: a JSON list of the
  /// uids whose Remove data completed. `qirsh.`-prefixed so a session wipe keeps
  /// it. Only the successful commit of a whole fresh EXPLICIT admission removes
  /// an entry ([clearRevocation]); no automatic event, resume revalidation,
  /// rebootstrap or restart does. The `removing` state is the barrier record
  /// above.
  static const String revokedKey = 'qirsh.removal_revoked.v1';

  final ReplicaStore _store;
  final AccountScopeControl _scope;
  final RemoveDataBarrier _barrier;

  /// Clears the owner marker IF it still names [uid] (the uid being removed). A
  /// marker that moved to another uid meanwhile belongs to that uid and is left.
  final Future<void> Function(String uid) _clearOwnerMarker;
  final Future<void> Function()? _serverCleanup;
  final FlutterSecureStorage _storage;
  final Future<void> Function(String step)? _debugStep;

  /// Drains already-dispatched admission work (owner-marker/generation writes,
  /// scope activations, identity commits) before anything destructive runs.
  /// Supplied by the session layer.
  final Future<void> Function()? _quiesce;
  final Future<void> Function(String uid)? _invalidateAdmissionGeneration;

  /// F2 — the serialization fence. EVERY entry point ([remove], [resumePending])
  /// is an operation that takes its turn here BEFORE it reads, decides on, writes
  /// or replaces any durable removal state; the record is read inside the turn,
  /// so a caller can never act on a record another operation already completed.
  /// A second request for a uid that already has an operation not yet sealed
  /// JOINS it (upgrading it durably when stronger); anything else waits its turn.
  /// Two sweeps never run concurrently and one target's record is never
  /// overwritten by another's.
  final List<_Op> _pending = [];
  Future<void> _tail = Future<void>.value();

  /// Serializes the read-modify-write of the revoked-uid list.
  Future<void> _revokedTail = Future<void>.value();

  Future<void> _step(String name) async => _debugStep?.call(name);

  /// True while a removal has started and not finished (even when its record is
  /// unreadable: then the uid is unknown and admission stays blocked).
  Future<bool> hasPending() async {
    final raw = await _storage.read(key: barrierKey);
    return raw != null && raw.isNotEmpty;
  }

  /// True from the moment an operation is accepted until it finished — queued or
  /// executing.
  bool get isRunning => _pending.isNotEmpty;

  /// The uids whose Remove data completed and that have not authenticated
  /// explicitly since. Throws when the record is unreadable: the caller must fail
  /// closed, never read that as "no restrictions".
  Future<Set<String>> revokedUids() async {
    final raw = await _storage.read(key: revokedKey);
    if (raw == null || raw.isEmpty) return <String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('revoked uids');
    return decoded.cast<String>().toSet();
  }

  Future<T> _revokedLocked<T>(Future<T> Function() f) {
    final run = _revokedTail.then((_) => f());
    _revokedTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// A fresh EXPLICIT admission of [uid] committed completely (authority, owner
  /// marker and generation, registry, database and key, scope publication,
  /// identity): it may be admitted by automatic paths again.
  Future<void> clearRevocation(String uid, {required AdmissionAuthority authority}) =>
      _revokedLocked(() async {
        authority.requireFor(uid);
        final revoked = await revokedUids();
        authority.requireFor(uid);
        if (!revoked.remove(uid)) return;
        if (revoked.isEmpty) {
          await _storage.delete(key: revokedKey);
        } else {
          await _storage.write(
              key: revokedKey, value: jsonEncode(revoked.toList()..sort()));
        }
        if (!authority.isCurrent) {
          // A dispatched storage mutation cannot be cancelled. Restore the
          // restriction under this same list lock before releasing stale work.
          revoked.add(uid);
          await _storage.write(
              key: revokedKey, value: jsonEncode(revoked.toList()..sort()));
          throw const StaleAdmissionException();
        }
      });

  Future<void> _addRevoked(String uid) => _revokedLocked(() async {
    final revoked = await revokedUids()
      ..add(uid);
    await _storage.write(
      key: revokedKey,
      value: jsonEncode(revoked.toList()..sort()),
    );
  });

  /// Removes [uid]'s replica and everything native that belongs to it (§4.4).
  /// Throws [RemoveDataIncompleteException] (barrier kept) when a step could not
  /// be confirmed; returns normally only after step 6's precondition holds.
  ///
  /// [revokeAdmission] (default) is an explicit user removal: on completion the
  /// uid stays unadmittable until a new explicit authentication. The rebootstrap
  /// `purge` passes false: it is a server-driven recovery that re-admits. An
  /// explicit removal that overlaps a purge of the same uid JOINS it and upgrades
  /// it — in memory and in the durable record — so the purge's completion still
  /// requires explicit authentication; a purge never downgrades an explicit one.
  Future<void> remove(String uid, {bool revokeAdmission = true}) {
    for (final op in _pending) {
      if (op.uid == uid && !op.sealed) {
        if (revokeAdmission && !op.revoke) _upgrade(op);
        return op.done!;
      }
    }
    final op = _Op(uid: uid, revoke: revokeAdmission);
    return op.done = _enqueue<void>(op, () => _removeBody(op));
  }

  /// Launch / admission: finishes a removal a crash left behind. Returns true
  /// when none is pending or it has now completed; false when it could not be
  /// completed (the caller must not admit anyone yet).
  ///
  /// F2: an unreadable Dart record, or a native barrier whose uid cannot be
  /// recovered, is "cannot complete", never "nothing pending". The record is read
  /// inside the serialized turn.
  Future<bool> resumePending() {
    if (_pending.isNotEmpty) {
      final last = _pending.last;
      if (last.isResume && !last.started) return last.resumed!;
    }
    final op = _Op(uid: null, revoke: true)..isResume = true;
    return op.resumed = _enqueue<bool>(op, _resumeBody);
  }

  Future<T> _enqueue<T>(_Op op, Future<T> Function() body) {
    _pending.add(op);
    final prior = _tail;
    final run = () async {
      try {
        await prior;
      } catch (_) {}
      op.started = true;
      try {
        return await body();
      } finally {
        _pending.remove(op);
      }
    }();
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// A join that is stronger than the operation it joins: made durable before the
  /// caller proceeds, so a crash from here on resumes as an explicit removal.
  void _upgrade(_Op op) {
    op.revoke = true;
    if (!op.recordIssued) return; // the record will be written with revoke:true
    op.recordWrites = op.recordWrites.then((_) async {
      try {
        await _storage.write(key: barrierKey, value: op.recordJson());
      } catch (e) {
        op.recordError ??= e;
      }
    });
  }

  Future<void> _removeBody(_Op op) async {
    final uid = op.uid!;
    final raw = await _readRaw();
    if (raw != null) {
      final other = _Record.tryParse(raw);
      if (other == null) throw const RemoveDataIncompleteException();
      if (other.uid != uid) {
        // Never overwrite another target's durable record: finish it first.
        await _runLeftover(other);
      } else {
        op.revoke = op.revoke || other.revoke; // never weaker than what is durable
      }
    }
    op.hash = await _store.uidHash(uid);
    // Step 1. The durable record goes first: from here a crash is resumed, and
    // the native barrier is (re)written idempotently on resume. Issued in one
    // synchronous block with its flag, so a join can neither miss nor reorder it.
    op.recordIssued = true;
    op.recordWrites = _storage
        .write(key: barrierKey, value: op.recordJson())
        .catchError((Object e) {
      op.recordError ??= e;
    });
    await op.recordWrites;
    if (op.recordError != null) throw const RemoveDataIncompleteException();
    try {
      await _step('afterBarrierRecord');
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
    await _run(op);
  }

  Future<bool> _resumeBody() async {
    try {
      final raw = await _readRaw();
      _Record record;
      if (raw != null) {
        final parsed = _Record.tryParse(raw);
        if (parsed == null) return false;
        record = parsed;
      } else {
        // A native barrier with no Dart record (crash between the two writes).
        final uid = await _barrier.pendingUid();
        if (uid != null) {
          record = _Record(uid: uid, uidHash: await _store.uidHash(uid));
        } else if (await _barrier.nativeBarrierPresent()) {
          return false;
        } else {
          return true;
        }
      }
      await _runLeftover(record);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Executes a removal a previous process recorded. Inside the caller's turn.
  Future<void> _runLeftover(_Record record) =>
      _run(_Op(uid: record.uid, revoke: record.revoke)..hash = record.uidHash);

  Future<void> _run(_Op op) async {
    final uid = op.uid!;
    try {
      await _invalidateAdmissionGeneration?.call(uid);
      await _quiesce?.call();
      await _barrier.begin(uid);
      await _step('afterNativeBegin');
      await _clearOwnerMarker(uid);
      await _step('afterOwnerCleared');
      // Step 2.
      await _scope.detach();
      await _step('afterScopeStopped');
      // Step 3.
      await _store.remove(uid);
      await _storage.delete(key: '$kConsentAskedKeyPrefix$uid');
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
      await _barrier.finish(uid);
      await _step('afterFinalSweep');
      // Joins that upgraded the record are flushed, then the operation is SEALED
      // in the same synchronous block: from here a request for this uid is a new
      // operation, so what is recorded below cannot change under it.
      while (true) {
        final writes = op.recordWrites;
        await writes;
        if (identical(writes, op.recordWrites)) break;
      }
      if (op.recordError != null) throw const RemoveDataIncompleteException();
      op.sealed = true;
      // The completed revocation is persisted BEFORE the active recovery record
      // is cleared, so there is no instant at which neither exists.
      if (op.revoke) {
        await _addRevoked(uid);
      }
      await _step('afterRevocationRecorded');
      await _storage.delete(key: barrierKey);
    } on RemoveDataIncompleteException {
      rethrow;
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
  }

  Future<String?> _readRaw() async {
    final raw = await _storage.read(key: barrierKey);
    return (raw == null || raw.isEmpty) ? null : raw;
  }
}

/// One accepted operation on the serialized queue.
class _Op {
  _Op({required this.uid, required this.revoke});

  /// The uid being removed; null for a resume (which learns it from the record).
  final String? uid;

  /// Whether completion records the uid as `removed_requires_explicit_auth`.
  /// Only ever raised, never lowered.
  bool revoke;
  String? hash;
  bool isResume = false;
  bool started = false;

  /// After this the operation is committing its result: a new request for the
  /// same uid is a new operation, not a join.
  bool sealed = false;

  /// The durable record has been issued (so a stronger join rewrites it).
  bool recordIssued = false;
  Future<void> recordWrites = Future<void>.value();
  Object? recordError;
  Future<void>? done;
  Future<bool>? resumed;

  String recordJson() => jsonEncode(
    _Record(uid: uid!, uidHash: hash!, revoke: revoke).toJson(),
  );
}

class _Record {
  const _Record({required this.uid, required this.uidHash, this.revoke = true});
  final String uid;
  final String uidHash;

  /// Whether completion records the uid as `removed_requires_explicit_auth`.
  final bool revoke;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'uidHash': uidHash,
    'revoke': revoke,
  };

  static _Record fromJson(Map<String, Object?> j) => _Record(
    uid: j['uid']! as String,
    uidHash: j['uidHash']! as String,
    revoke: j['revoke'] != false,
  );

  /// Null when the record cannot be read (corrupt): the caller fails closed.
  static _Record? tryParse(String raw) {
    try {
      return fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}
