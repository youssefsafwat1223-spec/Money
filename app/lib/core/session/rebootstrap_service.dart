import 'dart:async';

import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';
import '../../data/db/replica_store.dart';
import '../../data/sync/seq_pull.dart';
import '../../data/sync/server_capabilities.dart';
import '../../data/sync/sync_cursor.dart';
import 'account_scope.dart';
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
    Future<void> Function(String uid)? readmit,
    ReplicaFreeze? freeze,
    Future<void> Function(String phase)? debugAfterPhase,
  })  : _store = store,
        _capture = capture,
        _scope = scope,
        _bootstrapFresh = bootstrapFresh,
        _lookup = lookup,
        _removeData = removeData,
        _readmit = readmit,
        _freeze = freeze ?? ReplicaFreeze.instance,
        _debug = debugAfterPhase;

  final ReplicaStore _store;
  final RebootstrapCaptureControl _capture;
  final AccountScopeControl _scope;
  final Future<void> Function(AppDatabase fresh, String uid) _bootstrapFresh;
  final LedgerServerLookup _lookup;
  final Future<void> Function(String uid) _removeData;
  final Future<void> Function(String uid)? _readmit;
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
    _freeze.freeze();
    await _capture.hold();
    await _tick('frozen');
    try {
      return marker!.reason == 'purge'
          ? await _purge(uid)
          : await _recover(uid, marker.phase, swapping: marker.swapping);
    } on RecoveryIncompleteException {
      return RebootstrapOutcome.blocked;
    } catch (_) {
      return RebootstrapOutcome.retryLater;
    }
  }

  /// §4.10 `epoch_reason = purge`: no replay, receipts dropped (they live in the
  /// replica being deleted), native capture items of the uid removed by the §4.4
  /// sweep, old replica discarded.
  Future<RebootstrapOutcome> _purge(String uid) async {
    await _removeData(uid);
    await _capture.resume(const {});
    _freeze.thaw();
    await _readmit?.call(uid);
    return RebootstrapOutcome.purged;
  }

  Future<RebootstrapOutcome> _recover(String uid, RebootstrapPhase from,
      {bool swapping = false}) async {
    var phase = from;
    if (swapping) {
      // A crash inside the swap: only the (idempotent) file moves are left.
      await _store.swapStaging(uid);
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
      final old = await _store.openReplica(uid);
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
          final fresh = await _store.openStaging(uid);
          await recovery(old, fresh).seedDeviceLocalState();
          await _bootstrapFresh(fresh, uid);
          await done(RebootstrapPhase.freshBootstrapped);
        case RebootstrapPhase.freshBootstrapped:
          await recovery(old, await _store.openStaging(uid)).recoverReceipts();
          await done(RebootstrapPhase.receiptsRecovered);
        case RebootstrapPhase.receiptsRecovered:
          await recovery(old, await _store.openStaging(uid)).mergeRows();
          await done(RebootstrapPhase.pulledMerged);
        case RebootstrapPhase.pulledMerged:
          await recovery(old, await _store.openStaging(uid)).recoverOutbox();
          await done(RebootstrapPhase.outboxRecovered);
        case RebootstrapPhase.outboxRecovered:
          await recovery(old, await _store.openStaging(uid)).mergeConflicts();
          await done(RebootstrapPhase.conflictsMerged);
        case RebootstrapPhase.conflictsMerged:
          // No more local writes: withdraw the scope, then re-run the (idempotent)
          // recovery for whatever the user did meanwhile, verify, and swap.
          // The root shows "Updating your data…" meanwhile, never the signed-out
          // routes (no scope is published until the swap committed).
          await _scope.suspendForSwap();
          try {
            final closedOld = await _store.openReplica(uid);
            final fresh = await _store.openStaging(uid);
            final r = recovery(closedOld, fresh);
            await r.recoverReceipts();
            await r.mergeRows();
            await r.recoverOutbox();
            await r.mergeConflicts();
            await r.verify();
            await _store.swapStaging(uid);
          } catch (_) {
            // Not swapped: put the account back on whatever replica is live, and
            // fall back to the signed-out scope only if even that is impossible,
            // so the root never stays on the loading state.
            try {
              await _scope.activate(uid);
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
    await _scope.activate(uid);
    final committed = await _deferredWithReceipt(uid);
    await _capture.resume(committed);
    await _store.advanceRebootstrap(uid, RebootstrapPhase.captureResumed);
    _freeze.thaw();
    await _tick('capture_resumed');
    return RebootstrapOutcome.completed;
  }

  Future<Set<String>> _deferredWithReceipt(String uid) async {
    final ids = _capture.deferredCaptureIds;
    if (ids.isEmpty) return const {};
    final db = await _store.openReplica(uid);
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
