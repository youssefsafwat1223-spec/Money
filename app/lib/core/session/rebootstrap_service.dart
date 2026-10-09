import 'dart:async';

import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';
import '../../data/db/replica_store.dart';
import '../../data/sync/seq_pull.dart';
import '../../data/sync/server_capabilities.dart';
import '../../data/sync/sync_cursor.dart';
import 'account_scope.dart';
import 'admission_authority.dart';
import 'replica_recovery.dart';

/// WP-7 — process-wide freeze while a replica is being rebootstrapped (§4.10).
/// Capture delivery (native drain, `sync-captures`, APNs-tap import) and ledger
/// egress check it and do nothing while it is set. Armed at launch when the
/// registry still holds an unfinished rebootstrap marker.
class ReplicaFreeze {
  ReplicaFreeze._();
  static final ReplicaFreeze instance = ReplicaFreeze._();

  bool _frozen = false;
  bool get frozen => _frozen;
  void freeze() => _frozen = true;
  void thaw() => _frozen = false;
}

/// What a rebootstrap needs from the capture import layer (CAP-5 barrier hook).
abstract interface class RebootstrapCaptureControl {
  /// Quiescence barrier: no new import starts, an open import finishes its local
  /// transaction, post-commit native removals and server ACKs are deferred.
  Future<void> hold();

  /// Capture ids whose local result committed while the barrier was held.
  Set<String> get deferredCaptureIds;

  /// After the swap committed: native removal and server ACK for [committed]
  /// (the deferred ids whose receipt is in the NEW replica). Everything else
  /// stays in the native queue and is imported by a normal run.
  Future<void> resume(Set<String> committed);
}

enum RebootstrapOutcome {
  /// No epoch change / not enabled: nothing was started.
  notNeeded,

  /// Recovered into a fresh replica, swapped, capture resumed.
  completed,

  /// `epoch_reason = purge`: nothing replayed, the account's data removed.
  purged,

  /// A step failed (network, ...). The marker is kept; the next call resumes.
  retryLater,

  /// Recovery could not place every item. No swap; the old replica stays.
  blocked,
}

class RebootstrapService {
  RebootstrapService({
    required ReplicaStore store,
    required RebootstrapCaptureControl capture,
    required AccountScopeControl scope,
    required Future<void> Function(AppDatabase fresh, String uid) bootstrapFresh,
    required LedgerServerLookup lookup,
    required Future<void> Function(String uid) removeData,
    Future<void> Function(String uid, AdmissionAuthority? authority)? readmit,
    Future<AdmissionAuthority> Function(String uid)? maintenanceAuthority,
    ReplicaFreeze? freeze,
    Future<void> Function(String phase)? debugAfterPhase,
  }) : _store = store,
       _capture = capture,
       _scope = scope,
       _bootstrapFresh = bootstrapFresh,
       _lookup = lookup,
       _removeData = removeData,
       _readmit = readmit,
       _maintenance = maintenanceAuthority,
       _freeze = freeze ?? ReplicaFreeze.instance,
       _debug = debugAfterPhase;

  final ReplicaStore _store;
  final RebootstrapCaptureControl _capture;
  final AccountScopeControl _scope;
  final Future<void> Function(AppDatabase fresh, String uid) _bootstrapFresh;
  final LedgerServerLookup _lookup;
  final Future<void> Function(String uid) _removeData;
  final Future<void> Function(String uid, AdmissionAuthority? authority)?
  _readmit;

  /// F2: yields the authority this rebootstrap runs under. Every open, staging
  /// creation, activation and the purge re-admission re-checks it, so an explicit
  /// Remove data accepted meanwhile (which revokes it) stops all of them.
  final Future<AdmissionAuthority> Function(String uid)? _maintenance;
  final ReplicaFreeze _freeze;
  final Future<void> Function(String phase)? _debug;

  Future<RebootstrapOutcome>? _inFlight;

  /// Starts (with [reason], the server `epoch_reason`) or resumes (reason null)
  /// the rebootstrap of [uid]. Single flight.
  Future<RebootstrapOutcome> run(String uid, {String? reason}) {
    final running = _inFlight;
    if (running != null) return running;
    final f = _run(uid, reason).whenComplete(() => _inFlight = null);
    return _inFlight = f;
  }

