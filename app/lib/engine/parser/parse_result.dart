import '../models/parsed_transaction.dart';

/// نتيجة محاولة تحليل رسالة.
///
/// [isTransaction] = false عندما لا تحتوي الرسالة على معاملة مالية واضحة
/// (مثل أكواد OTP أو العروض) — تُتجاهَل بصمت (PRODUCT_SPEC §24.6).
class ParseResult {
  const ParseResult._({
    required this.isTransaction,
    this.transaction,
    this.bankKey,
    this.confidence = 0,
  });

  factory ParseResult.success(
    ParsedTransaction txn, {
    String? bankKey,
  }) =>
      ParseResult._(
        isTransaction: true,
        transaction: txn,
        bankKey: bankKey,
        confidence: txn.parseConfidence,
      );

  factory ParseResult.notTransaction({String? bankKey}) =>
      ParseResult._(isTransaction: false, bankKey: bankKey);

  final bool isTransaction;
  final ParsedTransaction? transaction;
  final String? bankKey;
  final double confidence;
}
