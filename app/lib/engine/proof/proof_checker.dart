/// PHASE 3 — the deterministic proof checker.
///
/// ## What it does
///
/// Takes a semantic PROPOSAL (which a future phase will obtain from an AI) and
/// decides, deterministically, whether it may become financial authority:
///
///     proven · review(reason) · notTransaction
///
/// ## What it never does
///
/// It never calls a model. It never generates a financial value. It never reads
/// a number out of the proposal — every money field is an evidence ID that is
/// resolved by lookup into the deterministic [EvidenceSet]. That is the
/// structural reason a model cannot fabricate an amount: there is no code path
/// from proposal text to a persisted digit.
///
/// ## No C1
///
/// Phase 0-D selected option (c): C1 is NOT part of this architecture. No
/// CharBiGRU, no MerchantClassifier standing in for it, no advisory context, no
/// veto. The mandatory no-C1 Sonnet re-measurement precedes Gemini parity
/// precisely because this changes the measured configuration.
library;

import '../../domain/finance/currency_scale.dart';
import '../models/transaction_type.dart';
import '../parser/bank_profile.dart';
import 'amount_candidates.dart';
import 'cue_roles.dart';
import 'direction_corroboration.dart';
import 'evidence.dart';

/// The verdict vocabulary. Deliberately three outcomes, not five: finer
/// taxonomy is deferred until a measured need appears.
enum ProofVerdict { proven, review, notTransaction }

/// Why a proposal did not reach [ProofVerdict.proven]. Machine-readable;
/// drives telemetry and review copy, never user-facing text directly.
enum ProofReason {
  // ---- protocol violations (the model broke the contract) -----------------
  literalDigitsInMoneyField,
  unknownEvidenceId,
  wrongKindEvidenceId,
  // ---- evidence completeness ---------------------------------------------
  evidenceTruncated,
  // ---- money -------------------------------------------------------------
  noAmountSelected,
  amountNotCompleteToken,
  amountAmbiguousToken,
  // ---- currency ----------------------------------------------------------
  noCurrencySelected,
  unsupportedCurrency,
  currencyScaleUnknown,
  amountPrecisionExceedsCurrencyScale,
  // ---- state -------------------------------------------------------------
  stateNotCompleted,
  contradictedByStateCue,
  /// The message describes an UNPAID future obligation — a bill reminder, a
  /// due date, a minimum payment. Money has not moved, so it may not be
  /// committed however confidently the model labels it `completed`.
  futureObligationNotCompleted,
  // ---- direction ---------------------------------------------------------
  directionNotDefinite,
  directionAmbiguous,
  directionConflict,
  // ---- family policy -----------------------------------------------------
  creditCardRepaymentReviewOnly,
  // ---- amount selection --------------------------------------------------
  // Resolving the amount by evidence ID makes fabrication impossible, but not
  // selection. These fire when the model pointed at a well-formed number that
  // the message itself labels as something other than the transaction.
  amountCarriesBalanceCue,
  amountCarriesFeeCue,
  amountCarriesVatCue,
  amountCarriesReferenceCue,
  /// More than one number survived deterministic filtering as a plausible
  /// transaction amount. The model may select evidence; it may not resolve
  /// financial ambiguity.
  amountAmbiguous,
}

/// What a caller proposes. Money and currency are **evidence IDs**, never
/// values — that is the whole point.
class ProofProposal {
  const ProofProposal({
    required this.isTransaction,
    required this.state,
    required this.direction,
    required this.type,
    this.amountId,
    this.currencyId,
    this.feeId,
    this.balanceId,
  });

  /// `transaction` / `non_transaction` / `ambiguous`.
  final String isTransaction;

  /// `completed` / `declined` / `pending` / `otp` / `promotional` /
  /// `balance_only` / `unknown`.
  final String state;

  /// `incoming` / `outgoing` / `neutral` / `ambiguous`.
  final String direction;

  /// The proposed Mali transaction type.
  final TransactionType type;

  /// Evidence IDs — e.g. `NUMBER_2`, `CURRENCY_1`.
  final String? amountId;
  final String? currencyId;
  final String? feeId;
  final String? balanceId;
}

