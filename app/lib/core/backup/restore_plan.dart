// MALI-014 / MALI-076n (Phase 6 Batch 5) — the immutable restore plan.
//
// Preparation produces exactly one RestorePlan; mutation consumes ONLY the plan.
// It holds sanitized, validated data and opaque protocol identifiers — NEVER the
// passphrase, derived key, SQLCipher key, raw unvalidated JSON, auth tokens, signed
// URLs, absolute private paths, or raw provider errors. Once built, nothing may
// introduce a new table/column and no unsupported field can reach SQL; changing the
// source requires building a new plan (a new operation).

class RestorePlan {
  RestorePlan({
    required this.operationId,
    required this.envelopeVersion,
    required this.snapshotSchemaVersion,
    required this.sourceFingerprint,
    required Map<String, List<Map<String, Object?>>> tables,
    required this.warnings,
  })  : tables = Map.unmodifiable({
          for (final e in tables.entries)
            e.key: List<Map<String, Object?>>.unmodifiable(
                e.value.map((r) => Map<String, Object?>.unmodifiable(r))),
        }),
        expectedRowCounts = Map.unmodifiable(
            {for (final e in tables.entries) e.key: e.value.length});

  /// Opaque per-operation id (not a timestamp). Bound 1:1 to [sourceFingerprint].
  final String operationId;

  /// The backup envelope version this plan was decoded from (1, 2, or 3).
  final int envelopeVersion;

  /// The snapshot schema version (drives compatibility transforms).
  final int snapshotSchemaVersion;

  /// A fingerprint of the immutable source bytes (opaque hex). Two plans over the
  /// same source share it; a different source yields a different fingerprint.
  final String sourceFingerprint;

  /// The validated, whitelisted table payloads — the ONLY data mutation consumes.
  final Map<String, List<Map<String, Object?>>> tables;

  /// Expected post-restore row count per table (before FK-repair transforms).
  final Map<String, int> expectedRowCounts;

  /// Privacy-safe notes safe to show the user (e.g. "restored a v2 backup"). Never
  /// raw snapshot fields or financial values.
  final List<String> warnings;

  int get totalRows =>
      expectedRowCounts.values.fold(0, (sum, n) => sum + n);

  /// Privacy-safe: reveals only shape, never row data.
  @override
  String toString() =>
      'RestorePlan(op:$operationId, env:v$envelopeVersion, schema:$snapshotSchemaVersion, '
      'tables:${tables.length}, rows:$totalRows)';
}
