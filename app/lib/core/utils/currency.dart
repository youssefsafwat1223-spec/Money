import 'package:flutter/widgets.dart';

import 'formatters.dart';

/// مصدر واحد لاسم/رمز العملة وتنسيق المبالغ — يمنع تضارب «ريال/جنيه» الثابتة.
class Currency {
  Currency._();

  /// الاسم العربي المختصر للعملة حسب رمز ISO. يغطّي كل الدول المدعومة.
  static String arabicLabel(String code) => switch (code.toUpperCase()) {
        'SAR' => 'ريال',
        'AED' => 'درهم',
        'EGP' => 'جنيه',
        'KWD' => 'دينار',
        'QAR' => 'ريال قطري',
        'BHD' => 'دينار بحريني',
        'OMR' => 'ريال عماني',
        'JOD' => 'دينار أردني',
        'ILS' => 'شيكل',
        'LBP' => 'ليرة لبنانية',
        'LYD' => 'دينار ليبي',
        'SYP' => 'ليرة سورية',
        'MAD' => 'درهم مغربي',
        'MRU' => 'أوقية',
        'DZD' => 'دينار جزائري',
        'TND' => 'دينار تونسي',
        'SDG' => 'جنيه سوداني',
        'IQD' => 'دينار عراقي',
        'YER' => 'ريال يمني',
        'SOS' => 'شلن صومالي',
        'DJF' => 'فرنك جيبوتي',
        'KMF' => 'فرنك قمري',
        'TRY' => 'ليرة تركية',
        'USD' => 'دولار',
        'EUR' => 'يورو',
        'GBP' => 'جنيه إسترليني',
        'INR' => 'روبية',
        'PKR' => 'روبية باكستانية',
        'BDT' => 'تاكا',
        'PHP' => 'بيزو',
        'IDR' => 'روبية إندونيسية',
        'MYR' => 'رينغيت',
        'SGD' => 'دولار سنغافوري',
        'NGN' => 'نايرا',
        'KES' => 'شلن كيني',
        'ZAR' => 'راند',
        'ETB' => 'بير',
        'GHS' => 'سيدي',
        'UGX' => 'شلن أوغندي',
        'TZS' => 'شلن تنزاني',
        _ => code.toUpperCase(),
      };

  /// "1,240.00 ريال"
  static String money(double amount, String code) =>
      '${Formatters.amount(amount)} ${arabicLabel(code)}';

  /// "1,240 ريال" (بدون كسور)
  static String moneyInt(num amount, String code) =>
      '${Formatters.integer(amount)} ${arabicLabel(code)}';

  /// The English label is the ISO code itself. Deliberate: "ريال" is ambiguous
  /// across SAR/QAR/OMR/YER in a way "SAR" is not, and an English-locale user
  /// reading a multi-currency ledger needs the code, not a translated noun.
  static String englishLabel(String code) => code.toUpperCase();

  /// Locale-aware label for callers with no element tree — providers,
  /// background isolates, report composition.
  static String labelFor(String code, String languageCode) =>
      languageCode == 'en' ? englishLabel(code) : arabicLabel(code);

  /// Locale-aware label. Mirrors `Formatters`' context-taking API so money
  /// reads in the same language as everything around it.
  /// "«ريال» (SAR)" in Arabic, "SAR" in English.
  ///
  /// The account list wrote `'\${label} (\$code)'` by hand. In Arabic that
  /// reads naturally — a familiar name plus the ISO code. In English
  /// [englishLabel] IS the code, so it rendered "SAR (SAR)": the same token
  /// twice, which looks like a bug to the reader because it is one.
  ///
  /// Collapsing when the two are equal keeps the Arabic exactly as it was and
  /// fixes English everywhere, including at call sites that do not exist yet.
  static String labelWithCode(BuildContext context, String code) {
    final name = label(context, code);
    final upper = code.toUpperCase();
    return name == upper ? upper : '$name ($upper)';
  }

  static String label(BuildContext context, String code) =>
      labelFor(code, Localizations.localeOf(context).languageCode);

  /// "1,240.00 SAR" / "1,240.00 ريال"
  static String moneyIn(BuildContext context, double amount, String code) =>
      '${Formatters.amount(amount)} ${label(context, code)}';

  /// "1,240 SAR" / "1,240 ريال"
  static String moneyIntIn(BuildContext context, num amount, String code) =>
      '${Formatters.integer(amount)} ${label(context, code)}';
}
