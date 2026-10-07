import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';

/// CAP-5 — read side of the capture receipts in the active replica.
///
/// A receipt is the `dedup_hashes` row `capture_payload:<capture_id>` written in
/// the SAME local transaction as the transaction / Smart Inbox row it points at
/// (I-3). A capture has a local result when its receipt exists OR a transaction
/// with `id == capture_id` exists (I-5). A receipt outlives the transaction it
/// points at, so a deleted transaction is never resurrected by a redelivery.
class CaptureReceipts {
  const CaptureReceipts(this._db);

  final AppDatabase _db;

  static const String prefix = 'capture_payload:';
  static final RegExp _captureId = RegExp(r'^[0-9a-f]{64}$');

  Future<bool> hasReceiptOrTransaction(String captureId) async {
    // An old-build `rejected:` marker proves nothing unless the deterministic
    // review row it should have come with exists.
    final row = await _db.customSelect(
      'SELECT 1 AS hit FROM dedup_hashes d WHERE d.hash = ? AND '
      "(d.transaction_id NOT LIKE 'rejected:%' OR EXISTS ("
      "SELECT 1 FROM smart_inbox_items s WHERE s.id = ? AND s.payload_id = ?)) "
      'UNION ALL SELECT 1 FROM transactions WHERE id = ? LIMIT 1;',
      variables: [
        Variable.withString('$prefix$captureId'),
        Variable.withString('local_capture:$captureId'),
        Variable.withString(captureId),
        Variable.withString(captureId),
      ],
    ).getSingleOrNull();
    return row != null;
  }

  /// Every capture id the replica proves consumed: all receipts, plus every
  /// transaction whose id has the shape of a capture id (64 hex). The native
  /// layer intersects this with its own legacy items, so over-reporting is
  /// harmless.
  Future<List<String>> consumedCandidateIds() async {
    final ids = <String>{};
    final receipts = await _db.customSelect(
        'SELECT hash FROM dedup_hashes WHERE hash LIKE ?;',
        variables: [Variable.withString('$prefix%')]).get();
    for (final r in receipts) {
      final id = r.read<String>('hash').substring(prefix.length);
      if (_captureId.hasMatch(id)) ids.add(id);
    }
    final txs = await _db
        .customSelect(
          "SELECT id FROM transactions WHERE length(id) = 64;",
        )
        .get();
    for (final t in txs) {
      final id = t.read<String>('id');
      if (_captureId.hasMatch(id)) ids.add(id);
    }
    return ids.toList();
  }
}

/// `replica_meta.owner_uid` of [db]: the authoritative owner of the replica the
/// capture import is bound to (null when the file carries none).
Future<String?> replicaOwnerUid(AppDatabase db) async {
  final rows =
      await db.customSelect('SELECT owner_uid FROM replica_meta;').get();
  return rows.isEmpty ? null : rows.single.read<String>('owner_uid');
}
