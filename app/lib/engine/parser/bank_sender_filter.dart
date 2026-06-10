import 'bank_profile.dart';

/// يحدّد ما إذا كان مرسِل الرسالة بنكاً/محفظة (وليس شخصاً).
///
/// الهدف: لا نقرأ إلا رسائل البنوك. لو حد بعت رسالة شخصية فيها مبلغ،
/// نتجاهلها لأن المرسِل رقم هاتف عادي وليس مُعرّف بنك.
///
/// القاعدة (heuristic، Dart نقي قابل للاختبار):
/// 1) يطابق ملف بنك معروف (senderId أو نص) → بنك.
/// 2) مُعرّف المرسِل اسم نصّي (alphanumeric sender ID مثل "AlRajhi") وليس
///    رقم هاتف شخصي → بنك.
/// 3) رقم هاتف شخصي → ليس بنكاً (يُتجاهَل).
class BankSenderFilter {
  BankSenderFilter._();

  static final RegExp _phoneLike = RegExp(r'^\+?[0-9][0-9\s\-()]{5,}$');
  static final RegExp _hasLetters = RegExp(r'[A-Za-z؀-ۿ]');

  static bool isLikelyBank(String? senderId, {String? text}) {
    // مصدر يدوي/مشاركة (بلا مُرسِل) → المستخدم اختاره بنفسه، نسمح به.
    if (senderId == null || senderId.trim().isEmpty) return true;

    final id = senderId.trim();

    // بنك معروف عبر المُعرّف أو النص.
    if (BankProfiles.detect(text ?? '', senderId: id) != null) return true;

    final isPhone = _phoneLike.hasMatch(id);
    final hasLetters = _hasLetters.hasMatch(id);

    // اسم مُرسِل أبجدي (علامة/بنك) وليس رقم هاتف → نقبله.
    return hasLetters && !isPhone;
  }
}
