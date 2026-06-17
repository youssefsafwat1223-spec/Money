import 'package:drift/drift.dart';

import '../../domain/repositories/dedup_store.dart';
import '../db/app_database.dart';

class DriftDedupStore implements DedupStore {
  const DriftDedupStore(this._db);

  final AppDatabase _db;

  /// Sliding ±300 s window using SQLite julianday arithmetic.
  /// No fixed-bucket boundary issue: a duplicate arriving 3 min before or after
  /// the stored time is always caught.
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async {
    final row = await _db.customSelect(
      '''
        SELECT transaction_id FROM dedup_hashes
        WHERE hash = ?
          AND ABS(
            CAST(
              (julianday(?) - julianday(occurred_at)) * 86400.0
            AS INTEGER)
          ) <= 300
        LIMIT 1;
      ''',
      variables: [
        Variable.withString(hash),
        Variable.withString(occurredAt.toUtc().toIso8601String()),
      ],
    ).getSingleOrNull();
    return row?.read<String>('transaction_id');
  }

  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {
    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at)
        VALUES (?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(hash),
        Variable.withString(transactionId),
        Variable.withString(occurredAt.toUtc().toIso8601String()),
        Variable.withString(DateTime.now().toUtc().toIso8601String()),
      ],
    );
  }
}
