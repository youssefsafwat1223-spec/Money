/// PHASE 11 — turns a deterministic parse into a [ProofProposal] the checker
/// can evaluate, by resolving parsed values back to EVIDENCE NODE IDS.
///
/// ## Why this is a separate, tested unit
///
/// `ProofChecker` refuses a proposal that carries literal digits in a money
/// field — the proposal must say "the amount is NUMBER_2", never "the amount is
/// 125.75". So something has to find, among the evidence extracted from the raw
/// message, the node that corresponds to what the parser concluded.
///
/// Getting that mapping wrong is worse than not running Proof at all: it
/// produces confident agreement or disagreement about the wrong token, and the
/// shadow measurement that gates activation would be measuring noise. Hence a
/// named unit with its own tests, rather than a few lines inlined at the call
/// site.
///
/// ## It refuses rather than guesses
///
/// Every failure returns null. A null proposal means Proof does not evaluate
/// this capture, which the gate records as `notEvaluated` — never as agreement.
/// Ambiguity is a refusal too: if two evidence nodes carry the same canonical
/// amount, there is no single node this parse refers to, and picking one would
/// be inventing a fact.
library;

import '../../engine/models/transaction_type.dart';
import '../../engine/proof/evidence.dart';
import '../../engine/proof/proof_checker.dart';

/// Why a capture could not be turned into a proposal.
///
/// Explicit codes exist because ~53% of the Tier 1 holdout refused to propose.
/// Without a reason per refusal that number is an opaque denominator loss during
/// Tier 2 — indistinguishable from "Proof is broken" — and the shadow gate could
/// not be interpreted at all. Each code names a specific, fixable cause.
enum ProofProposalRefusal {
  /// Amount is negative. The evidence tokeniser captures no signs, so no node
  /// can ever carry one.
  negativeAmount,

  /// The message contains no currency token.
  noCurrencyToken,

  /// The message names MORE THAN ONE currency, so an amount cannot be
  /// unambiguously paired with a currency.
  multipleCurrencyTokens,

  /// The message's single currency is not the one the parser concluded.
  currencyMismatch,

  /// The currency token carries no minor-unit scale, so no amount can be
  /// resolved against it.
  currencyScaleMissing,

  /// No evidence node carries the parsed amount's VALUE at that scale.
  amountNotFound,

  /// More than one node carries that value — commonly the amount and the
  /// balance coinciding. There is no single token the parse refers to.
  amountAmbiguous,

  /// The transaction type does not determine a direction (transfer, unknown).
  directionNotDerivable,
}

/// A proposal, or the reason there is none. Never both, never neither.
///
/// The XOR is ENFORCED, not merely documented: both parameters were nullable,
/// so `ProofProposalOutcome.proposed(null)` constructed the both-null state —
/// an outcome that says a capture neither proposed nor refused, which the
/// shadow record has no way to represent.
class ProofProposalOutcome {
  const ProofProposalOutcome.proposed(ProofProposal this.proposal)
      : refusal = null;
  const ProofProposalOutcome.refused(ProofProposalRefusal this.refusal)
      : proposal = null;

  final ProofProposal? proposal;
  final ProofProposalRefusal? refusal;
}

class ProofProposalBuilder {
  const ProofProposalBuilder();

  /// Outgoing versus incoming, stated exhaustively so a NEW enum value is a
  /// compile-time decision rather than a silent default. `unknown` maps to
  /// null: a direction we cannot name is not a direction we may propose.
  static String? directionFor(TransactionType type) {
    // `isExpense` is the enum's own outgoing definition. Reusing it means a new
    // expense-like type cannot end up classified one way here and another way
    // in the rest of the app.
    if (type.isExpense) return 'outgoing';
    switch (type) {
      case TransactionType.income:
      case TransactionType.refund:
        return 'incoming';
      case TransactionType.transfer:
      // A transfer's direction is not determined by its type — it depends on
      // which side of the account the message describes. Proposing one would be
      // a guess, so it is refused.
      case TransactionType.unknown:
        return null;
      // Every expense family already returned above.
      case TransactionType.payment:
      case TransactionType.withdrawal:
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return 'outgoing';
    }
  }

