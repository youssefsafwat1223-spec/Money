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
    this.catalogAmountCorroborated,
    this.typeUndetected = false,
    this.amountAmbiguous = false,
    this.dateAmbiguous = false,
  });

  factory ParseResult.success(
    ParsedTransaction txn, {
    String? bankKey,
    String? catalogRuleId,
    bool? catalogAmountCorroborated,
    bool typeUndetected = false,
    bool amountAmbiguous = false,
    bool dateAmbiguous = false,
  }) =>
      ParseResult._(
        isTransaction: true,
        transaction: txn,
        bankKey: bankKey,
        confidence: txn.parseConfidence,
        catalogRuleId: catalogRuleId,
        catalogAmountCorroborated: catalogAmountCorroborated,
        typeUndetected: typeUndetected,
        amountAmbiguous: amountAmbiguous,
        dateAmbiguous: dateAmbiguous,
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

  /// Whether a catalog rule's captured amount was independently reproduced by
  /// the heuristic extraction. Null when the amount did not come from a catalog
  /// rule. Exposed as a fact so consumers never infer it from the confidence cap.
  final bool? catalogAmountCorroborated;

  /// True when neither a rule nor the heuristics named a transaction type and
  /// the parser defaulted it to payment. Such a type is a guess, not a reading.
  final bool typeUndetected;

  /// The engine found more than one distinct strong amount candidate and could
  /// not single one out (the same fact that costs `_confidence` 0.35).
  final bool amountAmbiguous;

  /// The date has day and month both <= 12 with no profile guidance (the same
  /// fact that caps `_confidence` at 0.89).
  final bool dateAmbiguous;
}
