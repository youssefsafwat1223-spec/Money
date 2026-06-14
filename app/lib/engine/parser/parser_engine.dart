import '../models/parsed_transaction.dart';
import '../models/transaction_source.dart';
import '../models/transaction_type.dart';
import 'amount_candidate.dart';
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
      r'SAR|AED|EGP|KWD|QAR|BHD|OMR|USD|EUR|GBP|TRY|INR|PKR|CAD|AUD|JPY|CNY|CHF|MAD|DZD|TND|JOD|IQD|LBP';
  static final RegExp _currency =
      RegExp('(?:$_currencyPattern)', caseSensitive: false);
  static final RegExp _last4Star = RegExp(r'\*{2,}\s*([0-9]{4})');
  static final RegExp _last4Ending =
      RegExp(r'(?:ending|تنتهي\s*بـ?)\s*([0-9]{4})', caseSensitive: false);
  static final RegExp _dateTime =
      RegExp(r'([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2}))?');
  static final RegExp _merchant = RegExp(
      r'(?:لدى|لدي|At|Merchant|من|إلى|الى)\s*:?\s*(.+)',
      caseSensitive: false);
  static final RegExp _plainNumber =
      RegExp(r'\b([0-9][0-9,]*(?:\.[0-9]{1,2})?)\b');

  static const double pendingThreshold = 0.70;
  static const double genericMaxConfidence = 0.79;

  ParseResult parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    String defaultCurrency = 'SAR',
  }) {
    var text = Normalizer.normalizeCurrencyTokens(
      Normalizer.normalize(rawText),
    );
    final bank = BankProfiles.detect(
      text,
      senderId: senderId,
      extraProfiles: bankProfiles,
    );
    text = _applyCurrencyAliases(text, bank);
    final lines = text.split('\n');
    final lower = text.toLowerCase();

    if (_isIgnored(lower, bank)) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

    final type = _detectType(lower, bank);
    final amountExtraction = _extractAmounts(lines, bank: bank);
    final amount = amountExtraction.transactionAmount;

    // ليست معاملة مالية واضحة → تُتجاهَل (§24.6).
    if (amount == null && type == TransactionType.unknown) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }
    if (amount == null) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

    final source = _detectSource(lower, bank);
    final merchant = _extractMerchant(lines, bank: bank);
    final currency = _extractCurrency(text) ?? defaultCurrency;
    final last4 = _extractLast4(text);
    final balance = amountExtraction.balance;
    final occurredAt = _extractDate(text);

    final confidence = _confidence(
      bank: bank,
      senderMatched: bank?.matchesSender(senderId) ?? false,
      amount: amount,
      type: type,
      currencyResolved: _extractCurrency(text) != null,
      merchant: merchant,
      date: occurredAt,
      ambiguousAmount: amountExtraction.hasAmbiguity,
    );
    if (confidence < pendingThreshold) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

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

  TransactionType _detectType(String lower, BankProfile? bank) {
    if (bank != null) {
      for (final entry in bank.typeRules.entries) {
        if (_containsAny(
            lower, entry.value.map((e) => e.toLowerCase()).toList())) {
          return entry.key;
        }
      }
    }
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

  _AmountExtraction _extractAmounts(
    List<String> lines, {
    required BankProfile? bank,
  }) {
    final candidates = <AmountCandidate>[];
    for (final line in lines) {
      for (final match in _plainNumber.allMatches(line)) {
        final raw = match.group(1)!;
        final parsed = double.tryParse(raw.replaceAll(',', ''));
        if (parsed == null) continue;
        candidates.add(_classifyAmountCandidate(
          line: line,
          raw: raw,
          value: parsed,
          bank: bank,
        ));
      }
    }

    final balanceCandidates =
        candidates.where((c) => c.kind == AmountCandidateKind.balance);
    final balance =
        balanceCandidates.isEmpty ? null : balanceCandidates.first.value;
    final transactionCandidates = candidates
        .where((c) => c.isStrongTransaction)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    if (transactionCandidates.isEmpty) {
      return _AmountExtraction(
        transactionAmount: null,
        balance: balance,
        hasAmbiguity: false,
        candidates: candidates,
      );
    }

    final top = transactionCandidates.first;
    final strongDistinct = transactionCandidates
        .where((c) => (c.value - top.value).abs() > 0.009)
        .where((c) => (top.score - c.score).abs() <= 0.20)
        .isNotEmpty;
    return _AmountExtraction(
      transactionAmount: top.value,
      balance: balance,
      hasAmbiguity: strongDistinct,
      candidates: candidates,
    );
  }

  AmountCandidate _classifyAmountCandidate({
    required String line,
    required String raw,
    required double value,
    required BankProfile? bank,
  }) {
    final l = line.toLowerCase();
    final balanceWords = [
      'الرصيد',
      'رصيد',
      'balance',
      'available',
      ...?bank?.balanceRules.map((item) => item.toLowerCase()),
    ];
    final amountWords = [
      'مبلغ',
      'المبلغ',
      'amount',
      'amt',
      ...?bank?.amountRules.map((item) => item.toLowerCase()),
    ];
    const transactionWords = [
      'شراء',
      'خصم',
      'دفع',
      'سحب',
      'تحويل',
      'purchase',
      'payment',
      'paid',
      'spent',
      'debit',
      'withdrawal',
      'transfer',
      'pos',
    ];
    const referenceWords = [
      'ref',
      'reference',
      'auth',
      'authorization',
      'رقم العملية',
      'مرجع',
      'عملية رقم',
      'otp',
      'رمز',
      'code',
    ];

    if (raw.length == 4 &&
        (l.contains('****') ||
            l.contains('ending') ||
            l.contains('بطاقة') ||
            l.contains('card'))) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.cardLast4,
        score: 1,
      );
    }
    if (_numberBelongsToDate(line, raw)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.dateTime,
        score: 1,
      );
    }
    if (_containsAny(l, referenceWords)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.referenceNumber,
        score: 0.95,
      );
    }
    if (_containsAny(l, balanceWords)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.balance,
        score: 0.95,
      );
    }

    final hasAmountWord = _containsAny(l, amountWords);
    final hasTransactionWord = _containsAny(l, transactionWords);
    final hasCurrency = _currency.hasMatch(line);
    if (hasAmountWord || hasTransactionWord || hasCurrency) {
      var score = 0.55;
      if (hasAmountWord) score += 0.20;
      if (hasTransactionWord) score += 0.15;
      if (hasCurrency) score += 0.10;
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.transactionAmount,
        score: score.clamp(0.0, 1.0),
      );
    }

    return AmountCandidate(
      value: value,
      raw: raw,
      line: line,
      kind: AmountCandidateKind.unknown,
      score: 0.2,
    );
  }

  String? _extractMerchant(List<String> lines, {required BankProfile? bank}) {
    final bankTokens = bank?.merchantRules ?? const <String>[];
    for (final line in lines) {
      final m = _merchant.firstMatch(line);
      if (m != null) {
        final value = _cleanMerchant(m.group(1)!);
        if (value != null) return value;
      }
      for (final token in bankTokens) {
        final idx = line.toLowerCase().indexOf(token.toLowerCase());
        if (idx == -1) continue;
        final value = _cleanMerchant(line.substring(idx + token.length));
        if (value != null) return value;
      }
    }
    return null;
  }

  String? _cleanMerchant(String raw) {
    var value = raw.trim();
    // تنظيف لاحقات/علامات شائعة.
    value = value
        .replaceAll(RegExp(r'\b(?:في|on)\b.*$', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'\b(?:الرصيد|balance|available)\b.*$',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'[.;،]+$'), '')
        .trim();
    if (value.isNotEmpty &&
        !_currency.hasMatch(value) &&
        !value.contains(RegExp(r'^[0-9]'))) {
      return value;
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
    required BankProfile? bank,
    required bool senderMatched,
    required double? amount,
    required TransactionType type,
    required bool currencyResolved,
    required String? merchant,
    required DateTime? date,
    required bool ambiguousAmount,
  }) {
    var score = 0.10;
    if (bank != null) score += 0.15;
    if (senderMatched) score += 0.10;
    if (amount != null) score += 0.25;
    if (type != TransactionType.unknown) score += 0.15;
    if (currencyResolved) score += 0.10;
    if (merchant != null) score += 0.10;
    if (date != null) score += 0.05;
    if (!ambiguousAmount) score += 0.10;
    if (ambiguousAmount) score -= 0.25;
    final capped =
        bank == null ? score.clamp(0.0, genericMaxConfidence) : score;
    return capped.clamp(0.0, 1.0);
  }

  bool _isIgnored(String lower, BankProfile? bank) {
    final ignoreRules = [
      ...?bank?.ignoreRules.map((item) => item.toLowerCase()),
      'otp',
      'one time password',
      'verification code',
      'security code',
      'رمز الدخول',
      'رمز التحقق',
      'كود التحقق',
      'لا تشاركه',
      'عرض خاص',
      'promo',
      'offer',
      'coupon',
    ];
    return _containsAny(lower, ignoreRules);
  }

  String _applyCurrencyAliases(String text, BankProfile? bank) {
    var output = text;
    final aliases = bank?.currencyAliases ?? const <String, String>{};
    for (final entry in aliases.entries) {
      output = output.replaceAll(
        RegExp(RegExp.escape(entry.key), caseSensitive: false),
        entry.value.toUpperCase(),
      );
    }
    return output;
  }

  bool _numberBelongsToDate(String line, String raw) {
    final date = _dateTime.firstMatch(line);
    if (date == null) return false;
    for (var i = 1; i <= date.groupCount; i++) {
      if (date.group(i) == raw) return true;
    }
    return false;
  }

  bool _containsAny(String haystack, List<String> needles) =>
      needles.any(haystack.contains);
}

class _AmountExtraction {
  const _AmountExtraction({
    required this.transactionAmount,
    required this.balance,
    required this.hasAmbiguity,
    required this.candidates,
  });

  final double? transactionAmount;
  final double? balance;
  final bool hasAmbiguity;
  final List<AmountCandidate> candidates;
}
