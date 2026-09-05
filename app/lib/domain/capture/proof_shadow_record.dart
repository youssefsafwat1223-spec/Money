/// PHASE 11 — one durable shadow observation.
///
/// ## What this may and may not contain
///
/// Shadow measurement needs to answer "would this have committed, and was it
/// right?" — a question about OUTCOMES, not about money. So every field here is
/// an enum name, a boolean, or a small integer. There is deliberately no amount,
/// no currency value, no merchant, no direction value and no message text.
///
/// The field comparisons are stored as MATCH OUTCOMES (`matched` / `mismatched`
/// / `absent`) rather than as the compared values, because storing the values
/// would reconstruct the transaction inside a diagnostic table that exists for a
/// completely different purpose and has a different lifetime.
///
/// The only message-derived value is [evaluationKey], a truncated SHA-256 used
/// solely for idempotency. It is one-way, local, and lives in the same
/// SQLCipher-encrypted database that already stores the transactions themselves
/// and a `dedup_hashes` table built on the same principle.
library;

import '../../engine/proof/proof_checker.dart';
import 'proof_commit_gate.dart';
import 'proof_proposal_builder.dart';

/// Per-field agreement, without the field's value.
enum ProofFieldMatch { matched, mismatched, absent }

class ProofShadowRecord {
  const ProofShadowRecord({
    required this.evaluationKey,
    required this.evaluatedAt,
    this.transactionId,
    required this.engineVersion,
    required this.gateMode,
    required this.outcome,
    required this.wouldHaveCommitted,
    required this.parseConfidencePermille,
    required this.confidenceMinPermille,
    required this.proofVerdict,
    required this.amountMatch,
    required this.directionMatch,
    required this.currencyMatch,
    required this.refusal,
  });

  /// Idempotency key: truncated SHA-256 over engine version + message. Two
  /// evaluations of the SAME capture under the SAME engine are one observation,
  /// so reprocessing cannot inflate the Tier 2 denominator.
  final String evaluationKey;
  final DateTime evaluatedAt;

  /// The transaction this evaluation influenced, when one was created.
  ///
  /// `transactions.id` is the stable identity that actually exists in
  /// production: it never changes across edits, and it is what any later
  /// correction is applied to. `capture_uuid` was the obvious candidate but its
  /// pipeline (`capture_work_items`) has no production writer, so joining on it
  /// would produce a table of nulls.
  ///
  /// Null when no transaction was created (a refusal, an error, or a capture
  /// that produced no row) — those observations still count in the denominator
  /// and are classified `unattributed` rather than dropped.
  final String? transactionId;

  /// Reproducibility: which gate/engine produced this row. A threshold or
  /// engine change makes old rows non-comparable, and without this the mixed
  /// population would be silently averaged.
  final String engineVersion;

  final ProofGateMode gateMode;
  final ProofGateOutcome outcome;

  /// True when the gate agreed — i.e. armed, this capture would have been
  /// committed without a human seeing it. The Tier 2 numerator.
  final bool wouldHaveCommitted;

  final int parseConfidencePermille;
  final int confidenceMinPermille;

  /// Null when Proof did not run (no proposal, or an engine error).
  final ProofVerdict? proofVerdict;

  final ProofFieldMatch amountMatch;
  final ProofFieldMatch directionMatch;
  final ProofFieldMatch currencyMatch;

  /// Why no proposal was built, if that is why this was not evaluated. The
  /// field that makes a refusal rate diagnosable instead of an opaque
  /// denominator loss.
  final ProofProposalRefusal? refusal;

  Map<String, Object?> toRow() => {
        'evaluation_key': evaluationKey,
        'evaluated_at': evaluatedAt.toUtc().toIso8601String(),
        'transaction_id': transactionId,
        'engine_version': engineVersion,
        'gate_mode': gateMode.name,
        'outcome': outcome.name,
        'would_have_committed': wouldHaveCommitted ? 1 : 0,
        'parse_confidence_permille': parseConfidencePermille,
        'confidence_min_permille': confidenceMinPermille,
        'proof_verdict': proofVerdict?.name,
        'amount_match': amountMatch.name,
        'direction_match': directionMatch.name,
        'currency_match': currencyMatch.name,
        'refusal_reason': refusal?.name,
      };
}
