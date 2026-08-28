import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5 closure) §Blocker-1 — the DURABLE
// restore-operation journal (Drift table `restore_operations`, schema v28). It
// replaces the in-memory replay guard so a crash or acknowledgement loss cannot
// cause a destructive restore to run twice. Only privacy-safe fields are stored;
// the `committed` transition is written INSIDE the restore transaction so it is
// atomic with the restored data.

enum RestoreJournalState {
  prepared,
  mutating,
  committed,
  acknowledged,
  failedBeforeMutation,
  rolledBack,
  recoveryRequired,
}

class RestoreJournalRecord {
  const RestoreJournalRecord({
    required this.operationId,
    required this.sourceFingerprint,
    required this.envelopeVersion,
    required this.snapshotSchemaVersion,
    required this.ownerGenerationHash,
    required this.state,
    required this.preparedAt,
    required this.committedAt,
    required this.acknowledgedAt,
    required this.terminalErrorClass,
  });

  final String operationId;
  final String sourceFingerprint;
  final int envelopeVersion;
  final int snapshotSchemaVersion;
  final String? ownerGenerationHash;
  final RestoreJournalState state;
  final String preparedAt;
  final String? committedAt;
  final String? acknowledgedAt;
  final String? terminalErrorClass;

  bool get isCommitted =>
      state == RestoreJournalState.committed ||
      state == RestoreJournalState.acknowledged;
}

class RestoreJournal {
  RestoreJournal(this._db);

  final AppDatabase _db;

  static RestoreJournalState _parseState(String raw) =>
      RestoreJournalState.values.firstWhere((s) => s.name == raw,
          orElse: () => RestoreJournalState.prepared);

  Future<RestoreJournalRecord?> find(String operationId) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM restore_operations WHERE operation_id = ? LIMIT 1;',
          variables: [Variable.withString(operationId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final r = rows.first;
    return RestoreJournalRecord(
      operationId: r.read<String>('operation_id'),
      sourceFingerprint: r.read<String>('source_fingerprint'),
      envelopeVersion: r.read<int>('envelope_version'),
      snapshotSchemaVersion: r.read<int>('snapshot_schema_version'),
      ownerGenerationHash: r.readNullable<String>('owner_generation_hash'),
      state: _parseState(r.read<String>('state')),
      preparedAt: r.read<String>('prepared_at'),
      committedAt: r.readNullable<String>('committed_at'),
      acknowledgedAt: r.readNullable<String>('acknowledged_at'),
      terminalErrorClass: r.readNullable<String>('terminal_error_class'),
    );
  }

  /// Upsert the `prepared` marker before mutation (its own transaction — it must
  /// persist even if the restore later rolls back, so an abandoned prepare is
  /// discoverable).
  Future<void> markPrepared({
    required String operationId,
    required String sourceFingerprint,
    required int envelopeVersion,
    required int snapshotSchemaVersion,
    required String? ownerGenerationHash,
    required String nowIso,
  }) async {
    await _db.customStatement(
      'INSERT INTO restore_operations(operation_id, source_fingerprint, '
      'envelope_version, snapshot_schema_version, owner_generation_hash, state, '
      'prepared_at, committed_at, acknowledged_at, terminal_error_class) '
      "VALUES (?, ?, ?, ?, ?, 'prepared', ?, NULL, NULL, NULL) "
      'ON CONFLICT(operation_id) DO UPDATE SET '
      "state = 'prepared', prepared_at = excluded.prepared_at, "
      'committed_at = NULL, acknowledged_at = NULL, terminal_error_class = NULL;',
      [
        operationId,
        sourceFingerprint,
        envelopeVersion,
        snapshotSchemaVersion,
        ownerGenerationHash,
        nowIso,
      ],
    );
  }

  /// Write the `committed` transition — call INSIDE the restore transaction so it
  /// commits atomically with the restored data (and rolls back with it on failure).
  Future<void> markCommittedInTransaction(
      String operationId, String nowIso) async {
    await _db.customStatement(
      "UPDATE restore_operations SET state = 'committed', committed_at = ? "
      'WHERE operation_id = ?;',
      [nowIso, operationId],
    );
  }

  /// Audit **H-20**. A COMMITTED operation can never be relabelled rolled back.
  ///
  /// `markCommittedInTransaction` writes its marker INSIDE the destructive
  /// transaction, so a committed marker is durable proof that the replacement
  /// data is on disk. A later failure — a post-commit step, a lease release, a
  /// reopen — previously overwrote that marker with `rolledBack`, which both
  /// told the user their data survived when it had been replaced AND destroyed
  /// the evidence restart-recovery depends on.
  ///
  /// The `committed_at IS NULL` guard makes that impossible at the storage
  /// layer, for every caller, rather than relying on each call site to check.
  Future<void> markRolledBack(
      String operationId, String? errorClass, String nowIso) async {
    await _db.customStatement(
      "UPDATE restore_operations SET state = 'rolledBack', "
      'terminal_error_class = ? WHERE operation_id = ? '
      'AND committed_at IS NULL;',
      [errorClass, operationId],
    );
  }

  Future<void> markFailedBeforeMutation(
      String operationId, String? errorClass, String nowIso) async {
    await _db.customStatement(
      "UPDATE restore_operations SET state = 'failedBeforeMutation', "
      'terminal_error_class = ? WHERE operation_id = ?;',
      [errorClass, operationId],
    );
  }

  Future<void> markRecoveryRequired(String operationId, String nowIso) async {
    await _db.customStatement(
      "UPDATE restore_operations SET state = 'recoveryRequired' "
      'WHERE operation_id = ?;',
      [operationId],
    );
  }

  Future<void> markAcknowledged(String operationId, String nowIso) async {
    await _db.customStatement(
      "UPDATE restore_operations SET state = 'acknowledged', acknowledged_at = ? "
      "WHERE operation_id = ? AND state = 'committed';",
      [nowIso, operationId],
    );
  }

  /// Bounded retention — drop acknowledged / rolled-back / failed records older
  /// than [keepEntries] (keep the most recent). Recovery-required rows are kept.
  Future<void> prune({int keepEntries = 50}) async {
    await _db.customStatement(
      'DELETE FROM restore_operations WHERE operation_id IN ('
      '  SELECT operation_id FROM restore_operations '
      "  WHERE state IN ('acknowledged', 'rolledBack', 'failedBeforeMutation') "
      '  ORDER BY prepared_at DESC LIMIT -1 OFFSET ?);',
      [keepEntries],
    );
  }
}
