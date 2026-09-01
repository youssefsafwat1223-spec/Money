/// PHASE 10 — the single atomic authority for applying a proof result.
///
/// ## Why there is exactly one of these
///
/// A proof result can arrive from several directions: the shadow/AI path
/// finishing, a notification action being tapped, a retry after a crash, a
/// sync from another device. If each of those applied results in its own way,
/// "the newest write wins" would be decided by scheduling, and a result
/// computed before the user edited something could land after it.
///
/// So every future application of a proof result goes through [apply]. It is
/// the only place allowed to turn a model result into a change to a
/// transaction, and it decides by comparing REVISIONS rather than by trusting
/// arrival order.
///
/// ## The precedence rule, stated once
///
/// **A user edit always wins over an AI result.** Not "usually", and not "if it
/// arrived later" — a person who corrected an amount has told us something the
/// model does not know, and a result computed before that correction is stale
/// by definition even if it lands a millisecond after.
///
/// ## What "atomic" means here
///
/// Either the whole proof applies or none of it does. A partial application —
/// amount updated, direction not — would leave a transaction in a state no
/// model and no user ever chose, and nothing downstream could tell it apart
/// from a deliberate one. Hence [ProofApplyPlan]: the caller builds the whole
/// change, and it is committed or discarded as a unit.
library;

/// Why an apply was refused. Every rejection is explicit; there is no silent
/// no-op, because a caller that cannot tell "applied" from "ignored" will
/// eventually retry forever or drop a result on the floor.
enum ProofApplyRejection {
  /// The work item or transaction named does not exist.
  unknownTarget,

  /// The transaction moved on since the proof was computed — almost always a
  /// user edit. The proof loses.
  staleProofRevision,

  /// This exact result was already applied. Not an error: replay is expected
  /// after a crash or a duplicate delivery, and must be a no-op.
  alreadyApplied,

  /// The user edited while the model was running. The strongest form of the
  /// precedence rule.
  supersededByUserEdit,

  /// Another device applied first. Its result is authoritative; ours is not
  /// re-applied on top.
  supersededByRemote,
}

/// The outcome of an apply attempt.
class ProofApplyResult {
  const ProofApplyResult.applied(this.newRevision)
      : rejection = null,
        wasNoOp = false;

  const ProofApplyResult.rejected(this.rejection, this.newRevision)
      : wasNoOp = false;

  /// A replay of something already applied. Not a failure.
  const ProofApplyResult.noOp(this.newRevision)
      : rejection = ProofApplyRejection.alreadyApplied,
        wasNoOp = true;

  final ProofApplyRejection? rejection;
  final int newRevision;
  final bool wasNoOp;

  bool get isApplied => rejection == null;

  /// True when the caller should stop retrying. A stale or superseded result
  /// will never become valid by being retried — the world moved on.
  bool get isTerminal =>
      isApplied ||
      wasNoOp ||
      rejection == ProofApplyRejection.staleProofRevision ||
      rejection == ProofApplyRejection.supersededByUserEdit ||
      rejection == ProofApplyRejection.supersededByRemote;
}

/// The complete set of changes one proof result wants to make.
///
/// Built whole and applied whole. The `fee` is explicit rather than implied:
/// a capture that produces both a primary amount and a fee must apply both or
/// neither, or the ledger gains a purchase without its charge.
class ProofApplyPlan {
  const ProofApplyPlan({
    required this.captureUuid,
    required this.transactionId,
    required this.expectedRevision,
    required this.proofRevision,
    this.amountMinor,
    this.currency,
    this.direction,
    this.type,
    this.category,
    this.feeAmountMinor,
    this.feeCurrency,
  });

  /// Work-item identity — what the result was computed FOR.
  final String captureUuid;

  /// The EXISTING transaction this updates. Never null: applying a proof
  /// updates a transaction, it never creates a second one. A capture that has
  /// no transaction yet is not ready for this authority.
  final String transactionId;

  /// The transaction revision the proof was computed against. If the stored
  /// revision differs, something changed underneath us.
  final int expectedRevision;

  /// Identity of the proof result itself, so a replay of the SAME result is
  /// recognisable as a replay rather than as a competing write.
  final int proofRevision;

  final int? amountMinor;
  final String? currency;
  final String? direction;
  final String? type;
  final String? category;

  /// Fee leg. Explicitly part of the same atomic unit.
  final int? feeAmountMinor;
  final String? feeCurrency;

  bool get hasFee => feeAmountMinor != null;
}

/// The state [ProofApplyAuthority] compares against. Supplied by the caller so
/// this class stays pure and testable; the real implementation reads it inside
/// the same transaction as the write.
class TargetState {
  const TargetState({
    required this.exists,
    required this.revision,
    required this.appliedProofRevision,
    required this.userEditedAtRevision,
    this.remoteAppliedProofRevision,
  });

  final bool exists;

  /// Current transaction revision.
  final int revision;

  /// The proof revision already applied here, or null.
  final int? appliedProofRevision;

  /// The revision at which the user last edited by hand, or null.
  final int? userEditedAtRevision;

  /// A proof revision applied by another device, or null.
  final int? remoteAppliedProofRevision;
}

class ProofApplyAuthority {
  const ProofApplyAuthority();

  /// Decide whether [plan] may be applied against [current].
  ///
  /// Ordering matters and is deliberate:
  ///   1. existence — nothing else is meaningful without a target;
  ///   2. replay — checked BEFORE staleness, because a replay of the applied
  ///      result is a no-op even though its expected revision is now old.
  ///      Checking staleness first would report a confusing failure for the
  ///      most ordinary case there is;
  ///   3. user edit — the precedence rule, ahead of the generic revision check
  ///      so the rejection names the real reason;
  ///   4. remote apply;
  ///   5. generic staleness.
  ProofApplyResult decide(ProofApplyPlan plan, TargetState current) {
    if (!current.exists) {
      return ProofApplyResult.rejected(
          ProofApplyRejection.unknownTarget, current.revision);
    }

    // 2. Replay of the same result — expected after a crash or duplicate
    // delivery, and must be harmless.
    if (current.appliedProofRevision == plan.proofRevision) {
      return ProofApplyResult.noOp(current.revision);
    }

    // 3. The user edited after the proof was computed. This outranks
    // everything: they know something the model does not.
    final editedAt = current.userEditedAtRevision;
    if (editedAt != null && editedAt > plan.expectedRevision) {
      return ProofApplyResult.rejected(
          ProofApplyRejection.supersededByUserEdit, current.revision);
    }

    // 4. Another device already applied a NEWER proof.
    final remote = current.remoteAppliedProofRevision;
    if (remote != null && remote > plan.proofRevision) {
      return ProofApplyResult.rejected(
          ProofApplyRejection.supersededByRemote, current.revision);
    }

    // 5. Something else moved the row.
    if (current.revision != plan.expectedRevision) {
      return ProofApplyResult.rejected(
          ProofApplyRejection.staleProofRevision, current.revision);
    }

    return ProofApplyResult.applied(current.revision + 1);
  }
}
