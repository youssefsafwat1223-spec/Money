import '../../engine/dedup/transaction_dedup.dart';
import '../entities/transaction_entity.dart';

class DuplicateTransactionInput {
  const DuplicateTransactionInput({
    required this.amount,
    required this.currency,
    required this.merchantOrDescription,
    required this.comparisonTimestamp,
    required this.comparisonTimestampSource,
    this.cardLast4,
  });

  final double amount;
  final String currency;
  final String merchantOrDescription;
  final String? cardLast4;
  final DateTime comparisonTimestamp;
  final ComparisonTimestampSource comparisonTimestampSource;
}

class DuplicateDetectionResult {
  const DuplicateDetectionResult.normal()
      : status = DuplicateStatus.normal,
        existing = null,
        reason = null;

  const DuplicateDetectionResult.suspicious({
    required this.existing,
    required this.reason,
  }) : status = DuplicateStatus.suspiciousDuplicate;

  final DuplicateStatus status;
  final TransactionEntity? existing;
  final String? reason;

  bool get isSuspicious => status == DuplicateStatus.suspiciousDuplicate;
}

class DuplicateTransactionDetector {
  const DuplicateTransactionDetector();

  DuplicateDetectionResult detect({
    required DuplicateTransactionInput input,
    required Iterable<TransactionEntity> existingTransactions,
  }) {
    for (final existing in existingTransactions) {
      if (_matches(input, existing)) {
        return DuplicateDetectionResult.suspicious(
          existing: existing,
          reason: 'same amount, currency, merchant, timestamp'
              '${_hasLast4(input.cardLast4) && _hasLast4(existing.cardLast4) ? ', last4' : ''}',
        );
      }
    }
    return const DuplicateDetectionResult.normal();
  }

  bool _matches(
    DuplicateTransactionInput input,
    TransactionEntity existing,
  ) {
    final existingAmount = existing.foreignAmount ?? existing.amount;
    final existingCurrency = existing.foreignCurrency ?? existing.currency;
    if ((input.amount - existingAmount).abs() > 0.0001) return false;
    if (input.currency.trim().toUpperCase() !=
        existingCurrency.trim().toUpperCase()) {
      return false;
    }
    if (_normalized(input.merchantOrDescription) !=
        _normalized(existing.rawMerchant ?? existing.rawMessage)) {
      return false;
    }

    final existingComparison =
        (existing.comparisonTimestamp ?? existing.occurredAt).toUtc();
    if (!input.comparisonTimestamp
        .toUtc()
        .isAtSameMomentAs(existingComparison)) {
      return false;
    }

    final newLast4 = _cleanLast4(input.cardLast4);
    final existingLast4 = _cleanLast4(existing.cardLast4);
    if (_hasLast4(newLast4) &&
        _hasLast4(existingLast4) &&
        newLast4 != existingLast4) {
      return false;
    }

    return true;
  }

  static String _normalized(String value) =>
      TransactionDedup.normalizeMerchant(value);

  static bool _hasLast4(String? value) => value != null && value.isNotEmpty;

  static String? _cleanLast4(String? value) {
    final digits = value?.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits == null || digits.isEmpty) return null;
    return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
  }
}
