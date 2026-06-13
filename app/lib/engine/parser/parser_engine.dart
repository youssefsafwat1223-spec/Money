import '../models/parsed_transaction.dart';
import '../models/transaction_source.dart';
import '../models/transaction_type.dart';
import 'bank_profile.dart';
import 'normalizer.dart';
import 'parse_result.dart';

/// محرّك تحليل رسائل البنك → [ParsedTransaction].
///
/// Dart نقي بالكامل (لا يستورد flutter) ليُختبر بـ golden tests.
/// مبدئي وقابل للتوسعة: يغطّي القوالب التمثيلية السعودية (SAUDI_MARKET_SPEC.md).
class ParserEngine {
  const ParserEngine();

  // ── تعابير الاستخراج ──
  static const String _currencyPattern =
      r'SAR|AED|EGP|KWD|QAR|BHD|OMR|USD|EUR|GBP';
  static final RegExp _amountAfterCurrency = RegExp(
      '(?:$_currencyPattern)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)',
      caseSensitive: false);
  static final RegExp _amountBeforeCurrency = RegExp(
      '([0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?:$_currencyPattern)',
      caseSensitive: false);
  static final RegExp _currency =
      RegExp('(?:$_currencyPattern)', caseSensitive: false);
  static final RegExp _decimalNumber = RegExp(r'([0-9][0-9,]*\.[0-9]{1,2})');
  static final RegExp _last4Star = RegExp(r'\*{2,}\s*([0-9]{4})');
  static final RegExp _last4Ending =
      RegExp(r'(?:ending|تنتهي\s*بـ?)\s*([0-9]{4})', caseSensitive: false);
  static final RegExp _dateTime =
      RegExp(r'([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2}))?');
  static final RegExp _merchant =
      RegExp(r'(?:لدى|At|من|إلى)\s*:?\s*(.+)', caseSensitive: false);

  ParseResult parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    String defaultCurrency = 'SAR',
  }) {
    final text = Normalizer.normalizeCurrencyTokens(
      Normalizer.normalize(rawText),
    );
    final lines = text.split('\n');
    final lower = text.toLowerCase();
    final bank = BankProfiles.detect(
      text,
      senderId: senderId,
      extraProfiles: bankProfiles,
    );

    final type = _detectType(lower);
    final amount = _extractAmount(lines);

    // ليست معاملة مالية واضحة → تُتجاهَل (§24.6).
    if (amount == null && type == TransactionType.unknown) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }
    if (amount == null) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

    final source = _detectSource(lower, bank);
    final merchant = _extractMerchant(lines);
    final currency = _extractCurrency(text) ?? defaultCurrency;
    final last4 = _extractLast4(text);
    final balance = _extractBalance(lines);
    final occurredAt = _extractDate(text);

    final confidence = _confidence(
      amount: amount,
      type: type,
      merchant: merchant,
      date: occurredAt,
    );

    final txn = ParsedTransaction(
      amount: amount,
      currency: currency,
      type: type == TransactionType.unknown ? TransactionType.payment : type,
      source: source,
      rawMerchant: merchant,
      cardLast4: last4,
      balanceAfter: balance,
      occurredAt: occurredAt,
      parseConfidence: confidence,
    );

    return ParseResult.success(txn, bankKey: bank?.bankKey);
  }

  // ── helpers ──

  TransactionType _detectType(String lower) {
    if (_containsAny(lower, ['استرداد', 'رد مبلغ', 'refund', 'reversal'])) {
      return TransactionType.refund;
    }
    if (_containsAny(lower, ['سحب', 'صراف', 'atm'])) {
      return TransactionType.withdrawal;
    }
    if (_containsAny(lower, ['تحويل', 'حوالة', 'transfer'])) {
      return TransactionType.transfer;
    }
    if (_containsAny(lower, ['راتب', 'إيداع', 'ايداع', 'deposit', 'salary'])) {
      return TransactionType.income;
    }
    if (_containsAny(
        lower, ['شراء', 'دفع', 'purchase', 'payment', 'نقاط بيع', 'pos'])) {
      return TransactionType.payment;
    }
    return TransactionType.unknown;
  }

  TransactionSource _detectSource(String lower, BankProfile? bank) {
    if (_containsAny(lower, ['stc pay', 'stcpay', 'محفظة', 'wallet'])) {
      return TransactionSource.wallet;
    }
    if (_containsAny(lower, ['بطاقة', 'مدى', 'mada', 'card', 'ending'])) {
      return TransactionSource.card;
    }
    return bank?.defaultSource ?? TransactionSource.bank;
  }

  double? _extractAmount(List<String> lines) {
    // 1) سطر يحمل وسم "مبلغ"/"amount".
    for (final line in lines) {
      final l = line.toLowerCase();
      if (l.contains('مبلغ') || l.contains('amount')) {
        final v = _numberInLine(line);
        if (v != null) return v;
      }
    }
    // 2) أول سطر فيه عملة وليس رصيداً.
    for (final line in lines) {
      final l = line.toLowerCase();
      if (l.contains('الرصيد') || l.contains('balance')) continue;
      if (_currency.hasMatch(line)) {
        final v = _numberInLine(line);
        if (v != null) return v;
      }
    }
    return null;
  }

  double? _extractBalance(List<String> lines) {
    for (final line in lines) {
      final l = line.toLowerCase();
      if (l.contains('الرصيد') || l.contains('balance')) {
        return _numberInLine(line);
      }
    }
    return null;
  }

  double? _numberInLine(String line) {
    final m = _amountAfterCurrency.firstMatch(line) ??
        _amountBeforeCurrency.firstMatch(line) ??
        _decimalNumber.firstMatch(line);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  String? _extractMerchant(List<String> lines) {
    for (final line in lines) {
      final m = _merchant.firstMatch(line);
      if (m != null) {
        var value = m.group(1)!.trim();
        // تنظيف لاحقات/علامات شائعة.
        value = value.replaceAll(RegExp(r'[.;،]+$'), '').trim();
        if (value.isNotEmpty &&
            !_currency.hasMatch(value) &&
            !value.contains(RegExp(r'^[0-9]'))) {
          return value;
        }
      }
    }
    return null;
  }

  String? _extractCurrency(String text) {
    final m = _currency.firstMatch(text);
    return m?.group(0)?.toUpperCase();
  }

  String? _extractLast4(String text) {
    final m = _last4Star.firstMatch(text) ?? _last4Ending.firstMatch(text);
    return m?.group(1);
  }

  DateTime? _extractDate(String text) {
    final m = _dateTime.firstMatch(text);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = m.group(4) != null ? int.parse(m.group(4)!) : 0;
    final minute = m.group(5) != null ? int.parse(m.group(5)!) : 0;
    return DateTime(year, month, day, hour, minute);
  }

  double _confidence({
    required double? amount,
    required TransactionType type,
    required String? merchant,
    required DateTime? date,
  }) {
    var score = 0.4;
    if (amount != null) score += 0.30;
    if (type != TransactionType.unknown) score += 0.10;
    if (merchant != null) score += 0.10;
    if (date != null) score += 0.10;
    return score.clamp(0.0, 1.0);
  }

  bool _containsAny(String haystack, List<String> needles) =>
      needles.any(haystack.contains);
}
