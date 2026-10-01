import 'package:flutter/foundation.dart';

import '../../data/sync/exact_transport_capability.dart'
    show exactMoneyTransportUnverifiedReason;
import 'outbox_failure.dart';
import 'sync_health.dart';

/// A-5 — the one user-facing answer to "did my data reach the cloud?".
///
/// Pure derivation from facts the app already records (queue counts, per-domain
/// health, consent, identity, whether a run is in progress). It reports
/// [SyncStatusKind.allSynced] ONLY on ACK truth: nothing queued, parked,
/// dead-lettered or in flight, AND the last successful push is not older than
/// the last local mutation. A guest/signed-out identity or cloud consent being
/// off is never "synced" — that data is local only.
enum SyncStatusKind {
  allSynced,
  syncing,

  /// [SyncStatus.count] changes are queued/parked and will retry or wait for a
  /// dependency/capability.
  waiting,

  /// Cloud Sync is off: [SyncStatus.count] changes are kept on this device.
  consentOff,

  /// No cloud identity (guest or signed out): data stays on this device.
  signedOut,

  /// [SyncStatus.count] items failed and need attention.
  failed,
}

/// Who the sync would run as.
enum SyncIdentity { authenticated, guest, signedOut }

/// Domains whose outbox ACKs decide "all synced".
const Set<SyncDomain> _kOutboxDomains = {
  SyncDomain.ledger,
  SyncDomain.planning,
  SyncDomain.accounts,
  SyncDomain.children,
};

class SyncStatus {
  const SyncStatus({
    required this.kind,
    this.count = 0,
    this.waitingForConnection = 0,
    this.waitingForServer = 0,
    this.needsAttention = 0,
    this.stayFailed = 0,
    this.lastSuccessAt,
    this.nextRetryAt,
  });

  final SyncStatusKind kind;

  /// Headline number for [kind]: changes waiting / kept on device / failed.
  final int count;

  /// Sheet breakdown. Connection = retrying, dependency, auth, owner waits;
  /// server = held until the server supports the shape (awaiting FX / exact
  /// transport); attention = dead letters + terminally failed mappings.
  final int waitingForConnection;
  final int waitingForServer;
  final int needsAttention;

  /// Subset of [needsAttention] that a plain Retry cannot fix (business-rule
  /// duplicates, unsupported operations): they stay failed and are listed.
  final int stayFailed;

  /// Most recent successful push or pull across all domains.
  final DateTime? lastSuccessAt;
  final DateTime? nextRetryAt;

  bool get isFailed => kind == SyncStatusKind.failed;

  /// Whether the Retry action is meaningful.
  bool get canRetry =>
      kind == SyncStatusKind.waiting ||
      kind == SyncStatusKind.failed ||
      kind == SyncStatusKind.syncing;

  static SyncStatus derive({
    required SyncQueueCounts counts,
    required Map<SyncDomain, SyncDomainHealth> health,
    required bool cloudConsent,
    required SyncIdentity identity,
    required bool syncRunning,
  }) {
    final serverWait =
        (counts.parkedByReason[kParkAwaitingServerFxSupport] ?? 0) +
            (counts.parkedByReason[exactMoneyTransportUnverifiedReason] ?? 0);
    final queued = counts.pending +
        counts.parked +
        counts.smartInboxPendingSync +
        counts.senderMappingsPending +
        (counts.senderMappingsFailed - counts.senderMappingsPermanentFailed) +
        // D-5: server-less local rows awaiting backfill are not in any outbox but
        // are NOT in the cloud either.
        counts.unprovenLocalRows;
    final connectionWait = queued - serverWait;
    // D-5: an unresolved conflict needs the user's decision — never "synced".
    final attention = counts.deadLetter +
        counts.senderMappingsPermanentFailed +
        counts.conflicts;
    final stayFailed = (counts.deadLetterByReason[kFailDuplicateBusinessKey] ??
            0) +
        (counts.deadLetterByReason[kFailUnsupportedOperation] ?? 0);
    final kept = queued + attention;

    DateTime? latest(Iterable<DateTime?> xs) {
      DateTime? best;
      for (final x in xs) {
        if (x != null && (best == null || x.isAfter(best))) best = x;
      }
      return best;
    }

    final lastSuccess = latest([
      for (final h in health.values) ...[h.lastPushSuccessAt, h.lastPullSuccessAt],
    ]);
    final lastPush = latest([
      for (final d in _kOutboxDomains) health[d]?.lastPushSuccessAt,
    ]);

    SyncStatus make(SyncStatusKind kind, int count) => SyncStatus(
          kind: kind,
          count: count,
          waitingForConnection: connectionWait < 0 ? 0 : connectionWait,
          waitingForServer: serverWait,
          needsAttention: attention,
          stayFailed: stayFailed,
          lastSuccessAt: lastSuccess,
          nextRetryAt: counts.nextRetryAt,
        );

    if (identity != SyncIdentity.authenticated) {
      return make(SyncStatusKind.signedOut, kept);
    }
    if (!cloudConsent) return make(SyncStatusKind.consentOff, kept);
    if (attention > 0) return make(SyncStatusKind.failed, attention);
    // Offline truth: a run in progress must not mask work that is known to be
    // blocked on the network (outbox rows stalled on transientNetwork, or the
    // outbox domains' latest attempt failed offline). Report waiting(n) — runs
    // can be back-to-back/slow while offline, so `running` is nearly always true.
    final offlineBlocked = queued > 0 &&
        (counts.networkStalled > 0 ||
            _kOutboxDomains.any((d) {
              final h = health[d];
              return h != null &&
                  h.lastErrorClass == SyncErrorClass.offline &&
                  h.consecutiveFailures > 0;
            }));
    if (syncRunning && !offlineBlocked) {
      return make(SyncStatusKind.syncing, queued);
    }
    if (queued > 0 || counts.inFlight > 0) {
      return make(SyncStatusKind.waiting, queued > 0 ? queued : counts.inFlight);
    }
    // Nothing queued — but ALL-SYNCED additionally requires proof: a push
    // success at or after the newest local mutation. Without it the data is not
    // yet confirmed in the cloud, so the honest state is "syncing".
    final mutated = counts.lastLocalMutationAt;
    if (mutated != null && (lastPush == null || lastPush.isBefore(mutated))) {
      return make(SyncStatusKind.syncing, 0);
    }
    return make(SyncStatusKind.allSynced, 0);
  }
}

/// Process-wide "a sync run is in progress" signal. The AppShell orchestrator
/// brackets each run; the status surface listens. Counted, so overlapping
/// begin/end pairs cannot leave it stuck.
class SyncRunState extends ChangeNotifier {
  SyncRunState._();
  static final SyncRunState instance = SyncRunState._();

  int _depth = 0;
  bool get running => _depth > 0;

  void begin() {
    _depth++;
    if (_depth == 1) notifyListeners();
  }

  void end() {
    if (_depth == 0) return;
    _depth--;
    if (_depth == 0) notifyListeners();
  }
}
