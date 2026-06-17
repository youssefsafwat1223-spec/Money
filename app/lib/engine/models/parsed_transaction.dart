import 'transaction_source.dart';
import 'transaction_type.dart';

/// نتيجة استخراج عملية مالية من نص رسالة (DTO نقي، بلا أي اعتماد على Flutter).
///
/// ملاحظة: هذه موديلات يدوية مؤقتة لتشغيل المحرك واختباراته بدون codegen.
/// Codex يحوّلها إلى freezed لاحقاً عند الحاجة.
class ParsedTransaction {
  const ParsedTransaction({
    required this.amount,
    required this.currency,
    required this.type,
    required this.source,
    this.rawMerchant,
    this.cardLast4,
    this.balanceAfter,
    this.occurredAt,
    this.foreignAmount,
    this.foreignCurrency,
    this.fundingSource,
    this.parseConfidence = 0,
  });

  final double amount;
  final String currency;
  final TransactionType type;
  final TransactionSource source;
  final String? rawMerchant;
  final String? cardLast4;
  final double? balanceAfter;
  final DateTime? occurredAt;
  final double? foreignAmount;
  final String? foreignCurrency;
  final String? fundingSource;
  final double parseConfidence;

  ParsedTransaction copyWith({
    double? amount,
    String? currency,
    TransactionType? type,
    TransactionSource? source,
    String? rawMerchant,
    String? cardLast4,
    double? balanceAfter,
    DateTime? occurredAt,
    double? foreignAmount,
    String? foreignCurrency,
    String? fundingSource,
    double? parseConfidence,
  }) {
    return ParsedTransaction(
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      type: type ?? this.type,
      source: source ?? this.source,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      cardLast4: cardLast4 ?? this.cardLast4,
      balanceAfter: balanceAfter ?? this.balanceAfter,
      occurredAt: occurredAt ?? this.occurredAt,
      foreignAmount: foreignAmount ?? this.foreignAmount,
      foreignCurrency: foreignCurrency ?? this.foreignCurrency,
      fundingSource: fundingSource ?? this.fundingSource,
      parseConfidence: parseConfidence ?? this.parseConfidence,
    );
  }

  @override
  String toString() =>
      'ParsedTransaction(amount: $amount $currency, type: $type, source: $source, '
      'merchant: $rawMerchant, last4: $cardLast4, balance: $balanceAfter, '
      'date: $occurredAt'
      '${foreignAmount == null ? '' : ', foreignAmount: $foreignAmount'}'
      '${foreignCurrency == null ? '' : ', foreignCurrency: $foreignCurrency'}'
      '${fundingSource == null ? '' : ', fundingSource: $fundingSource'}'
      ', conf: ${parseConfidence.toStringAsFixed(2)})';
}