  /// Canonical decimal for [minorUnits] at [scale], in the form
  /// `ProofResult.amountCanonical` reports back.
  ///
  /// This is for REPORTING only — never for matching. `Evidence.canonical`
  /// preserves the token as WRITTEN (`1.2` stays `1.2`, `001.00` keeps its
  /// leading zeros), while this always emits fixed width. Matching on it
  /// lexically silently refused every legitimately-written amount whose
  /// spelling differed from full scale.
  static String canonicalAmount(int minorUnits, int scale) {
    final negative = minorUnits < 0;
    final digits = minorUnits.abs().toString().padLeft(scale + 1, '0');
    final whole = digits.substring(0, digits.length - scale);
    final frac = scale == 0 ? '' : '.${digits.substring(digits.length - scale)}';
    return '${negative ? '-' : ''}$whole$frac';
  }

  /// Minor units for an evidence token's canonical decimal at [scale], or null
  /// if it cannot be represented EXACTLY at that scale.
  ///
  /// Value comparison, not string comparison: `1.2`, `1.20` and `01.200` are
  /// the same money and must all match 120 minor units at scale 2, while
  /// `1.235` at scale 2 must match NOTHING rather than be rounded into
  /// agreement with `1.24`.
  static int? minorFromCanonical(String canonical, int scale) {
    final t = canonical.trim();
    if (t.isEmpty || t.contains('-')) return null; // evidence carries no signs
    final parts = t.split('.');
    if (parts.length > 2) return null;
    final whole = parts[0].isEmpty ? '0' : parts[0];
    final frac = parts.length == 2 ? parts[1] : '';
    if (!RegExp(r'^\d+$').hasMatch(whole)) return null;
    if (frac.isNotEmpty && !RegExp(r'^\d+$').hasMatch(frac)) return null;
    // Excess precision is only acceptable when it is all zeros: `500.00` at
    // scale 0 is 500, but `1.235` at scale 2 is not representable.
    if (frac.length > scale) {
      if (frac.substring(scale).contains(RegExp(r'[1-9]'))) return null;
    }
    final padded = frac.padRight(scale, '0').substring(0, scale);
    final combined = '$whole$padded';
    return int.tryParse(combined);
  }

  /// Build a proposal, or say precisely why not.
  ProofProposalOutcome build({
    required EvidenceSet evidence,
    required TransactionType type,
    required int amountMinorUnits,
    required String currencyIso,
  }) {
    final direction = directionFor(type);
    if (direction == null) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.directionNotDerivable);
    }

    // Negative amounts cannot be corroborated: the evidence tokeniser does not
    // capture signs, so no node can ever carry one.
    if (amountMinorUnits < 0) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.negativeAmount);
    }

    // ONE currency in the whole message, not merely one matching. A message
    // naming two currencies cannot unambiguously pair an amount with a
    // currency, and mispairing is exactly what would corrupt the shadow
    // measurement while looking like a confident answer.
    final allCurrencies = evidence.items
        .where((e) => e.evidenceClass == EvidenceClass.currency)
        .toList();
    if (allCurrencies.isEmpty) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.noCurrencyToken);
    }
    if (allCurrencies.length > 1) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.multipleCurrencyTokens);
    }
    final currencyNode = allCurrencies.single;
    if ((currencyNode.iso ?? '').toUpperCase() !=
        currencyIso.trim().toUpperCase()) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.currencyMismatch);
    }
    final scale = currencyNode.scale;
    if (scale == null) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.currencyScaleMissing);
    }

    // Match by VALUE. See minorFromCanonical: `1.2` and `1.20` are the same
    // money, and `1.235` matches nothing at scale 2 rather than rounding into
    // false agreement.
    final amountNodes = evidence.items
        .where((e) =>
            e.evidenceClass == EvidenceClass.number &&
            e.canonical != null &&
            minorFromCanonical(e.canonical!, scale) == amountMinorUnits)
        .toList();
    if (amountNodes.isEmpty) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.amountNotFound);
    }
    if (amountNodes.length > 1) {
      return const ProofProposalOutcome.refused(
          ProofProposalRefusal.amountAmbiguous);
    }

    return ProofProposalOutcome.proposed(ProofProposal(
      isTransaction: 'transaction',
      state: 'completed',
      direction: direction,
      type: type,
      amountId: amountNodes.single.id,
      currencyId: currencyNode.id,
    ));
  }
}
