enum AmountCandidateKind {
  transactionAmount,
  balance,
  cardLast4,
  dateTime,
  referenceNumber,
  unknown,
}

class AmountCandidate {
  const AmountCandidate({
    required this.value,
    required this.raw,
    required this.line,
    required this.kind,
    required this.score,
  });

  /// HEURISTIC-ONLY numeric projection used for candidate classification and
  /// ambiguity ranking. Canonical money always comes from the lexical [raw].
  final double value;
  /// Exact lexical token captured from the message.
  final String raw;
  final String line;
  final AmountCandidateKind kind;
  /// HEURISTIC-ONLY confidence/ranking score; never a financial value.
  final double score;

  bool get isStrongTransaction =>
      kind == AmountCandidateKind.transactionAmount && score >= 0.65;
}
