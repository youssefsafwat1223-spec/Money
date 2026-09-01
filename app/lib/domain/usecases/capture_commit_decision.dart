import '../entities/transaction_entity.dart';
import '../../engine/parser/capture_money.dart';

/// The single authority deciding whether a CAPTURED bank message may create or
/// confirm financial ledger rows.
///
/// ## Why this exists
///
/// Before this seam, one captured message could produce two financial rows
/// whose commit status was decided in two unrelated places: the primary row
/// from `canAutoConfirm` (parse confidence, category confidence, new merchant,
/// direction contradiction) and the FEE row from a direct
/// `resolveAiCaptureIngress` call that bypassed `canAutoConfirm` entirely. A
/// future change could therefore secure the primary row and silently leave fees
/// uncontrolled — which is exactly the failure mode a proof-carrying commit gate
/// must not inherit.
///
/// Both decisions now flow through this one object. It does **not** change what
/// they decide.
///
/// ## What this class deliberately does NOT do
///
/// * It does not alter any current outcome. Every factory below reproduces the
///   pre-existing expression verbatim; Phase-1 is seam extraction only, proved
///   by `test/domain/capture_commit_characterization_test.dart`.
/// * It does not know about proof verdicts, evidence graphs or AI. Those attach
///   here in later phases, which is the point of introducing it now.
/// * It does not govern MANUAL entry. `SaveManualTransactionUseCase` is a
///   separate class and stays outside capture authority: a user typing a
///   transaction is not a captured message and must not be gated by parser
///   confidence.
class CaptureCommitDecision {
  const CaptureCommitDecision._({
    required this.status,
    required this.reason,
  });

  /// The status the ledger row must receive.
  final TransactionStatus status;

  /// Why, in machine-readable form. Diagnostics and tests only — never user
  /// copy. Later phases extend this vocabulary with proof reasons.
  final CaptureCommitReason reason;

  bool get isConfirmed => status == TransactionStatus.confirmed;

  /// The PRIMARY row produced by a captured message.
  ///
  /// Verbatim port of the pre-seam expression:
  /// `(canAutoConfirm && !foreignUnpriced && !requiresReview)`.
  factory CaptureCommitDecision.primary({
    required bool canAutoConfirm,
    required bool foreignUnpriced,
    required bool requiresReview,
  }) {
    if (!canAutoConfirm) {
      return const CaptureCommitDecision._(
        status: TransactionStatus.pending,
        reason: CaptureCommitReason.lowConfidenceOrNewMerchant,
      );
    }
    if (foreignUnpriced) {
      return const CaptureCommitDecision._(
        status: TransactionStatus.pending,
        reason: CaptureCommitReason.foreignUnpriced,
      );
    }
    if (requiresReview) {
      return const CaptureCommitDecision._(
        status: TransactionStatus.pending,
        reason: CaptureCommitReason.nonExactAmountIngress,
      );
    }
    return const CaptureCommitDecision._(
      status: TransactionStatus.confirmed,
      reason: CaptureCommitReason.autoConfirmed,
    );
  }

  /// The FEE row produced by the same captured message.
  ///
  /// Verbatim port of the pre-seam expression: the fee line obeys the
  /// `resolveAiCaptureIngress` contract (MALI-026 / B8-2.10 §12) — a non-exact
  /// fee amount cannot auto-confirm in canonical mode.
  ///
  /// It deliberately does NOT consult `canAutoConfirm` today, because it never
  /// did. Routing it through this class changes where the decision lives, not
  /// what it decides; unifying the two policies would be a behaviour change and
  /// belongs to a later, separately-approved phase.
  factory CaptureCommitDecision.fee({
    required bool hasExactText,
    required bool canonicalMode,
  }) {
    final ingress = resolveAiCaptureIngress(
      hasExactText: hasExactText,
      canonicalMode: canonicalMode,
    );
    return ingress == AiCaptureIngress.legacyPendingReview
        ? const CaptureCommitDecision._(
            status: TransactionStatus.pending,
            reason: CaptureCommitReason.nonExactAmountIngress,
          )
        : const CaptureCommitDecision._(
            status: TransactionStatus.confirmed,
            reason: CaptureCommitReason.autoConfirmed,
          );
  }

  @override
  String toString() => 'CaptureCommitDecision(${status.name}, ${reason.name})';
}

/// Machine-readable justification for a capture commit decision.
enum CaptureCommitReason {
  /// Every current gate passed.
  autoConfirmed,

  /// Parse/category confidence below threshold, an unseen merchant, or an
  /// independent direction contradiction.
  lowConfidenceOrNewMerchant,

  /// Foreign-currency spend on a home-currency card, parked awaiting pricing.
  foreignUnpriced,

  /// The amount reached canonical mode without verified exact text
  /// (`AiCaptureIngress.legacyPendingReview`).
  nonExactAmountIngress,
}