/// The deterministic outcome. When [verdict] is [ProofVerdict.proven] the
/// resolved values are safe to persist; otherwise they are diagnostic only.
class ProofResult {
  const ProofResult({
    required this.verdict,
    required this.reasons,
    this.amountText,
    this.amountCanonical,
    this.currency,
    this.currencyScale,
    this.direction,
    this.type,
  });

  final ProofVerdict verdict;
  final List<ProofReason> reasons;

  /// The EXACT source token, taken from the evidence node — never from the
  /// proposal.
  final String? amountText;
  final String? amountCanonical;
  final String? currency;
  final int? currencyScale;
  final String? direction;
  final TransactionType? type;

  bool get isProven => verdict == ProofVerdict.proven;

  @override
  String toString() =>
      'ProofResult(${verdict.name}, ${reasons.map((r) => r.name).join(",")})';
}

/// Transaction families that may never auto-commit yet, whatever the numbers
/// say. Credit-card repayment is here because Phase 0-A approved the
/// `transfer` accounting semantic but the production `_mapType` still collapses
/// it to `payment`; committing it as spend would double-count purchases the
/// card already booked.
const Set<TransactionType> kReviewOnlyFamilies = {
  TransactionType.creditCardPayment,
};

/// Anything but `completed` is not committable as a finished transaction.
const Set<String> kNonCommittableStates = {
  'declined',
  'pending',
  'otp',
  'promotional',
  'balance_only',
  'unknown',
};

/// True when a string carries a digit that is not an evidence-ID suffix — i.e.
/// the model wrote a literal number where an ID was required.
bool _looksLikeLiteralDigits(String? v) {
  if (v == null) return false;
  const prefixes = ['NUMBER_', 'CURRENCY_', 'STATE_CUE_', 'DIRECTION_CUE_'];
  for (final p in prefixes) {
    if (v.startsWith(p)) return false;
  }
  return RegExp(r'[0-9٠-٩۰-۹]').hasMatch(v);
}

/// The deterministic proof checker.
class ProofChecker {
  const ProofChecker();

