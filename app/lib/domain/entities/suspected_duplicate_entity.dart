import 'transaction_entity.dart';
import '../finance/money.dart';

class SuspectedDuplicateEntity {
  const SuspectedDuplicateEntity({
    required this.id,
    required this.rawMessage,
    this.senderId,
    required this.existingTransactionId,
    required this.amountMoney,
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
  final Money amountMoney;

  /// DISPLAY-ONLY compatibility getter. Persistence uses [amountMoney].
  double get amount => amountMoney.toDouble();
  final String currency;
  final String? rawMerchant;
  final DateTime occurredAt;
  final DateTime createdAt;
  final String? cardLast4;
  final DateTime? comparisonTimestamp;
  final ComparisonTimestampSource? comparisonTimestampSource;
  final String? duplicateReason;

  SuspectedDuplicateEntity copyWith({
    String? id,
    String? rawMessage,
    String? senderId,
    String? existingTransactionId,
    Money? amountMoney,
    String? currency,
    String? rawMerchant,
    DateTime? occurredAt,
    DateTime? createdAt,
    String? cardLast4,
    DateTime? comparisonTimestamp,
    ComparisonTimestampSource? comparisonTimestampSource,
    String? duplicateReason,
  }) {
    return SuspectedDuplicateEntity(
      id: id ?? this.id,
      rawMessage: rawMessage ?? this.rawMessage,
      senderId: senderId ?? this.senderId,
      existingTransactionId:
          existingTransactionId ?? this.existingTransactionId,
      amountMoney: amountMoney ?? this.amountMoney,
      currency: currency ?? this.currency,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      occurredAt: occurredAt ?? this.occurredAt,
      createdAt: createdAt ?? this.createdAt,
      cardLast4: cardLast4 ?? this.cardLast4,
      comparisonTimestamp: comparisonTimestamp ?? this.comparisonTimestamp,
      comparisonTimestampSource:
          comparisonTimestampSource ?? this.comparisonTimestampSource,
      duplicateReason: duplicateReason ?? this.duplicateReason,
    );
  }
}