  Future<void> _tick(String phase) async => _debug?.call(phase);

  Future<RebootstrapOutcome> _run(String uid, String? reason) async {
    var marker = await _store.rebootstrapMarker(uid);
    if (marker == null) {
      if (reason == null || !await _store.beginRebootstrap(uid, reason)) {
        return RebootstrapOutcome.notNeeded;
      }
      marker = await _store.rebootstrapMarker(uid);
    }
    AdmissionAuthority? authority;
    try {
      authority = await _maintenance?.call(uid);
    } on StaleAdmissionException {
      // The uid's data was explicitly removed: nothing to recover or re-admit.
      return RebootstrapOutcome.notNeeded;
    }
    _freeze.freeze();
    await _capture.hold();
    await _tick('frozen');
    try {
      return marker!.reason == 'purge'
          ? await _purge(uid, authority)
          : await _recover(
              uid,
              marker.phase,
              authority,
              swapping: marker.swapping,
            );
    } on StaleAdmissionException {
      // An explicit Remove data revoked this rebootstrap mid-way. It is not
      // resumed and nothing is re-admitted; release what it froze.
      try {
        await _capture.resume(const {});
      } catch (_) {}
      _freeze.thaw();
      return RebootstrapOutcome.notNeeded;
    } on RecoveryIncompleteException {
      return RebootstrapOutcome.blocked;
    } catch (_) {
      return RebootstrapOutcome.retryLater;
    }
  }

  /// §4.10 `epoch_reason = purge`: no replay, receipts dropped (they live in the
  /// replica being deleted), native capture items of the uid removed by the §4.4
  /// sweep, old replica discarded.
  Future<RebootstrapOutcome> _purge(
    String uid,
    AdmissionAuthority? authority,
  ) async {
    authority?.requireCurrent();
    await _removeData(uid);
    await _capture.resume(const {});
    _freeze.thaw();
    // The re-admission is the one thing that may recreate the purged replica;
    // it carries the maintenance authority and is skipped once that is revoked.
    authority?.requireCurrent();
    await _readmit?.call(uid, authority);
    return RebootstrapOutcome.purged;
  }

  Future<RebootstrapOutcome> _recover(
    String uid,
    RebootstrapPhase from,
    AdmissionAuthority? authority, {
    bool swapping = false,
  }) async {
    var phase = from;
    if (swapping) {
      // A crash inside the swap: only the (idempotent) file moves are left.
      authority?.requireCurrent();
      await _store.swapStaging(uid, authority: authority);
      phase = RebootstrapPhase.swapped;
    }
    Future<void> done(RebootstrapPhase p) async {
      await _store.advanceRebootstrap(uid, p);
      phase = p;
      await _tick(p.wire);
    }

    ReplicaRecovery recovery(AppDatabase old, AppDatabase fresh) =>
        ReplicaRecovery(old: old, fresh: fresh, lookup: _lookup);

    while (phase.index < RebootstrapPhase.swapped.index) {
      authority?.requireCurrent();
      final old = await _store.openReplica(uid, authority: authority);
      switch (phase) {
        case RebootstrapPhase.frozen:
          // Extraction checkpoint: the live replica must be readable and sound.
          final check = await old.customSelect('PRAGMA quick_check;').get();
          if (check.length != 1 ||
              check.single.read<String>('quick_check') != 'ok') {
            return RebootstrapOutcome.blocked;
          }
          await done(RebootstrapPhase.extracted);
        case RebootstrapPhase.extracted:
          final fresh = await _store.openStaging(uid, authority: authority);
          await recovery(old, fresh).seedDeviceLocalState();
          await _bootstrapFresh(fresh, uid);
          await done(RebootstrapPhase.freshBootstrapped);
        case RebootstrapPhase.freshBootstrapped:
          await recovery(
            old,
            await _store.openStaging(uid, authority: authority),
          ).recoverReceipts();
          await done(RebootstrapPhase.receiptsRecovered);
        case RebootstrapPhase.receiptsRecovered:
          await recovery(
            old,
            await _store.openStaging(uid, authority: authority),
          ).mergeRows();
          await done(RebootstrapPhase.pulledMerged);
        case RebootstrapPhase.pulledMerged:
          await recovery(
            old,
            await _store.openStaging(uid, authority: authority),
          ).recoverOutbox();
          await done(RebootstrapPhase.outboxRecovered);
        case RebootstrapPhase.outboxRecovered:
          await recovery(
            old,
            await _store.openStaging(uid, authority: authority),
          ).mergeConflicts();
          await done(RebootstrapPhase.conflictsMerged);
        case RebootstrapPhase.conflictsMerged:
          // No more local writes: withdraw the scope, then re-run the (idempotent)
          // recovery for whatever the user did meanwhile, verify, and swap.
          // The root shows "Updating your data…" meanwhile, never the signed-out
          // routes (no scope is published until the swap committed).
          authority?.requireCurrent();
          await _scope.suspendForSwap();
          try {
            authority?.requireCurrent();
            final closedOld = await _store.openReplica(
              uid,
              authority: authority,
            );
            final fresh = await _store.openStaging(uid, authority: authority);
            final r = recovery(closedOld, fresh);
            await r.recoverReceipts();
            await r.mergeRows();
            await r.recoverOutbox();
            await r.mergeConflicts();
            await r.verify();
            authority?.requireCurrent();
            await _store.swapStaging(uid, authority: authority);
          } catch (_) {
            // Not swapped: put the account back on whatever replica is live, and
            // fall back to the signed-out scope only if even that is impossible,
            // so the root never stays on the loading state.
            try {
              await _scope.activate(uid, authority: authority);
            } catch (_) {
              await _scope.detach();
            }
            rethrow;
          }
          phase = RebootstrapPhase.swapped;
          await _tick('swapped');
        default:
          break;
      }
    }

    // swapped committed: reopen the account on the new replica, then let
    // capture resume. Only deferred ids whose receipt is in it cross the barrier.
    authority?.requireCurrent();
    await _scope.activate(uid, authority: authority);
    final committed = await _deferredWithReceipt(uid, authority);
    await _capture.resume(committed);
    await _store.advanceRebootstrap(uid, RebootstrapPhase.captureResumed);
    _freeze.thaw();
    await _tick('capture_resumed');
    return RebootstrapOutcome.completed;
  }

