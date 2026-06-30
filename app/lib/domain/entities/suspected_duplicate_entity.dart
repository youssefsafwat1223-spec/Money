import 'transaction_entity.dart';

class SuspectedDuplicateEntity {
  const SuspectedDuplicateEntity({
    required this.id,
    required this.rawMessage,
    this.senderId,
    required this.existingTransactionId,
    required this.amount,
    required this.currency,
    this.rawMerchant,
    required this.occurredAt,
    required this.createdAt,
    this.cardLast4,
    this.comparisonTimestamp,
    this.comparisonTimestampSource,
    this.duplicateReason,
  });

  final String id;
  final String rawMessage;
  final String? senderId;
  final String existingTransactionId;
  final double amount;
  final String currency;
  final String? rawMerchant;
  final DateTime occurredAt;
  final DateTime createdAt;
  final String? cardLast4;
  final DateTime? comparisonTimestamp;
  final ComparisonTimestampSource? comparisonTimestampSource;
  final String? duplicateReason;
}
