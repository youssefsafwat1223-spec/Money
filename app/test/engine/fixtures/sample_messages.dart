/// عيّنات رسائل تمثيلية (SAUDI_MARKET_SPEC.md §4) — أساس الـ golden tests.
///
/// ⚠️ هذه قوالب تمثيلية. تُستبدل/تُكمَّل بـ corpus رسائل حقيقية مجهّلة
/// قبل الإطلاق (BUILD_PLAN §1).
class SampleMessages {
  SampleMessages._();

  static const cardPaymentAr = '''
عملية شراء
بطاقة:مدى;****4521
مبلغ:SAR 45.00
لدى:BURGER BOUTIQUE
في:2026-04-08 12:45
الرصيد:SAR 2,310.50''';

  static const cardPaymentEn = '''
Purchase
Card ending 4521
Amount SAR 45.00
At BURGER BOUTIQUE
2026-04-08 12:45''';

  static const atmWithdrawal = '''
سحب نقدي
مبلغ:SAR 500.00
من جهاز الصراف
بطاقة:****4521
الرصيد:SAR 1,810.50''';

  static const transfer = '''
تحويل صادر
مبلغ:SAR 300.00
إلى:MOHAMMED A''';

  static const salaryIncome = '''
إيداع راتب
مبلغ:SAR 9,500.00
الرصيد:SAR 11,310.50''';

  static const refund = '''
استرداد مبلغ
مبلغ:SAR 45.00
من:BURGER BOUTIQUE''';

  static const stcPay = '''
تم الدفع بنجاح
المبلغ: 30.00 ريال
لدى: JARIR
رقم العملية: 123456''';

  // أرقام هندية (تطبيع).
  static const arabicIndicDigits = '''
عملية شراء
مبلغ:SAR ٢٥٠.٧٥
لدى:بنده
في:٢٠٢٦-٠٤-٠٨ ١٤:٣٠''';

  // رسالة غير مالية (يجب تجاهلها).
  static const otpMessage = 'رمز الدخول الخاص بك هو ٤٥٨٩٢١ لا تشاركه مع أحد';

  static const promoMessage =
      'عرض خاص! خصم ٥٠٪ على جميع المنتجات هذا الأسبوع فقط';
}
