import '../models/transaction_source.dart';

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
    this.defaultSource = TransactionSource.bank,
  });

  final String bankKey;
  final String displayName;
  final List<String> keywords;
  final TransactionSource defaultSource;
}

/// سجل البنوك المدعومة في الـ MVP (السعودية — P0).
class BankProfiles {
  BankProfiles._();

  static const List<BankProfile> all = [
    BankProfile(
      bankKey: 'snb',
      displayName: 'الأهلي السعودي',
      keywords: ['الأهلي', 'snb', 'الاهلي'],
    ),
    BankProfile(
      bankKey: 'alrajhi',
      displayName: 'الراجحي',
      keywords: ['الراجحي', 'rajhi'],
    ),
    BankProfile(
      bankKey: 'riyad',
      displayName: 'بنك الرياض',
      keywords: ['الرياض', 'riyad'],
    ),
    BankProfile(
      bankKey: 'stcpay',
      displayName: 'STC Pay',
      keywords: ['stc pay', 'stcpay', 'stc'],
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
      for (final kw in profile.keywords) {
        if (haystack.contains(kw.toLowerCase())) return profile;
      }
    }
    return null;
  }
}
