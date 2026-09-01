/// PHASE 9 — the assist/review states a capture can be in.
///
/// ## Why this is one enum rather than a pile of booleans
///
/// A capture is "pending" for very different reasons — the model has not run,
/// the device is offline, the model ran and the proof checker refused it, the
/// message was not a transaction at all. Collapsing those into a single
/// `isPending` flag loses exactly the information the user needs to act, and
/// makes it impossible to tell a temporary state from a decided one.
///
/// So each state carries what the UI must know: whether it is terminal, whether
/// retrying makes sense, and whether the user is being asked a question.
///
/// ## What a state may NOT do
///
/// None of these carries authority. A review state describes what the system
/// believes; changing a transaction still goes through the domain layer and the
/// Phase-10 CAS. In particular [proven] does not mean "committed" — Phase 11
/// (auto-commit) remains blocked, so proven still surfaces for confirmation.
library;

enum CaptureReviewState {
  /// The proof checker returned PROVEN. Still surfaced for confirmation:
  /// auto-commit is Phase 11 and is blocked.
  proven,

  /// The model has not answered yet. Transient, not a decision.
  pendingAi,

  /// No connectivity, so the model has not been asked yet. Distinct from
  /// [pendingAi] because the remedy is different and the user can see why.
  offlinePending,

  /// Two or more numbers could be the transaction amount and deterministic
  /// evidence does not settle it. The user is asked WHICH.
  amountConflict,

  /// The currency could not be established, or two candidates disagree.
  currencyConflict,

  /// Direction is not corroborated by any deterministic source.
  directionAmbiguous,

  /// Deterministic sources disagree about direction. Stronger than
  /// [directionAmbiguous]: something asserted the opposite, so it is never
  /// resolved by picking one.
  directionConflict,

  /// Amount, currency and direction are settled; only the category is unclear.
  /// The money is right, so this is the mildest question the app can ask.
  categoryAmbiguous,

  /// The message is not a committable transaction — declined, OTP,
  /// promotional, a balance notice, an unpaid obligation.
  rejectedNotTransaction,

  /// The attempt failed for an operational reason. Retrying is meaningful,
  /// unlike every other non-terminal state here.
  retryableFailure;

  /// Whether the system is still working and the user need do nothing.
  bool get isTransient =>
      this == CaptureReviewState.pendingAi ||
      this == CaptureReviewState.offlinePending ||
      this == CaptureReviewState.retryableFailure;

  /// Whether the user is being asked to decide something.
  bool get needsUserDecision =>
      this == CaptureReviewState.amountConflict ||
      this == CaptureReviewState.currencyConflict ||
      this == CaptureReviewState.directionAmbiguous ||
      this == CaptureReviewState.directionConflict ||
      this == CaptureReviewState.categoryAmbiguous;

  /// Whether re-running the model could change the outcome.
  ///
  /// Deliberately narrow. Re-running on an ambiguity the DETERMINISTIC layer
  /// refused would just spend money to be refused again — the ambiguity is a
  /// property of the message, not of the attempt.
  bool get isRetryable =>
      this == CaptureReviewState.retryableFailure ||
      this == CaptureReviewState.offlinePending;

  /// Whether the state is final absent a user action.
  bool get isTerminal =>
      this == CaptureReviewState.proven ||
      this == CaptureReviewState.rejectedNotTransaction;
}

/// What the user did with a reviewed capture. Instrumentation only.
///
/// Recorded so that Phase 9's real purpose — collecting genuine labels — has
/// something to collect. These are OBSERVATIONS OF REAL USER ACTIONS. Nothing
/// here may be synthesised, inferred from a heuristic, or back-filled: a
/// fabricated label is worse than no label, because it would silently become
/// evidence for a later gate.
enum CaptureReviewAction { accepted, corrected, dismissed }

/// Which field a correction changed.
///
/// `direction` is called out because a wrong direction is a wrong-signed
/// transaction — the most damaging single-field error the system can make, and
/// the one whose correction rate matters most.
enum CorrectedField { amount, currency, direction, type, category, merchant }

/// One observed review outcome. Privacy-safe: identities and enums only, never
/// message text, never a merchant string, never an amount.
class CaptureReviewOutcome {
  const CaptureReviewOutcome({
    required this.captureUuid,
    required this.state,
    required this.action,
    this.correctedFields = const {},
  });

  final String captureUuid;
  final CaptureReviewState state;
  final CaptureReviewAction action;

  /// Empty unless [action] is [CaptureReviewAction.corrected].
  final Set<CorrectedField> correctedFields;

  bool get correctedDirection =>
      correctedFields.contains(CorrectedField.direction);

  /// Telemetry shape. Contains no free text by construction — a reviewer can
  /// verify that from the types alone rather than by auditing call sites.
  Map<String, Object?> toTelemetry() => {
        'capture_uuid': captureUuid,
        'review_state': state.name,
        'review_action': action.name,
        'corrected_fields': correctedFields.map((f) => f.name).toList()..sort(),
        'corrected_direction': correctedDirection,
      };
}
