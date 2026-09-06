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
  ///   confirmedUnchanged   the user accepted the parse as-is
  ///   correctedFinancial   a PROOF-RELEVANT field was changed.
  ///                        THE correctness-failure numerator
  ///   rejectedOrDeleted    the parse was thrown away rather than fixed
  ///   unresolved           no provenance event yet — the user has not acted.
  ///                        NEVER counted as correct
  ///
  /// ## Provenance, not timestamps
  ///
  /// These come from `proof_correction_events`, an append-only log written ONLY
  /// from the explicit user-intent repository methods. The earlier version
  /// inferred correction from `updated_at > created_at`, which was wrong in the
  /// dangerous direction: `confirm()` bumps `updated_at` exactly as an edit
  /// does, so a user AGREEING with the parse was indistinguishable from a user
  /// FIXING it.
  ///
  /// Every non-user writer — sync pull-apply, the import soft-hide, the
  /// migration timestamp repair — mutates `transactions` with raw SQL and never
  /// calls those methods, so it physically cannot emit a correction event. The
  /// immunity is structural rather than a filter someone must remember.
  ///
  /// A category-only, merchant-only, note-only or date-only edit logs
  /// `non_financial_edit` and is NOT a correctness failure.
  ///
  /// ## The release gate
  ///
  ///   financially wrong = correctedFinancial
  ///   gate: wouldHaveCommitted >= 1000 AND correctedFinancial == 0
  ///
  /// `unresolved` is reported separately and never counted as correct — a
  /// capture nobody has looked at is not evidence that the parse was right.

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
    // STRICT PRECEDENCE, applied in order, so every attributed observation
    // lands in exactly one bucket:
    //
    //   corrected_financial  >  rejected/vanished  >  confirmed  >  unresolved
    //
    // The earlier version let a CONFIRMED-then-VANISHED row match both
    // `confirmedUnchanged` and `rejectedOrDeleted` — double-counted, which drove
    // the `unresolved` remainder NEGATIVE. Each predicate below now excludes
    // everything above it.
    const evt = 'proof_correction_events';
    const hasCorrected = 'EXISTS (SELECT 1 FROM $evt ec '
        "WHERE ec.transaction_id = s.transaction_id "
        "AND ec.event_type = 'corrected_financial')";
    const goneOrRejected = '(EXISTS (SELECT 1 FROM $evt er '
        "WHERE er.transaction_id = s.transaction_id "
        "AND er.event_type = 'rejected_or_deleted') "
        'OR NOT EXISTS (SELECT 1 FROM transactions t '
        'WHERE t.id = s.transaction_id))';

    final correctedFinancial =
        await count("$attributed AND s.transaction_id != '' AND $hasCorrected");

    // A vanished row counts here too: the parse did not survive, and calling
    // that "unresolved" would flatter the gate.
    final rejectedOrDeleted = await count(
        "$attributed AND s.transaction_id != '' "
        'AND NOT $hasCorrected AND $goneOrRejected');

    final confirmedUnchanged = await count(
        "$attributed AND s.transaction_id != '' "
        'AND NOT $hasCorrected AND NOT $goneOrRejected '
        'AND EXISTS (SELECT 1 FROM $evt e WHERE e.transaction_id = '
        "s.transaction_id AND e.event_type = 'confirmed')");

    // Remainder: attributed, still present, and no decisive event yet.
    final unresolved = wouldCommit -
        unattributed -
        correctedFinancial -
        rejectedOrDeleted -
        confirmedUnchanged;

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
      confirmedUnchanged: confirmedUnchanged,
      correctedFinancial: correctedFinancial,
      rejectedOrDeleted: rejectedOrDeleted,
      unattributed: unattributed,
      unresolved: unresolved,
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
    required this.confirmedUnchanged,
    required this.correctedFinancial,
    required this.rejectedOrDeleted,
    required this.unattributed,
    required this.unresolved,
    required this.refusalBreakdown,
  });

  final String engineVersion;
  final int attempted;
  final int evaluated;
  final int refusedToPropose;
  final int evaluationErrors;
  final int wouldHaveCommitted;

  /// The user accepted the parse as-is — an explicit `confirmed` event with no
  /// financial correction after it.
  final int confirmedUnchanged;

  /// A Proof-relevant field was changed. THE correctness-failure numerator.
  final int correctedFinancial;

  /// Thrown away rather than fixed, or the row no longer exists.
  final int rejectedOrDeleted;

  /// No transaction id — refusal, error, or no row created.
  final int unattributed;

  /// Attributed but no decisive event yet. NEVER counted as correct: a capture
  /// nobody has looked at is not evidence that the parse was right.
  final int unresolved;
  final Map<String, int> refusalBreakdown;

  /// Every attempted evaluation lands in exactly one bucket. If this is ever
  /// false the denominator is lying, so it is asserted rather than assumed.
  bool get partitionsCleanly =>
      evaluated + refusedToPropose + evaluationErrors == attempted;

  /// The would-have-committed population likewise partitions completely — no
  /// observation is silently dropped, including deleted transactions.
  bool get attributionPartitionsCleanly =>
      confirmedUnchanged +
          correctedFinancial +
          rejectedOrDeleted +
          unattributed +
          unresolved ==
      wouldHaveCommitted;

  /// Observations a human actually resolved. This — not `wouldHaveCommitted` —
  /// is the evidence base.
  int get resolvedObservations =>
      confirmedUnchanged + correctedFinancial + rejectedOrDeleted;

  /// THE RELEASE GATE.
  ///
  /// n counts RESOLVED observations, not merely attributed ones. A naive
  /// `wouldHaveCommitted >= 1000` passes vacuously when all 1000 captures are
  /// sitting unlooked-at: zero corrections found because nobody looked. That is
  /// a falsely-passing safety gate, which is the one failure mode this whole
  /// exercise exists to prevent. `unresolved` is never evidence of correctness.
  bool meetsTier2Gate({int minObservations = 1000}) =>
      resolvedObservations >= minObservations && correctedFinancial == 0;
}
