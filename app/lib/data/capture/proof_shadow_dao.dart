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
        'direction_match, currency_match, refusal_reason, transaction_id'
        ') VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
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
          Variable<String>(row['transaction_id'] as String? ?? ''),
        ],
      );
    } catch (_) {
      // Diagnostics are never load-bearing.
    }
  }

  /// THE TIER 2 DENOMINATOR CONTRACT.
  ///
  /// One deterministic query, always scoped to a single [engineVersion] —
  /// never averaged across versions, because a threshold or engine change makes
  /// older observations non-comparable and blending them would silently produce
  /// a meaningless rate.
  ///
  /// Definitions, stated once so the n >= 1000 gate is unambiguous:
  ///
  ///   attempted        every evaluation the gate tried. THE DENOMINATOR.
  ///   evaluated        Proof ran and produced a verdict
  ///   refusedToPropose no proposal could be built (see refusal breakdown)
  ///   evaluationErrors evidence/checker failures — NOT refusals
  ///   wouldHaveCommitted  armed, these would have committed unseen.
  ///                       THE NUMERATOR for the safety question.
  ///
  /// Attribution, for the "was it right?" question:
  ///
  ///   autoConfirmedUntouched  committed at insert and never written since —
  ///                           the ONLY clean positive signal available
  ///   touchedAfterCreation    written after creation. NOT a correction count
  ///                           — see below
  ///   deleted                 the transaction is gone — classified, NOT dropped
  ///   unattributed            no transaction id (refusal/error/no row created)
  ///   stillPending            pending and never written since
  ///
  /// ## Why there is no "corrected" bucket
  ///
  /// An earlier version of this class had `laterCorrected`, inferred from
  /// `updated_at > created_at`, documented as an upper bound on real
  /// corrections. **That was wrong, and wrong in the dangerous direction.**
  ///
  /// `confirm()` bumps `updated_at`
  /// (`drift_transaction_repository.dart` — `UPDATE transactions SET status =
  /// 'confirmed' … updated_at = ?`). So a user CONFIRMING a pending capture —
  /// the action that means "the parse was RIGHT" — produced the same signal as
  /// a correction. `categorize`, soft delete, sync pull-apply, the import
  /// soft-hide and the migration timestamp repair all bump it too.
  ///
  /// So `touchedAfterCreation` does not bound corrections; it is saturated by
  /// the happy path. It is reported because dropping it would hide the
  /// population, not because it measures error.
  ///
  /// **Consequence for the release gate.** Tier 2's "would it have been
  /// right?" half is NOT answerable from this store today. The safety
  /// numerator (`wouldHaveCommitted`) is sound; the correctness numerator
  /// requires real edit provenance — a per-field edit log, or activating the
  /// dormant `capture_review_labels` pipeline, which has no production writer.
  /// Do not compute an error rate from these columns.
  Future<ProofTier2Summary> tier2Summary({
    required String engineVersion,
  }) async {
    Future<int> count(String where, [List<Variable<Object>>? vars]) async {
      final rows = await _db.customSelect(
        'SELECT COUNT(*) AS n FROM proof_shadow_evaluations s '
        'WHERE s.engine_version = ? $where',
        variables: <Variable<Object>>[
          Variable<String>(engineVersion),
          ...?vars,
        ],
      ).get();
      return rows.isEmpty ? 0 : (rows.first.read<int?>('n') ?? 0);
    }

    const errorOutcomes = "('evidenceError','checkerError')";
    final attempted = await count('');
    final errors = await count('AND s.outcome IN $errorOutcomes');
    final refused = await count("AND s.refusal_reason != '' "
        'AND s.outcome NOT IN $errorOutcomes');
    final wouldCommit = await count('AND s.would_have_committed = 1');
    final evaluated = attempted - errors - refused;

    // Attribution is scoped to the would-have-committed population: that is the
    // only set whose correctness the Tier 2 gate is about.
    const attributed = 'AND s.would_have_committed = 1';
    final unattributed = await count("$attributed AND s.transaction_id = ''");
    final deleted = await count("$attributed AND s.transaction_id != '' "
        'AND NOT EXISTS (SELECT 1 FROM transactions t '
        'WHERE t.id = s.transaction_id)');
    final autoConfirmedUntouched =
        await count("$attributed AND s.transaction_id != '' "
            'AND EXISTS (SELECT 1 FROM transactions t WHERE t.id = s.transaction_id '
            "AND t.status = 'confirmed' AND t.updated_at <= t.created_at)");
    final touched = await count("$attributed AND s.transaction_id != '' "
        'AND EXISTS (SELECT 1 FROM transactions t WHERE t.id = s.transaction_id '
        'AND t.updated_at > t.created_at)');
    final stillPending = await count("$attributed AND s.transaction_id != '' "
        'AND EXISTS (SELECT 1 FROM transactions t WHERE t.id = s.transaction_id '
        "AND t.status != 'confirmed' AND t.updated_at <= t.created_at)");

    final refusals = <String, int>{};
    final rows = await _db.customSelect(
      'SELECT refusal_reason AS r, COUNT(*) AS n FROM proof_shadow_evaluations '
      // An absent reason is stored as '' rather than NULL, because Drift binds
      // non-null variables. Filtering on IS NOT NULL alone would count every
      // successfully-proposed evaluation as a refusal.
      "WHERE engine_version = ? AND refusal_reason != '' GROUP BY refusal_reason",
      variables: <Variable<Object>>[Variable<String>(engineVersion)],
    ).get();
    for (final row in rows) {
      refusals[row.read<String>('r')] = row.read<int>('n');
    }

    return ProofTier2Summary(
      engineVersion: engineVersion,
      attempted: attempted,
      evaluated: evaluated,
      refusedToPropose: refused,
      evaluationErrors: errors,
      wouldHaveCommitted: wouldCommit,
      autoConfirmedUntouched: autoConfirmedUntouched,
      touchedAfterCreation: touched,
      deleted: deleted,
      unattributed: unattributed,
      stillPending: stillPending,
      refusalBreakdown: refusals,
    );
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

/// The Tier 2 evidence bundle for ONE engine version.
class ProofTier2Summary {
  const ProofTier2Summary({
    required this.engineVersion,
    required this.attempted,
    required this.evaluated,
    required this.refusedToPropose,
    required this.evaluationErrors,
    required this.wouldHaveCommitted,
    required this.autoConfirmedUntouched,
    required this.touchedAfterCreation,
    required this.deleted,
    required this.unattributed,
    required this.stillPending,
    required this.refusalBreakdown,
  });

  final String engineVersion;
  final int attempted;
  final int evaluated;
  final int refusedToPropose;
  final int evaluationErrors;
  final int wouldHaveCommitted;
  /// Committed at insert and never written since. The only clean positive.
  final int autoConfirmedUntouched;

  /// Written after creation. NOT a correction count — `confirm()` bumps
  /// `updated_at`, so this is saturated by ordinary confirmations.
  final int touchedAfterCreation;
  final int deleted;
  final int unattributed;
  final int stillPending;
  final Map<String, int> refusalBreakdown;

  /// Every attempted evaluation lands in exactly one bucket. If this is ever
  /// false the denominator is lying, so it is asserted rather than assumed.
  bool get partitionsCleanly =>
      evaluated + refusedToPropose + evaluationErrors == attempted;

  /// The would-have-committed population likewise partitions completely — no
  /// observation is silently dropped, including deleted transactions.
  bool get attributionPartitionsCleanly =>
      autoConfirmedUntouched +
          touchedAfterCreation +
          deleted +
          unattributed +
          stillPending ==
      wouldHaveCommitted;
}
