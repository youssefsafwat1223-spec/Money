import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/db/database_access_broker.dart' show DatabaseOpenReservation;
import '../../data/db/replica_location.dart';
import '../../data/db/replica_store.dart';
import '../security/secure_storage_options.dart';

/// Offline local read — the durable grant that lets a device show the SAME
/// existing local account data when the SDK session has expired or is absent.
///
/// This is NOT an [AdmissionAuthority]: it has no `canCreate`, no write power, no
/// uid-forwarding to consent, capture-owner publication or account control. It is
/// device-local proof, not a credential: the record holds no token, password or
/// key. NOT WIRED into AppSession/router/bootstrap yet — nothing in the app calls
/// it, so app behaviour is unchanged.
///
/// The helper does not and cannot prove that the SDK session is fresh. The caller
/// (future AppSession wiring) hands [LocalReadIssueProof] only after the identity
/// publication really returned and the real SDK session was checked; the helper
/// merely re-evaluates that predicate at every point it could still matter.

// ------------------------------------------------------------------- codec

/// `committed` is the only state that grants. `preparing` and `blocked` deny.
enum LocalReadGrantState { preparing, committed, blocked }

/// The one current-selection record: `{version, state, operationId, uid,
/// replicaId}`. [operationId] is a fresh random nonce naming one grant
/// transaction (it is not an in-process epoch, which resets on every launch).
@immutable
class LocalReadGrantRecord {
  const LocalReadGrantRecord({
    required this.state,
    required this.operationId,
    required this.uid,
    required this.replicaId,
  });

  static const int version = 1;

  final LocalReadGrantState state;
  final String operationId;
  final String uid;

  /// Empty only for a `blocked` record written before a replica was known.
  final String replicaId;

  String encode() => jsonEncode({
        'version': version,
        'state': state.name,
        'operationId': operationId,
        'uid': uid,
        'replicaId': replicaId,
      });

  /// Strict decode: null for anything missing, malformed, of another version, or
  /// carrying any field other than the five above. Null always means "deny".
  static LocalReadGrantRecord? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json.length != 5) return null;
      final stateName = json['state'];
      final operationId = json['operationId'];
      final uid = json['uid'];
      final replicaId = json['replicaId'];
      if (json['version'] != version ||
          stateName is! String ||
          operationId is! String ||
          uid is! String ||
          replicaId is! String) {
        return null;
      }
      final matches =
          LocalReadGrantState.values.where((s) => s.name == stateName);
      if (matches.isEmpty || operationId.isEmpty || uid.isEmpty) return null;
      final state = matches.single;
      if (replicaId.isEmpty && state != LocalReadGrantState.blocked) {
        return null;
      }
      return LocalReadGrantRecord(
        state: state,
        operationId: operationId,
        uid: uid,
        replicaId: replicaId,
      );
    } catch (_) {
      return null;
    }
  }
}

// ------------------------------------------------------------- durable store

/// Where the single record lives. A seam so tests can fail, hold or crash a
/// write at an exact point.
abstract class LocalReadDurableStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Secure storage under [storageKey]. Deliberately NOT `qirsh.`-prefixed: the
/// session wipe preserves every `qirsh.*` secret (they protect the database), but
/// a grant must be swept by a reset like any other session residue.
class SecureLocalReadStore implements LocalReadDurableStore {
  SecureLocalReadStore({FlutterSecureStorage? storage})
      : _storage = storage ?? SecureStorageOptions.storage;

  static const String storageKey = 'local_read_grant.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: storageKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: storageKey, value: value);
}

// ---------------------------------------------------------------- vocabulary

enum LocalReadGrantFailure {
  /// A write or its exact readback did not succeed.
  persistence,

  /// A newer operation or a revocation took over before this one could land.
  superseded,

  /// The caller's lifecycle predicate no longer holds.
  notLive,

  /// A durable denial is still incomplete; nothing new may be issued.
  denialPending,
}

