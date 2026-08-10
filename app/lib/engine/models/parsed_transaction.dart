import '../../domain/finance/money_input.dart';
import 'transaction_source.dart';
import 'transaction_type.dart';

/// نتيجة استخراج عملية مالية من نص رسالة (DTO نقي، بلا أي اعتماد على Flutter).
///
/// ملاحظة: هذه موديلات يدوية مؤقتة لتشغيل المحرك واختباراته بدون codegen.
/// Codex يحوّلها إلى freezed لاحقاً عند الحاجة.
class ParsedTransaction {
  factory ParsedTransaction({
    required String? amountText,
    required double amount,
    required String currency,
    required TransactionType type,
    required TransactionSource source,
    String? rawMerchant,
    String? cardLast4,
    String? accountNumber,
    String? balanceAfterText,
    double? balanceAfter,
    DateTime? occurredAt,
    String? foreignAmountText,
    double? foreignAmount,
    String? foreignCurrency,
    String? fundingSource,
    double parseConfidence = 0,
  }) {
    final canonicalAmountText = _normalizeOptional(amountText);
    final canonicalBalanceText = _normalizeOptional(balanceAfterText);
    final canonicalForeignText = _normalizeOptional(foreignAmountText);
    return ParsedTransaction._(
      amountText: canonicalAmountText,
      amount: _heuristicFromCanonical(canonicalAmountText, amount),
      currency: currency,
      type: type,
      source: source,
      rawMerchant: rawMerchant,
      cardLast4: cardLast4,
      accountNumber: accountNumber,
      balanceAfterText: canonicalBalanceText,
      balanceAfter:
          _heuristicNullableFromCanonical(canonicalBalanceText, balanceAfter),
      occurredAt: occurredAt,
      foreignAmountText: canonicalForeignText,
      foreignAmount:
          _heuristicNullableFromCanonical(canonicalForeignText, foreignAmount),
      foreignCurrency: foreignCurrency,
      fundingSource: fundingSource,
      parseConfidence: parseConfidence,
    );
  }

  const ParsedTransaction._({
    required this.amountText,
    required this.amount,
    required this.currency,
    required this.type,
    required this.source,
    this.rawMerchant,
    this.cardLast4,
    this.accountNumber,
    this.balanceAfterText,
    this.balanceAfter,
    this.occurredAt,
    this.foreignAmountText,
    this.foreignAmount,
    this.foreignCurrency,
    this.fundingSource,
    required this.parseConfidence,
  });

  static String? _normalizeOptional(String? token) =>
      token == null ? null : normalizeLocalizedDecimal(token);

  static double _heuristicFromCanonical(String? text, double fallback) =>
      text == null ? fallback : double.tryParse(text) ?? fallback;

  static double? _heuristicNullableFromCanonical(
          String? text, double? fallback) =>
      text == null ? fallback : double.tryParse(text) ?? fallback;

  /// Canonicalized lexical token. Null is reserved for the explicitly isolated
  /// legacy AI-number response from a backend that does not yet send amount_text.
  final String? amountText;

  /// HEURISTIC/DISPLAY-ONLY. Persisted money must come from [amountText].
  final double amount;
  final String currency;
  final TransactionType type;
  final TransactionSource source;
  final String? rawMerchant;
  final String? cardLast4;

  /// رقم/جزء رقم الحساب البنكي المستخرج من الرسالة (لو ذُكر صراحةً بجوار كلمة
  /// «حساب/account»). أرقام فقط؛ قد يكون آخر بضع خانات. يُستخدم لتحسين إسناد
  /// الحساب — أنظر AddTransactionUseCase.
  final String? accountNumber;
  final String? balanceAfterText;
  /// HEURISTIC/DISPLAY-ONLY. Persisted money uses [balanceAfterText].
  final double? balanceAfter;
  final DateTime? occurredAt;
  final String? foreignAmountText;
  /// HEURISTIC/DISPLAY-ONLY. Persisted money uses [foreignAmountText].
  final double? foreignAmount;
  final String? foreignCurrency;
  final String? fundingSource;
  final double parseConfidence;

  ParsedTransaction copyWith({
    String? amountText,
    double? amount,
    String? currency,
    TransactionType? type,
    TransactionSource? source,
    String? rawMerchant,
    String? cardLast4,
    String? accountNumber,
    String? balanceAfterText,
    double? balanceAfter,
    DateTime? occurredAt,
    String? foreignAmountText,
    double? foreignAmount,
    String? foreignCurrency,
    String? fundingSource,
    double? parseConfidence,
  }) {
    return ParsedTransaction(
      amountText: amountText ?? this.amountText,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      type: type ?? this.type,
      source: source ?? this.source,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      cardLast4: cardLast4 ?? this.cardLast4,
      accountNumber: accountNumber ?? this.accountNumber,
      balanceAfterText: balanceAfterText ?? this.balanceAfterText,
      balanceAfter: balanceAfter ?? this.balanceAfter,
      occurredAt: occurredAt ?? this.occurredAt,
      foreignAmountText: foreignAmountText ?? this.foreignAmountText,
      foreignAmount: foreignAmount ?? this.foreignAmount,
      foreignCurrency: foreignCurrency ?? this.foreignCurrency,
      fundingSource: fundingSource ?? this.fundingSource,
      parseConfidence: parseConfidence ?? this.parseConfidence,
    );
  }

  @override
  String toString() =>
      'ParsedTransaction(amountText: $amountText, amount: $amount $currency, type: $type, source: $source, '
      'merchant: $rawMerchant, last4: $cardLast4, balance: $balanceAfter, '
      'balanceText: $balanceAfterText, '
      'date: $occurredAt'
      '${foreignAmount == null ? '' : ', foreignAmount: $foreignAmount, foreignAmountText: $foreignAmountText'}'
      '${foreignCurrency == null ? '' : ', foreignCurrency: $foreignCurrency'}'
      '${fundingSource == null ? '' : ', fundingSource: $fundingSource'}'
      ', conf: ${parseConfidence.toStringAsFixed(2)})';
}
