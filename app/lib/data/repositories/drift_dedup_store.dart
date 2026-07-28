import 'package:drift/drift.dart';

import '../../domain/repositories/dedup_store.dart';
import '../db/app_database.dart';

class DriftDedupStore implements DedupStore {
  const DriftDedupStore(this._db);

  final AppDatabase _db;

  /// Runs [action] inside ONE transaction on the same database the dedup
  /// markers live in — used to commit an imported transaction together with
  /// its payload marker atomically (MALI-012): a kill between the two can
  /// no longer leave an imported row whose payload re-imports as a duplicate.
  Future<T> runAtomically<T>(Future<T> Function() action) =>
      _db.transaction(action);

  /// Joins `transactions` and skips deleted ones (status 'ignored'): once the
  /// user deletes a transaction, re-adding the same SMS must be allowed again,
  /// otherwise the stale hash would keep reporting "already recorded".
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async {
    final row = await _db.customSelect(
      '''
        SELECT d.transaction_id FROM dedup_hashes d
        LEFT JOIN transactions t ON t.id = d.transaction_id
        WHERE d.hash = ?
          AND (t.status IS NULL OR t.status != 'ignored')
          AND d.occurred_at = ?
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