class LocalReadGrantException implements Exception {
  const LocalReadGrantException(this.reason);
  final LocalReadGrantFailure reason;
  @override
  String toString() => 'LocalReadGrantException(${reason.name})';
}

/// A process capability was used after its grant was revoked or superseded.
class StaleLocalReadException implements Exception {
  const StaleLocalReadException();
  @override
  String toString() => 'StaleLocalReadException: local read grant revoked.';
}

/// What the caller asserts when it asks for the committed receipt: the identity
/// publication of [uid] has RETURNED and the real SDK session was just checked
/// (non-expired, same uid). [isCurrent] must stay true only while that whole
/// admission is still the live one (no synchronous listener, logout, removal or
/// account switch since). The helper re-checks it before and after the write.
@immutable
class LocalReadIssueProof {
  const LocalReadIssueProof({required this.uid, required this.isCurrent});
  final String uid;
  final bool Function() isCurrent;
}

/// A reserved grant transaction whose `preparing` record is durable and read
/// back. Only [LocalReadAuthority.commit] consumes it.
@immutable
class LocalReadIssue {
  const LocalReadIssue._(
      this._owner, this.operationId, this.uid, this.replicaId);
  final LocalReadAuthority _owner;
  final String operationId;
  final String uid;
  final String replicaId;
}

/// The process capability for reading uid's replica [replicaId] under grant
/// [operationId]. It is current only while that exact grant is the live one in
/// the issuing [LocalReadAuthority]; revocation flips it synchronously.
@immutable
class LocalReadCapability {
  const LocalReadCapability._(this._owner, this.uid, this.replicaId,
      this.operationId, this._processGeneration);
  final LocalReadAuthority _owner;
  final String uid;
  final String replicaId;
  final String operationId;

  /// The authority's process generation at issue time. A mode transition
  /// ([LocalReadAuthority.retireProcessCapabilities]) bumps it, so a capability
  /// retired by a reconnect stays stale even after a fresh restore of the SAME
  /// durable grant.
  final int _processGeneration;

  bool get isCurrent =>
      _owner._selected &&
      !_owner._pendingOperationDenials.containsKey(operationId) &&
      _owner._committedOp == operationId &&
      _owner._processGeneration == _processGeneration;

  void requireCurrent() {
    if (!isCurrent) throw const StaleLocalReadException();
  }
}

/// Whether a revocation is DURABLE. Only [denied] and [registryLocked] mean a
/// restart will deny; [incomplete] means nothing could be persisted: the process
/// stays locked, the denial is retained, and a restart guarantee is NOT claimed.
enum LocalReadRevocation {
  /// The store holds no committed grant for the uid (written `blocked` and read
  /// back, or already absent/denying).
  denied,

  /// The secure record could not be written, but the existing registry entry was
  /// locked and read back as `locked`.
  registryLocked,

  /// No durable denial could be established.
  incomplete;

  bool get isDurable => this != incomplete;
}

enum LocalReadRestoreDenial { grant, denialPending, superseded, replica }

/// Result of [LocalReadAuthority.restore]. Exactly one of ([capability],
/// [replica]) or [denial] is set.
class LocalReadRestore {
  const LocalReadRestore._granted(this.capability, this.replica)
      : denial = null,
        replicaDenial = null;
  const LocalReadRestore._denied(this.denial, [this.replicaDenial])
      : capability = null,
        replica = null;

  final LocalReadCapability? capability;
  final LocalReadReplica? replica;
  final LocalReadRestoreDenial? denial;
  final LocalReadDenial? replicaDenial;

  bool get isGranted => capability != null;
}

// ----------------------------------------------------------------- authority

/// One in-isolate storage lane carried across supported authority replacement.
/// The mutable tail orders already-dispatched writes and every later enqueue,
/// including work retained by an outgoing authority. This is not an OS lock.
class _LocalReadStorageLane {
  Future<void> tail = Future<void>.value();
  LocalReadAuthority? selected;
}

