import 'package:drift/drift.dart';

import '../../domain/capture/proof_shadow_record.dart';
import '../db/app_database.dart';

/// Durable local store for Proof shadow observations.
///
/// ## Idempotency, stated explicitly
///
/// `INSERT OR IGNORE` on the `evaluation_key` primary key. Re-processing the
/// same capture under the same engine version is ONE observation, not two —
/// otherwise a retry loop or a re-parse would inflate the Tier 2 denominator
/// and make the false-commit rate look better than it is. First write wins;
/// later evaluations of the same key are dropped, which is the correct bias
/// because the first is the one that actually influenced a commit.
///
/// ## Local-first
///
/// This table is never synced. It has no outbox row, no status column and no
/// remote counterpart — unlike `engagement_events`, which is a sync QUEUE and
/// was deliberately not reused for exactly that reason. Aggregation for Tier 2
/// happens on-device, or via an explicit separately-approved export.
class ProofShadowDao {
  ProofShadowDao(this._db);

  final AppDatabase _db;

  /// Never throws. A diagnostic write must not be able to affect a commit, so
  /// every failure — including a closed or migrating database — is swallowed
  /// here rather than at the call site, where a caller might forget.
  Future<void> record(ProofShadowRecord r) async {
    try {
      final row = r.toRow();
      await _db.customInsert(
        'INSERT OR IGNORE INTO proof_shadow_evaluations ('
        'evaluation_key, evaluated_at, engine_version, gate_mode, outcome, '
        'would_have_committed, parse_confidence_permille, '
        'confidence_min_permille, proof_verdict, amount_match, '
        'direction_match, currency_match, refusal_reason'
        ') VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>(row['evaluation_key'] as String),
          Variable<String>(row['evaluated_at'] as String),
          Variable<String>(row['engine_version'] as String),
          Variable<String>(row['gate_mode'] as String),
          Variable<String>(row['outcome'] as String),
          Variable<int>(row['would_have_committed'] as int),
          Variable<int>(row['parse_confidence_permille'] as int),
          Variable<int>(row['confidence_min_permille'] as int),
          Variable<String>(row['proof_verdict'] as String? ?? ''),
          Variable<String>(row['amount_match'] as String),
          Variable<String>(row['direction_match'] as String),
          Variable<String>(row['currency_match'] as String),
          Variable<String>(row['refusal_reason'] as String? ?? ''),
        ],
      );
    } catch (_) {
      // Diagnostics are never load-bearing.
    }
  }

  /// Tier 2 counting surface, ALWAYS scoped to one engine version.
  ///
  /// Scoping is not optional. `ProofShadowRecord` warns that a mixed population
  /// would be silently averaged, and an unscoped COUNT would do exactly that:
  /// the first engine bump would blend observations produced under different
  /// gates and thresholds into one meaningless rate. Requiring the caller to
  /// name a version makes that impossible to do by accident.
  Future<Map<String, int>> summary({required String engineVersion}) async {
    final out = <String, int>{};
    final totals = await _db.customSelect(
      'SELECT COUNT(*) AS n, SUM(would_have_committed) AS committed '
      'FROM proof_shadow_evaluations WHERE engine_version = ?',
      variables: <Variable<Object>>[Variable<String>(engineVersion)],
    ).get();
    if (totals.isNotEmpty) {
      out['evaluations'] = totals.first.read<int?>('n') ?? 0;
      out['would_have_committed'] = totals.first.read<int?>('committed') ?? 0;
    }
    final refusals = await _db.customSelect(
      'SELECT refusal_reason AS r, COUNT(*) AS n FROM proof_shadow_evaluations '
      // An absent reason is stored as '' rather than NULL, because Drift binds
      // non-null variables. Filtering on IS NOT NULL alone would count every
      // successfully-proposed evaluation as a refusal.
      "WHERE engine_version = ? AND refusal_reason != '' "
      'GROUP BY refusal_reason',
      variables: <Variable<Object>>[Variable<String>(engineVersion)],
    ).get();
    for (final row in refusals) {
      out['refusal_${row.read<String>('r')}'] = row.read<int>('n');
    }
    return out;
  }

  /// Which engine versions are present. A Tier 2 reader must know whether the
  /// population is mixed before trusting any single-version rate.
  Future<List<String>> engineVersions() async {
    final rows = await _db.customSelect(
      'SELECT DISTINCT engine_version AS v FROM proof_shadow_evaluations '
      'ORDER BY engine_version',
    ).get();
    return [for (final r in rows) r.read<String>('v')];
  }
}
