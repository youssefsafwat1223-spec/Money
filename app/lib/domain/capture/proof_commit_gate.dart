/// PHASE 11 — the gate that lets Proof influence a capture commit, and the
/// exact limits on how far that influence may go.
///
/// ## The one safety property this class exists to guarantee
///
/// **Proof can only ever WITHHOLD a confirmation. It can never grant one.**
///
/// A capture that the deterministic parser would not auto-confirm is not
/// auto-confirmed because Proof is happy about it. That is deliberate and it is
/// the whole reason enabling this is safe: a wrong Proof verdict cannot commit
/// money, because a Proof verdict alone was never sufficient to commit money.
/// The worst a broken Proof can do is send correct captures to review — an
/// annoyance, not a financial error.
///
/// This is why the flag is named for autocommit but the gate is subtractive: it
/// governs whether an auto-confirmation that ALREADY passed every deterministic
/// check is additionally corroborated before it lands.
///
/// ## Shadow versus armed
///
/// In [ProofGateMode.shadow] the gate computes a verdict and returns it for
/// recording, and the commit decision is **byte-identical to what it would have
/// been without Proof**. That is what makes shadow measurement honest: the
/// numbers describe the decision that would have been made, because it is the
/// decision that WAS made.
///
/// In [ProofGateMode.armed] a disagreement downgrades `confirmed` to `pending`.
/// Nothing else changes.
library;

import '../../engine/proof/proof_checker.dart';

/// Whether the gate may influence the decision, or only observe it.
enum ProofGateMode {
  /// Compute and record; never alter the outcome. The default, and the state
  /// the first public release ships in.
  shadow,

  /// Compute, record, and downgrade a confirmation on disagreement.
  armed,
}

/// Why the gate agreed or refused. Recorded for shadow measurement; the
/// non-agreement values are exactly the population that would have been sent to
/// review had the gate been armed.
enum ProofGateOutcome {
  /// Proof ran and corroborates the deterministic parse on every field it
  /// speaks about, at or above the configured confidence floor.
  agree,

  /// Proof did not reach a `proven` verdict.
  disagreeVerdict,

  /// Proof reached `proven` but contradicts the parse on amount, currency or
  /// direction — the three fields where being wrong means the wrong money.
  disagreeFields,

  /// Everything corroborates, but parse confidence is below the floor.
  belowConfidence,

  /// Proof produced nothing for this capture (no evidence, not run, or the
  /// engine is unavailable). Never treated as agreement.
  notEvaluated,
}

/// The gate's finding for one capture.
class ProofGateDecision {
  const ProofGateDecision({
    required this.mode,
    required this.outcome,
    required this.parseConfidencePermille,
    required this.confidenceMinPermille,
  });

  final ProofGateMode mode;
  final ProofGateOutcome outcome;
  final int parseConfidencePermille;
  final int confidenceMinPermille;

  bool get agrees => outcome == ProofGateOutcome.agree;

  /// True only when the gate is armed AND did not agree. This is the only
  /// condition under which the gate changes anything.
  bool get withholdsConfirmation =>
      mode == ProofGateMode.armed && !agrees;

  /// Compact form for the shadow record. No message text, no amounts — an
  /// outcome label and two integers, so recording a shadow verdict can never
  /// become a way to exfiltrate financial content.
  Map<String, Object?> toRecord() => {
        'mode': mode.name,
        'outcome': outcome.name,
        'parse_confidence_permille': parseConfidencePermille,
        'confidence_min_permille': confidenceMinPermille,
      };
}

/// Evaluates Proof against the deterministic parse.
class ProofCommitGate {
  const ProofCommitGate();

  /// The shipped default floor: 990‰ of the DETERMINISTIC PARSER's confidence.
  ///
  /// Named for the parser on purpose. `ProofResult` carries a verdict enum and
  /// no numeric confidence, so there is no such thing as "proof confidence" to
  /// threshold. The earlier name `proof_confidence_min` implied one and would
  /// have become a false contract the moment anyone tuned it.
  ///
  /// Deliberately far above the deterministic auto-confirm bar of 0.92, because
  /// this gate governs the subset that is about to be committed WITHOUT a human
  /// looking at it. The looser bar decides "is this probably right"; this one
  /// decides "is this safe to never show anyone".
  static const int defaultParserConfidenceMinPermille = 990;

  /// [proof] may be null — the engine not running is not agreement.
  ///
  /// [parsedDirection], [parsedAmountCanonical] and [parsedCurrency] are the
  /// deterministic parser's values. Comparison is exact and case-insensitive
  /// for the string fields; a field Proof does not speak about is not evidence
  /// of agreement, so a null on EITHER side is a disagreement, never a pass.
  ProofGateDecision evaluate({
    required ProofGateMode mode,
    required ProofResult? proof,
    required double parseConfidence,
    /// `'outgoing'` / `'incoming'` — the checker's vocabulary, produced by
    /// `ProofProposalBuilder.directionFor`. NOT a `TransactionType.name`: the
    /// checker never emits those, so comparing against one would disagree
    /// always and silently.
    required String? parsedDirection,

    /// Canonical decimal string at the currency's scale (`125.75`, `45.750`) —
    /// the same form `Evidence.canonical` and `ProofResult.amountCanonical`
    /// use. NOT minor units.
    required String? parsedAmountCanonical,
    required String? parsedCurrency,
    int confidenceMinPermille = defaultParserConfidenceMinPermille,
  }) {
    // `.floor()` throws UnsupportedError on NaN/Infinity, and this runs on the
    // commit path for every capture. A non-finite confidence from any upstream
    // must degrade to "no confidence", never abort a save.
    final permille =
        parseConfidence.isFinite ? (parseConfidence * 1000).floor() : 0;

    ProofGateDecision decide(ProofGateOutcome o) => ProofGateDecision(
          mode: mode,
          outcome: o,
          parseConfidencePermille: permille,
          confidenceMinPermille: confidenceMinPermille,
        );

    if (proof == null) return decide(ProofGateOutcome.notEvaluated);
    if (proof.verdict != ProofVerdict.proven) {
      return decide(ProofGateOutcome.disagreeVerdict);
    }

    // The three fields where disagreement means the wrong money moved. A null
    // on either side fails: "Proof did not say" is not "Proof agreed".
    // Both sides must be present AND non-blank. `same('', '')` returning true
    // would make two absent values agree, which is the exact opposite of the
    // rule this gate exists to enforce: absence is never agreement.
    bool same(String? a, String? b) {
      if (a == null || b == null) return false;
      final x = a.trim().toLowerCase();
      final y = b.trim().toLowerCase();
      if (x.isEmpty || y.isEmpty) return false;
      return x == y;
    }

    if (!same(proof.direction, parsedDirection) ||
        !same(proof.amountCanonical, parsedAmountCanonical) ||
        !same(proof.currency, parsedCurrency)) {
      return decide(ProofGateOutcome.disagreeFields);
    }

    if (permille < confidenceMinPermille) {
      return decide(ProofGateOutcome.belowConfidence);
    }
    return decide(ProofGateOutcome.agree);
  }
}
