import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/sync/seq_pull.dart' show SyncPullStop;
import '../../data/sync/server_capabilities.dart' show ServerCapabilityState;
import 'sync_health.dart' show SyncPullObservation;
import 'sync_status.dart' show SyncPullProof;

/// WP-8: every table's sequence cursor of [uid] (`seq:<uid>:<entity>`), as the
/// integers WP-4 stores. Counts only; no row content.
Future<List<int>> readSeqCursors(AppDatabase db, String uid) async {
  final rows = await db
      .customSelect('SELECT last_id FROM sync_cursors WHERE entity LIKE '
          "${sqlString('seq:$uid:%')};")
      .get();
  return [for (final r in rows) int.tryParse(r.read<String>('last_id')) ?? 0];
}

/// Derives the head proof the status needs (plan §13: "the last pull reached
/// server last_seq with a matching epoch"). Pure over what the pull gate
/// recorded plus the local cursors; it never calls the network.
///
/// With the sequence pull not active (capability not verified, or no server
/// head to compare with) the answer is [SyncPullProof.notApplicable], which
/// leaves the legacy "all synced" rule untouched.
Future<SyncPullProof> deriveSyncPullProof({
  required AppDatabase db,
  required String? uid,
  required ServerCapabilityState syncSeq,
  required SyncPullObservation? observation,
  required bool rebootstrapPending,
}) async {
  if (uid == null || syncSeq != ServerCapabilityState.verified) {
    return SyncPullProof.notApplicable;
  }
  if (rebootstrapPending) return SyncPullProof.stoppedTransient;
  final stop = observation?.stop;
  if (stop == SyncPullStop.epochMismatch) return SyncPullProof.stoppedEpoch;
  if (stop != null) return SyncPullProof.stoppedTransient;
  if (observation == null) return SyncPullProof.behind;
  final head = observation.headSeq;
  if (head == null) return SyncPullProof.notApplicable;
  if (head == 0) return SyncPullProof.proven; // an empty stream: nothing to pull
  final cursors = await readSeqCursors(db, uid);
  if (cursors.isEmpty || cursors.any((c) => c < head)) {
    return SyncPullProof.behind;
  }
  return SyncPullProof.proven;
}