  /// [corroborators] are the PRE-AI deterministic direction sources (D1/D2/D3)
  /// from `deterministicCorroborators`. Passing none leaves only whatever D1
  /// the evidence set itself carries, which can only make the gate stricter.
  ProofResult check(
    EvidenceSet evidence,
    ProofProposal proposal, {
    List<DirectionCorroborator>? corroborators,
    BankProfile? bank,
  }) {
    final reasons = <ProofReason>[];

    // ---- 0. protocol conformance ----------------------------------------
    // A literal digit in a money field is a contract violation, not a value to
    // interpret. Checked FIRST so nothing downstream can read it.
    for (final v in [
      proposal.amountId,
      proposal.currencyId,
      proposal.feeId,
      proposal.balanceId,
    ]) {
      if (_looksLikeLiteralDigits(v)) {
        reasons.add(ProofReason.literalDigitsInMoneyField);
        break;
      }
    }

    // ---- 1. evidence completeness ---------------------------------------
    // A truncated evidence set is INCOMPLETE by construction: the amount that
    // would have falsified this proposal may be one of the omitted nodes. It
    // can never be proven from.
    if (evidence.exceedsNodeCap) {
      reasons.add(ProofReason.evidenceTruncated);
    }

    // ---- 2. is this a transaction at all? --------------------------------
    if (proposal.isTransaction == 'non_transaction') {
      return ProofResult(
        verdict: ProofVerdict.notTransaction,
        reasons: const [],
        type: proposal.type,
      );
    }
    if (proposal.isTransaction != 'transaction') {
      reasons.add(ProofReason.stateNotCompleted);
    }

    // ---- 3. state --------------------------------------------------------
    if (kNonCommittableStates.contains(proposal.state)) {
      // A declined/OTP/promotional message is not a failed proof — it is
      // correctly identified as not a committable transaction.
      if (proposal.state == 'declined' ||
          proposal.state == 'otp' ||
          proposal.state == 'promotional' ||
          proposal.state == 'balance_only') {
        return ProofResult(
          verdict: ProofVerdict.notTransaction,
          reasons: const [],
          type: proposal.type,
        );
      }
      reasons.add(ProofReason.stateNotCompleted);
    }

    // A future OBLIGATION is not a completed transaction. The model may label
    // a bill reminder `completed` — the rev-5 supplement showed one reaching
    // commitability — so the deterministic layer decides this, not the model.
    //
    // An explicit settlement statement in the SAME message overrides the
    // obligation phrase: `Amount due has been settled` reports money that HAS
    // moved and merely names the obligation it cleared. Without that override
    // the guard would block legitimate payment confirmations, which is the
    // failure mode it must not have.
    if (proposal.state == 'completed') {
      final cues = evidence.ofClass(EvidenceClass.stateCue);
      final obligation =
          cues.any((e) => e.stateCue == StateCueKind.obligationDue);
      final settled = cues.any((e) => e.stateCue == StateCueKind.completed);
      if (obligation && !settled) {
        reasons.add(ProofReason.futureObligationNotCompleted);
      }
    }

    // A deterministic state cue that contradicts a `completed` claim wins:
    // the message itself said "declined".
    if (proposal.state == 'completed') {
      final contradicting = evidence
          .ofClass(EvidenceClass.stateCue)
          .where((e) =>
              e.stateCue == StateCueKind.declined ||
              e.stateCue == StateCueKind.otp ||
              e.stateCue == StateCueKind.promotional)
          .isNotEmpty;
      if (contradicting) {
        return ProofResult(
          verdict: ProofVerdict.notTransaction,
          reasons: const [ProofReason.contradictedByStateCue],
          type: proposal.type,
        );
      }
    }

    // ---- 4. amount — resolved ONLY by ID lookup --------------------------
    Evidence? amount;
    if (proposal.amountId == null) {
      reasons.add(ProofReason.noAmountSelected);
    } else {
      amount = evidence.byId(proposal.amountId!);
      if (amount == null) {
        reasons.add(ProofReason.unknownEvidenceId);
      } else if (amount.evidenceClass != EvidenceClass.number) {
        reasons.add(ProofReason.wrongKindEvidenceId);
        amount = null;
      } else if (amount.canonical == null) {
        // The existing money contract refused this token as ambiguous
        // (e.g. `12,50`). It may never become an amount.
        reasons.add(ProofReason.amountAmbiguousToken);
        amount = null;
      } else if (!_isCompleteTokenOf(evidence, amount)) {
        reasons.add(ProofReason.amountNotCompleteToken);
        amount = null;
      }
    }

    // ---- 5. currency -----------------------------------------------------
    Evidence? currency;
    if (proposal.currencyId == null) {
      reasons.add(ProofReason.noCurrencySelected);
    } else {
      currency = evidence.byId(proposal.currencyId!);
      if (currency == null) {
        reasons.add(ProofReason.unknownEvidenceId);
      } else if (currency.evidenceClass != EvidenceClass.currency) {
        reasons.add(ProofReason.wrongKindEvidenceId);
        currency = null;
      } else if (currency.iso == null ||
          !isSupportedCurrency(currency.iso!)) {
        reasons.add(ProofReason.unsupportedCurrency);
        currency = null;
      } else if (currency.scale == null) {
        reasons.add(ProofReason.currencyScaleUnknown);
        currency = null;
      }
    }

    // ---- 6. precision must fit the currency ------------------------------
    if (amount != null && currency != null) {
      final decimals = amount.decimals ?? 0;
      if (decimals > currency.scale!) {
        // `12.4501` is not a KWD amount whatever the model says.
        reasons.add(ProofReason.amountPrecisionExceedsCurrencyScale);
      }
    }

    // ---- 7. direction — independent deterministic corroboration ----------
    final directionOutcome = _checkDirection(evidence, proposal, corroborators);
    if (directionOutcome != null) reasons.add(directionOutcome);

    // ---- 8. family policy ------------------------------------------------
    if (kReviewOnlyFamilies.contains(proposal.type)) {
      reasons.add(ProofReason.creditCardRepaymentReviewOnly);
    }

    // ---- 9. the message's own label for the selected number ---------------
    // ID resolution proves the amount is a real token of this message. It says
    // nothing about whether it is the TRANSACTION. A balance, a card suffix, a
    // VAT line and a purchase are all complete tokens; only one of them may be
    // committed, and the message itself says which.
    //
    // NOTE — a fee-only message ("Service charge SAR 5.00 debited") falls to
    // review here rather than auto-committing. The research checker waives the
    // fee/VAT roles when the transaction genuinely IS a fee, but
    // `TransactionType` has no `fee` member to express that with: fees map to
    // `payment`, indistinguishable from a purchase. The divergence therefore
    // costs coverage on fee messages and cannot cost safety, so it is recorded
    // rather than closed by inventing an enum member here.
    if (amount != null) {
      final roles = cueRoles(evidence)[amount.id] ?? const <String>{};
      if (roles.contains('balance')) {
        reasons.add(ProofReason.amountCarriesBalanceCue);
      }
      if (roles.contains('fee')) {
        reasons.add(ProofReason.amountCarriesFeeCue);
      }
      if (roles.contains('vat')) {
        reasons.add(ProofReason.amountCarriesVatCue);
      }
      if (roles.contains('accountRef')) {
        reasons.add(ProofReason.amountCarriesReferenceCue);
      }
      // Pointing the same node at two different roles is incoherent whatever
      // the roles are: the amount cannot also be the fee or the balance.
      if (amount.id == proposal.feeId || amount.id == proposal.balanceId) {
        reasons.add(ProofReason.amountCarriesFeeCue);
      }
    }

    // ---- 10. multi-amount ambiguity — fail closed ------------------------
    // Reached even when `amount` is null: a message with two plausible amounts
    // and no selection is no less ambiguous than one with a selection.
    final candidates = amountCandidates(evidence, bank: bank);
    if (candidates.length > 1) {
      reasons.add(ProofReason.amountAmbiguous);
    }

    final proven = reasons.isEmpty;
    return ProofResult(
      verdict: proven ? ProofVerdict.proven : ProofVerdict.review,
      reasons: List.unmodifiable(reasons),
      amountText: amount?.text,
      amountCanonical: amount?.canonical,
      currency: currency?.iso,
      currencyScale: currency?.scale,
      direction: proven ? proposal.direction : null,
      type: proposal.type,
    );
  }