/// One serialized authority state machine over one [LocalReadDurableStore].
///
/// Every durable read and write goes through a single lane, so a write that was
/// already dispatched finishes (and is read back) before any later one starts,
/// and a superseded operation re-checks itself INSIDE the lane right before it
/// writes. In-memory state changes synchronously on revoke/supersede; durable
/// state follows through the lane and is reported truthfully.
class LocalReadAuthority {
  LocalReadAuthority({
    required LocalReadDurableStore store,
    @visibleForTesting String Function()? newOperationId,
  })  : _store = store,
        _newOperationId = newOperationId ?? _randomOperationId {
    _lane.selected = this;
  }

  final LocalReadDurableStore _store;
  final String Function() _newOperationId;

  _LocalReadStorageLane _lane = _LocalReadStorageLane();
  bool _hasQueuedWork = false;
  bool get _selected => identical(_lane.selected, this);

  /// Configure a fresh replacement BEFORE using it. Both instances keep the
  /// same mutable lane, so the outgoing store's captured reads and dispatched
  /// writes drain before incoming mutations. A previously independent, used
  /// authority cannot retroactively order storage work it already dispatched.
  void takeOverStorageOrdering(LocalReadAuthority previous) {
    if (!identical(_lane, previous._lane)) {
      if (_hasQueuedWork) {
        throw StateError('Configure a replacement before using its store');
      }
      _lane = previous._lane;
    }
    if (!identical(previous, this)) previous.releaseStorageSelection();
    _lane.selected = this;
  }

  /// Retire private publication state synchronously. Queued restrictive work
  /// stays in the shared lane and still completes; it cannot publish a grant.
  void releaseStorageSelection() {
    if (_selected) _lane.selected = null;
    _epoch++;
    _processGeneration++;
    _currentOp = null;
    _currentUid = null;
    _committedOp = null;
  }

  /// The operation currently selected in this process (reserved or committed),
  /// and the uid it belongs to.
  String? _currentOp;
  String? _currentUid;

  /// The operation whose `committed` record is durable and read back.
  String? _committedOp;

  /// Bumped by every revoke and every new issue; lets a long restore notice that
  /// something changed while it awaited.
  int _epoch = 0;

  /// Bumped by [retireProcessCapabilities]; capabilities carry the value they
  /// were issued under.
  int _processGeneration = 0;

  /// uids whose denial has not been established durably yet.
  final Set<String> _pendingDenials = {};

  /// uids whose durable denial is still outstanding (retry targets).
  Set<String> get pendingDenialUids => Set.unmodifiable(_pendingDenials);

  /// A mode transition (reconnect, same-UID reauthentication): every process
  /// capability issued so far stops being current, synchronously, and stays
  /// stale for good. The durable grant is untouched: the only way back is a
  /// fresh [restore], which issues a new capability.
  void retireProcessCapabilities() {
    _processGeneration++;
    _committedOp = null;
    _epoch++;
  }

