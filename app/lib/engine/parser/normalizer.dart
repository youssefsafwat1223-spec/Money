/// تطبيع نص الرسالة قبل الاستخراج (خاص بالسوق السعودي + عام).
///
/// المسؤوليات:
/// - تحويل الأرقام العربية/الهندية إلى غربية (٠-٩ و ۰-۹ → 0-9).
/// - إزالة التطويل (ـ) والمسافات الزائدة.
/// - توحيد كلمات ورموز العملات إلى رموز ISO.
class Normalizer {
  Normalizer._();

  // الأرقام العربية-الهندية (U+0660..0669) والممتدة (U+06F0..06F9).
  static const int _arabicIndicZero = 0x0660;
  static const int _extendedArabicIndicZero = 0x06F0;

  /// يحوّل كل الأرقام غير اللاتينية إلى 0-9.
  static String normalizeDigits(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= _arabicIndicZero && rune <= _arabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - _arabicIndicZero));
      } else if (rune >= _extendedArabicIndicZero &&
          rune <= _extendedArabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - _extendedArabicIndicZero));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// توحيد رموز وكلمات العملات إلى رموز ISO.
  static String normalizeCurrencyTokens(String input) {
    return input
        .replaceAll(RegExp(r'ر\.س\.?', caseSensitive: false), 'SAR')
        .replaceAll(RegExp(r'د\.إ\.?', caseSensitive: false), 'AED')
        .replaceAll(RegExp(r'ج\.م\.?', caseSensitive: false), 'EGP')
        .replaceAll('﷼', 'SAR')
        .replaceAll(RegExp(r'ريال\s+سعودي'), 'SAR')
        .replaceAll(RegExp(r'ريال\s+قطري'), 'QAR')
        .replaceAll(RegExp(r'ريال\s+عماني'), 'OMR')
        .replaceAll(RegExp(r'درهم\s+إماراتي|درهم\s+اماراتي|درهم'), 'AED')
        .replaceAll(RegExp(r'جنيه\s+مصري|جنيه'), 'EGP')
        .replaceAll(RegExp(r'دينار\s+كويتي'), 'KWD')
        .replaceAll(RegExp(r'دينار\s+بحريني'), 'BHD')
        .replaceAll(RegExp(r'دولار\s+أمريكي|دولار\s+امريكي|دولار'), 'USD')
        .replaceAll(RegExp(r'ريال'), 'SAR');
  }

  /// التطبيع الكامل: أرقام + تطويل + مسافات (مع الحفاظ على أسطر جديدة).
  static String normalize(String input) {
    var text = normalizeDigits(input);
    text = text.replaceAll('ـ', ''); // إزالة التطويل
    // توحيد المسافات داخل كل سطر دون دمج الأسطر.
    text = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return text.trim();
  }
}
