/// تطبيع نص الرسالة قبل الاستخراج (خاص بالسوق السعودي + عام).
///
/// المسؤوليات:
/// - تحويل الأرقام العربية/الهندية إلى غربية (٠-٩ و ۰-۹ → 0-9).
/// - إزالة التطويل (ـ) والمسافات الزائدة.
/// - توحيد رمز العملة إلى الرمز القياسي SAR.
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

  /// توحيد رموز العملة السعودية إلى "SAR".
  static String normalizeCurrencyTokens(String input) {
    return input
        .replaceAll('ر.س', 'SAR')
        .replaceAll('ر.س.', 'SAR')
        .replaceAll('﷼', 'SAR')
        .replaceAll('ريال', 'SAR');
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