  static String _randomOperationId() {
    final rng = Random.secure();
    return List<int>.generate(16, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// True while a UID-wide denial is not yet durable. New issuance is refused.
  /// Operation denials are checked against the exact restored record instead.
  bool get isDenialPending => _pendingDenials.isNotEmpty;

  Future<T> _enqueue<T>(Future<T> Function() op) {
    _hasQueuedWork = true;
    final run = _lane.tail.then((_) => op());
    _lane.tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Writes [record] and requires the exact string back.
  Future<void> _writeVerified(LocalReadGrantRecord record) async {
    final encoded = record.encode();
    try {
      await _store.write(encoded);
      if (await _store.read() != encoded) {
        throw const LocalReadGrantException(LocalReadGrantFailure.persistence);
      }
    } on LocalReadGrantException {
      rethrow;
    } catch (_) {
      throw const LocalReadGrantException(LocalReadGrantFailure.persistence);
    }
  }

  Future<LocalReadGrantRecord?> _readRecord() async {
    try {
      return LocalReadGrantRecord.tryDecode(await _store.read());
    } catch (_) {
      return null;
    }
  }

  /// Reserves a fresh nonce for ([uid], [replicaId]) and makes `preparing`
  /// durable (written and read back) BEFORE returning. From the synchronous
  /// instant of the call any earlier grant is no longer usable in this process,
  /// and once `preparing` has landed it no longer grants after a restart either.
  /// If that write cannot be confirmed the issue is abandoned (the previous
  /// record, if any, is whatever storage still holds) and a
  /// [LocalReadGrantException] is thrown.
  Future<LocalReadIssue> beginIssue({
    required String uid,
    required String replicaId,
  }) async {
    if (uid.isEmpty || replicaId.isEmpty) {
      throw ArgumentError('uid and replicaId are required');
    }
    if (!_selected) {
      throw const LocalReadGrantException(LocalReadGrantFailure.superseded);
    }
    if (isDenialPending) {
      throw const LocalReadGrantException(LocalReadGrantFailure.denialPending);
    }
    final op = _newOperationId();
    _epoch++;
    _currentOp = op;
    _currentUid = uid;
    _committedOp = null;
    try {
      await _enqueue(() async {
        if (_currentOp != op) {
          throw const LocalReadGrantException(LocalReadGrantFailure.superseded);
        }
        // A denial that is not durable yet blocks every grant that has not been
        // exposed, including one reserved before the denial began.
        if (isDenialPending) {
          throw const LocalReadGrantException(
              LocalReadGrantFailure.denialPending);
        }
        await _writeVerified(LocalReadGrantRecord(
          state: LocalReadGrantState.preparing,
          operationId: op,
          uid: uid,
          replicaId: replicaId,
        ));
        // The write was dispatched before the denial began: `preparing` is
        // durable and denies, but no issue is handed out.
        if (isDenialPending) {
          throw const LocalReadGrantException(
              LocalReadGrantFailure.denialPending);
        }
      });
    } catch (_) {
      if (_currentOp == op) {
        _currentOp = null;
        _currentUid = null;
      }
      rethrow;
    }
    if (!_selected || _currentOp != op) {
      throw const LocalReadGrantException(LocalReadGrantFailure.superseded);
    }
    return LocalReadIssue._(this, op, uid, replicaId);
  }

  bool _live(LocalReadIssue issue, LocalReadIssueProof proof) =>
      _selected &&
      identical(issue._owner, this) &&
      _currentOp == issue.operationId &&
      _currentUid == issue.uid &&
      proof.uid == issue.uid &&
      proof.isCurrent();

  /// Makes the grant `committed` (written and exactly read back) and only then
  /// returns the process capability. [proof] is checked before the call is
  /// queued, again inside the lane immediately before the write, and again after
  /// the readback. If it stopped holding while the record landed and nothing else
  /// has taken over, the same operation is written `blocked` before failing, so a
  /// stale continuation never leaves a committed grant behind.
  Future<LocalReadCapability> commit(
    LocalReadIssue issue, {
    required LocalReadIssueProof proof,
  }) async {
    LocalReadGrantException whyNot() => LocalReadGrantException(isDenialPending
        ? LocalReadGrantFailure.denialPending
        : _currentOp == issue.operationId
            ? LocalReadGrantFailure.notLive
            : LocalReadGrantFailure.superseded);

    void requireLive() {
      if (isDenialPending || !_live(issue, proof)) throw whyNot();
    }

    requireLive();
    final committed = LocalReadGrantRecord(
      state: LocalReadGrantState.committed,
      operationId: issue.operationId,
      uid: issue.uid,
      replicaId: issue.replicaId,
    );
    await _enqueue(() async {
      requireLive();
      try {
        await _writeVerified(committed);
      } catch (_) {
        // The write may or may not have landed: no grant is exposed, and a
        // denial is attempted for the same operation.
        await _denyAfterFailedCommit(issue);
        rethrow;
      }
      if (isDenialPending || !_live(issue, proof)) {
        // Revoke/supersede queue their own record behind this one; only a lapse
        // nobody else is handling (a lifecycle that ended, or another uid's
        // denial that is still pending) needs the blocked record written here.
        final error = whyNot();
        // Replacement retired the private selection, but this turn still owns
        // the dispatched commit. Deny its unexposed record before the incoming
        // lane can read or mutate it, even if no successor is ever issued.
        if (_currentOp == issue.operationId || !_selected) {
          await _denyAfterFailedCommit(issue);
        }
        throw error;
      }
      _committedOp = issue.operationId;
    });
    // Rechecked after the lane's await: nothing is exposed for a grant that was
    // revoked or superseded in the meantime.
    // Evaluate the caller predicate first: it can synchronously trigger a
    // lifecycle listener, so denial must be checked after it has returned.
    if (!_live(issue, proof) ||
        isDenialPending ||
        _committedOp != issue.operationId) {
      final error = whyNot();
      // Re-enter the lane and deny only this still-selected operation. A newer
      // owner must never be overwritten by this unexposed grant's cleanup.
      if (!_selected) {
        // The successor may already have run. The normal exact-operation
        // denial compares in the shared lane and retains unreadable failures.
        await revokeOperation(operationId: issue.operationId, uid: issue.uid);
      } else {
        await _enqueue(() async {
          if (_currentOp == issue.operationId) {
            await _denyAfterFailedCommit(issue);
          }
        });
      }
      throw error;
    }
    return LocalReadCapability._(this, issue.uid, issue.replicaId,
        issue.operationId, _processGeneration);
  }

  /// Writes this issue's operation `blocked`. Inside the lane. A failure leaves
  /// the denial pending (new issuance refused until [revoke] completes it).
  Future<void> _denyAfterFailedCommit(LocalReadIssue issue) async {
    if (!_selected) _pendingOperationDenials[issue.operationId] = issue.uid;
    if (_currentOp == issue.operationId) {
      _currentOp = null;
      _currentUid = null;
      _committedOp = null;
    }
    try {
      await _writeVerified(LocalReadGrantRecord(
        state: LocalReadGrantState.blocked,
        operationId: issue.operationId,
        uid: issue.uid,
        replicaId: issue.replicaId,
      ));
      _pendingOperationDenials.remove(issue.operationId);
    } catch (_) {
      if (!_selected) {
        _pendingOperationDenials[issue.operationId] = issue.uid;
      } else {
        _pendingDenials.add(issue.uid);
      }
    }
  }

  /// Revokes [uid]'s grant. Everything in-memory happens synchronously, before
  /// anything is awaited: capabilities of [uid] stop being current, an issue in
  /// flight fails its next check, and new issuance is refused until the denial is
  /// durable. Then, behind any write already dispatched, the `blocked` record is
  /// written and read back.
  ///
  /// If that fails, [lockRegistry] (the caller's explicit, authorized replica
  /// lock) may count as durable only if it returns true, which means it re-read
  /// the registry and saw the exact entry `locked`. Otherwise the result is
  /// [LocalReadRevocation.incomplete]: the process stays locked and the denial
  /// stays pending; call again to retry. Nothing here deletes a key or a file.
  ///
  /// A stored grant that belongs to ANOTHER uid is left untouched.
  Future<LocalReadRevocation> revoke({
    required String uid,
    Future<bool> Function()? lockRegistry,
  }) {
    _epoch++;
    _pendingDenials.add(uid);
    if (_currentUid == uid) {
      _currentOp = null;
      _currentUid = null;
      _committedOp = null;
    }
    return _enqueue(() async {
      String? raw;
      var readable = true;
      try {
        raw = await _store.read();
      } catch (_) {
        readable = false;
      }
      final stored = readable ? LocalReadGrantRecord.tryDecode(raw) : null;
      final alreadyDenying = readable &&
          ((raw == null || raw.isEmpty) ||
              (stored != null &&
                  (stored.uid != uid ||
                      stored.state != LocalReadGrantState.committed)));
      if (!alreadyDenying) {
        try {
          await _writeVerified(LocalReadGrantRecord(
            state: LocalReadGrantState.blocked,
            operationId: _newOperationId(),
            uid: uid,
            replicaId: stored?.replicaId ?? '',
          ));
        } catch (_) {
          var locked = false;
          try {
            locked = await lockRegistry?.call() ?? false;
          } catch (_) {
            // A failed lock call is simply "not locked".
          }
          if (!locked) return LocalReadRevocation.incomplete;
          _pendingDenials.remove(uid);
          return LocalReadRevocation.registryLocked;
        }
      }
      _pendingDenials.remove(uid);
      return LocalReadRevocation.denied;
    });
  }

  /// O-LC-1a: operations whose bound denial could not be made durable yet
  /// (operationId -> uid). Retried by [revokeOperation] only; never a uid-wide
  /// revoke, so a successor's grant is never selected by them.
  Map<String, String> _pendingOperationDenials = {};

  Map<String, String> get pendingOperationDenials =>
      Map.unmodifiable(_pendingOperationDenials);

  /// O8-3: carries outstanding operation denials over from an authority this
  /// one replaces (the same process, the same durable store). The shared ledger
  /// also retains denials whose queued write is still pending at replacement;
  /// their completion updates the replacement's view. In-memory only: writes
  /// nothing, claims no restart guarantee and selects no other record.
  void adoptPendingOperationDenials(Map<String, String> outstanding) {
    outstanding.addAll(_pendingOperationDenials);
    _pendingOperationDenials = outstanding;
  }

  /// A committed record whose own operation denial has not landed yet is not a
  /// grant, whatever else the store still says.
  bool _operationDenied(LocalReadGrantRecord record) =>
      _pendingOperationDenials.containsKey(record.operationId);

  /// Denies ONE specific grant operation (the originating, uncertain one) and
  /// nothing else. Unlike [revoke] it is compare-and-set on the stored record's
  /// `operationId`: a record naming any other operation (an independently
  /// issued successor, for the same or another uid) is left untouched, the
  /// authority's current/committed selection is cleared only when it IS this
  /// operation, and no uid-wide denial is registered. The stored record is read
  /// and replaced inside the authority's own queue, so no write interleaves.
  Future<LocalReadRevocation> revokeOperation({
    required String operationId,
    required String uid,
    Future<bool> Function()? lockRegistry,
  }) {
    if (_currentOp == operationId) {
      _epoch++;
      _currentOp = null;
      _currentUid = null;
      _committedOp = null;
    } else if (_committedOp == operationId) {
      _epoch++;
      _committedOp = null;
    }
    _pendingOperationDenials[operationId] = uid;
    return _enqueue(() async {
      String? raw;
      try {
        raw = await _store.read();
      } catch (_) {
        // Cannot tell the originating record from a successor's: not durable.
        return LocalReadRevocation.incomplete;
      }
      final stored = LocalReadGrantRecord.tryDecode(raw);
      if (stored == null ||
          stored.operationId != operationId ||
          stored.state == LocalReadGrantState.blocked) {
        // Missing/malformed records never grant; any other operation is not the
        // originating one; an already blocked record is already the denial.
        _pendingOperationDenials.remove(operationId);
        return LocalReadRevocation.denied;
      }
      try {
        await _writeVerified(LocalReadGrantRecord(
          state: LocalReadGrantState.blocked,
          operationId: _newOperationId(),
          uid: stored.uid,
          replicaId: stored.replicaId,
        ));
      } catch (_) {
        var locked = false;
        try {
          locked = await lockRegistry?.call() ?? false;
        } catch (_) {}
        if (!locked) return LocalReadRevocation.incomplete;
        _pendingOperationDenials.remove(operationId);
        return LocalReadRevocation.registryLocked;
      }
      _pendingOperationDenials.remove(operationId);
      return LocalReadRevocation.denied;
    });
  }

  /// The stored record, whatever its state (null when missing or malformed).
  /// Read behind any write in flight; creates and changes nothing.
  Future<LocalReadGrantRecord?> peekRecord() => _enqueue(_readRecord);

  /// Cold-start restoration. Reads the stored record (behind any write in
  /// flight) and accepts it only if it is `committed`; then
  /// [ReplicaStore.openReadOnlyReplica] must verify the owner marker, removal
  /// state, `active` registry, files, key, schema and the file's own
  /// `replica_meta` against that record. The record is re-read afterwards and
  /// the handle is closed, not returned, if anything changed meanwhile.
  ///
  /// Does not need, look at or create an SDK session; it supplies no cloud,
  /// consent or capture-owner authority; and it writes nothing.
  ///
  /// [reserve] is the host's coordinator seam: it runs after the record and the
  /// store's evidence validated and before the read-only connection is touched.
  /// Both seams are REQUIRED (R8): production never restores outside the
  /// coordinator; [restoreUncoordinatedForTesting] is the only fixture escape.
  Future<LocalReadRestore> restore(
    ReplicaStore store, {
    required DatabaseOpenReservation Function(String uid) reserve,
    required void Function(ReplicaLocation location) verifyExclusion,
  }) =>
      _restore(
        store,
        (record) => store.openReadOnlyReplica(
          record.uid,
          replicaId: record.replicaId,
          reserve: reserve,
          verifyExclusion: verifyExclusion,
        ),
      );

  /// R8: a restoration with no coordinator seam, for fixtures only: the caller
  /// supplies the opener (a test passes
  /// `ReplicaStore.openReadOnlyReplicaUncoordinatedForTesting`). The verified
  /// replica carries no reservation and the host refuses to publish it. An
  /// architecture pin forbids any use of this name under `lib/`.
  @visibleForTesting
  Future<LocalReadRestore> restoreUncoordinatedForTesting(
    ReplicaStore store, {
    required Future<LocalReadReplica> Function(String uid, String replicaId)
        open,
  }) =>
      _restore(store, (record) => open(record.uid, record.replicaId));

  Future<LocalReadRestore> _restore(
    ReplicaStore store,
    Future<LocalReadReplica> Function(LocalReadGrantRecord record) open,
  ) async {
    if (!_selected) {
      return const LocalReadRestore._denied(LocalReadRestoreDenial.superseded);
    }
    if (isDenialPending) {
      return const LocalReadRestore._denied(
          LocalReadRestoreDenial.denialPending);
    }
    final epoch = _epoch;
    final record = await _enqueue(_readRecord);
    if (record == null || record.state != LocalReadGrantState.committed) {
      return const LocalReadRestore._denied(LocalReadRestoreDenial.grant);
    }
    if (_operationDenied(record)) {
      return const LocalReadRestore._denied(
          LocalReadRestoreDenial.denialPending);
    }
    if (!_selected || _epoch != epoch ||
        (_currentOp != null && _currentOp != record.operationId)) {
      return const LocalReadRestore._denied(LocalReadRestoreDenial.superseded);
    }
    final LocalReadReplica replica;
    try {
      replica = await open(record);
    } on LocalReadUnavailableException catch (e) {
      return LocalReadRestore._denied(LocalReadRestoreDenial.replica, e.reason);
    }
    final again = await _enqueue(_readRecord);
    if (!_selected || _epoch != epoch ||
        isDenialPending ||
        again == null ||
        _operationDenied(again) ||
        again.state != LocalReadGrantState.committed ||
        again.operationId != record.operationId ||
        again.uid != record.uid ||
        again.replicaId != record.replicaId) {
      await replica.database.close();
      return const LocalReadRestore._denied(LocalReadRestoreDenial.superseded);
    }
    _currentOp = record.operationId;
    _currentUid = record.uid;
    _committedOp = record.operationId;
    return LocalReadRestore._granted(
      LocalReadCapability._(this, record.uid, record.replicaId,
          record.operationId, _processGeneration),
      replica,
    );
  }
}
