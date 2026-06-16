class BankDiscoveryRequest {
  const BankDiscoveryRequest({
    required this.senderId,
    required this.sanitizedSms,
    this.detectedCurrency,
    this.localeHint,
  });

  final String senderId;
  final String sanitizedSms;
  final String? detectedCurrency;
  final String? localeHint;
}

class BankDiscoverySuggestion {
  const BankDiscoverySuggestion({
    required this.suggestedBankName,
    required this.country,
    required this.confidence,
    required this.reason,
    this.bankKeySuggestion,
  });

  final String suggestedBankName;
  final String? bankKeySuggestion;
  final String country;
  final double confidence;
  final String reason;

  factory BankDiscoverySuggestion.fromJson(Map<String, dynamic> json) {
    final bankName = (json['suggestedBankName'] ??
        json['bankName'] ??
        json['bank_name']) as String?;
    final country = json['country'] as String?;
    final confidence = json['confidence'];
    final reason = json['reason'] as String?;
    if (bankName == null ||
        bankName.trim().isEmpty ||
        country == null ||
        country.trim().isEmpty ||
        confidence is! num ||
        reason == null ||
        reason.trim().isEmpty) {
      throw const FormatException('Invalid bank discovery response.');
    }
    return BankDiscoverySuggestion(
      suggestedBankName: bankName.trim(),
      bankKeySuggestion:
          (json['bankKeySuggestion'] ?? json['bank_key_suggestion']) as String?,
      country: country.trim().toUpperCase(),
      confidence: confidence.toDouble().clamp(0.0, 1.0),
      reason: reason.trim(),
    );
  }
}

enum BankDiscoveryResultStatus {
  ineligible,
  skipped,
  noSuggestion,
  pendingSuggestion,
}

class BankDiscoveryResult {
  const BankDiscoveryResult._({
    required this.status,
    this.reason,
    this.suggestion,
  });

  const BankDiscoveryResult.ineligible(String reason)
      : this._(status: BankDiscoveryResultStatus.ineligible, reason: reason);

  const BankDiscoveryResult.skipped(String reason)
      : this._(status: BankDiscoveryResultStatus.skipped, reason: reason);

  const BankDiscoveryResult.noSuggestion(String reason)
      : this._(status: BankDiscoveryResultStatus.noSuggestion, reason: reason);

  const BankDiscoveryResult.pendingSuggestion(
    BankDiscoverySuggestion suggestion,
  ) : this._(
          status: BankDiscoveryResultStatus.pendingSuggestion,
          suggestion: suggestion,
        );

  final BankDiscoveryResultStatus status;
  final String? reason;
  final BankDiscoverySuggestion? suggestion;
}