  /// The evidence extractor already produces MAXIMAL tokens, so a node is a
  /// complete token by construction. This re-verifies it independently: if the
  /// extractor and the checker ever disagree, the message must be refused
  /// rather than trusted.
  bool _isCompleteTokenOf(EvidenceSet evidence, Evidence amount) {
    if (amount.start < 0 || amount.end > evidence.source.length) return false;
    if (evidence.source.substring(amount.start, amount.end) != amount.text) {
      return false;
    }
    // No neighbouring digit may sit immediately outside the span — that would
    // mean the node is a FRAGMENT of a longer number.
    final digit = RegExp(r'[0-9٠-٩۰-۹]');
    if (amount.start > 0 &&
        digit.hasMatch(evidence.source[amount.start - 1])) {
      return false;
    }
    if (amount.end < evidence.source.length &&
        digit.hasMatch(evidence.source[amount.end])) {
      return false;
    }
    return true;
  }

  /// Direction policy, per approved Phase 0-B.
  ///
  /// D1 — deterministic lexical cue polarity — is the only corroborator this
  /// phase implements; D2/D3 need bank/catalog rules that carry explicit
  /// polarity, which the evidence layer does not yet emit.
  ///
  /// The prohibition that matters: an AI-proposed TYPE may never corroborate an
  /// AI-proposed DIRECTION. That would be one model claim counted twice, so
  /// `DirectionSignal.ofType` is deliberately NOT consulted here.
  ProofReason? _checkDirection(
    EvidenceSet evidence,
    ProofProposal proposal,
    List<DirectionCorroborator>? supplied,
  ) {
    if (proposal.direction != 'incoming' && proposal.direction != 'outgoing') {
      return ProofReason.directionNotDefinite;
    }
    // When no corroborators are supplied, fall back to the D1 cues the
    // evidence set carries. D2/D3 are simply absent in that case.
    final corroborators = supplied ??
        deterministicCorroborators(sms: evidence.source, evidence: evidence);

    final resolution = resolveDirection(corroborators);
    switch (resolution.outcome) {
      case DirectionOutcome.ambiguous:
        return ProofReason.directionAmbiguous;
      case DirectionOutcome.conflict:
        // Authoritative sources disagree. Never broken by majority or
        // priority, and D4 may not break it either.
        return ProofReason.directionConflict;
      case DirectionOutcome.corroborated:
        final proposed = proposal.direction == 'incoming'
            ? DirectionCuePolarity.incoming
            : DirectionCuePolarity.outgoing;
        return resolution.polarity == proposed
            ? null
            : ProofReason.directionConflict;
    }
  }
}