  Future<Set<String>> _deferredWithReceipt(
    String uid,
    AdmissionAuthority? authority,
  ) async {
    final ids = _capture.deferredCaptureIds;
    if (ids.isEmpty) return const {};
    final db = await _store.openReplica(uid, authority: authority);
    final out = <String>{};
    for (final id in ids) {
      final row = await db.customSelect(
        "SELECT 1 AS x FROM dedup_hashes WHERE hash = 'capture_payload:$id' "
        'UNION ALL SELECT 1 FROM transactions WHERE id = ? LIMIT 1;',
        variables: [Variable.withString(id)],
      ).getSingleOrNull();
      if (row != null) out.add(id);
    }
    return out;
  }
}

/// Decides, once per sync cycle, whether the replica of [uid] must be
/// rebootstrapped: only behind the `replica_epoch` capability (false in
/// production, so the typed `SyncPullStop.epochMismatch` stop is unchanged).
class EpochRebootstrapTrigger {
  EpochRebootstrapTrigger({
    required ReplicaStore store,
    required RebootstrapService service,
    required Future<ServerCapabilityState> Function() capability,
    required SeqRemote remote,
    required Future<RecordedSyncEpoch?> Function(String uid) recordedEpoch,
  })  : _store = store,
        _service = service,
        _capability = capability,
        _remote = remote,
        _recorded = recordedEpoch;

  final ReplicaStore _store;
  final RebootstrapService _service;
  final Future<ServerCapabilityState> Function() _capability;
  final SeqRemote _remote;
  final Future<RecordedSyncEpoch?> Function(String uid) _recorded;

  Future<RebootstrapOutcome> check(String uid) async {
    try {
      if (await _capability() != ServerCapabilityState.verified) {
        return RebootstrapOutcome.notNeeded;
      }
      if (await _store.rebootstrapMarker(uid) != null) {
        return await _service.run(uid);
      }
      final head = await _remote.fetchHead(uid);
      final recorded = await _recorded(uid);
      if (head == null || recorded == null || recorded.epoch == head.epoch) {
        return RebootstrapOutcome.notNeeded;
      }
      return await _service.run(uid, reason: head.epochReason ?? 'reset');
    } catch (_) {
      return RebootstrapOutcome.retryLater;
    }
  }
}
