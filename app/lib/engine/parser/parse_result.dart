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
    this.catalogRuleId,
  });

  factory ParseResult.success(
    ParsedTransaction txn, {
    String? bankKey,
    String? catalogRuleId,
  }) =>
      ParseResult._(
        isTransaction: true,
        transaction: txn,
        bankKey: bankKey,
        confidence: txn.parseConfidence,
        catalogRuleId: catalogRuleId,
      );

  factory ParseResult.notTransaction({String? bankKey}) =>
      ParseResult._(isTransaction: false, bankKey: bankKey);

  final bool isTransaction;
  final ParsedTransaction? transaction;
  final String? bankKey;
  final double confidence;

  /// F-016/F-014 — the id of the catalog rule that decided this parse, when
  /// one matched. Null on the heuristic path. Surfaced so the Parser Lab and
  /// the device can be compared on WHICH authority produced the result.
  final String? catalogRuleId;
}
