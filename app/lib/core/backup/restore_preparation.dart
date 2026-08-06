import 'package:crypto/crypto.dart';

import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'restore_compatibility.dart';
import 'restore_plan.dart';
import 'restore_backup_usecase.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5) §2A/§3 — the restore PREPARATION phase.
// Runs entirely BEFORE the file-exclusive maintenance gate and mutates NO database
// row. It validates the decoded snapshot and produces an immutable [RestorePlan];
// mutation later consumes only the plan. A wrong passphrase, corrupted envelope,
// unsupported version, oversized source, or invalid schema all fail here (via the
// envelope reader upstream, or [BackupException] below) before any destructive work.
class RestorePreparation {
  const RestorePreparation._();

  /// Build an immutable plan from an already-decrypted [snapshot] (the envelope
  /// decode/decrypt + KDF/size limits are enforced upstream by the envelope reader,
  /// which produces typed errors). [sourceBytes] are the raw encrypted source, used
  /// only to compute the opaque source fingerprint — never retained in the plan.
  /// Throws [BackupException] on any structural/whitelist/schema failure.
  static RestorePlan build({
    required Map<String, dynamic> snapshot,
    required int envelopeVersion,
    required List<int> sourceBytes,
    required String operationId,
  }) {
    final schemaVersion = _schema(snapshot);
    if (schemaVersion > RestoreBackupUseCase.currentSchemaVersion) {
      throw const BackupException(
        'هذه النسخة الاحتياطية من إصدار أحدث من التطبيق. حدّث التطبيق ثم '
        'أعد المحاولة.',
      );
    }
    // Structural + sensitive-field + required-table validation (shared with the
    // mutation core). Throws BackupException on failure — before any mutation.
    final rawTables = RestoreBackupUseCase.validateTables(snapshot, schemaVersion);

    // Reject any table outside the restorable whitelist — an unknown table, or an
    // intentionally-excluded (remote/pending relay/cache) table, must never reach a
    // restore plan. Do not silently guess compatibility.
    for (final table in rawTables.keys) {
      if (!BackupSnapshotBuilder.restorableColumns.containsKey(table)) {
        throw BackupException(
          'النسخة الاحتياطية تحتوي على جدول غير مدعوم ("$table"). '
          'تعذّرت الاستعادة.',
        );
      }
    }

    // Sanitize to the whitelist: keep only backup-safe columns, dropping any other
    // field (e.g. a legacy db_encryption_key_ref value) so nothing unvalidated can
    // reach SQL from the plan.
    final sanitized = <String, List<Map<String, Object?>>>{};
    for (final entry in rawTables.entries) {
      final allowed = BackupSnapshotBuilder.restorableColumns[entry.key]!;
      final rows = <Map<String, Object?>>[];
      for (final row in (entry.value as List).cast<Map<String, dynamic>>()) {
        final clean = <String, Object?>{};
        for (final column in allowed) {
          if (row.containsKey(column)) clean[column] = row[column];
        }
        rows.add(clean);
      }
      sanitized[entry.key] = rows;
    }

    // §Blocker-2 — apply the EXPLICIT preparation-time adapter for this snapshot
    // version, normalizing to the current plan shape (verifies version-specific
    // required tables, applies any column defaults, records version warnings).
    final normalized = RestoreCompatibility.normalize(sanitized, schemaVersion);

    final warnings = <String>[
      if (envelopeVersion < 3) 'legacy_envelope_v$envelopeVersion',
      ...normalized.warnings,
    ];

    return RestorePlan(
      operationId: operationId,
      envelopeVersion: envelopeVersion,
      snapshotSchemaVersion: schemaVersion,
      sourceFingerprint: fingerprint(sourceBytes),
      tables: normalized.tables,
      warnings: warnings,
    );
  }

  static int _schema(Map<String, dynamic> snapshot) {
    final value = snapshot['schemaVersion'];
    return (value is int && value > 0) ? value : 1;
  }

  /// Opaque source fingerprint (sha256 hex of the raw encrypted source). Two plans
  /// over the same source share it; a different source yields a different one.
  static String fingerprint(List<int> sourceBytes) =>
      sha256.convert(sourceBytes).toString();
}
