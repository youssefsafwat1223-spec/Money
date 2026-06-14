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

  final double value;
  final String raw;
  final String line;
  final AmountCandidateKind kind;
  final double score;

  bool get isStrongTransaction =>
      kind == AmountCandidateKind.transactionAmount && score >= 0.65;
}
