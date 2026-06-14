import '../models/transaction_source.dart';
import '../models/transaction_type.dart';

/// ملف تعريف بنك/محفظة (P0 للسوق السعودي).
///
/// هذا هيكل مبدئي: الكشف عبر كلمات مفتاحية في النص أو معرّف المرسِل.
/// Codex يوسّعه بقواعد regex لكل بنك من SAUDI_MARKET_SPEC.md وبقاعدة
/// بيانات `parsing_rules` القابلة للتحديث عن بُعد.
class BankProfile {
  const BankProfile({
    required this.bankKey,
    required this.displayName,
    required this.keywords,
    this.country,
    this.locale,
    this.senderIds = const [],
    this.currencyAliases = const {},
    this.ignoreRules = const [],
    this.typeRules = const {},
    this.amountRules = const [],
    this.balanceRules = const [],
    this.merchantRules = const [],
    this.dateRules = const [],
    this.version = 1,
    this.defaultSource = TransactionSource.bank,
  });

  final String bankKey;
  final String displayName;
  final List<String> keywords;
  final String? country;
  final String? locale;
  final List<String> senderIds;
  final Map<String, String> currencyAliases;
  final List<String> ignoreRules;
  final Map<TransactionType, List<String>> typeRules;
  final List<String> amountRules;
  final List<String> balanceRules;
  final List<String> merchantRules;
  final List<String> dateRules;
  final int version;
  final TransactionSource defaultSource;

  bool matchesSender(String? senderId) {
    final sender = senderId?.trim().toLowerCase();
    if (sender == null || sender.isEmpty) return false;
    return [...senderIds, ...keywords]
        .any((item) => sender.contains(item.toLowerCase()));
  }
}

/// سجل البنوك المدعومة في الـ MVP (السعودية — P0).
class BankProfiles {
  BankProfiles._();

  static const List<BankProfile> all = [
    BankProfile(
      bankKey: 'snb',
      displayName: 'الأهلي السعودي',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['snb', 'alahli', 'al ahli'],
      keywords: ['الأهلي', 'snb', 'الاهلي'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'alrajhi',
      displayName: 'الراجحي',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['rajhi', 'alrajhi'],
      keywords: ['الراجحي', 'rajhi'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'riyad',
      displayName: 'بنك الرياض',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['riyad'],
      keywords: ['الرياض', 'riyad'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'stcpay',
      displayName: 'STC Pay',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['stcpay', 'stc pay'],
      keywords: ['stc pay', 'stcpay', 'stc'],
      amountRules: ['المبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance'],
      merchantRules: ['لدى', 'at'],
      defaultSource: TransactionSource.wallet,
    ),
  ];

  /// كشف البنك من معرّف المرسِل أو نص الرسالة (best-effort).
  static BankProfile? detect(
    String normalizedText, {
    String? senderId,
    List<BankProfile> extraProfiles = const [],
  }) {
    final haystack = '${senderId ?? ''} $normalizedText'.toLowerCase();
    for (final profile in [...extraProfiles, ...all]) {
      for (final kw in [...profile.senderIds, ...profile.keywords]) {
        if (haystack.contains(kw.toLowerCase())) return profile;
      }
    }
    return null;
  }
}
